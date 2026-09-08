function Test-CommandExists($command) {
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'stop'
    $res = $false
    try {
        if(Get-Command $command) {
            $res = $true
        }
    } catch {
        $res = $false
    } finally {
        $ErrorActionPreference=$oldPreference
    }
    return $res
}

# check dependencies
if(-Not (Test-CommandExists docker)) {
    Write-Error 'docker is not available'
}

function Get-EnvOrDefault($name, $def) {
    $entry = Get-ChildItem env: | Where-Object { $_.Name -eq $name } | Select-Object -First 1
    if(($null -ne $entry) -and ![System.String]::IsNullOrWhiteSpace($entry.Value)) {
        return $entry.Value
    }
    return $def
}

function Retry-Command {
    [CmdletBinding()]
    param (
        [parameter(Mandatory, ValueFromPipeline)]
        [ValidateNotNullOrEmpty()]
        [scriptblock] $ScriptBlock,
        [int] $RetryCount = 3,
        [int] $Delay = 30,
        [string] $SuccessMessage = 'Command executed successfuly!',
        [string] $FailureMessage = 'Failed to execute the command'
        )

    process {
        $Attempt = 1
        $Flag = $true

        do {
            try {
                $PreviousPreference = $ErrorActionPreference
                $ErrorActionPreference = 'Stop'
                Invoke-Command -NoNewScope -ScriptBlock $ScriptBlock -OutVariable Result 4>&1
                $ErrorActionPreference = $PreviousPreference

                # flow control will execute the next line only if the command in the scriptblock executed without any errors
                # if an error is thrown, flow control will go to the 'catch' block
                Write-Verbose "$SuccessMessage `n"
                $Flag = $false
            }
            catch {
                if ($Attempt -gt $RetryCount) {
                    Write-Verbose "$FailureMessage! Total retry attempts: $RetryCount"
                    Write-Verbose "[Error Message] $($_.exception.message) `n"
                    $Flag = $false
                } else {
                    Write-Verbose "[$Attempt/$RetryCount] $FailureMessage. Retrying in $Delay seconds..."
                    Start-Sleep -Seconds $Delay
                    $Attempt = $Attempt + 1
                }
            }
        }
        While ($Flag)
    }
}

function Cleanup($name='') {
    if([System.String]::IsNullOrWhiteSpace($name)) {
        $name = Get-EnvOrDefault 'IMAGE_NAME' ''
    }

    if(![System.String]::IsNullOrWhiteSpace($name)) {
        # Ignore "no such container" — this is a best-effort pre-test cleanup
        try { docker kill "$name" 2>&1 | Out-Null } catch {}
        try { docker rm -fv "$name" 2>&1 | Out-Null } catch {}
    }
}

function CleanupNetwork($name) {
    docker network rm $name 2>&1 | Out-Null
}

function Is-ContainerRunning($container) {
    Start-Sleep -Seconds 5
    return Retry-Command -RetryCount 10 -Delay 2 -ScriptBlock {
        $exitCode, $stdout, $stderr = Run-Program 'docker.exe' "inspect --format `"{{.State.Running}}`" $container"
        if(($exitCode -ne 0) -or (-not $stdout.Contains('true')) ) {
            throw('Exit code incorrect, or invalid value for running state')
        }
        return $true
    }
}

function Run-Program($cmd, $params, [int]$timeoutMs = 120000) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.CreateNoWindow = $true
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.WorkingDirectory = (Get-Location)
    $psi.FileName = $cmd
    $psi.Arguments = $params
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()
    # Async reads avoid stdout/stderr pipe deadlock when both streams produce output
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit($timeoutMs)) {
        Write-Host -ForegroundColor DarkYellow "[timeout] $cmd $params (killed after ${timeoutMs}ms)"
        $proc.Kill()
        $proc.WaitForExit()
    }
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    if(($env:TESTS_DEBUG -eq 'debug') -or ($env:TESTS_DEBUG -eq 'verbose') -or ($proc.ExitCode -ne 0)) {
        Write-Host -ForegroundColor DarkBlue "[cmd] $cmd $params"
        if ($env:TESTS_DEBUG -ne 'debug') { Write-Host -ForegroundColor DarkGray "[stdout] $stdout" }
        if ($proc.ExitCode -ne 0) {
            Write-Host -ForegroundColor DarkRed "[stderr] $stderr"
        }
    }
    return $proc.ExitCode, $stdout, $stderr
}

# return the published port for given container port $1
function Get-Port($container, $port=22) {
    $exitCode, $stdout, $stderr = Run-Program 'docker.exe' "port $container $port"
    return ($stdout -split ":" | Select-Object -Skip 1).Trim()
}

# run a given command through ssh on the test container.
function Run-ThruSSH($container, $privateKeyVal, $cmd) {
    $SSH_PORT = Get-Port $container 22
    if([System.String]::IsNullOrWhiteSpace($SSH_PORT)) {
        Write-Error 'Failed to get SSH port'
        return -1, $null, $null
    } else {
        $TMP_PRIV_KEY_FILE = New-TemporaryFile
        Set-Content -Path $TMP_PRIV_KEY_FILE -Value "$privateKeyVal"
        icacls.exe $TMP_PRIV_KEY_FILE /inheritance:r /grant:r "${env:USERNAME}:(R)" | Out-Null

        $exitCode, $stdout, $stderr = Run-Program 'ssh.exe' "-4 -v -i `"${TMP_PRIV_KEY_FILE}`" -o LogLevel=quiet -o UserKnownHostsFile=NUL -o StrictHostKeyChecking=no -o ConnectTimeout=30 -o BatchMode=yes -o ServerAliveInterval=10 -o ServerAliveCountMax=3 -l jenkins 127.0.0.1 -p $SSH_PORT $cmd" 120000
        Remove-Item -Force $TMP_PRIV_KEY_FILE

        return $exitCode, $stdout, $stderr
    }
}
