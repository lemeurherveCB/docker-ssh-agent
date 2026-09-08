# nanoserver:ltsc2025 ships with an empty LSA Primary Domain name, causing
# LogonUser / S4U token creation to fail with STATUS_NO_SUCH_DOMAIN (0xC00000DF).
# LsaSetInformationPolicy is a silent no-op on this image (HKLM\SECURITY has no
# backing store). The fix writes the "WORKGROUP" LSA_UNICODE_STRING blob directly
# to HKLM\SECURITY\Policy\PolPrDmN and PolDnDDN as SYSTEM (required for access).
# This script bootstraps itself as SYSTEM via a throwaway service if needed.
# Ref: https://github.com/microsoft/Windows-Containers/issues/640

# "WORKGROUP" as stored in HKLM\SECURITY\Policy\PolPrDmN / PolDnDDN (REG_NONE):
# [UInt16 Length=18][UInt16 MaxLen=20][UInt32 Offset=8]["WORKGROUP" UTF-16LE][NUL]
$blob = [byte[]] @(
    0x12, 0x00, 0x14, 0x00, 0x08, 0x00, 0x00, 0x00,
    0x57, 0x00, 0x4F, 0x00, 0x52, 0x00, 0x4B, 0x00,
    0x47, 0x00, 0x52, 0x00, 0x4F, 0x00, 0x55, 0x00,
    0x50, 0x00, 0x00, 0x00
)

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

# Running as SYSTEM — nanoserver:ltsc2025 is missing these keys entirely
# (HKLM\SECURITY\Policy itself does exist), so create them before writing.
foreach ($key in @('HKLM:\SECURITY\Policy\PolPrDmN', 'HKLM:\SECURITY\Policy\PolDnDDN')) {
    if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
    Set-ItemProperty -Path $key -Name '(Default)' -Value $blob -Type None -Force
}

# Verify
$raw  = (Get-ItemProperty -Path 'HKLM:\SECURITY\Policy\PolPrDmN').'(Default)'
$name = [Text.Encoding]::Unicode.GetString($raw, 8, [BitConverter]::ToUInt16($raw, 0))
if ($name -ne 'WORKGROUP') { throw "SetPrimaryDomain: unexpected value after write: '$name'" }
Write-Host "LSA Primary Domain set to WORKGROUP"
