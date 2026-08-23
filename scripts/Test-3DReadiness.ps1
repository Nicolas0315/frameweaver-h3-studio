[CmdletBinding()]
param(
    [string]$ManifestPath,
    [string]$ProbeJson,
    [string[]]$InstalledModelId = @(),
    [int]$ReserveVramMiB = 0,
    [int]$MaxGpuUtilizationPercent = -1,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $PSScriptRoot '3d-validation-manifest.json'
}

function Get-Live3DProbe {
    $ProbeGpuOutput = @(& nvidia-smi '--query-gpu=name,memory.total,memory.used,memory.free,utilization.gpu,temperature.gpu' '--format=csv,noheader,nounits' 2>$null)
    $ProbeGpuExitCode = $LASTEXITCODE
    $ProbeGpuLine = $ProbeGpuOutput | Select-Object -First 1
    if ($ProbeGpuExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($ProbeGpuLine)) {
        throw 'nvidia-smi did not return a GPU probe.'
    }

    $ProbeFields = @($ProbeGpuLine -split ',' | ForEach-Object { $_.Trim() })
    if ($ProbeFields.Count -ne 6) {
        throw "Unexpected nvidia-smi field count: $($ProbeFields.Count)"
    }

    $ProbeTrainingMatches = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.CommandLine -and $_.CommandLine -match '(?i)(kohya|deepspeed|accelerate\s+launch|train(?:ing)?[_-]|finetun|dreambooth)'
        } |
        Select-Object ProcessId, Name)

    $ProbeBlenderAvailable = $null -ne (Get-Command blender.exe -ErrorAction SilentlyContinue) -or
        (Test-Path -Path 'C:\Program Files\Blender Foundation\Blender *\blender.exe')

    return [pscustomobject]@{
        host = [Environment]::MachineName
        gpu = [pscustomobject]@{
            name = $ProbeFields[0]
            totalVramMiB = [int]$ProbeFields[1]
            usedVramMiB = [int]$ProbeFields[2]
            freeVramMiB = [int]$ProbeFields[3]
            utilizationPercent = [int]$ProbeFields[4]
            temperatureC = [int]$ProbeFields[5]
        }
        trainingDetected = $ProbeTrainingMatches.Count -gt 0
        trainingProcesses = $ProbeTrainingMatches
        availableExecutables = @($(if ($ProbeBlenderAvailable) { 'blender' }))
        observedAt = (Get-Date).ToUniversalTime().ToString('o')
    }
}

function Get-3DReadinessReport {
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)]$Probe,
        [string[]]$AvailableModels,
        [int]$Reserve,
        [int]$MaxUtilization
    )

    $ProbeGpu = $Probe.gpu
    $Results = foreach ($Case in $Manifest.cases) {
        $Reasons = [System.Collections.Generic.List[string]]::new()

        if ([bool]$Case.alwaysDeferred) {
            $Reasons.Add('policy_deferred')
        }
        if ([bool]$Probe.trainingDetected) {
            $Reasons.Add('training_detected')
        }
        if ([int]$ProbeGpu.utilizationPercent -gt $MaxUtilization) {
            $Reasons.Add('gpu_busy')
        }
        if ([int]$Case.minimumTotalVramMiB -gt [int]$ProbeGpu.totalVramMiB) {
            $Reasons.Add('insufficient_total_vram')
        }
        if ([int]$Case.estimatedVramMiB + $Reserve -gt [int]$ProbeGpu.freeVramMiB) {
            $Reasons.Add('insufficient_free_vram')
        }
        if ($null -ne $Case.modelId -and $AvailableModels -notcontains [string]$Case.modelId) {
            $Reasons.Add('model_not_installed')
        }
        if ($null -ne $Case.requiredExecutable -and @($Probe.availableExecutables) -notcontains [string]$Case.requiredExecutable) {
            $Reasons.Add('runtime_not_installed')
        }

        [pscustomobject]@{
            id = $Case.id
            label = $Case.label
            phase = $Case.phase
            runner = $Case.runner
            minimumTotalVramMiB = [int]$Case.minimumTotalVramMiB
            estimatedVramMiB = [int]$Case.estimatedVramMiB
            decision = if ($Reasons.Count -eq 0) { 'ready' } else { 'deferred' }
            reasons = @($Reasons)
        }
    }

    return [pscustomobject]@{
        schemaVersion = 1
        host = $Probe.host
        observedAt = $Probe.observedAt
        gpu = $ProbeGpu
        gates = [pscustomobject]@{
            reserveVramMiB = $Reserve
            maxGpuUtilizationPercent = $MaxUtilization
            trainingDetected = [bool]$Probe.trainingDetected
        }
        cases = @($Results)
    }
}

