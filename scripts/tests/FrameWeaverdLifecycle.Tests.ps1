$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$installer = Join-Path $repoRoot 'scripts\Install-FrameWeaverdTask.ps1'
$runner = Join-Path $repoRoot 'scripts\Start-FrameWeaver.ps1'
$script:ownedFrameWeaverdProcesses = @{}

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
    param(
        [string]$LogDirectory,
        [switch]$Strict
    )

    $events = @()
    foreach ($logFile in @(Get-ChildItem -LiteralPath $LogDirectory -Filter '*.jsonl' -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $stream = $null
        $reader = $null
        try {
            # The runner owns a FileShare.Read writer. A cooperative tailer must
            # both request read access and permit that existing writer.
            $stream = [IO.File]::Open($logFile.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
            $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $true)
            $content = $reader.ReadToEnd()
            $lines = @($content -split "`r?`n")
        } catch {
            continue
        } finally {
            if ($reader) { $reader.Dispose() }
            elseif ($stream) { $stream.Dispose() }
        }
        $lastNonEmptyLine = -1
        for ($lineIndex = 0; $lineIndex -lt $lines.Count; $lineIndex++) {
            if (-not [string]::IsNullOrWhiteSpace($lines[$lineIndex])) { $lastNonEmptyLine = $lineIndex }
        }
        $hasTerminalNewline = $content -match "(?:`r?`n)$"
        for ($lineIndex = 0; $lineIndex -lt $lines.Count; $lineIndex++) {
            $line = $lines[$lineIndex]
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                try { $events += $line | ConvertFrom-Json -ErrorAction Stop } catch {
                    # Only an unterminated final line may be concurrently
                    # flushed. A closed file, or any earlier line, is corrupt.
                    if (-not $Strict -and $lineIndex -eq $lastNonEmptyLine -and -not $hasTerminalNewline) { continue }
                    throw "invalid lifecycle JSONL in $($logFile.FullName) at line $($lineIndex + 1): $($_.Exception.Message)"
                }
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
            if ($hasExited -and $ExitCodePath) {
                [IO.File]::WriteAllText($ExitCodePath, [string]$runnerExitCode, [Text.Encoding]::ASCII)
            }
        } catch { $observationError = $_.Exception.Message }
    }
    if (-not $RunnerProcess -and $ExitCodePath -and (Test-Path -LiteralPath $ExitCodePath)) {
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

function ConvertTo-FrameWeaverdNativeCommandLine {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string[]]$Arguments)

    $encoded = foreach ($argument in $Arguments) {
        if ($argument.Length -eq 0) { '""'; continue }
        if ($argument -notmatch '[\s"]') { $argument; continue }

        $builder = [Text.StringBuilder]::new()
        [void]$builder.Append([char]'"')
        $backslashes = 0
        foreach ($character in $argument.ToCharArray()) {
            if ($character -eq [char]'\') {
                $backslashes++
            } elseif ($character -eq [char]'"') {
                [void]$builder.Append([char]'\', ($backslashes * 2) + 1)
                [void]$builder.Append($character)
                $backslashes = 0
            } else {
                [void]$builder.Append([char]'\', $backslashes)
                [void]$builder.Append($character)
                $backslashes = 0
            }
        }
        [void]$builder.Append([char]'\', $backslashes * 2)
        [void]$builder.Append([char]'"')
        $builder.ToString()
    }
    return [string]::Join(' ', [string[]]@($encoded))
}

function Wait-FrameWeaverdExitReceipt {
    param(
        [Parameter(Mandatory = $true)][System.Diagnostics.Process]$Process,
        [Parameter(Mandatory = $true)][string]$ExitCodePath
    )

    $deadline = (Get-Date).ToUniversalTime().AddSeconds(15)
    $remaining = [int][Math]::Max(0, ($deadline - (Get-Date).ToUniversalTime()).TotalMilliseconds)
    if ($remaining -eq 0 -or -not $Process.WaitForExit($remaining)) { throw "runner exit timed out after 15 seconds (pid=$($Process.Id))" }
    $lease = $script:ownedFrameWeaverdProcesses[[string]$Process.Id]
    Close-FrameWeaverdExitCapture -Lease $lease -DeadlineUtc $deadline
    $Process.Refresh()
    if (-not $Process.HasExited) { throw "runner did not exit (pid=$($Process.Id))" }
    $exitCode = $Process.ExitCode
    [IO.File]::WriteAllText($ExitCodePath, [string]$exitCode, [Text.Encoding]::ASCII)
    return $exitCode
}

function Start-FrameWeaverdExitCapturedPowerShell {
    param(
        [AllowEmptyString()][string[]]$ChildArguments,
        [string]$ExitCodePath,
        [string]$StandardOutputPath,
        [string]$StandardErrorPath
    )

    # The returned process is the fixture itself. Cache its Handle before it can
    # exit so Windows PowerShell retains the actual exit code for the receipt.
    $commandLine = ConvertTo-FrameWeaverdNativeCommandLine -Arguments $ChildArguments
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'powershell.exe'; $startInfo.Arguments = $commandLine
    $startInfo.UseShellExecute = $false; $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true; $startInfo.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw 'fixture runner did not start' }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $null = $process.Handle
    $lease = Register-FrameWeaverdOwnedProcess -Process $process
    $lease | Add-Member NoteProperty CaptureTasks @($stdoutTask,$stderrTask)
    $lease | Add-Member NoteProperty CapturePaths @($StandardOutputPath,$StandardErrorPath)
    return $process
}

function Close-FrameWeaverdExitCapture {
    param([Parameter(Mandatory = $true)]$Lease, [datetime]$DeadlineUtc)
    if (-not $lease -or -not $lease.CaptureTasks) { return }
    if (-not $DeadlineUtc) { $DeadlineUtc = (Get-Date).ToUniversalTime().AddSeconds(15) }
    for ($index = 0; $index -lt $lease.CaptureTasks.Count; $index++) {
        $remaining = [int][Math]::Max(0, ($DeadlineUtc - (Get-Date).ToUniversalTime()).TotalMilliseconds)
        if ($remaining -eq 0 -or -not $lease.CaptureTasks[$index].Wait($remaining)) {
            throw "fixture capture drain timed out (pid=$($Lease.Id), stream=$index)"
        }
        $content = $lease.CaptureTasks[$index].GetAwaiter().GetResult()
        [IO.File]::WriteAllText($lease.CapturePaths[$index], $content, [Text.Encoding]::UTF8)
        if (-not (Test-Path -LiteralPath $lease.CapturePaths[$index])) { throw "fixture capture output missing: $($lease.CapturePaths[$index])" }
    }
    $lease.CaptureTasks = $null
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

function Register-FrameWeaverdOwnedProcess {
    param(
        [Parameter(Mandatory = $true)][System.Diagnostics.Process]$Process,
        $ParentLease,
        [string]$Nonce = ([guid]::NewGuid().ToString('N'))
    )

    $process.Refresh()
    $lease = [pscustomobject]@{
        Process = $Process
        Id = $Process.Id
        StartTimeUtc = $Process.StartTime.ToUniversalTime()
        Nonce = $Nonce
        ParentNonce = if ($ParentLease) { $ParentLease.Nonce } else { $null }
    }
    $script:ownedFrameWeaverdProcesses[[string]$lease.Id] = $lease
    return $lease
}


function Register-FrameWeaverdOwnedChildProcess {
    param(
        [Parameter(Mandatory = $true)][System.Diagnostics.Process]$RunnerProcess,
        [Parameter(Mandatory = $true)][int]$ChildProcessId
    )

    $child = Microsoft.PowerShell.Management\Get-Process -Id $ChildProcessId -ErrorAction Stop
    $childMetadata = CimCmdlets\Get-CimInstance Win32_Process -Filter "ProcessId=$ChildProcessId" -ErrorAction Stop
    $ancestorId = [int]$childMetadata.ParentProcessId
    $parentLease = $null
    for ($depth = 0; $depth -lt 8 -and $ancestorId -gt 0; $depth++) {
        $candidateLease = $script:ownedFrameWeaverdProcesses[[string]$ancestorId]
        if ($candidateLease -and (Test-FrameWeaverdOwnedProcessLease -Lease $candidateLease)) { $parentLease = $candidateLease; break }
        $ancestor = CimCmdlets\Get-CimInstance Win32_Process -Filter "ProcessId=$ancestorId" -ErrorAction SilentlyContinue
        if (-not $ancestor) { break }
        $ancestorId = [int]$ancestor.ParentProcessId
    }
    if (-not $parentLease) { throw "refusing to own process without a live registered ancestor pid=$ChildProcessId" }
    return Register-FrameWeaverdOwnedProcess -Process $child -ParentLease $parentLease
}

function Test-FrameWeaverdOwnedProcessLease {
    param([Parameter(Mandatory = $true)]$Lease)

    $registered = $script:ownedFrameWeaverdProcesses[[string]$Lease.Id]
    if (-not $registered -or $registered.Nonce -ne $Lease.Nonce) { return $false }
    if (-not $Lease.Process -or $Lease.Process.Id -ne $Lease.Id) { return $false }
    try {
        $Lease.Process.Refresh()
        if ($Lease.Process.HasExited) { return $false }
        $current = Microsoft.PowerShell.Management\Get-Process -Id $Lease.Id -ErrorAction Stop
        return $current.StartTime.ToUniversalTime().Ticks -eq $Lease.StartTimeUtc.Ticks
    } catch { return $false }
}

function Stop-FrameWeaverdOwnedProcess {
    param([Parameter(Mandatory = $true)]$Lease)

    if (-not (Test-FrameWeaverdOwnedProcessLease -Lease $Lease)) { return $false }
    try {
        $Lease.Process.Kill()
        if (-not $Lease.Process.WaitForExit(15000)) { return $false }
        $Lease.Process.Refresh()
        return $Lease.Process.HasExited
    } catch { return $false }
}

function Assert-FrameWeaverdOwnedProcessStopped {
    param(
        [Parameter(Mandatory = $true)]$Lease,
        [scriptblock]$StopOperation = ${function:Stop-FrameWeaverdOwnedProcess}
    )

    # A stale lease is already terminal; only a live lease may authorize a stop.
    if (Test-FrameWeaverdOwnedProcessLease -Lease $Lease) {
        if (-not [bool](& $StopOperation $Lease)) {
            throw "owned fixture process could not be stopped (pid=$($Lease.Id), nonce=$($Lease.Nonce))"
        }
        if (Test-FrameWeaverdOwnedProcessLease -Lease $Lease) {
            throw "owned fixture process is still live after stop (pid=$($Lease.Id), nonce=$($Lease.Nonce))"
        }
    }
}

function Assert-FrameWeaverdFixtureCleanup {
    $failures = @()
    # Roots first prevents a watchdog from creating a replacement while child
    # leases are being collected. Every stop remains guarded by its own lease.
    $roots = @($script:ownedFrameWeaverdProcesses.Values | Where-Object { -not $_.ParentNonce })
    foreach ($lease in $roots) { try { Assert-FrameWeaverdOwnedProcessStopped -Lease $lease } catch { $failures += $_.Exception.Message } }
    foreach ($lease in @($script:ownedFrameWeaverdProcesses.Values)) {
        try { Assert-FrameWeaverdOwnedProcessStopped -Lease $lease } catch { $failures += $_.Exception.Message }
    }
    $deadline = (Get-Date).ToUniversalTime().AddSeconds(15)
    foreach ($lease in @($script:ownedFrameWeaverdProcesses.Values)) {
        try { Close-FrameWeaverdExitCapture -Lease $lease -DeadlineUtc $deadline } catch { $failures += $_.Exception.Message }
        finally { try { $lease.Process.Dispose() } catch { $failures += "fixture process dispose failed (pid=$($lease.Id)): $($_.Exception.Message)" } }
    }
    if ($failures.Count -gt 0) { throw "fixture cleanup failed: $($failures -join '; ')" }
}

function Get-FrameWeaverdFixtureProcessObservation {
    param([int[]]$ProcessIds)

    $observed = @()
    foreach ($processId in @($ProcessIds | Where-Object { $_ -gt 0 } | Select-Object -Unique)) {
        $process = CimCmdlets\Get-CimInstance Win32_Process -Filter "ProcessId=$processId" -ErrorAction SilentlyContinue
        $observed += [pscustomobject]@{
            pid = $processId
            live = [bool]$process
            parent_pid = if ($process) { [int]$process.ParentProcessId } else { $null }
            name = if ($process) { $process.Name } else { $null }
            creation_date = if ($process) { [string]$process.CreationDate } else { $null }
        }
    }
    return $observed
}

function Assert-FrameWeaverdFixturePathsReleased {
    param(
        [string[]]$Paths,
        [int[]]$ProcessIds,
        [Parameter(Mandatory = $true)][string]$ObservationPath
    )

    $pathObservations = @()
    foreach ($path in @($Paths)) {
        if (-not $path -or -not (Test-Path -LiteralPath $path)) { throw "fixture capture output missing: $path" }
        $released = $false
        $errorText = $null
        try {
            $stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            $stream.Dispose()
            $released = $true
        } catch { $errorText = $_.Exception.Message }
        $pathObservations += [pscustomobject]@{ path = $path; released = $released; error = $errorText }
    }
    $observation = [pscustomobject]@{
        observed_at = (Get-Date).ToUniversalTime().ToString('o')
        fixture_root = $repoRoot
        paths = $pathObservations
        tracked_processes = @(Get-FrameWeaverdFixtureProcessObservation -ProcessIds $ProcessIds)
    }
    [IO.File]::WriteAllText($ObservationPath, ($observation | ConvertTo-Json -Depth 6), [Text.Encoding]::UTF8)
    $locked = @($pathObservations | Where-Object { -not $_.released })
    if ($locked.Count -gt 0) { throw "fixture output handle remained locked; observation=$ObservationPath; paths=$($locked.path -join ',')" }
}

function Get-FrameWeaverdRegisteredDescendantLeases {
    param([Parameter(Mandatory = $true)]$ParentLease)

    $descendants = @()
    foreach ($childLease in @($script:ownedFrameWeaverdProcesses.Values | Where-Object { $_.ParentNonce -eq $ParentLease.Nonce })) {
        $descendants += Get-FrameWeaverdRegisteredDescendantLeases -ParentLease $childLease
        $descendants += $childLease
    }
    return $descendants
}

function Stop-FrameWeaverdTestProcess {
    param([System.Diagnostics.Process]$Process)

    if (-not $Process) { return $false }
    $lease = $script:ownedFrameWeaverdProcesses[[string]$Process.Id]
    if (-not $lease) { return $false }
    $stopped = $false
    # A watchdog can turn a child termination into a restart.  Stop its owned
    # runner first, then collect already-registered descendants; this preserves
    # the lease proof while preventing a cleanup-created replacement child.
    if (Stop-FrameWeaverdOwnedProcess -Lease $lease) { $stopped = $true }
    foreach ($descendantLease in @(Get-FrameWeaverdRegisteredDescendantLeases -ParentLease $lease)) {
        if (Stop-FrameWeaverdOwnedProcess -Lease $descendantLease) { $stopped = $true }
    }
    Close-FrameWeaverdExitCapture -Lease $lease
    return $stopped
}

Describe 'FrameWeaverd Scheduled Task lifecycle' {
    BeforeAll { $script:frameWeaverdInitialTestDrive = [IO.Path]::GetFullPath($TestDrive) }
    AfterEach {
        Assert-FrameWeaverdFixtureCleanup
    }

    AfterAll {
        $testDrivePath = [IO.Path]::GetFullPath($TestDrive)
        $tempRoot = [IO.Path]::GetFullPath($env:TEMP).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        $tempPrefix = $tempRoot + [IO.Path]::DirectorySeparatorChar
        if ($testDrivePath -ne $script:frameWeaverdInitialTestDrive -or $testDrivePath -eq $tempRoot -or -not $testDrivePath.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'unsafe TestDrive cleanup path' }
        if (Test-Path -LiteralPath $testDrivePath) {
            $item = Get-Item -LiteralPath $testDrivePath -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'unsafe TestDrive reparse path' }
            try {
                Remove-Item -LiteralPath $testDrivePath -Force -Recurse -ErrorAction Stop
            } catch {
                throw "fixture TestDrive cleanup failed: $($_.Exception.Message)"
            }
            if (Test-Path -LiteralPath $TestDrive) { throw "fixture TestDrive cleanup left path behind: $TestDrive" }
        }
    }

    It 'captures runner PID exit status and bounded output tails for diagnostics' {
        $stdoutPath = Join-Path $TestDrive 'runner.stdout.log'
        $stderrPath = Join-Path $TestDrive 'runner.stderr.log'
        $exitCodePath = Join-Path $TestDrive 'runner.exitcode'
        $runnerProcess = Start-FrameWeaverdExitCapturedPowerShell -ChildArguments @('-NoProfile','-Command','Write-Output fixture-stdout; Write-Error fixture-stderr; exit 23') -ExitCodePath $exitCodePath -StandardOutputPath $stdoutPath -StandardErrorPath $stderrPath
        Wait-FrameWeaverdExitReceipt -Process $runnerProcess -ExitCodePath $exitCodePath | Out-Null

        $observation = Get-FrameWeaverdRunnerObservation -RunnerProcess $runnerProcess -StandardOutputPath $stdoutPath -StandardErrorPath $stderrPath -ExitCodePath $exitCodePath

        $observation.pid | Should Be $runnerProcess.Id
        $observation.has_exited | Should Be $true
        $observation.exit_code | Should Be 23
        $observation.stdout_tail | Should Match 'fixture-stdout'
        $observation.stderr_tail | Should Match 'fixture-stderr'
    }

    It 'round-trips hostile argv values through the direct fixture process on Windows PowerShell' {
        $capture = Join-Path $repoRoot 'scripts\tests\fixtures\capture-argv.ps1'
        $argvPath = Join-Path $TestDrive 'captured-argv.json'
        $stdoutPath = Join-Path $TestDrive 'argv.stdout.log'
        $stderrPath = Join-Path $TestDrive 'argv.stderr.log'
        $exitCodePath = Join-Path $TestDrive 'argv.exitcode'
        $values = @('', 'plain', 'contains space', 'quote"inside', 'trailing\', 'space and trailing\')
        $runnerProcess = Start-FrameWeaverdExitCapturedPowerShell -ChildArguments (@('-NoProfile','-ExecutionPolicy','Bypass','-File',$capture,'-OutputPath',$argvPath) + $values) -ExitCodePath $exitCodePath -StandardOutputPath $stdoutPath -StandardErrorPath $stderrPath
        Wait-FrameWeaverdExitReceipt -Process $runnerProcess -ExitCodePath $exitCodePath | Out-Null

        [int](Get-Content -LiteralPath $exitCodePath -Raw) | Should Be 0
        $captured = @((Get-Content -LiteralPath $argvPath -Raw | ConvertFrom-Json))
        $captured.Count | Should Be $values.Count
        for ($index = 0; $index -lt $values.Count; $index++) { $captured[$index] | Should Be $values[$index] }
    }

    It 'reports an exited runner before the second-event wait timeout' {
        $stdoutPath = Join-Path $TestDrive 'exited-runner.stdout.log'
        $stderrPath = Join-Path $TestDrive 'exited-runner.stderr.log'
        $exitCodePath = Join-Path $TestDrive 'exited-runner.exitcode'
        $logDirectory = Join-Path $TestDrive 'exited-runner-logs'
        New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null
        $runnerProcess = Start-FrameWeaverdExitCapturedPowerShell -ChildArguments @('-NoProfile','-Command','Write-Error fixture-runner-error; exit 17') -ExitCodePath $exitCodePath -StandardOutputPath $stdoutPath -StandardErrorPath $stderrPath
        Wait-FrameWeaverdExitReceipt -Process $runnerProcess -ExitCodePath $exitCodePath | Out-Null

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

    It 'does not stop a PID-reuse sentinel without its owned process lease' {
        $sleeper = Join-Path $repoRoot 'scripts\tests\fixtures\sleep-30.ps1'
        $sentinel = Start-Process -FilePath powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$sleeper) -WindowStyle Hidden -PassThru
        try {
            $lease = Register-FrameWeaverdOwnedProcess -Process $sentinel
            $forgedNonceLease = [pscustomobject]@{ Process = $sentinel; Id = $sentinel.Id; StartTimeUtc = $lease.StartTimeUtc; Nonce = [guid]::NewGuid().ToString('N') }
            $staleStartLease = [pscustomobject]@{ Process = $sentinel; Id = $sentinel.Id; StartTimeUtc = $lease.StartTimeUtc.AddTicks(-1); Nonce = $lease.Nonce }

            (Stop-FrameWeaverdOwnedProcess -Lease $forgedNonceLease) | Should Be $false
            (Stop-FrameWeaverdOwnedProcess -Lease $staleStartLease) | Should Be $false
            $sentinel.Refresh()
            $sentinel.HasExited | Should Be $false
        } finally {
            Assert-FrameWeaverdOwnedProcessStopped -Lease $lease
        }
    }

    It 'fails fixture cleanup when a verified owned lease reports a stop failure' {
        $sleeper = Join-Path $repoRoot 'scripts\tests\fixtures\sleep-30.ps1'
        $fixture = Start-Process -FilePath powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$sleeper) -WindowStyle Hidden -PassThru
        $lease = Register-FrameWeaverdOwnedProcess -Process $fixture
        try {
            $cleanupFailure = $null
            try { Assert-FrameWeaverdOwnedProcessStopped -Lease $lease -StopOperation { param($ignoredLease) $false } } catch { $cleanupFailure = $_.Exception.Message }
            $cleanupFailure | Should Match '^owned fixture process could not be stopped \(pid='
            $fixture.Refresh()
            $fixture.HasExited | Should Be $false
        } finally {
            Assert-FrameWeaverdOwnedProcessStopped -Lease $lease
        }
    }

    It 'stops an already registered child after its parent fixture exits' {
        $sleeper = Join-Path $repoRoot 'scripts\tests\fixtures\sleep-30.ps1'
        $spawner = Join-Path $repoRoot 'scripts\tests\fixtures\spawn-child-and-sleep.ps1'
        $childPidPath = Join-Path $TestDrive 'owned-child.pid'
        $root = Start-Process -FilePath powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$spawner,'-ChildPidPath',$childPidPath,'-ChildScriptPath',$sleeper,'-ParentSeconds','2') -WindowStyle Hidden -PassThru
        try {
            Register-FrameWeaverdOwnedProcess -Process $root | Out-Null
            $deadline = (Get-Date).AddSeconds(5)
            while (-not (Test-Path -LiteralPath $childPidPath) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 50 }
            (Test-Path -LiteralPath $childPidPath) | Should Be $true
            $childPid = [int](Get-Content -LiteralPath $childPidPath -Raw)
            Register-FrameWeaverdOwnedChildProcess -RunnerProcess $root -ChildProcessId $childPid | Out-Null
            $root.WaitForExit()

            (Stop-FrameWeaverdTestProcess $root) | Should Be $true
            $root.Refresh()
            $root.HasExited | Should Be $true
            (Microsoft.PowerShell.Management\Get-Process -Id $childPid -ErrorAction SilentlyContinue) | Should Be $null
        } finally {
            $rootLease = $script:ownedFrameWeaverdProcesses[[string]$root.Id]
            if ($rootLease) { Assert-FrameWeaverdOwnedProcessStopped -Lease $rootLease }
        }
    }

    It 'registers the bootstrap process that directly executes the fixture' {
        $stdoutPath = Join-Path $TestDrive 'inner-lease.stdout.log'
        $stderrPath = Join-Path $TestDrive 'inner-lease.stderr.log'
        $exitCodePath = Join-Path $TestDrive 'inner-lease.exitcode'
        $runnerProcess = Start-FrameWeaverdExitCapturedPowerShell -ChildArguments @('-NoProfile','-Command','Start-Sleep -Seconds 30') -ExitCodePath $exitCodePath -StandardOutputPath $stdoutPath -StandardErrorPath $stderrPath
        try {
            $bootstrapLease = $script:ownedFrameWeaverdProcesses[[string]$runnerProcess.Id]
            $bootstrapLease | Should Not Be $null
            (Test-FrameWeaverdOwnedProcessLease -Lease $bootstrapLease) | Should Be $true
        } finally {
            Stop-FrameWeaverdTestProcess $runnerProcess | Out-Null
        }
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

    It 'does not start the daemon when the initial lifecycle sink cannot be created' {
        $blockedLogPath = Join-Path $TestDrive 'initial-sink-is-a-file'
        $markerPath = Join-Path $TestDrive 'daemon-started.marker'
        Set-Content -LiteralPath $blockedLogPath -Value 'not-a-directory'
        $markerFixture = Join-Path $repoRoot 'scripts\tests\fixtures\write-marker-and-sleep.ps1'
        $childArguments = "-NoProfile -ExecutionPolicy Bypass -File `"$markerFixture`" -MarkerPath `"$markerPath`""

        $stdoutPath = Join-Path $TestDrive 'initial-sink.stdout.log'
        $stderrPath = Join-Path $TestDrive 'initial-sink.stderr.log'
        $exitCodePath = Join-Path $TestDrive 'initial-sink.exitcode'
        $runnerProcess = Start-FrameWeaverdExitCapturedPowerShell -ChildArguments @('-NoProfile','-ExecutionPolicy','Bypass','-File',$runner,'-ProjectRoot',$repoRoot,'-BinaryPath',"$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe",'-BinaryArguments',$childArguments,'-Port','15176','-HealthTimeoutSeconds','1','-LogDirectory',$blockedLogPath) -ExitCodePath $exitCodePath -StandardOutputPath $stdoutPath -StandardErrorPath $stderrPath
        Wait-FrameWeaverdExitReceipt -Process $runnerProcess -ExitCodePath $exitCodePath | Out-Null

        [int](Get-Content -LiteralPath $exitCodePath -Raw) | Should Be 1
        (Get-Content -LiteralPath $stderrPath -Raw) | Should Match 'initial lifecycle sink'
        (Test-Path -LiteralPath $markerPath) | Should Be $false
    }

    It 'passes a marker child argv intact when the initial lifecycle sink is writable' {
        $logDirectory = Join-Path $TestDrive 'initial-sink-writable'
        $markerPath = Join-Path $TestDrive 'argv-child-started.marker'
        $markerFixture = Join-Path $repoRoot 'scripts\tests\fixtures\write-marker-and-sleep.ps1'
        $childArguments = "-NoProfile -ExecutionPolicy Bypass -File `"$markerFixture`" -MarkerPath `"$markerPath`""

        $stdoutPath = Join-Path $TestDrive 'marker-child.stdout.log'
        $stderrPath = Join-Path $TestDrive 'marker-child.stderr.log'
        $exitCodePath = Join-Path $TestDrive 'marker-child.exitcode'
        $runnerProcess = Start-FrameWeaverdExitCapturedPowerShell -ChildArguments @('-NoProfile','-ExecutionPolicy','Bypass','-File',$runner,'-ProjectRoot',$repoRoot,'-BinaryPath',"$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe",'-BinaryArguments',$childArguments,'-Port','15174','-HealthTimeoutSeconds','1','-LogDirectory',$logDirectory) -ExitCodePath $exitCodePath -StandardOutputPath $stdoutPath -StandardErrorPath $stderrPath
        Wait-FrameWeaverdExitReceipt -Process $runnerProcess -ExitCodePath $exitCodePath | Out-Null

        [int](Get-Content -LiteralPath $exitCodePath -Raw) | Should Be 1
        (Test-Path -LiteralPath $markerPath) | Should Be $true
        (Get-Content -LiteralPath $markerPath -Raw) | Should Be 'started'
        (Get-Content -LiteralPath $stdoutPath -Raw) | Should Not Match '(?m)^True$'
    }

    It 'preserves all lifecycle events across rotation while a cooperative reader holds the old JSONL' {
        $logDirectory = Join-Path $TestDrive 'rotation-reader-logs'
        $sleeper = Join-Path $repoRoot 'scripts\tests\fixtures\sleep-30.ps1'
        $childArguments = "-NoProfile -ExecutionPolicy Bypass -File `"$sleeper`""
        $stdoutPath = Join-Path $TestDrive 'rotation-reader.stdout.log'
        $stderrPath = Join-Path $TestDrive 'rotation-reader.stderr.log'
        $exitCodePath = Join-Path $TestDrive 'rotation-reader.exitcode'
        $runnerProcess = Start-FrameWeaverdExitCapturedPowerShell -ChildArguments @('-NoProfile','-ExecutionPolicy','Bypass','-File',$runner,'-ProjectRoot',$repoRoot,'-BinaryPath',"$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe",'-BinaryArguments',$childArguments,'-Port','15175','-HealthTimeoutSeconds','1','-LogDirectory',$logDirectory,'-TestInitialLogDateKey','20260821','-TestRotatedLogDateKey','20260822') -ExitCodePath $exitCodePath -StandardOutputPath $stdoutPath -StandardErrorPath $stderrPath
        $oldReader = $null
        try {
            $deadline = (Get-Date).AddSeconds(5)
            do { $oldLog = Get-ChildItem -LiteralPath $logDirectory -Filter '*.jsonl' -ErrorAction SilentlyContinue | Select-Object -First 1; if (-not $oldLog) { Start-Sleep -Milliseconds 50 } } while (-not $oldLog -and (Get-Date) -lt $deadline)
            $oldLog | Should Not Be $null
            $oldReader = [IO.File]::Open($oldLog.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
            Wait-FrameWeaverdExitReceipt -Process $runnerProcess -ExitCodePath $exitCodePath | Out-Null
            [int](Get-Content -LiteralPath $exitCodePath -Raw) | Should Be 1
            $events = @(Get-TestLogEvents $logDirectory -Strict)
            @($events | Where-Object { $_.event -eq 'starting' }).Count | Should Be 1
            @($events | Where-Object { $_.event -eq 'health_timeout' }).Count | Should Be 1
            @($events | Where-Object { $_.event -eq 'panic_or_exit' }).Count | Should Be 1
            @(Get-ChildItem -LiteralPath $logDirectory -Filter '*.jsonl').Count | Should Be 2
        } finally {
            if ($oldReader) { $oldReader.Dispose() }
            Stop-FrameWeaverdTestProcess $runnerProcess
        }
    }

    It 'keeps writing to the old sink when rotated sink creation fails' {
        $logDirectory = Join-Path $TestDrive 'rotation-sink-failure-logs'
        $sleeper = Join-Path $repoRoot 'scripts\tests\fixtures\sleep-30.ps1'
        $childArguments = "-NoProfile -ExecutionPolicy Bypass -File `"$sleeper`""
        $stdoutPath = Join-Path $TestDrive 'rotation-sink-failure.stdout.log'
        $stderrPath = Join-Path $TestDrive 'rotation-sink-failure.stderr.log'
        $exitCodePath = Join-Path $TestDrive 'rotation-sink-failure.exitcode'
        $runnerProcess = Start-FrameWeaverdExitCapturedPowerShell -ChildArguments @('-NoProfile','-ExecutionPolicy','Bypass','-File',$runner,'-ProjectRoot',$repoRoot,'-BinaryPath',"$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe",'-BinaryArguments',$childArguments,'-Port','15173','-HealthTimeoutSeconds','1','-LogDirectory',$logDirectory,'-TestInitialLogDateKey','20260821','-TestRotatedLogDateKey','20260822','-TestFailRotatedLogSink') -ExitCodePath $exitCodePath -StandardOutputPath $stdoutPath -StandardErrorPath $stderrPath
        Wait-FrameWeaverdExitReceipt -Process $runnerProcess -ExitCodePath $exitCodePath | Out-Null

        [int](Get-Content -LiteralPath $exitCodePath -Raw) | Should Be 1
        $events = @(Get-TestLogEvents $logDirectory -Strict)
        @($events | Where-Object { $_.event -eq 'starting' }).Count | Should Be 1
        @($events | Where-Object { $_.event -eq 'health_timeout' }).Count | Should Be 1
        @($events | Where-Object { $_.event -eq 'panic_or_exit' }).Count | Should Be 1
        @(Get-ChildItem -LiteralPath $logDirectory -Filter '*.jsonl').Count | Should Be 1
        (Get-ChildItem -LiteralPath $logDirectory -Filter '*.jsonl').Name | Should Match '20260821'
    }

    It 'defers pruning a locked expired frameweaverd log without deleting it' {
        $logDirectory = Join-Path $TestDrive 'locked-expired-log-prune'
        New-Item -ItemType Directory -Path $logDirectory | Out-Null
        $lockedExpired = Join-Path $logDirectory 'frameweaverd-locked-expired.jsonl'
        Set-Content -LiteralPath $lockedExpired -Value '{"event":"old"}'
        (Get-Item -LiteralPath $lockedExpired).LastWriteTime = (Get-Date).AddDays(-8)
        $lock = [IO.File]::Open($lockedExpired, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $sleeper = Join-Path $repoRoot 'scripts\tests\fixtures\sleep-30.ps1'
        $childArguments = "-NoProfile -ExecutionPolicy Bypass -File `"$sleeper`""
        try {
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner -ProjectRoot $repoRoot -BinaryPath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -BinaryArguments $childArguments -Port 15172 -HealthTimeoutSeconds 1 -LogDirectory $logDirectory
            $LASTEXITCODE | Should Be 1
            (Test-Path -LiteralPath $lockedExpired) | Should Be $true
        } finally {
            $lock.Dispose()
        }
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
        $runnerProcess = $null; $shadowProcess = $null; $daemonProcessLease = $null
        try {
            $env:FRAMEWEAVER_SHADOW_COMFY_ADDR = "127.0.0.1:$shadowPort"
            $shadowProcess = Start-Process -FilePath $shadow -PassThru
            Register-FrameWeaverdOwnedProcess -Process $shadowProcess | Out-Null
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
            $daemonProcessLease = Register-FrameWeaverdOwnedChildProcess -RunnerProcess $runnerProcess -ChildProcessId ([int]$ready[0].pid)

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
            if ($daemonProcessLease) { Stop-FrameWeaverdOwnedProcess -Lease $daemonProcessLease | Out-Null }
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
        $cleanupObservationPath = Join-Path $env:TEMP "frameweaver-watchdog-cleanup-$runId.json"
        $previousComfy = $env:FRAMEWEAVER_COMFY_URL
        $previousLocalAppData = $env:LOCALAPPDATA
        $previousShadowAddress = $env:FRAMEWEAVER_SHADOW_COMFY_ADDR
        $runnerProcess = $null; $shadowProcess = $null; $firstDaemonPid = $null; $secondDaemonPid = $null; $firstDaemonLease = $null; $secondDaemonLease = $null; $logReadLock = $null; $incompatibleReaderError = $null
        try {
            $env:FRAMEWEAVER_SHADOW_COMFY_ADDR = "127.0.0.1:$shadowPort"
            $shadowProcess = Start-Process -FilePath $shadow -PassThru
            Register-FrameWeaverdOwnedProcess -Process $shadowProcess | Out-Null
            $deadline = (Get-Date).AddSeconds(10)
            while ((Get-Date) -lt $deadline -and -not (Test-NetConnection 127.0.0.1 -Port $shadowPort -InformationLevel Quiet)) { Start-Sleep -Milliseconds 100 }

            $env:FRAMEWEAVER_COMFY_URL = "http://127.0.0.1:$shadowPort"
            $env:LOCALAPPDATA = $dataDirectory
            $runnerProcess = Start-FrameWeaverdExitCapturedPowerShell -ChildArguments @('-NoProfile','-ExecutionPolicy','Bypass','-File',$runner,'-ProjectRoot',$repoRoot,'-BinaryPath',$daemon,'-Port',$daemonPort,'-HealthTimeoutSeconds','10','-LogDirectory',$logDirectory,'-RestartCount','1','-RestartDelaySeconds','1') -ExitCodePath $runnerExitCodePath -StandardOutputPath $runnerStdoutPath -StandardErrorPath $runnerStderrPath
            Wait-FrameWeaverdHealth -Uri "http://127.0.0.1:$daemonPort/api/health" -RunnerProcess $runnerProcess -LogDirectory $logDirectory | Out-Null
            $firstReady = @(Wait-FrameWeaverdLogEvent -LogDirectory $logDirectory -Predicate { $_.event -eq 'health_ready' } | Select-Object -Last 1)
            $firstDaemonPid = [int]$firstReady[0].pid
            $firstDaemonLease = Register-FrameWeaverdOwnedChildProcess -RunnerProcess $runnerProcess -ChildProcessId $firstDaemonPid

            # A cooperative tailer permits the runner's already-owned writer.
            $logFile = Get-ChildItem -LiteralPath $logDirectory -Filter '*.jsonl' | Select-Object -Last 1
            $logReadLock = [IO.File]::Open($logFile.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
            try {
                [IO.File]::Open($logFile.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read).Dispose()
            } catch {
                $incompatibleReaderError = $_.Exception
            }
            $incompatibleReaderError | Should Not Be $null

            (Stop-FrameWeaverdOwnedProcess -Lease $firstDaemonLease) | Should Be $true
            $secondReady = @(Wait-FrameWeaverdLogEvent -LogDirectory $logDirectory -Predicate { $_.event -eq 'health_ready' -and [int]$_.pid -ne $firstDaemonPid } -TimeoutSeconds 15 -RunnerProcess $runnerProcess -RunnerStandardOutputPath $runnerStdoutPath -RunnerStandardErrorPath $runnerStderrPath -RunnerExitCodePath $runnerExitCodePath)
            $secondDaemonPid = [int]$secondReady[0].pid
            $secondDaemonLease = Register-FrameWeaverdOwnedChildProcess -RunnerProcess $runnerProcess -ChildProcessId $secondDaemonPid
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
            $cleanupPids = @($runnerProcess.Id, $shadowProcess.Id, $firstDaemonPid, $secondDaemonPid)
            $env:FRAMEWEAVER_COMFY_URL = $previousComfy
            $env:LOCALAPPDATA = $previousLocalAppData
            $env:FRAMEWEAVER_SHADOW_COMFY_ADDR = $previousShadowAddress
            if ($logReadLock) { $logReadLock.Dispose() }
            if ($runnerProcess) {
                $runnerLease = $script:ownedFrameWeaverdProcesses[[string]$runnerProcess.Id]
                if (-not $runnerLease) { throw "fixture runner has no owned lease (pid=$($runnerProcess.Id))" }
                Assert-FrameWeaverdOwnedProcessStopped -Lease $runnerLease
            }
            if ($firstDaemonLease) { Assert-FrameWeaverdOwnedProcessStopped -Lease $firstDaemonLease }
            if ($secondDaemonLease) { Assert-FrameWeaverdOwnedProcessStopped -Lease $secondDaemonLease }
            if ($shadowProcess) {
                $shadowLease = $script:ownedFrameWeaverdProcesses[[string]$shadowProcess.Id]
                if (-not $shadowLease) { throw "fixture shadow has no owned lease (pid=$($shadowProcess.Id))" }
                Assert-FrameWeaverdOwnedProcessStopped -Lease $shadowLease
            }
            if ($runnerLease) { Close-FrameWeaverdExitCapture -Lease $runnerLease -DeadlineUtc ((Get-Date).ToUniversalTime().AddSeconds(15)) }
            Assert-FrameWeaverdFixturePathsReleased -Paths @($runnerStdoutPath, $runnerStderrPath) -ProcessIds $cleanupPids -ObservationPath $cleanupObservationPath
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
