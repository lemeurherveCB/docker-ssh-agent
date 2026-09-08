Import-Module -DisableNameChecking -Force $PSScriptRoot/test_helpers.psm1

$global:IMAGE_NAME = Get-EnvOrDefault 'IMAGE_NAME' '' # Ex: jenkins4eval/ssh-agent:nanoserver-ltsc2022-jdk25

Write-Host "= TESTS: Preparing $global:IMAGE_NAME"

$imageItems = $global:IMAGE_NAME.Split(':')
$global:IMAGE_TAG = $imageItems[1]

$items = $global:IMAGE_TAG.Split('-')
# Remove the 'jdk' prefix
$global:JAVARELEASE = $items[2].Remove(0,3)
$global:WINDOWSFLAVOR = $items[0]
$global:WINDOWSVERSIONTAG = $items[1]

# TODO: make this name unique for concurency
$global:CONTAINERNAME = 'pester-jenkins-ssh-agent-{0}' -f $global:IMAGE_TAG

$global:CONTAINERSHELL = 'powershell.exe'
if($global:WINDOWSFLAVOR -eq 'nanoserver') {
    $global:CONTAINERSHELL = 'pwsh.exe'
}

$global:PUBLIC_SSH_KEY = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE/i37TqJWMPfqjtyzRsHH/KocA8jt7bz4i4nCtTlTQY jenkins-test-key'
$global:PRIVATE_SSH_KEY = @"
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACBP4t+06iVjD36o7cs0bBx/yqHAPI7e28+IuJwrU5U0GAAAAJjRFwYr0RcG
KwAAAAtzc2gtZWQyNTUxOQAAACBP4t+06iVjD36o7cs0bBx/yqHAPI7e28+IuJwrU5U0GA
AAAEApPBumA8YhlbXVHc1zMH7deg/ZYKeh1Ira5BQhtmKqOU/i37TqJWMPfqjtyzRsHH/K
ocA8jt7bz4i4nCtTlTQYAAAAEGplbmtpbnMtdGVzdC1rZXkBAgMEBQ==
-----END OPENSSH PRIVATE KEY-----
"@

$global:GITLFSVERSION = '3.8.0'
$global:PWSHVERSION = '7.6.5'

Cleanup($global:CONTAINERNAME)

Describe "[$global:IMAGE_TAG] image has setup-sshd.ps1 in the correct location" {
    BeforeAll {
        $exitCode, $stdout, $stderr = Run-Program 'docker' "run --detach --tty --name=`"$global:CONTAINERNAME`" --publish-all `"$global:IMAGE_NAME`" `"$global:CONTAINERSHELL`""
        $exitCode | Should -Be 0
        Is-ContainerRunning $global:CONTAINERNAME | Should -BeTrue
    }

    It 'has setup-sshd.ps1 in C:/ProgramData/Jenkins' {
        $exitCode, $stdout, $stderr = Run-Program 'docker' "exec $global:CONTAINERNAME $global:CONTAINERSHELL -C `"if(Test-Path C:/ProgramData/Jenkins/setup-sshd.ps1) { exit 0 } else { exit 1}`""
        $exitCode | Should -Be 0
    }

    AfterAll {
        Cleanup($global:CONTAINERNAME)
    }
}

Describe "[$global:IMAGE_TAG] image has no pre-existing SSH host keys" {
    BeforeAll {
        $exitCode, $stdout, $stderr = Run-Program 'docker' "run --detach --tty --name=`"$global:CONTAINERNAME`" --publish-all `"$global:IMAGE_NAME`" `"$global:CONTAINERSHELL`""
        $exitCode | Should -Be 0
        Is-ContainerRunning $global:CONTAINERNAME | Should -BeTrue
    }

    It 'has has no SSH host key present in C:\ProgramData\ssh' {
        $exitCode, $stdout, $stderr = Run-Program 'docker' "exec $global:CONTAINERNAME $global:CONTAINERSHELL -C `"if(Test-Path C:/ProgramData/ssh/ssh_host*_key*) { exit 0 } else { exit 1 }`""
        $exitCode | Should -Be 1
    }

    AfterAll {
        Cleanup($global:CONTAINERNAME)
    }
}

