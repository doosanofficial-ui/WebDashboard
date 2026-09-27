# UI and CAN Architecture Audit - Approval Gate

Date: 2026-09-27
Scope: read-only audit of the current native iOS app and the Windows CAN integration seams.
No production UI or CAN code is changed by this audit.

## Evidence

- Current production screenshot: /tmp/telemetry-gps-rail-live.png
- Approval mockups:
  - /tmp/telemetry-mockup-a-full.png: Operator Grid (recommended)
  - /tmp/telemetry-mockup-b-full.png: Data Dense Signals
  - /tmp/telemetry-mockup-c-full.png: Setup First-run Console
- Current branch baseline: a7235c2
- User-owned mobile/ changes are excluded.

## Exhaustive Screen Inventory

| Surface | Source | Primary controls | Audit result |
| --- | --- | --- | --- |
| Root tabs | mobile-ios/App/DashboardView.swift:6-45 | Live, Signals, Sessions, Setup | Correct information architecture, but tab shell has no compact iPad strategy |
| Live cockpit | mobile-ios/App/LiveCockpitView.swift:12-728 | Edit, MARK, REC, GPS, page picker, widget actions | P0 visual density and bottom rail width failure |
| Signals | mobile-ios/App/SignalsView.swift:5-285 | Edit catalog, demo/live adapter, stop, signal rows | Good diagnostic boundary, but no search/filter and developer controls are too prominent |
| Sessions | mobile-ios/App/SessionsView.swift:4-181 | Start/stop recording, MARK, JSON, CSV | No session history; export is duplicated in Setup |
| Setup | mobile-ios/App/DashboardView.swift:49-227 | Connect, disconnect, credential, settings, exports, profile, BLE | P1 monolithic Form; too many unrelated responsibilities |
| Dashboard editor | mobile-ios/App/DashboardEditorView.swift:4-430 | Done, page picker, add page/widget, orientation, snap, delete, align, duplicate, delete, inspector | P0 fixed canvas and cramped editor controls |
| Signal catalog editor | mobile-ios/App/SignalCatalogEditorView.swift:4-240 | Add, select, delete, apply, cancel, save | P1 dense HStack fields, no delete confirmation, weak validation feedback |
| CarPlay projection | mobile-ios/App/CarPlay/CarPlayProjection.swift:6-23 | System list only | Must stay entitlement-gated and status-only |

## P0 UI Findings

1. Live action rail is not resilient to the fourth action. The current
   MARK/REC/GPS rail uses flexible MARK space plus fixed REC/GPS/status widths
   in LiveCockpitView.swift:240-308; the current screenshot renders MARK as
   vertically stacked letters. Use equal-width action cells and a separate
   compact status row.
2. Live hierarchy is too tall for a driving screen. The status strip,
   58-point primary value, 2x2 wheels, two 132-point charts, GPS, profile canvas,
   and safe-area rail are stacked in LiveCockpitView.swift:12-48 and
   98-217. The primary driving state should fit before the first swipe:
   connection strip, primary value, wheel 2x2, charts/GPS summary, actions.
   The customizable profile canvas should be a separate Live subpage or preset.
3. Typography is not tokenized for Dynamic Type. Raw .caption/.caption2 and
   hard-coded system sizes are spread across LiveCockpitView.swift,
   SignalsView.swift, SessionsView.swift, and TelemetryMetricCard.swift.
   Caption2 is too small for moving-vehicle use and the current all-caps
   tracking increases visual noise.
4. The declared horizontalSizeClass is not used in LiveCockpitView.swift:10.
   iPad and compact iPhone therefore share assumptions instead of using
   AnyLayout/ViewThatFits for the actual proposal.
5. Setup is a single Form with server, credential, background, export, adapter,
   and BLE sections in DashboardView.swift:49-227. It has no first-run sequence,
   no advanced-section boundary, and duplicates export actions in SessionsView.
6. DashboardEditorCanvas uses fixed heights and cell calculations in
   DashboardEditorView.swift:303-365. Portrait/landscape, keyboard, Dynamic Type,
   and iPad split widths can clip or create excessive empty space.
7. DashboardEditor deletion and page deletion are destructive Button actions in
   DashboardEditorView.swift:94-101 and 154-157 without a confirmation dialog or
   undo path.
8. SignalCatalogEditor uses multiple horizontal field groups in portrait
   SignalCatalogEditorView.swift:67-93. This will compress text fields and
   numeric input affordances on iPhone; deletion at 46-49 has no confirmation.

## P1 UI Findings

- SignalsView.swift:100-156 always renders the fallback seven-signal list even
  when no server frame/profile exists. It is correctly stale, but the screen
  should say "No source" instead of presenting an apparent catalog.
- SignalsView.swift:184-211 keeps Demo adapter and live transport controls in
  the main diagnostic page. Put them inside a collapsed Developer section.
