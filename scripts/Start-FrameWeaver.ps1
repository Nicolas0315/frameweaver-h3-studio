[CmdletBinding()]
param(
    [string]$ProjectRoot,
    [int]$Port = 5180,
    [string]$BinaryPath,
    [string]$BinaryArguments = '',
    [string]$LogDirectory = (Join-Path $env:LOCALAPPDATA 'FrameWeaver\logs'),
    [int]$HealthTimeoutSeconds = 30,
    [ValidateRange(0, 100)]
    [int]$RestartCount = 3,
    [ValidateRange(0, 86400)]
    [int]$RestartDelaySeconds = 60,
    [string]$TestInitialLogDateKey,
    [string]$TestRotatedLogDateKey
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = if ($ProjectRoot) { $ProjectRoot } else { Split-Path -Parent $PSScriptRoot }
$projectRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path
if (-not $BinaryPath) {
    $release = Join-Path $projectRoot 'frameweaverd\target\release\frameweaverd.exe'
    $debug = Join-Path $projectRoot 'frameweaverd\target\debug\frameweaverd.exe'
    $BinaryPath = if (Test-Path -LiteralPath $release) { $release } elseif (Test-Path -LiteralPath $debug) { $debug } else { throw 'frameweaverd binary is missing; build it before starting the lifecycle task.' }
}
$BinaryPath = (Resolve-Path -LiteralPath $BinaryPath).Path
New-Item -ItemType Directory -Force -Path $LogDirectory | Out-Null

function Prune-OldLogs {
    foreach ($file in @(Get-ChildItem -LiteralPath $LogDirectory -File | Where-Object { $_.Name -like 'frameweaverd-*' -and $_.Extension -in '.jsonl', '.stdout', '.stderr' -and $_.LastWriteTime -lt (Get-Date).AddDays(-7) })) {
        if ($script:jsonl -and $file.FullName -eq $script:jsonl) { continue }
        try { Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop } catch {}
    }
}
Prune-OldLogs
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
function Get-LogDateKey {
    if ($TestInitialLogDateKey) {
        if ($script:eventCount -ge 1 -and $TestRotatedLogDateKey) { return $TestRotatedLogDateKey }
        return $TestInitialLogDateKey
    }
    return (Get-Date).ToString('yyyyMMdd')
}
$script:eventCount = 0
$script:dateKey = Get-LogDateKey
$script:sequence = 0
$script:logInstanceId = [guid]::NewGuid().ToString('N')
$script:jsonl = $null
$script:jsonlStream = $null
$script:jsonlWriter = $null
function Close-LogWriter {
    if ($script:jsonlWriter) {
        $script:jsonlWriter.Flush()
        $script:jsonlWriter.Dispose()
        $script:jsonlWriter = $null
        $script:jsonlStream = $null
    } elseif ($script:jsonlStream) {
        $script:jsonlStream.Dispose()
        $script:jsonlStream = $null
    }
}
function New-LogFile {
    $newDateKey = Get-LogDateKey
    $script:sequence++
    $sequenceKey = '{0:D6}' -f $script:sequence
    $newPath = Join-Path $LogDirectory "frameweaverd-$newDateKey-$stamp-$PID-$script:logInstanceId-$sequenceKey.jsonl"
    $newStream = $null
    $newWriter = $null
    try {
        $newStream = [IO.FileStream]::new($newPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        $newWriter = [IO.StreamWriter]::new($newStream, [Text.UTF8Encoding]::new($false))
        $newWriter.AutoFlush = $true
    } catch {
        if ($newWriter) { $newWriter.Dispose() }
        elseif ($newStream) { $newStream.Dispose() }
        if ($script:jsonlWriter) { return $false }
        throw
    }
    $oldWriter = $script:jsonlWriter
    $oldStream = $script:jsonlStream
    if ($oldWriter) {
        try { $oldWriter.Flush() } catch {
            $newWriter.Dispose()
            return $false
        }
    }
    $script:jsonl = $newPath
    $script:dateKey = $newDateKey
    $script:jsonlStream = $newStream
    $script:jsonlWriter = $newWriter
    if ($oldWriter) { $oldWriter.Dispose() }
    elseif ($oldStream) { $oldStream.Dispose() }
    Prune-OldLogs
    return $true
}
function Redact([string]$Value) {
    if ($null -eq $Value) { return $null }
    return ($Value -replace '(?i)((token|secret|password|authorization)[^\r\n:=]*[=:]\s*)[^\s,}]+', '$1[REDACTED]' -replace '(?i)("prompt"\s*:\s*")[^"]*', '$1[REDACTED]')
}
function Write-Event([string]$Event, [hashtable]$Fields = @{}) {
    if (-not $script:jsonl -or $script:dateKey -ne (Get-LogDateKey) -or ((Test-Path -LiteralPath $script:jsonl) -and (Get-Item -LiteralPath $script:jsonl).Length -ge 10MB)) { New-LogFile }
    $record = @{ timestamp = (Get-Date).ToUniversalTime().ToString('o'); event = $Event } + $Fields
    $script:jsonlWriter.WriteLine(($record | ConvertTo-Json -Compress))
    $script:eventCount++
}
New-LogFile

if (Test-NetConnection 127.0.0.1 -Port $Port -InformationLevel Quiet) {
    try { $existing = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/health" -TimeoutSec 2 } catch { Write-Event 'port_conflict' @{ port = $Port; reason = 'health_unavailable' }; Close-LogWriter; exit 1 }
    if ($existing.service -notin 'ready','ok' -or -not $existing.build) { Write-Event 'port_conflict' @{ port = $Port; reason = 'foreign_service' }; Close-LogWriter; exit 1 }
    Write-Event 'already_listening' @{ port = $Port; build = $existing.build.sha }
    Close-LogWriter
    return [pscustomobject]@{ Started = $false; Reason = 'already_listening'; Log = $script:jsonl }
}

function Write-ProcessOutput([string]$Source, [string]$Line) {
    $safeLine = Redact $Line
    try {
        $daemon = $safeLine | ConvertFrom-Json -ErrorAction Stop
        if ($daemon.event -and $daemon.result -and $null -ne $daemon.duration_ms) {
            Write-Event ([string]$daemon.event) @{
                source = $Source
                job_id = [string]$daemon.job_id
                owner_short = [string]$daemon.owner_short
                from = [string]$daemon.from
                to = [string]$daemon.to
                result = [string]$daemon.result
                duration_ms = [int64]$daemon.duration_ms
            }
            return
        }
    } catch {}
    Write-Event 'process_output' @{ source = $Source; line = $safeLine }
}
function Drain-Output([string]$OutEvent, [string]$ErrEvent) {
    foreach ($item in @(Get-Event -SourceIdentifier $outEvent -ErrorAction SilentlyContinue)) {
        if ($item.SourceEventArgs.Data) { Write-ProcessOutput 'stdout' $item.SourceEventArgs.Data }
        Remove-Event -EventIdentifier $item.EventIdentifier -ErrorAction SilentlyContinue
    }
    foreach ($item in @(Get-Event -SourceIdentifier $errEvent -ErrorAction SilentlyContinue)) {
        if ($item.SourceEventArgs.Data) { Write-ProcessOutput 'stderr' $item.SourceEventArgs.Data }
        Remove-Event -EventIdentifier $item.EventIdentifier -ErrorAction SilentlyContinue
    }
}

$attempt = 0
while ($true) {
    Write-Event 'starting' @{ binary = $BinaryPath; port = $Port; working_directory = $projectRoot; redaction = 'token, secret, password, authorization, prompt values'; attempt = $attempt }
    $oldAddress = $env:FRAMEWEAVER_LISTEN_ADDR
    try {
        $env:FRAMEWEAVER_LISTEN_ADDR = "127.0.0.1:$Port"
        $start = [Diagnostics.ProcessStartInfo]::new($BinaryPath)
        $start.Arguments = $BinaryArguments
        $start.WorkingDirectory = $projectRoot
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $start
        $null = $process.Start()
    } finally { $env:FRAMEWEAVER_LISTEN_ADDR = $oldAddress }
    $outEvent = "frameweaverd-stdout-$($process.Id)-$stamp-$attempt"
    $errEvent = "frameweaverd-stderr-$($process.Id)-$stamp-$attempt"
    Register-ObjectEvent -InputObject $process -EventName OutputDataReceived -SourceIdentifier $outEvent | Out-Null
    Register-ObjectEvent -InputObject $process -EventName ErrorDataReceived -SourceIdentifier $errEvent | Out-Null
    $process.BeginOutputReadLine(); $process.BeginErrorReadLine()

    $deadline = (Get-Date).AddSeconds($HealthTimeoutSeconds)
    $healthy = $false
    while ((Get-Date) -lt $deadline -and -not $process.HasExited) {
        Drain-Output -OutEvent $outEvent -ErrEvent $errEvent
        try {
            $health = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/health" -TimeoutSec 1
            if ($health.service -eq 'ready' -and $health.database -eq 'ready') { $healthy = $true; break }
        } catch {}
        Start-Sleep -Milliseconds 250
    }
    if (-not $healthy) {
        Write-Event 'health_timeout' @{ port = $Port; pid = $process.Id; action = 'stop_child' }
        if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
        Drain-Output -OutEvent $outEvent -ErrEvent $errEvent
        Write-Event 'panic_or_exit' @{ exit_code = 1; pid = $process.Id; reason = 'health_timeout' }
        Unregister-Event -SourceIdentifier $outEvent -ErrorAction SilentlyContinue
        Unregister-Event -SourceIdentifier $errEvent -ErrorAction SilentlyContinue
        Close-LogWriter
        exit 1
    }
    Write-Event 'health_ready' @{ port = $Port; pid = $process.Id; attempt = $attempt }
    while (-not $process.HasExited) { Drain-Output -OutEvent $outEvent -ErrEvent $errEvent; Start-Sleep -Milliseconds 200 }
    $process.WaitForExit(); Drain-Output -OutEvent $outEvent -ErrEvent $errEvent
    $exitCode = $process.ExitCode
    Write-Event ($(if ($exitCode -eq 0) { 'exit' } else { 'panic_or_exit' })) @{ exit_code = $exitCode; pid = $process.Id; attempt = $attempt }
    Unregister-Event -SourceIdentifier $outEvent -ErrorAction SilentlyContinue
    Unregister-Event -SourceIdentifier $errEvent -ErrorAction SilentlyContinue
    if ($exitCode -eq 0 -or $attempt -ge $RestartCount) { Close-LogWriter; exit $exitCode }
    $attempt++
    Write-Event 'watchdog_restart' @{ prior_pid = $process.Id; attempt = $attempt; delay_seconds = $RestartDelaySeconds; exit_code = $exitCode }
    if ($RestartDelaySeconds -gt 0) { Start-Sleep -Seconds $RestartDelaySeconds }
}