Describe "[$global:IMAGE_TAG] checking image metadata" {
    It 'has correct volumes' {
        $exitCode, $stdout, $stderr = Run-Program 'docker' "inspect --format '{{.Config.Volumes}}' $global:IMAGE_NAME"
        $exitCode | Should -Be 0

        $stdout | Should -Match 'C:/Users/jenkins/AppData/Local/Temp'
        $stdout | Should -Match 'C:/Users/jenkins/Work'
    }

    It 'has the source GitHub URL in docker metadata' {
        $exitCode, $stdout, $stderr = Run-Program 'docker' "inspect --format=`"{{index .Config.Labels \`"org.opencontainers.image.source\`"}}`" $global:IMAGE_NAME"
        $exitCode | Should -Be 0
        $stdout.Trim() | Should -Match 'https://github.com/jenkinsci/docker-ssh-agent'
    }
}

Describe "[$global:IMAGE_TAG] image has expected tools versions installed and in the PATH" {
    BeforeAll {
        $exitCode, $stdout, $stderr = Run-Program 'docker' "run --detach --tty --name=`"$global:CONTAINERNAME`" --publish-all `"$global:IMAGE_NAME`" `"$global:PUBLIC_SSH_KEY`""
        $exitCode | Should -Be 0
        Is-ContainerRunning $global:CONTAINERNAME
    }

    It 'has expected java installed and in the path' {
        $exitCode, $stdout, $stderr = Run-Program 'docker' "exec $global:CONTAINERNAME $global:CONTAINERSHELL -C `"if(`$null -eq (Get-Command java.exe -ErrorAction SilentlyContinue)) { exit -1 } else { exit 0 }`""
        $exitCode | Should -Be 0

        $exitCode, $stdout, $stderr = Run-Program 'docker' "exec $global:CONTAINERNAME $global:CONTAINERSHELL -C `"`$version = java -version 2>&1 ; Write-Host `$version`""
        $stdout.Trim() | Should -Match "^openjdk version `"$global:JAVARELEASE"
    }

    It 'has expected git-lfs (and thus git) installed and in the path' {
        $exitCode, $stdout, $stderr = Run-Program 'docker' "exec $global:CONTAINERNAME $global:CONTAINERSHELL -C `"`& git lfs env`""
        $exitCode | Should -Be 0
        $stdout.Trim() | Should -Match "^git-lfs/$([regex]::Escape($global:GITLFSVERSION))"
    }

    if ($global:WINDOWSFLAVOR -eq 'nanoserver') {
        It 'has expected pwsh installed and in the path' {
            $exitCode, $stdout, $stderr = Run-Program 'docker' "exec $global:CONTAINERNAME $global:CONTAINERSHELL -C `"`$PSVersionTable.PSVersion.ToString()`""
            $exitCode | Should -Be 0
            $stdout.Trim() | Should -Match "^$([regex]::Escape($global:PWSHVERSION))"
        }
    }

    AfterAll {
        Cleanup($global:CONTAINERNAME)
    }
}

Describe "[$global:IMAGE_TAG] create agent container with pubkey as argument" {
    BeforeAll {
        $exitCode, $stdout, $stderr = Run-Program 'docker' "run --detach --tty --name=`"$global:CONTAINERNAME`" --publish-all `"$global:IMAGE_NAME`" `"$global:PUBLIC_SSH_KEY`""
        $exitCode | Should -Be 0
        Is-ContainerRunning $global:CONTAINERNAME | Should -BeTrue
    }

    It 'runs commands via ssh, container with pubkey as argument' {
        $exitCode, $stdout, $stderr = Run-ThruSSH $global:CONTAINERNAME "$global:PRIVATE_SSH_KEY" "$global:CONTAINERSHELL -NoLogo -C `"Write-Host 'f00'`""
        $exitCode | Should -Be 0
        $stdout | Should -Match 'f00'
    }

    AfterAll {
        Cleanup($global:CONTAINERNAME)
    }
}

Describe "[$global:IMAGE_TAG] create agent container with pubkey as envvar" {
    BeforeAll {
        $exitCode, $stdout, $stderr = Run-Program 'docker' "run --detach --tty --name=`"$global:CONTAINERNAME`" --publish-all `"$global:IMAGE_NAME`" `"$global:PUBLIC_SSH_KEY`""
        $exitCode | Should -Be 0
        Is-ContainerRunning $global:CONTAINERNAME | Should -BeTrue
    }

    It 'runs commands via ssh, container with pubkey as envvar' {
        $exitCode, $stdout, $stderr = Run-ThruSSH $global:CONTAINERNAME "$global:PRIVATE_SSH_KEY" "$global:CONTAINERSHELL -NoLogo -C `"Write-Host 'f00'`""
        $exitCode | Should -Be 0
        $stdout | Should -Match 'f00'
    }

    AfterAll {
        Cleanup($global:CONTAINERNAME)
    }
}


$global:DOCKER_PLUGIN_DEFAULT_ARG="/usr/sbin/sshd -D -p 22"
Describe "[$global:IMAGE_TAG] create agent container like docker-plugin with '$global:DOCKER_PLUGIN_DEFAULT_ARG' as argument" {
    BeforeAll {
        [string]::IsNullOrWhiteSpace($global:DOCKER_PLUGIN_DEFAULT_ARG) | Should -BeFalse
        $exitCode, $stdout, $stderr = Run-Program 'docker' "run --detach --tty --name=`"$global:CONTAINERNAME`" --publish-all --env=`"JENKINS_AGENT_SSH_PUBKEY=$global:PUBLIC_SSH_KEY`" `"$global:IMAGE_NAME`" `"$global:DOCKER_PLUGIN_DEFAULT_ARG`""
        $exitCode | Should -Be 0
        Is-ContainerRunning $global:CONTAINERNAME | Should -BeTrue
    }

    It 'runs commands via ssh, container like docker-plugin' {
        $exitCode, $stdout, $stderr = Run-ThruSSH $global:CONTAINERNAME "$global:PRIVATE_SSH_KEY" "$global:CONTAINERSHELL -NoLogo -C `"Write-Host 'f00'`""
        $exitCode | Should -Be 0
        $stdout | Should -Match 'f00'
    }

    AfterAll {
        Cleanup($global:CONTAINERNAME)
    }
}

Describe "[$global:IMAGE_TAG] image can be built" {
    BeforeAll {
        Push-Location -StackName 'build-test' -Path "$PSScriptRoot/.."
    }

    It 'builds image' {
        $exitCode, $stdout, $stderr = Run-Program 'docker' "build --build-arg `"WINDOWS_VERSION_TAG=${global:WINDOWSVERSIONTAG}`" --build-arg `"JAVA_RELEASE=${global:JAVARELEASE}`" --tag=${global:IMAGE_TAG} --file ./windows/${global:WINDOWSFLAVOR}/Dockerfile ." 1800000
        $exitCode | Should -Be 0
    }

    AfterAll {
        Run-Program 'docker' "rmi -f $($global:IMAGE_TAG)" 60000 | Out-Null
        Pop-Location -StackName 'build-test'
    }
}

Describe "[$global:IMAGE_TAG] image can be built with custom build args" {
    BeforeAll {
        Push-Location -StackName 'agent' -Path "$PSScriptRoot/.."
    }

    It 'uses build args correctly' {
        $TEST_USER = 'testuser'
        $TEST_JAW = 'C:/hamster'
        $CUSTOM_IMAGE_NAME = "custom-$($global:IMAGE_NAME)"

        $exitCode, $stdout, $stderr = Run-Program 'docker' "build --build-arg `"WINDOWS_VERSION_TAG=${global:WINDOWSVERSIONTAG}`" --build-arg `"JAVA_RELEASE=${global:JAVARELEASE}`" --build-arg `"user=$TEST_USER`" --build-arg `"JENKINS_AGENT_WORK=$TEST_JAW`" --tag=$CUSTOM_IMAGE_NAME --file ./windows/${global:WINDOWSFLAVOR}/Dockerfile ." 1800000
        $exitCode | Should -Be 0

        $exitCode, $stdout, $stderr = Run-Program 'docker' "run --detach --tty --name=$global:CONTAINERNAME --publish-all $CUSTOM_IMAGE_NAME $global:CONTAINERSHELL"
        $exitCode | Should -Be 0
        Is-ContainerRunning "$global:CONTAINERNAME" | Should -BeTrue

        $exitCode, $stdout, $stderr = Run-Program 'docker' "exec $global:CONTAINERNAME net user $TEST_USER"
        $exitCode | Should -Be 0
        $stdout | Should -Match "User name\s*$TEST_USER"

        $exitCode, $stdout, $stderr = Run-Program 'docker' "exec $global:CONTAINERNAME $global:CONTAINERSHELL -C `"(Get-ChildItem env:\ | Where-Object { `$_.Name -eq 'JENKINS_AGENT_WORK' }).Value`""
        $exitCode | Should -Be 0
        $stdout.Trim() | Should -Match "$TEST_JAW"
    }

    AfterAll {
        Cleanup($global:CONTAINERNAME)
        Run-Program 'docker' "rmi -f custom-$($global:IMAGE_NAME)" 60000 | Out-Null
        Pop-Location -StackName 'agent'
    }
}