- SessionsView.swift:4-181 shows current session state but not prior sessions,
  interrupted-session reason, frame count, or last export destination.
- SetupView exports and SessionsView exports represent one action in two places;
  keep export in Sessions and retain only storage policy text in Setup.
- Map/profile/editor surfaces lack an explicit compact/expanded preview and
  consistent 44-point touch target audit.
- CarPlayProjection.swift:10-20 maps every primaryValues entry into the list.
  Once entitlement exists, this must become an explicit allowlist of glanceable
  status/alerts, not a raw signal dump.

## Proposed UI Direction

Recommended: mockup A, Operator Grid.

- Use a compact top status rail.
- Use one primary metric hero with age/source/quality on the same surface.
- Use two-by-two wheel metrics with short labels and one-line values.
- Use fixed-height mini charts with a clear latest value and stale badge.
- Use a GPS summary card, not a large map on the driving page.
- Use equal-width MARK / REC / GPS controls; put recording/GPS detail beside
  them, not inside the buttons.
- Move full profile canvas, editor and developer controls out of the first
  driving viewport.
- Use the same spacing/font/status tokens on Signals, Sessions and Setup.

## CAN Integration Findings

- Current server requirements contain FastAPI, Uvicorn and httpx only:
  server/requirements.txt:1-3. python-can is not installed or imported.
- Current source factory supports only DummyCANSource:
  server/can_source/__init__.py:7-15.
- Current source interface returns only dict[str, float]:
  server/can_source/base.py:6-11. It cannot preserve arbitration ID, DLC,
  raw payload, CAN-FD flags, channel, or hardware timestamp.
- Current server v1 payload contains only v/t/sig/status:
  server/app.py:115-123. Raw CAN and CAN-FD metadata are not transported.
- Native CANFrame rejects DLC above 8:
  mobile-ios/TelemetryCore/Sources/TelemetryCore/CAN.swift:32-34.
- Native signal definitions and bit positions are capped at 64 bits:
  CAN.swift:125-136. This is sufficient for classical CAN payloads but not
  user-defined signals anywhere in a 64-byte CAN-FD payload.
- Therefore python-can is not currently used and CAN-FD is not currently
  supported end-to-end. The current project is Classical CAN / decoded snapshot
  only.

## Recommended CAN Architecture After Approval

1. Preferred Vector path: CANoe owns VN1640A and the measurement database. A
   CANoe CAPL/Python/C# bridge publishes a versioned local JSON/UDP/TCP envelope
   to the Windows server. This avoids competing channel ownership and preserves
   CANoe's decoded signal semantics.
2. Optional direct path: a Windows-only python-can VectorSource uses the Vector
   XL Driver Library and explicit Vector Hardware Configuration application/channel
   mapping. It must be mutually exclusive with CANoe ownership or use a verified
   multi-application configuration.
3. Add an additive v2 raw frame envelope while keeping v1 decoded snapshots:
   source, channel, received_at, arbitration_id, extended, is_fd, bitrate_switch,
   error_state_indicator, raw_dlc, data_length, payload_hex, and decoded signals.
4. Keep Classical CAN and CAN-FD behind the same FrameSource interface. Map
   Classical DLC 0-8 directly; map CAN-FD DLC 9-15 to 12/16/20/24/32/48/64
   data bytes. Never treat a CAN-FD DLC code as a payload byte count.
5. Extend Swift CANFrame and SignalDefinition only after the server contract and
   recorded fixtures exist. Add raw-frame and CAN-FD UI badges to Signals, not
   to the primary driving page.

## Official Source Conclusions

- Vector's VN1600 page lists VN1640A support for CAN/CAN FD and up to 8 Mbit/s
  CAN-FD bitrate. This proves hardware capability, not this project's integration.
- python-can's VectorBus documentation supports Windows Vector channels and
  explicit fd/data_bitrate/BitTimingFd configuration. This proves a plausible
  direct adapter, not that CANoe 15 and python-can may safely own the same
  channel simultaneously.
- Vector documents CANoe COM automation and CAPL/Python/C# test/programming
  interfaces, but the exact CANoe 15 edition/license/API surface must be checked
  against the installed CANoe 15 Help and license.
- Bosch defines CAN FD as expanding the payload from 8 to 64 bytes and allowing
  a data-phase bitrate switch. The existing eight-byte Swift validation is
  therefore a deliberate current limitation, not CAN-FD support.

References:
- https://www.vector.com/en/product/vn1600/
- https://python-can.readthedocs.io/_/downloads/en/main/pdf/
- https://github.com/hardbyte/python-can
- https://support.vector.com/kb/?id=kb_article_view&sysparm_article=KB0013442
- https://www.bosch-semiconductors.com/products/ip-modules/can-protocols/can-fd/
- https://www.vector.com/en/product/canoe/
