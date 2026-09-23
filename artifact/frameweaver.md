# FrameWeaverd lifecycle fixture receipt

- Worktree HEAD: `c2539c75c653d0ded413f6222a92aa51690b5988`
- Uncommitted fixture diff hash: `63c139533596ba592920fb11b580b276be98c8eb`
- Owned fixture residual scan: `0` (`powershell.exe`, `frameweaverd.exe`, and `frameweaver-shadow-comfy.exe` with the worktree command line)
- Suite 1: Pester `20 passed, 0 failed`; stderr empty; OS exit receipt was not retained.
- Suite 2: Pester `20 passed, 0 failed`; stderr length `0`; wrapper exit file recorded `1` and is not accepted as a success receipt.

## Wrapper under investigation

```powershell
$cmd = "Invoke-Pester -Script '$tf' -EnableExit; `$code=`$LASTEXITCODE; [IO.File]::WriteAllText('$a.exit',[string]`$code,[Text.Encoding]::ASCII); exit `$code"
$p = Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-Command',$cmd) -RedirectStandardOutput ($a+'.out') -RedirectStandardError ($a+'.err') -WindowStyle Hidden -PassThru
```

The stale `$LASTEXITCODE` capture is the suspected receipt defect. No additional suite was started after observing it.
