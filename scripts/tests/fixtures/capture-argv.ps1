[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Values
)

[IO.File]::WriteAllText($OutputPath, ($Values | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
