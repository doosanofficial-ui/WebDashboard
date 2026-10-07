# UI visual review record

UI verification requires direct inspection of actual screenshot pixels. Automated tests and generated captures are separate evidence. Copy the record below for the active task; replace placeholders with observed facts and stable artifact links.

## Scope and provenance

- Task and acceptance criteria:
- Source commit / build identity:
- Capture date, platform/device/runtime, viewport, orientation, text size and language:
- Capture source (existing CI artifact, permitted live capture or user-provided image):
- Automated functional evidence and result:
- Visual scope and required screens/states:
- Physical-device scope and availability:

## Screens and states

Add a row for each required screen/state and each screenshot used as visual evidence. Directly open every referenced screenshot; do not mark an unopened capture passed.

| Screen/state | Screenshot link | Capture provenance/environment | Directly opened by / review time | Pixel inspection findings | Visual result | Parent core review |
| --- | --- | --- | --- | --- | --- | --- |
| <required screen and state> | <stable link> | <commit/build and capture environment> | <reviewer/time or NOT OPENED> | <content/state, legibility, clipping/overlap, controls/navigation> | <PASS / FAIL / UNVERIFIED> | <reviewer/time or NOT REVIEWED> |

Include viewport, orientation, text-size or language variants when relevant to the change. A contact sheet can help navigation but does not replace opening evidence at a readable scale. Preserve original captures and identify any redacted shareable copies.

## Unverified items

Report these separately even if automated tests passed:

| Category | Screen/state or scope | Evidence / reason | Next required check |
| --- | --- | --- | --- |
| Unopened screenshot | <scope or NONE> | <path/reason> | <direct inspection> |
| Blocked/inaccessible capture | <scope or NONE> | <observed access/capture limitation> | <permitted recovery> |
| Physical-device UI not inspected | <scope or NONE> | <device absence, installation hold or other observed boundary> | <separately permitted device review> |

## Completion boundary

- Automated functional result:
- Directly inspected visual result:
- Physical-device result:
- Parent/primary agent's direct core screenshot review:
- Remaining defects and unverified scope:
- User-facing completion claim supported by the evidence:

Screenshots establish visible presentation at capture time. They do not by themselves prove BLE/GPS acquisition, durable recording, background/reconnection behavior or preservation of existing data. Do not clear those separate gates or resume a paused install through a visual-review result.

This record is a template, not completed UI verification evidence.
