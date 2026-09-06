[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$MarkerPath,
    [int]$Seconds = 5
)

[IO.File]::WriteAllText($MarkerPath, 'started', [Text.Encoding]::ASCII)
Start-Sleep -Seconds $Seconds
