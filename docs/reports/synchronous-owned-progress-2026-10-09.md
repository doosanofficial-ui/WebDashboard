# Synchronous owned progress: completion and cleanup delay

The optional native process probe could delay phase completion and owned-group
cleanup after the completion waiter had already reported the original outcome.
`owned_progress` now records the owned group and local log metadata without
spawning `pgrep` or `ps`. Process rows are `null`, with `not-sampled` status and
an explicit reason; this is unknown process state, not an empty or healthy group.

## Observed failure

Source: commit `4e8e75ad770da9d279eb8de8f6ac8ac3a74958df`,
[Layout job 113766574706](https://github.com/doosanofficial-ui/WebDashboard/actions/runs/37914143464/job/113766574706),
artifact `11610753233`, ZIP SHA-256
`8a0473d1a0b586368eff968c18815b947c61cf1d8672123f9b27f6c6142f879e`.
The original receipts and bounded owned-UUID logs were preserved.

| Python call observation | Seconds |
| --- | ---: |
| Original bootstatus budget | 180 |
| Progress call spanning completion notification | 20.946 |
| Event.set return to main observation | 17.857 |
| TERM request, relative to phase start | 198.494 |
| Entire recorded phase | 210.604 |

The save immediately after that progress call took 0.001041 seconds.
The final progress call after TERM took another 10.801 seconds. These are Python
call observations, not kernel execution or notification-delivery timestamps.

## Regression and limits

Two real owned Python-child regressions failed before the change and passed
afterward. They hold the optional native probe behind a gate and require both
timely completion and Timeout cleanup to return before that gate is released.
They also check original verdict/budget preservation, child reaping, waiter
termination, owned-group absence, no native progress probe, and unknown process
rows. The complete device-free Python suite passed 195 tests. No local Xcode,
Simulator, physical-device action or new diagnostic collection was run.

Phase deadlines, verdicts, completion boundaries, TERM/KILL/reaping and existing
owned-UUID diagnostics are unchanged. Filesystem calls, process launch and host
scheduling can still delay wall-clock return; this is not a hard deadline guarantee.

The Simulator boot root cause remains unknown. In the retained failing Layout
logs, the renderer callback occurred early and Reminders migration activity
continued after the Timeout observation. Those events do not identify the
readiness stage awaited by bootstatus. Its stdout was empty, and 4,198 middle
events were evicted from the bounded head/tail capture. No pre-deadline native
client stack or direct readiness-stage observation establishes a blocked service.
Remote CI for this change is tracked separately by its exact commit after push.
