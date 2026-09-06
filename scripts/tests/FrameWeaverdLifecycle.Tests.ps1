$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$installer = Join-Path $repoRoot 'scripts\Install-FrameWeaverdTask.ps1'
$runner = Join-Path $repoRoot 'scripts\Start-FrameWeaver.ps1'

function Get-LoopbackTestPort {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        return $listener.LocalEndpoint.Port
    } finally {
        $listener.Stop()
    }
}

function Get-TestLogEvents {
    param([string]$LogDirectory)

    $events = @()
    foreach ($logFile in @(Get-ChildItem -LiteralPath $LogDirectory -Filter '*.jsonl' -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $stream = $null
        $reader = $null
        try {
            # The runner owns a FileShare.Read writer. A cooperative tailer must
            # both request read access and permit that existing writer.
            $stream = [IO.File]::Open($logFile.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
            $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $true)
            $lines = @($reader.ReadToEnd() -split "`r?`n")
        } catch {
            continue
        } finally {
            if ($reader) { $reader.Dispose() }
            elseif ($stream) { $stream.Dispose() }
        }
        foreach ($line in $lines) {
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                # A concurrently flushed line can be partial; defer it to the
                # next poll rather than turning it into a synthetic event.
                try { $events += $line | ConvertFrom-Json -ErrorAction Stop } catch {}
            }
        }
    }
    return $events
}

function Get-FrameWeaverdDiagnosticTail {
    param([string]$Path)

    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return '' }
    return (@(Get-Content -LiteralPath $Path -Tail 20 -ErrorAction SilentlyContinue) -join "`n")
}

function Get-FrameWeaverdRunnerObservation {
    param(
        [System.Diagnostics.Process]$RunnerProcess,
        [string]$StandardOutputPath,
        [string]$StandardErrorPath,
        [string]$ExitCodePath
    )

    $hasExited = $true
    $runnerExitCode = $null
    $runnerPid = $null
    $observationError = $null
    if ($RunnerProcess) {
        $runnerPid = $RunnerProcess.Id
        try {
            $hasExited = $RunnerProcess.HasExited
            if ($hasExited) { $runnerExitCode = $RunnerProcess.ExitCode }
            else {
                $RunnerProcess.Refresh()
                $hasExited = $RunnerProcess.HasExited
                if ($hasExited) { $runnerExitCode = $RunnerProcess.ExitCode }
            }
        } catch { $observationError = $_.Exception.Message }
    }
    if ($ExitCodePath -and (Test-Path -LiteralPath $ExitCodePath)) {
        $capturedExitCode = Get-Content -LiteralPath $ExitCodePath -Raw -ErrorAction SilentlyContinue
        if ($capturedExitCode -match '^-?\d+$') { $runnerExitCode = [int]$capturedExitCode }
    }
    return [pscustomobject]@{
        pid = $runnerPid
        has_exited = $hasExited
        exit_code = $runnerExitCode
        observation_error = $observationError
        exit_code_path = $ExitCodePath
        stdout_tail = Get-FrameWeaverdDiagnosticTail $StandardOutputPath
        stderr_tail = Get-FrameWeaverdDiagnosticTail $StandardErrorPath
    }
}

function Start-FrameWeaverdExitCapturedPowerShell {
    param(
        [string[]]$ChildArguments,
        [string]$ExitCodePath,
        [string]$StandardOutputPath,
        [string]$StandardErrorPath
    )

    # Pass the child argv as Base64 JSON so the wrapper can preserve script paths
    # and command text without relying on Start-Process quote reconstruction.
    $argumentsJson = $ChildArguments | ConvertTo-Json -Compress
    $argumentsBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($argumentsJson))
    $wrapper = Join-Path $PSScriptRoot 'fixtures\run-exit-captured-process.ps1'
    return Start-Process -FilePath powershell.exe -ArgumentList @(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',$wrapper,
        '-Executable','powershell.exe','-ArgumentsBase64',$argumentsBase64,'-ExitCodePath',$ExitCodePath
    ) -RedirectStandardOutput $StandardOutputPath -RedirectStandardError $StandardErrorPath -WindowStyle Hidden -PassThru
}

