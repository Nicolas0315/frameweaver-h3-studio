[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Executable,
    [Parameter(Mandatory = $true)][string]$ArgumentsBase64,
    [Parameter(Mandatory = $true)][string]$ExitCodePath
)

$argumentsJson = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ArgumentsBase64))
$arguments = @($argumentsJson | ConvertFrom-Json)
try {
    & $Executable @arguments
    $exitCode = $LASTEXITCODE
} catch {
    $exitCode = 1
    [Console]::Error.WriteLine($_.Exception.Message)
}
[IO.File]::WriteAllText($ExitCodePath, [string]$exitCode, [Text.Encoding]::ASCII)
exit $exitCode
