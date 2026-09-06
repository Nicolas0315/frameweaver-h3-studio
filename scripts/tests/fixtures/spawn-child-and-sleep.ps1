[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ChildPidPath,
    [Parameter(Mandatory = $true)][string]$ChildScriptPath,
    [int]$ParentSeconds = 30
)

$child = Start-Process -FilePath powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$ChildScriptPath) -WindowStyle Hidden -PassThru
[IO.File]::WriteAllText($ChildPidPath, [string]$child.Id, [Text.Encoding]::ASCII)
Start-Sleep -Seconds $ParentSeconds
