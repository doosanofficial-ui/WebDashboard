# Simulator startup budget diagnosis

Source baseline: `d847813d17ad518de76c334889919f00b5146b94`. Its automatic Native Reliability run [37694912708](https://github.com/doosanofficial-ui/WebDashboard/actions/runs/37694912708) failed. Layout14 and Help4 did not reach App build or XCTest; basic iPhone17 UI13/31 and separate SE2/2 passed. Earlier failure artifacts remain preserved. No run was retried.

| Same-SHA group | bootstatus outcome | Phase start to first empty log timestamp | Early event time span |
| --- | --- | ---: | ---: |
| Layout | 180s timeout; final receipt190.385s | 31.455s | 56.156s |
| Help | 180s timeout; final receipt193.707s | 18.538s | 48.126s |
| SE | PASS; completion observed152.506s | 1.344s | 41.701s |
| Replay route | PASS; completion observed141.230s | 19.240s | 44.252s |

The first-log timestamp is an indirect measure of metadata, file operations and host scheduling before launch; it is not a measured `sysctl` duration. Both failed and successful old-image jobs had delayed observations and `pgrep` timeouts. SE used image20261006.0244.1/macOS27.0.1; route, layout and help used image20260928.0222.1/macOS27.0. A shared matrix host, image defect, CPU or memory exhaustion is not established. `memoryBytes` in the old receipts is total physical RAM, not free memory.

All four early NDJSON streams contain only the created UUID (foreign/invalid0), and all hit the same2MiB cap before bootstatus completion or timeout. Shared initial framebuffer fallback, missing stores and early deviceDidBoot do not distinguish success from failure. Later boot progress is unobserved. Layout and Help preserved collector cleanup true with signal EPERM, Simulator cleanup false from shutdown timeout, and successful UUID-specific delete. Do not replace these mixed outcomes with a clean or retained-device claim.

The confirmed runner defect is that `run_owned_phase` starts its deadline, synchronously calls optional `resource_snapshot`, then opens the log and launches the child. `resource_snapshot` runs external memory `sysctl`; local Python3.9.6 also invokes external `uname -p`/`file` through a cold `platform.platform`. Slow observations can consume a child's budget before it executes. The10s failure-state diagnostic also lost5.976s/7.279s before its first log timestamp. The contribution of each operation to the remote delay cannot be separated from the old receipts.

The narrow change uses only `os.uname`, `os.cpu_count`, `os.getloadavg` and runner environment fields within timed phases. Physical memory is explicitly not sampled there; Seed producer resource reporting stays unchanged. The receipt records phase start, snapshot completion, launch request/return, child-wait start, observed completion and group-stop request. It preserves the original deadline and boot60/bootstatus180/App600/UI1200/cleanup60 budgets, child error, UUID targets and process-group cleanup. No runtime fallback, extra boot attempt or global service operation is added.

Actual owned-Python-child regression with a deliberately slow memory dependency:

- Before: timely success and exit7 were both replaced by timeout (two expected assertion failures). The old late-child case also reported timeout, but its already-spent startup budget does not prove that the delayed child actually ran.
- After: all three initial cases pass, including the unchanged0.6s late-child budget and chronological startup receipt. Independent review identified scheduling fragility in the unit fixture; final tests use a2s fixture budget and a2.4s delayed child/probe, with an added hard guard forbidding external platform/memory probes. This changes only test scheduling tolerance, not runner boot/App/UI/cleanup budgets. Two earlier fake-dependency harness errors are preserved separately and are not counted as product failures or valid RED.
- This reproduces the runner deadline defect. It does not reproduce the remote CoreSimulator root cause.

The new automatic SHA must still execute the original Layout14 and Help4 selectors, preserve actual summaries and require all31 basic UI cases plus separate SE2. New receipt timing must distinguish a late launcher/waiter from completed preparation, without resetting deadlines. If bootstrap still fails, inspect the new launch timings and preserve the original error and cleanup; do not widen timeout or rerun the same SHA without a new hypothesis. Synchronous optional `owned_progress` can still delay main-thread TERM/final recording despite the independent completion waiter; the new stop timestamp exposes that remaining limitation. Late unified-log coverage remains bounded and unverified.

The application UI is unchanged. For the existing figure39 Done concern, the full750×1334 PNG SHA256 `2ca987b6e2947367ef305b38a2d5ff8fe95711ebb7e099a167d8ee9d19b0cb9e` matches both report payloads. Done AX `(280.5,40,74.5,36)`pt is within the375×667 window with20pt right inset; the original shows the whole label/capsule. Exact touch region, Done-specific hittability, VoiceOver and the parent's presentation discrepancy remain unverified. Existing user files, other Simulators and Teams services are preserved.