function Invoke-3DReadinessSelfTest {
    $TestManifest = [pscustomobject]@{
        cases = @(
            [pscustomobject]@{ id = 'smoke'; label = 'Smoke'; phase = 'postprocess'; runner = 'blender'; minimumTotalVramMiB = 0; estimatedVramMiB = 0; modelId = $null; requiredExecutable = 'blender'; alwaysDeferred = $false },
            [pscustomobject]@{ id = 'light'; label = 'Light'; phase = 'preview'; runner = 'worker'; minimumTotalVramMiB = 4096; estimatedVramMiB = 4096; modelId = 'light-model'; requiredExecutable = $null; alwaysDeferred = $false },
            [pscustomobject]@{ id = 'heavy'; label = 'Heavy'; phase = 'training'; runner = 'worker'; minimumTotalVramMiB = 12000; estimatedVramMiB = 12000; modelId = 'heavy-model'; requiredExecutable = $null; alwaysDeferred = $true }
        )
    }
    $TestProbe = [pscustomobject]@{
        host = 'TEST'
        observedAt = '2026-01-01T00:00:00Z'
        trainingDetected = $false
        availableExecutables = @('blender')
        gpu = [pscustomobject]@{ name = 'TEST GPU'; totalVramMiB = 8192; usedVramMiB = 512; freeVramMiB = 7680; utilizationPercent = 0; temperatureC = 30 }
    }
    $TestReport = Get-3DReadinessReport -Manifest $TestManifest -Probe $TestProbe -AvailableModels @('light-model') -Reserve 1024 -MaxUtilization 10

    if (($TestReport.cases | Where-Object id -eq 'smoke').decision -ne 'ready') { throw 'Self-test failed: smoke must be ready.' }
    if (($TestReport.cases | Where-Object id -eq 'light').decision -ne 'ready') { throw 'Self-test failed: installed light model must be ready.' }
    $TestHeavy = $TestReport.cases | Where-Object id -eq 'heavy'
    if ($TestHeavy.decision -ne 'deferred' -or $TestHeavy.reasons -notcontains 'policy_deferred' -or $TestHeavy.reasons -notcontains 'insufficient_total_vram' -or $TestHeavy.reasons -notcontains 'insufficient_free_vram') {
        throw 'Self-test failed: heavy case must be deferred by policy, total VRAM, and free VRAM.'
    }

    $TestMissingModel = Get-3DReadinessReport -Manifest $TestManifest -Probe $TestProbe -AvailableModels @() -Reserve 1024 -MaxUtilization 10
    if (($TestMissingModel.cases | Where-Object id -eq 'light').reasons -notcontains 'model_not_installed') {
        throw 'Self-test failed: missing model must defer the case.'
    }

    $TestProbe.availableExecutables = @()
    $TestMissingRuntime = Get-3DReadinessReport -Manifest $TestManifest -Probe $TestProbe -AvailableModels @('light-model') -Reserve 1024 -MaxUtilization 10
    if (($TestMissingRuntime.cases | Where-Object id -eq 'smoke').reasons -notcontains 'runtime_not_installed') {
        throw 'Self-test failed: missing runtime must defer the case.'
    }
    $TestProbe.availableExecutables = @('blender')

    $TestProbe.gpu.utilizationPercent = 50
    $TestBusy = Get-3DReadinessReport -Manifest $TestManifest -Probe $TestProbe -AvailableModels @('light-model') -Reserve 1024 -MaxUtilization 10
    if (($TestBusy.cases | Where-Object id -eq 'light').reasons -notcontains 'gpu_busy') {
        throw 'Self-test failed: busy GPU must defer the case.'
    }

    $TestProbe.gpu.utilizationPercent = 0
    $TestProbe.trainingDetected = $true
    $TestTraining = Get-3DReadinessReport -Manifest $TestManifest -Probe $TestProbe -AvailableModels @('light-model') -Reserve 1024 -MaxUtilization 10
    if (($TestTraining.cases | Where-Object id -eq 'light').reasons -notcontains 'training_detected') {
        throw 'Self-test failed: detected training must defer the case.'
    }

    [pscustomobject]@{ selfTest = 'passed'; assertions = 7 } | ConvertTo-Json -Compress
}

if ($SelfTest) {
    Invoke-3DReadinessSelfTest
    exit 0
}

$Manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
$EffectiveReserve = if ($ReserveVramMiB -gt 0) { $ReserveVramMiB } else { [int]$Manifest.defaultReserveVramMiB }
$EffectiveMaxUtilization = if ($MaxGpuUtilizationPercent -ge 0) { $MaxGpuUtilizationPercent } else { [int]$Manifest.defaultMaxGpuUtilizationPercent }
$Probe = if ([string]::IsNullOrWhiteSpace($ProbeJson)) { Get-Live3DProbe } else { $ProbeJson | ConvertFrom-Json }

Get-3DReadinessReport -Manifest $Manifest -Probe $Probe -AvailableModels $InstalledModelId -Reserve $EffectiveReserve -MaxUtilization $EffectiveMaxUtilization |
    ConvertTo-Json -Depth 8
