# Hosted cleanup after a shutdown failure

Base: `eb6ce2143ac074ece88d857566ad0e0444fea9cc`, canonical `main`.
Scope: `scripts/verify_ios_lifecycle.py`, its existing Python contract tests, and this record.

## Confirmed failure and unchanged contracts

The base SHA's automatic Hosted workflow ran89/89 XCTest cases successfully, then its own UUID `A49CC5A1-611E-4B34-8455-2F362CDF76BB` shutdown raised `TimeoutExpired` at60 seconds. The original `finally` block therefore never called the following delete or private workspace cleanup. The saved job log and runner source establish this control-flow defect; they do not establish the CoreSimulator timeout cause or subsequent external runner retirement.

The fix preserves the original command budgets: shutdown60, delete60, bootstrap180, Xcode900. Cleanup commands still use only the UUID returned by this run's create command. The existing unchecked shutdown return-code policy and checked delete policy are preserved. A nonzero unchecked shutdown result is recorded explicitly with `commandSucceeded=false`, `accepted=true`; a raised timeout or launch error remains a failure. No timeout extension, retry, global service operation, existing Simulator selection or physical installation is added.

## Behavior after the change

- Attempt shutdown and delete separately, including after a shutdown exception.
- Always attempt cleanup of the private source workspace after these operations.
- Preserve a pending body exception. If the body passed, rethrow the first cleanup exception; later delete/workspace/receipt errors cannot turn it into success or replace it.
- Write `simulator-cleanup.json` with the created UUID, phase command/policy/timeout/exit/error details and workspace outcome. Missing receipt evidence is a failing gate when the body passed.
- Print the existing Hosted PASS marker only after cleanup and receipt completion. Passing XCTest counters alone cannot print a combined PASS after cleanup fails.

## RED and GREEN evidence

Before changing the production runner, two new tests executed its actual `main` control flow and failed as expected: events were only `[shutdown]`, and shutdown timeout replaced the original bootstatus timeout. This is the reproduced control-flow defect, not a reproduction of the CoreSimulator environment delay.

Independent review also identified an unprotected receipt-error diagnostic. Two further RED assertions reproduced stderr `BrokenPipeError` replacing the pending body/first cleanup exception. Recording the receipt error before a best-effort diagnostic guard fixed this path. Final read-only review: Critical0/Important0.

Final whole Python runner suite:106 tests passed in9.815s, zero failures/skips. The eleven added cases cover shutdown timeout, simultaneous body/shutdown/delete failure, delete nonzero after passing counters, legacy unchecked shutdown status, Xcode failure plus cleanup launch failure, failure before a UUID exists, receipt failure with/without a prior body failure, workspace failure after the first cleanup timeout, and receipt-plus-stderr failure with a pending body/first cleanup error.

These tests execute the real runner orchestration with synthetic external host/device boundaries and real ordinary-file owned/unrelated markers. They never execute Xcode or simctl and are not89 native XCTest cases or hardware evidence. Existing process-runner contracts still exercise their own private synthetic child processes. The fresh committed SHA must be judged from its own automatic CI result, including its native XCTest summary and new cleanup receipt.

Local evidence: `hosted-cleanup-control-flow-20261008/` in the delegated workspace preserves the original runner/tests, RED log, full GREEN log, source hashes, commands and the44 user-file baseline. Prior70 task inputs and all44 user files matched their preserved hashes; actual keystore bytes were not read. App/UI, runtime selection, UI selectors and Teams were not changed.

## Remaining limits

The native shutdown and bootstrap timeout causes and the older Layout activation-point cause remain unconfirmed. This change repairs follow-up cleanup and failure preservation, not general Simulator readiness or shutdown reliability. No failed workflow rerun or local physical/Simulator trial was requested.
