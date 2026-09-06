# Lifecycle watchdog investigation - 2026-09-06

## Scope and safety boundary

- Base under test: `6f7737f`.
- The fixture uses a unique loopback port, `$TestDrive` log directory, a unique
  `LOCALAPPDATA`, and `frameweaver-shadow-comfy.exe` plus `frameweaverd.exe`
  built in the isolated worktree.
- It does not use a production Comfy endpoint, Discord credentials, or an
  existing Scheduled Task. The XML Apply test replaces every Scheduled Task
  cmdlet with Pester-local functions.

## Observations

| Run | Result | Event evidence |
| --- | --- | --- |
| Pester with exit-code capture | 7 passed, 1 failed, exit 1 | `starting` at `02:47:40.553Z`, first `health_ready` for PID `109460` at `02:47:41.153Z`, `panic_or_exit` at `02:47:44.298Z`, and `watchdog_restart` at `02:47:44.323Z`. No attempt-1 `starting` event was written before the test's 15-second event wait elapsed. |
| Direct isolated watchdog observation | passed | First `health_ready` arrived about 0.60 seconds after `starting`; after the child was stopped, attempt 1 wrote `starting` after about 1.02 seconds and a second `health_ready` about 0.52 seconds later. The port was the same unique loopback port for both attempts. |
| Pester rerun with exit-code capture | 8 passed, 0 failed, exit 0 | The watchdog test passed in 14.24 seconds; the full lifecycle file completed in 39.61 seconds. |

The failure log includes the first child stdout records (`frameweaverd listening`
and `startup reconciliation complete`) before the forced child exit. Therefore
the failed observation is not explained by an unflushed first-child output.

## Narrowed location and current status

`Start-FrameWeaver.ps1` writes `watchdog_restart`, sleeps for the configured
one second, then synchronously writes the next `starting` event before it calls
`Process.Start` for the replacement daemon. Since the failed log contains
`watchdog_restart` but no attempt-1 `starting`, the unobserved interval is in
the runner between that event and the next loop entry. It is before replacement
daemon launch, so the evidence does not support attributing this occurrence to
the replacement daemon's port bind, health probe, or stdout flush.

The Pester helper waiting for the second event does not receive the runner
process object, so it cannot report whether the runner exited during that
interval. No runner stderr or runner-exit event is currently persisted by the
fixture. The direct observation and subsequent full Pester pass demonstrate
that the contract can succeed, but the captured failure means reliability is
not established. Cause remains **unconfirmed**; no timeout was increased and
no retry was added.

## Follow-up required before treating this as stable

Instrument the runner fixture to persist its own exit/error state and add the
runner process to the second-event wait diagnostics. Then reproduce the same
forced-child-exit sequence without changing the 15-second assertion. Do not
classify a successful rerun as a fix for the captured failure.
