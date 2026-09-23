# Offline OBD Candidate Qualification

Run from the repository root on a Mac with full Xcode, GitHub CLI and XcodeGen:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  PATH="$HOME/.local/bin:$PATH" scripts/obd_eval/evaluate.sh
```

The tool downloads two exact upstream commits into a new ASCII `/tmp` directory,
records archive hashes/toolchain versions, builds/tests them and compiles a temporary
iOS Simulator host. Source changes are limited to inserting our tests into the
temporary SwiftOBD2 test target and creating a separate LTSupportAutomotive test host.
It does not modify upstream production code or this app's package dependencies.
Both upstream source archives retain their MIT license files.

No app is launched, Bluetooth manager instantiated, scanner connected, or ECU command
sent by the qualification probes. The upstream tests were inspected for mock/pure
operation at the pinned commits. Review that assumption if updating either pin.

## Results

The exit status is nonzero when **any candidate phase fails**. Do not interpret that
as a production-server test failure or change assertions to green-light an SDK.
Read `exit-codes.tsv` and the corresponding log to distinguish compilation failure
from failed acceptance assertions. A zero exit still would not prove real hardware,
iOS background scheduling, or the user's required independent success reports.

Current pinned results (2026-09-23):

- SwiftOBD2 upstream 26 tests pass; our timeout acceptance test fails.
- LTSupportAutomotive builds; our PID06 and padding boundary tests fail.
- The temporary iOS Simulator host compiles both packages with Xcode 26.3 / SDK 26.2.

These probes are intentionally **not in the production CI passing suite**. They are
reproducible adoption gates for external candidates. Do not ship either SDK unmodified
on the strength of the upstream suite or simulator compile alone.

Details: `docs/reports/obd-candidate-qualification-2026-09-23.md`.