function Get-LoopbackPortObservation {
    param([int]$Port)

    $listeners = @(
        Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue |
            Where-Object { $_.LocalAddress -eq '127.0.0.1' } |
            Select-Object LocalAddress, LocalPort, OwningProcess
    )
    return [pscustomobject]@{
        observed_at = (Get-Date).ToUniversalTime().ToString('o')
        port = $Port
        listeners = $listeners
    }
}

function Wait-FrameWeaverdHealth {
    param(
        [string]$Uri,
        [System.Diagnostics.Process]$RunnerProcess,
        [string]$LogDirectory,
        [int]$TimeoutSeconds = 15
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastBody = $null
    $lastError = $null
    do {
        if ($RunnerProcess) {
            $RunnerProcess.Refresh()
            if ($RunnerProcess.HasExited) {
                throw "runner exited before health was ready (pid=$($RunnerProcess.Id), exit_code=$($RunnerProcess.ExitCode)); events=$((Get-TestLogEvents $LogDirectory | ConvertTo-Json -Compress))"
            }
        }
        try {
            $response = Microsoft.PowerShell.Utility\Invoke-WebRequest -Uri $Uri -TimeoutSec 1 -UseBasicParsing
            $lastBody = $response.Content
            $health = $response.Content | ConvertFrom-Json -ErrorAction Stop
            if ($health.service -eq 'ready' -and $health.database -eq 'ready') { return $health }
        } catch {
            $lastError = $_.Exception.Message
        }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)

    $runnerState = if ($RunnerProcess) { $RunnerProcess.Refresh(); "pid=$($RunnerProcess.Id), exited=$($RunnerProcess.HasExited)" } else { 'not_started' }
    throw "health readiness timed out ($runnerState); last_body=$lastBody; last_error=$lastError; events=$((Get-TestLogEvents $LogDirectory | ConvertTo-Json -Compress))"
}

function Wait-FrameWeaverdLogEvent {
    param(
        [string]$LogDirectory,
        [scriptblock]$Predicate,
        [int]$TimeoutSeconds = 10,
        [System.Diagnostics.Process]$RunnerProcess,
        [string]$RunnerStandardOutputPath,
        [string]$RunnerStandardErrorPath,
        [string]$RunnerExitCodePath
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if ($RunnerProcess) {
            $runner = Get-FrameWeaverdRunnerObservation -RunnerProcess $RunnerProcess -StandardOutputPath $RunnerStandardOutputPath -StandardErrorPath $RunnerStandardErrorPath -ExitCodePath $RunnerExitCodePath
            if ($runner.has_exited) {
                throw "runner exited while waiting for lifecycle event; runner=$($runner | ConvertTo-Json -Compress); events=$((Get-TestLogEvents $LogDirectory | ConvertTo-Json -Compress))"
            }
        }
        $match = @(Get-TestLogEvents $LogDirectory | Where-Object $Predicate | Select-Object -Last 1)
        if ($match.Count -eq 1) { return $match[0] }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)

    $runner = if ($RunnerProcess) { Get-FrameWeaverdRunnerObservation -RunnerProcess $RunnerProcess -StandardOutputPath $RunnerStandardOutputPath -StandardErrorPath $RunnerStandardErrorPath -ExitCodePath $RunnerExitCodePath | ConvertTo-Json -Compress } else { 'not-observed' }
    throw "expected lifecycle log event was not written; runner=$runner; events=$((Get-TestLogEvents $LogDirectory | ConvertTo-Json -Compress))"
}

function Stop-FrameWeaverdTestProcess {
    param([System.Diagnostics.Process]$Process)

    if (-not $Process) { return }
    $descendants = @()
    function Get-Descendants([int]$ParentProcessId) {
        foreach ($child in @(CimCmdlets\Get-CimInstance Win32_Process -Filter "ParentProcessId=$ParentProcessId" -ErrorAction SilentlyContinue)) {
            Get-Descendants -ParentProcessId $child.ProcessId
            [int]$child.ProcessId
        }
    }
    $descendants = @(Get-Descendants -ParentProcessId $Process.Id | Select-Object -Unique)
    foreach ($processId in $descendants) {
        try {
            $childProcess = Microsoft.PowerShell.Management\Get-Process -Id $processId -ErrorAction Stop
            Microsoft.PowerShell.Management\Stop-Process -Id $childProcess.Id -Force -ErrorAction Stop
            Microsoft.PowerShell.Management\Wait-Process -Id $childProcess.Id -Timeout 10 -ErrorAction SilentlyContinue
        } catch {}
    }
    try {
        $Process.Refresh()
        if (-not $Process.HasExited) {
            Microsoft.PowerShell.Management\Stop-Process -Id $Process.Id -Force -ErrorAction Stop
        }
    } catch {}
    try { Microsoft.PowerShell.Management\Wait-Process -Id $Process.Id -Timeout 10 -ErrorAction SilentlyContinue } catch {}
}

Describe 'FrameWeaverd Scheduled Task lifecycle' {
    It 'captures runner PID exit status and bounded output tails for diagnostics' {
        $stdoutPath = Join-Path $TestDrive 'runner.stdout.log'
        $stderrPath = Join-Path $TestDrive 'runner.stderr.log'
        $exitCodePath = Join-Path $TestDrive 'runner.exitcode'
        $runnerProcess = Start-FrameWeaverdExitCapturedPowerShell -ChildArguments @('-NoProfile','-Command','Write-Output fixture-stdout; Write-Error fixture-stderr; exit 23') -ExitCodePath $exitCodePath -StandardOutputPath $stdoutPath -StandardErrorPath $stderrPath
        $runnerProcess.WaitForExit()

        $observation = Get-FrameWeaverdRunnerObservation -RunnerProcess $runnerProcess -StandardOutputPath $stdoutPath -StandardErrorPath $stderrPath -ExitCodePath $exitCodePath

        $observation.pid | Should Be $runnerProcess.Id
        $observation.has_exited | Should Be $true
        $observation.exit_code | Should Be 23
        $observation.stdout_tail | Should Match 'fixture-stdout'
        $observation.stderr_tail | Should Match 'fixture-stderr'
    }

    It 'reports an exited runner before the second-event wait timeout' {
        $stdoutPath = Join-Path $TestDrive 'exited-runner.stdout.log'
        $stderrPath = Join-Path $TestDrive 'exited-runner.stderr.log'
        $exitCodePath = Join-Path $TestDrive 'exited-runner.exitcode'
        $logDirectory = Join-Path $TestDrive 'exited-runner-logs'
        New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null
        $runnerProcess = Start-FrameWeaverdExitCapturedPowerShell -ChildArguments @('-NoProfile','-Command','Write-Error fixture-runner-error; exit 17') -ExitCodePath $exitCodePath -StandardOutputPath $stdoutPath -StandardErrorPath $stderrPath
        $runnerProcess.WaitForExit()

        $message = $null
        try {
            Wait-FrameWeaverdLogEvent -LogDirectory $logDirectory -Predicate { $_.event -eq 'health_ready' } -TimeoutSeconds 15 -RunnerProcess $runnerProcess -RunnerStandardOutputPath $stdoutPath -RunnerStandardErrorPath $stderrPath -RunnerExitCodePath $exitCodePath
            throw 'expected an exited runner observation'
        } catch {
            $message = $_.Exception.Message
        }
        $message | Should Match 'runner exited'
        $message | Should Match 'fixture-runner-error'
        $message | Should Match '"exit_code":17'
    }

    It 'renders a non-mutating task definition with the expected restart policy' {
        $taskName = "FrameWeaverd-Test-$([guid]::NewGuid())"
        $before = ScheduledTasks\Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue

        $plan = & $installer -TaskName $taskName -ProjectRoot $repoRoot

        $plan.Apply | Should Be $false
        $plan.TaskName | Should Be $taskName
        $plan.Action.WorkingDirectory | Should Be $repoRoot
        $plan.Action.Execute | Should Match 'powershell.exe$'
        $plan.Action.Arguments | Should Match 'Start-FrameWeaver.ps1'
        $plan.Restart.Count | Should Be 3
        $plan.Restart.Interval | Should Be 'PT1M'
        $plan.Rollback.Command | Should Match ([regex]::Escape("Unregister-ScheduledTask -TaskName '$taskName'"))
        (ScheduledTasks\Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) | Should Be $before
    }

    It 'exports a dry-run rollback artifact and rejects an unsafe task name' {
        $rollbackPath = Join-Path $TestDrive 'rollback.ps1'
        $plan = & $installer -TaskName 'FrameWeaverd-Test' -ProjectRoot $repoRoot -RollbackPath $rollbackPath

        $plan.Rollback.ExportPath | Should Be $rollbackPath
        (Test-Path -LiteralPath $rollbackPath) | Should Be $true
        (Get-Content -Raw -LiteralPath $rollbackPath) | Should Match 'Unregister-ScheduledTask'

        $failure = $null
        try { & $installer -TaskName "bad'; Remove-Item" -ProjectRoot $repoRoot | Out-Null } catch { $failure = $_.Exception.Message }
        $failure | Should Match 'TaskName'
    }

    It 'stops an unhealthy child and exits nonzero after writing lifecycle JSONL' {
        $logDirectory = Join-Path $TestDrive 'runner-logs'
        $sleeper = Join-Path $repoRoot 'scripts\tests\fixtures\sleep-30.ps1'
        $childArguments = "-NoProfile -ExecutionPolicy Bypass -File `"$sleeper`""
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner -ProjectRoot $repoRoot -BinaryPath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -BinaryArguments $childArguments -Port 15179 -HealthTimeoutSeconds 1 -LogDirectory $logDirectory
        $LASTEXITCODE | Should Be 1
        $log = Get-Content -Raw ((Get-ChildItem $logDirectory -Filter '*.jsonl' | Select-Object -Last 1).FullName)
        $log | Should Match 'health_timeout'
        $log | Should Match 'panic_or_exit'
        $timeout = @($log -split "`r?`n" | Where-Object { $_ -match 'health_timeout' } | Select-Object -Last 1 | ConvertFrom-Json)
        (Get-Process -Id $timeout.pid -ErrorAction SilentlyContinue) | Should Be $null
    }

    It 'prunes all expired log companions and rotates JSONL when the date key changes' {
        $logDirectory = Join-Path $TestDrive 'rotation-logs'
        New-Item -ItemType Directory -Path $logDirectory | Out-Null
        foreach ($extension in '.jsonl', '.stdout', '.stderr') {
            $expired = Join-Path $logDirectory "expired$extension"
            Set-Content -LiteralPath $expired -Value 'old'
            (Get-Item $expired).LastWriteTime = (Get-Date).AddDays(-8)
        }
        $sleeper = Join-Path $repoRoot 'scripts\tests\fixtures\sleep-30.ps1'
        $childArguments = "-NoProfile -ExecutionPolicy Bypass -File `"$sleeper`""
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner -ProjectRoot $repoRoot -BinaryPath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -BinaryArguments $childArguments -Port 15178 -HealthTimeoutSeconds 1 -LogDirectory $logDirectory -TestInitialLogDateKey '20260821' -TestRotatedLogDateKey '20260822'
        $LASTEXITCODE | Should Be 1
        # The launcher must never delete unrelated files from its log directory.
        (Get-ChildItem $logDirectory -Filter 'expired.*').Count | Should Be 3
        (@(Get-ChildItem $logDirectory -Filter '*.jsonl').Name -join "`n") | Should Match '20260821'
        (@(Get-ChildItem $logDirectory -Filter '*.jsonl').Name -join "`n") | Should Match '20260822'
    }

    It 'preserves daemon structured event fields instead of stringifying JSON output' {
        $logDirectory = Join-Path $TestDrive 'structured-logs'
        $emitter = Join-Path $repoRoot 'scripts\tests\fixtures\emit-structured-event.ps1'
        $childArguments = "-NoProfile -ExecutionPolicy Bypass -File `"$emitter`""
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner -ProjectRoot $repoRoot -BinaryPath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -BinaryArguments $childArguments -Port 15177 -HealthTimeoutSeconds 1 -LogDirectory $logDirectory
        $LASTEXITCODE | Should Be 1
        $events = @(Get-Content -LiteralPath ((Get-ChildItem $logDirectory -Filter '*.jsonl' | Select-Object -Last 1).FullName) | ConvertFrom-Json)
        $structured = @($events | Where-Object { $_.event -eq 'job_cancel' } | Select-Object -Last 1)
        $structured.Count | Should Be 1
        $structured[0].job_id | Should Be '11111111-1111-4111-8111-111111111111'
        $structured[0].result | Should Be 'cancelled'
        $structured[0].duration_ms | Should Be 12
        $structured[0].owner_short | Should Be '11111111'
        $structured[0].from | Should Be 'running'
        $structured[0].to | Should Be 'cancelled'
        @($structured[0].PSObject.Properties.Name | Where-Object { $_ -eq 'line' }).Count | Should Be 0
    }

    It 'captures a flattened production frameweaverd operation JSON line without a line fallback' {
        $daemon = Join-Path $repoRoot 'frameweaverd\target\debug\frameweaverd.exe'
        $shadow = Join-Path $repoRoot 'frameweaverd\target\debug\frameweaver-shadow-comfy.exe'
        (Test-Path -LiteralPath $daemon) | Should Be $true
        (Test-Path -LiteralPath $shadow) | Should Be $true
        $daemonPort = Get-LoopbackTestPort
        $shadowPort = Get-LoopbackTestPort
        $runId = [guid]::NewGuid().ToString('N')
        $logDirectory = Join-Path $TestDrive "production-structured-logs-$runId"
        $dataDirectory = Join-Path $TestDrive "production-localappdata-$runId"
        $runnerStdoutPath = Join-Path $TestDrive "production-runner-$runId.stdout.log"
        $runnerStderrPath = Join-Path $TestDrive "production-runner-$runId.stderr.log"
        $runnerExitCodePath = Join-Path $TestDrive "production-runner-$runId.exitcode"
        $previousComfy = $env:FRAMEWEAVER_COMFY_URL
        $previousLocalAppData = $env:LOCALAPPDATA
        $previousShadowAddress = $env:FRAMEWEAVER_SHADOW_COMFY_ADDR
        $runnerProcess = $null; $shadowProcess = $null; $daemonPid = $null
        try {
            $env:FRAMEWEAVER_SHADOW_COMFY_ADDR = "127.0.0.1:$shadowPort"
            $shadowProcess = Start-Process -FilePath $shadow -PassThru
            $deadline = (Get-Date).AddSeconds(10)
            while ((Get-Date) -lt $deadline -and -not (Test-NetConnection 127.0.0.1 -Port $shadowPort -InformationLevel Quiet)) { Start-Sleep -Milliseconds 100 }
            (Test-NetConnection 127.0.0.1 -Port $shadowPort -InformationLevel Quiet) | Should Be $true

            $env:FRAMEWEAVER_COMFY_URL = "http://127.0.0.1:$shadowPort"
            $env:LOCALAPPDATA = $dataDirectory
            $runnerProcess = Start-FrameWeaverdExitCapturedPowerShell -ChildArguments @('-NoProfile','-ExecutionPolicy','Bypass','-File',$runner,'-ProjectRoot',$repoRoot,'-BinaryPath',$daemon,'-Port',$daemonPort,'-HealthTimeoutSeconds','10','-LogDirectory',$logDirectory) -ExitCodePath $runnerExitCodePath -StandardOutputPath $runnerStdoutPath -StandardErrorPath $runnerStderrPath
            $health = Wait-FrameWeaverdHealth -Uri "http://127.0.0.1:$daemonPort/api/health" -RunnerProcess $runnerProcess -LogDirectory $logDirectory
            $health.service | Should Be 'ready'
            $health.database | Should Be 'ready'
            $ready = @(Wait-FrameWeaverdLogEvent -LogDirectory $logDirectory -Predicate { $_.event -eq 'health_ready' })
            $ready.Count | Should Be 1
            $daemonPid = [int]$ready[0].pid

            $owner = '11111111-1111-4111-8111-111111111111'
            $client = '22222222-2222-4222-8222-222222222222'
            $payload = @{ client_id = $client; kind = 'image'; mode = 'test'; prompt = 'test'; settings = @{}; workflow = @{} } | ConvertTo-Json -Compress
            $beforePost = [pscustomobject]@{
                runner = Get-FrameWeaverdRunnerObservation -RunnerProcess $runnerProcess -StandardOutputPath $runnerStdoutPath -StandardErrorPath $runnerStderrPath -ExitCodePath $runnerExitCodePath
                port = Get-LoopbackPortObservation -Port $daemonPort
                events = Get-TestLogEvents $logDirectory
            }
            try {
                Microsoft.PowerShell.Utility\Invoke-WebRequest -Uri "http://127.0.0.1:$daemonPort/api/jobs" -Method Post -ContentType 'application/json' -Headers @{ 'X-FrameWeaver-Owner' = $owner } -Body $payload -UseBasicParsing | Out-Null
            } catch {
                $afterPost = [pscustomobject]@{
                    runner = Get-FrameWeaverdRunnerObservation -RunnerProcess $runnerProcess -StandardOutputPath $runnerStdoutPath -StandardErrorPath $runnerStderrPath -ExitCodePath $runnerExitCodePath
                    port = Get-LoopbackPortObservation -Port $daemonPort
                    events = Get-TestLogEvents $logDirectory
                }
                throw "job submit POST failed; before=$($beforePost | ConvertTo-Json -Compress -Depth 5); after=$($afterPost | ConvertTo-Json -Compress -Depth 5); original=$($_.Exception.Message)"
            }
            $structured = @(Wait-FrameWeaverdLogEvent -LogDirectory $logDirectory -Predicate { $_.event -eq 'job_submit' -and $_.result -eq 'submitted' })
            $structured.Count | Should Be 1
            foreach ($field in 'event','job_id','owner_short','from','to','result','duration_ms') { ($structured[0].PSObject.Properties.Name -contains $field) | Should Be $true }
            $structured[0].event | Should Be 'job_submit'
            $structured[0].owner_short | Should Be '11111111'
            $structured[0].result | Should Be 'submitted'
            @($structured[0].PSObject.Properties.Name | Where-Object { $_ -eq 'line' }).Count | Should Be 0
        } finally {
            $env:FRAMEWEAVER_COMFY_URL = $previousComfy
            $env:LOCALAPPDATA = $previousLocalAppData
            $env:FRAMEWEAVER_SHADOW_COMFY_ADDR = $previousShadowAddress
            if ($runnerProcess) { Stop-FrameWeaverdTestProcess $runnerProcess }
            if ($daemonPid) { Stop-FrameWeaverdTestProcess (Microsoft.PowerShell.Management\Get-Process -Id $daemonPid -ErrorAction SilentlyContinue) }
            if ($shadowProcess) { Stop-FrameWeaverdTestProcess $shadowProcess }
        }
    }

    It 'restarts a crashed daemon child without relying on Task Scheduler restart semantics' {
        $daemon = Join-Path $repoRoot 'frameweaverd\target\debug\frameweaverd.exe'
        $shadow = Join-Path $repoRoot 'frameweaverd\target\debug\frameweaver-shadow-comfy.exe'
        $daemonPort = Get-LoopbackTestPort
        $shadowPort = Get-LoopbackTestPort
        $runId = [guid]::NewGuid().ToString('N')
        $logDirectory = Join-Path $TestDrive "watchdog-logs-$runId"
        $dataDirectory = Join-Path $TestDrive "watchdog-localappdata-$runId"
        $runnerStdoutPath = Join-Path $TestDrive "watchdog-runner-$runId.stdout.log"
        $runnerStderrPath = Join-Path $TestDrive "watchdog-runner-$runId.stderr.log"
        $runnerExitCodePath = Join-Path $TestDrive "watchdog-runner-$runId.exitcode"
        $previousComfy = $env:FRAMEWEAVER_COMFY_URL
        $previousLocalAppData = $env:LOCALAPPDATA
        $previousShadowAddress = $env:FRAMEWEAVER_SHADOW_COMFY_ADDR
        $runnerProcess = $null; $shadowProcess = $null; $firstDaemonPid = $null; $secondDaemonPid = $null; $logReadLock = $null; $incompatibleReaderError = $null
        try {
            $env:FRAMEWEAVER_SHADOW_COMFY_ADDR = "127.0.0.1:$shadowPort"
            $shadowProcess = Start-Process -FilePath $shadow -PassThru
            $deadline = (Get-Date).AddSeconds(10)
            while ((Get-Date) -lt $deadline -and -not (Test-NetConnection 127.0.0.1 -Port $shadowPort -InformationLevel Quiet)) { Start-Sleep -Milliseconds 100 }

            $env:FRAMEWEAVER_COMFY_URL = "http://127.0.0.1:$shadowPort"
            $env:LOCALAPPDATA = $dataDirectory
            $runnerProcess = Start-FrameWeaverdExitCapturedPowerShell -ChildArguments @('-NoProfile','-ExecutionPolicy','Bypass','-File',$runner,'-ProjectRoot',$repoRoot,'-BinaryPath',$daemon,'-Port',$daemonPort,'-HealthTimeoutSeconds','10','-LogDirectory',$logDirectory,'-RestartCount','1','-RestartDelaySeconds','1') -ExitCodePath $runnerExitCodePath -StandardOutputPath $runnerStdoutPath -StandardErrorPath $runnerStderrPath
            Wait-FrameWeaverdHealth -Uri "http://127.0.0.1:$daemonPort/api/health" -RunnerProcess $runnerProcess -LogDirectory $logDirectory | Out-Null
            $firstReady = @(Wait-FrameWeaverdLogEvent -LogDirectory $logDirectory -Predicate { $_.event -eq 'health_ready' } | Select-Object -Last 1)
            $firstDaemonPid = [int]$firstReady[0].pid

            # A cooperative tailer permits the runner's already-owned writer.
            $logFile = Get-ChildItem -LiteralPath $logDirectory -Filter '*.jsonl' | Select-Object -Last 1
            $logReadLock = [IO.File]::Open($logFile.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
            try {
                [IO.File]::Open($logFile.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read).Dispose()
            } catch {
                $incompatibleReaderError = $_.Exception
            }
            $incompatibleReaderError | Should Not Be $null

            Microsoft.PowerShell.Management\Stop-Process -Id $firstDaemonPid -Force
            $secondReady = @(Wait-FrameWeaverdLogEvent -LogDirectory $logDirectory -Predicate { $_.event -eq 'health_ready' -and [int]$_.pid -ne $firstDaemonPid } -TimeoutSeconds 15 -RunnerProcess $runnerProcess -RunnerStandardOutputPath $runnerStdoutPath -RunnerStandardErrorPath $runnerStderrPath -RunnerExitCodePath $runnerExitCodePath)
            $secondDaemonPid = [int]$secondReady[0].pid
            Wait-FrameWeaverdHealth -Uri "http://127.0.0.1:$daemonPort/api/health" -RunnerProcess $runnerProcess -LogDirectory $logDirectory | Out-Null

            $runnerProcess.Refresh()
            $runnerProcess.HasExited | Should Be $false
            $secondDaemonPid | Should Not Be $firstDaemonPid
            $events = @(Get-TestLogEvents $logDirectory)
            $panic = @($events | Where-Object { $_.event -eq 'panic_or_exit' -and [int]$_.pid -eq $firstDaemonPid -and [int]$_.attempt -eq 0 })
            $restart = @($events | Where-Object { $_.event -eq 'watchdog_restart' -and [int]$_.prior_pid -eq $firstDaemonPid -and [int]$_.attempt -eq 1 })
            $starting = @($events | Where-Object { $_.event -eq 'starting' -and [int]$_.attempt -eq 1 })
            $ready = @($events | Where-Object { $_.event -eq 'health_ready' -and [int]$_.pid -eq $secondDaemonPid -and [int]$_.attempt -eq 1 })
            $panic.Count | Should Be 1
            $restart.Count | Should Be 1
            $starting.Count | Should Be 1
            $ready.Count | Should Be 1
            ([array]::IndexOf($events, $panic[0]) -lt [array]::IndexOf($events, $restart[0])) | Should Be $true
            ([array]::IndexOf($events, $restart[0]) -lt [array]::IndexOf($events, $starting[0])) | Should Be $true
            ([array]::IndexOf($events, $starting[0]) -lt [array]::IndexOf($events, $ready[0])) | Should Be $true
        } finally {
            $env:FRAMEWEAVER_COMFY_URL = $previousComfy
            $env:LOCALAPPDATA = $previousLocalAppData
            $env:FRAMEWEAVER_SHADOW_COMFY_ADDR = $previousShadowAddress
            if ($logReadLock) { $logReadLock.Dispose() }
            if ($runnerProcess) { Stop-FrameWeaverdTestProcess $runnerProcess }
            if ($firstDaemonPid) { Stop-FrameWeaverdTestProcess (Microsoft.PowerShell.Management\Get-Process -Id $firstDaemonPid -ErrorAction SilentlyContinue) }
            if ($secondDaemonPid) { Stop-FrameWeaverdTestProcess (Microsoft.PowerShell.Management\Get-Process -Id $secondDaemonPid -ErrorAction SilentlyContinue) }
            if ($shadowProcess) { Stop-FrameWeaverdTestProcess $shadowProcess }
        }
    }

    It 'exports existing task XML before an Apply replacement and makes rollback restore it' {
        $rollbackPath = Join-Path $TestDrive 'restore-existing.ps1'
        $global:frameweaverRegisterCalls = 0
        $global:frameweaverRestoreTaskName = $null
        $global:frameweaverRestoreXml = $null
        function global:Get-ScheduledTask { [pscustomobject]@{ TaskName = 'FrameWeaverd-Test' } }
        function global:Export-ScheduledTask { '<Task version="1.4"><RegistrationInfo /></Task>' }
        function global:New-ScheduledTaskAction { [pscustomobject]@{} }
        function global:New-ScheduledTaskTrigger { [pscustomobject]@{} }
        function global:New-ScheduledTaskSettingsSet { [pscustomobject]@{} }
        function global:Register-ScheduledTask {
            param($TaskName, $Xml, [Parameter(ValueFromRemainingArguments = $true)]$Rest)
            $global:frameweaverRegisterCalls++
            if ($Xml) { $global:frameweaverRestoreTaskName = $TaskName; $global:frameweaverRestoreXml = $Xml }
            [pscustomobject]@{}
        }
        try {
            & $installer -TaskName 'FrameWeaverd-Test' -ProjectRoot $repoRoot -RollbackPath $rollbackPath -Apply | Out-Null
            $global:frameweaverRegisterCalls | Should Be 1
            (Get-Content -Raw -LiteralPath $rollbackPath) | Should Match 'Register-ScheduledTask'
            & $rollbackPath
            $global:frameweaverRegisterCalls | Should Be 2
            $global:frameweaverRestoreTaskName | Should Be 'FrameWeaverd-Test'
            $global:frameweaverRestoreXml | Should Match '<Task version="1.4">'
        } finally {
            'Get-ScheduledTask','Export-ScheduledTask','New-ScheduledTaskAction','New-ScheduledTaskTrigger','New-ScheduledTaskSettingsSet','Register-ScheduledTask' |
                ForEach-Object { Remove-Item "Function:global:$_" -ErrorAction SilentlyContinue }
            Remove-Variable frameweaverRegisterCalls,frameweaverRestoreTaskName,frameweaverRestoreXml -Scope Global -ErrorAction SilentlyContinue
        }
    }
}
