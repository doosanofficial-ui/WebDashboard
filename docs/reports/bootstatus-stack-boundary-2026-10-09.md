# Owned bootstatus stack observation boundary

Native stack execution is paused. The current Mac does not have an established no-new-authentication launch path for the exact Apple simctl target, and debugger connection-loss cleanup has not been exercised. No debugger, sampler, or new Simulator was started for this investigation. Existing physical installation47148ad and user files remain preserved.

## Verified local tool and permission state

Read-only inspection at2026-10-09 14:09UTC found:

- `/usr/sbin/DevToolsSecurity -status` returned exit0 and `Developer mode is currently disabled.` A default-sandbox query had failed to read the policy definition; that was not treated as disabled. The successful query used existing shell permissions without changing the policy.
- The official local [DevToolsSecurity(8) manual](/usr/share/man/man8/DevToolsSecurity.8:17) explains that debugger/performance tools can request administrator authorization on first use. Disabled mode does not prove all debugging impossible, but it does not establish a no-authentication path. No authorization store, hidden session, credentials, or init file was read.
- Xcode's `/Applications/Xcode.app/Contents/Developer/usr/bin/simctl` is a shell wrapper. It checks CoreSimulator's version, may invoke `xcodebuild -runFirstLaunch`, then execs `/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl`.
- Installed CoreSimulator version1171.7 matched the wrapper's expected1171.7, excluding the version-triggered first-launch branch at this local inspection. Remote CI version state is unobserved; this finding cannot be projected onto those failures.
- The actual native simctl is Apple-signed arm64e with library validation, identifier `com.apple.CoreSimulator.simctl`, and SHA256 `3f644d5dc842574dec0124bd9e240c4d55b7b065f69231e03f813876baa00c82`. Its reported entitlements do not include `get-task-allow`. That alone is not proof of denial; target-specific launch permission remains unverified. Apple's [debugging entitlement documentation](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.debugger) describes task-port access and its entitlement conditions.

This establishes a new observable launch boundary: a returned wrapper PID does not prove the native simctl exec has occurred. Directly launching native simctl would be a separate diagnostic variant of the xcrun/wrapper baseline, with the required developer environment preserved. Neither this boundary nor version equality identifies bootstatus's actual internal waiting location.

## Official reference path and remaining safety prerequisites

[SBTarget.Launch](https://lldb.llvm.org/python_api/lldb.SBTarget.html#lldb.SBTarget.Launch) creates a new executable instance and returns its SBProcess. That is a candidate for retaining the process reference from launch rather than attaching to an external PID. [SBProcess.GetUniqueID](https://lldb.llvm.org/python_api/lldb.SBProcess.html#lldb.SBProcess.GetUniqueID) identifies an LLDB process instance; it is not a kernel PID-generation token. The adapter must keep the original reference, compare event instance IDs and reject changed identities, including identical PIDs with different instances. It must not fall back to PID or name attachment.

The installed API documents SetDetachOnError(False) and a flag for killing rather than detaching the inferior on connection loss. SBProcess.Destroy/Kill targets that reference and shuts down its monitoring threads. These are documented mechanisms, not evidence that this Mac's debugserver and inferior actually terminate under all tested failure paths. Their process groups need not match an outer wrapper's group. The outer wrapper exiting or killpg succeeding cannot replace inferior-exit and debugger-cleanup receipts.

Async mode does not bound Launch, interrupt, stack or Kill wall time. Before native execution, a separate watchdog, capped stack output, timely original completion/TERM and late-launch/connection-loss cleanup must be proved. A sampler started by the existing collector thread would not inherit its log child's group. No such native adapter was added or enabled here.

## Device-free admission regression

`scripts/bootstatus_stack_admission.py` implements only read-only policy detection and a pure admission/planning guard. It has no debugger adapter, PID inspection, stack read, native process launch or runner integration. Even an eligible plan records `nativeExecutionPerformed:false`; declared proof booleans in a unit fixture are not native proof.

The guard:

- accepts only an exact successful policy status and returns unknown on denial, timeout or missing output;
- requires explicit true launch authorization, stable-reference and cleanup prerequisites, independently of policy status;
- validates the native bootstatus path, canonical owned UUID, integer PID and LLDB instance IDs, and all event identity fields;
- rejects a reused PID with a different instance, foreign phase/UUID/executable and malformed numeric identities;
- preserves the original deadline and clips a requested planning interval to at most2seconds and remaining budget; rejects nonfinite/overflowing clocks or differences;
- requires cleanup of the original stable reference rather than an event PID.

These tests bound admission decisions only. They cannot prove a native call's duration, task-port permissions, actual kernel binding, stack-output retention or cleanup. A future observer must attempt at most one capture before the original180second phase deadline, supervise actual output and preserve the existing total2MiB retained/staging budget.

TDD first failed because the module did not exist. Later RED runs exposed missing policy stdout, bool-as-int event PID, overflowing clock conversion and infinite clock difference. The corrected actual module passed11 device-free tests. Existing owned phase tests separately cover held optional progress probes, original completion and timeout/TERM; they remain the baseline for a future native adapter.

Protected Teams PID44537 and tunnelPID8391 were confirmed present by the requested PID-only name query. No Teams process was changed. Native stack location and real debugger cleanup remain unobserved because their authorization and safety prerequisites are not established.

The final complete device-free script suite passed **207tests in19.339seconds** on2026-10-09 14:20:58UTC. Documentation validation and diff checks passed. The actual new policy helper also returned disabled and the admission decision returned blocked; it did not start a debugger or create a Simulator. Independent read-only review led to the integer-difference overflow regression before the final pass. These results do not establish native launch permission or stack location.
