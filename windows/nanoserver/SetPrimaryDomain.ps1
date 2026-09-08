# nanoserver:ltsc2025 ships with an empty LSA Primary Domain name, causing
# LogonUser / S4U token creation to fail with STATUS_NO_SUCH_DOMAIN (0xC00000DF).
# Fix: call LsaSetInformationPolicy(PolicyPrimaryDomainInformation, "WORKGROUP") via
# P/Invoke to update lsass in-memory state. Registry write (PolPrDmN) is kept as
# belt-and-suspenders for code paths that read the hive directly.
# HKLM\SECURITY is a volatile hive — both writes are discarded on Docker layer commit,
# so this script must run at container START TIME (invoked from setup-sshd.ps1).
# Requires SYSTEM; bootstraps via a throwaway service if running as a lesser account.
# Ref: https://github.com/microsoft/Windows-Containers/issues/640

$ErrorActionPreference = 'Stop'

$isSystem = ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq 'S-1-5-18')

if (-not $isSystem) {
    # Re-launch as SYSTEM: create a service whose binary is cmd.exe /c start "" /b <cmd>
    # The outer cmd.exe exits immediately (SCM gets 1053) but the detached grandchild
    # runs as NT AUTHORITY\SYSTEM and completes the registry write.
    $self     = $MyInvocation.MyCommand.Path
    $doneFile = "$self.done"
    $logFile  = "$self.log"
    $cmdFile  = ($self -replace '\.ps1$', '-sys.cmd')
    # nanoserver has no powershell.exe (Windows PowerShell); re-use the host we run under.
    $shell    = (Get-Process -Id $PID).Path
    Set-Content -Path $cmdFile -Encoding ASCII -Value (
        "@echo off`r`n" +
        "`"$shell`" -NoProfile -File `"$self`" > `"$logFile`" 2>&1`r`n" +
        "echo %ERRORLEVEL% > `"$doneFile`"`r`n"
    )
    sc.exe create __sysrun binPath= "cmd.exe /c start `"`" /b `"$cmdFile`"" | Out-Null
    sc.exe start  __sysrun | Out-Null
    sc.exe delete __sysrun | Out-Null

    $deadline = [datetime]::UtcNow.AddSeconds(60)
    while (-not (Test-Path $doneFile) -and [datetime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 500
    }
    if (-not (Test-Path $doneFile)) {
        if (Test-Path $logFile) { Write-Host "--- SYSTEM run log ---"; Get-Content $logFile | Write-Host }
        throw 'SetPrimaryDomain: SYSTEM bootstrap timed out after 60s'
    }
    $rc = (Get-Content $doneFile -Raw).Trim()
    if (Test-Path $logFile) { Get-Content $logFile | Write-Host }
    Remove-Item $doneFile, $cmdFile, $logFile -Force -ErrorAction SilentlyContinue
    if ($rc -ne '0') { throw "SetPrimaryDomain: SYSTEM run failed with exit code $rc" }
    return
}

# Running as SYSTEM

# Update lsass in-memory state via LsaSetInformationPolicy (class 3 = PolicyPrimaryDomainInformation).
# Access mask: POLICY_VIEW_LOCAL_INFORMATION (0x1) | POLICY_TRUST_ADMIN (0x8) = 0x9.
# Without POLICY_TRUST_ADMIN, LsaSetInformationPolicy returns STATUS_ACCESS_DENIED.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

[StructLayout(LayoutKind.Sequential)]
public struct LSA_UNICODE_STRING {
    public ushort Length;
    public ushort MaximumLength;
    public IntPtr Buffer;
}

[StructLayout(LayoutKind.Sequential)]
public struct LSA_OBJECT_ATTRIBUTES {
    public int    Length;
    public IntPtr RootDirectory;
    public IntPtr ObjectName;
    public uint   Attributes;
    public IntPtr SecurityDescriptor;
    public IntPtr SecurityQualityOfService;
}

[StructLayout(LayoutKind.Sequential)]
public struct POLICY_DOMAIN_INFO {
    public LSA_UNICODE_STRING Name;
    public IntPtr             Sid;
}

public static class Lsa {
    [DllImport("advapi32.dll")]
    public static extern uint LsaOpenPolicy(IntPtr sn, ref LSA_OBJECT_ATTRIBUTES oa, uint access, out IntPtr h);
    [DllImport("advapi32.dll")]
    public static extern uint LsaSetInformationPolicy(IntPtr h, int cls, ref POLICY_DOMAIN_INFO info);
    [DllImport("advapi32.dll")]
    public static extern uint LsaClose(IntPtr h);
    [DllImport("advapi32.dll")]
    public static extern int  LsaNtStatusToWinError(uint s);
}
'@

$M  = [System.Runtime.InteropServices.Marshal]
$oa = New-Object LSA_OBJECT_ATTRIBUTES
$oa.Length = $M::SizeOf([type]'LSA_OBJECT_ATTRIBUTES')
$h  = [IntPtr]::Zero
$st = [Lsa]::LsaOpenPolicy([IntPtr]::Zero, [ref]$oa, 0x9, [ref]$h)
if ($st -ne 0) {
    Write-Warning ("LsaOpenPolicy NTSTATUS 0x{0:X8} (Win32 {1})" -f $st, [Lsa]::LsaNtStatusToWinError($st))
} else {
    $nameBuf = $M::StringToHGlobalUni('WORKGROUP')
    $info    = New-Object POLICY_DOMAIN_INFO
    $u       = New-Object LSA_UNICODE_STRING
    $u.Buffer = $nameBuf
    $u.Length        = 18  # 'WORKGROUP'.Length * 2 = 18
    $u.MaximumLength = 20  # +2 for null terminator
    $info.Name = $u
    $info.Sid  = [IntPtr]::Zero
    $st2 = [Lsa]::LsaSetInformationPolicy($h, 3, [ref]$info)
    $M::FreeHGlobal($nameBuf)
    [Lsa]::LsaClose($h) | Out-Null
    if ($st2 -ne 0) {
        Write-Warning ("LsaSetInformationPolicy NTSTATUS 0x{0:X8} (Win32 {1})" -f $st2, [Lsa]::LsaNtStatusToWinError($st2))
    }
}

# Belt-and-suspenders: also write PolPrDmN and PolDnDDN registry keys directly.
# "WORKGROUP" as LSA_UNICODE_STRING blob (REG_NONE):
# [UInt16 Length=18][UInt16 MaxLen=20][UInt32 Offset=8]["WORKGROUP" UTF-16LE][NUL]
$blob = [byte[]] @(
    0x12, 0x00, 0x14, 0x00, 0x08, 0x00, 0x00, 0x00,
    0x57, 0x00, 0x4F, 0x00, 0x52, 0x00, 0x4B, 0x00,
    0x47, 0x00, 0x52, 0x00, 0x4F, 0x00, 0x55, 0x00,
    0x50, 0x00, 0x00, 0x00
)
foreach ($key in @('HKLM:\SECURITY\Policy\PolPrDmN', 'HKLM:\SECURITY\Policy\PolDnDDN')) {
    if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
    Set-ItemProperty -Path $key -Name '(Default)' -Value $blob -Type None -Force
}

# Verify (registry read confirms the SYSTEM write succeeded)
$raw  = (Get-ItemProperty -Path 'HKLM:\SECURITY\Policy\PolPrDmN').'(Default)'
$name = [Text.Encoding]::Unicode.GetString($raw, 8, [BitConverter]::ToUInt16($raw, 0))
if ($name -ne 'WORKGROUP') { throw "SetPrimaryDomain: unexpected registry value after write: '$name'" }
Write-Host "LSA Primary Domain set to WORKGROUP"
