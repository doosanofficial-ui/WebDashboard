"""Read-only Help source plan and unapplied copy proposal; never a native gate.

This module has no Simulator, defaults, process lifecycle or upload adapter.
Pinned function bodies prevent inferred screenshot states from surviving an
unreviewed capture change. It never changes images, manifests or product files.
"""
import argparse
import ast
import difflib
import hashlib
import json
from pathlib import Path
import re

import verify_help_assets as assets

HELP_SOURCE = "mobile-ios/App/AppHelpView.swift"
LANGUAGE_SOURCE = "mobile-ios/App/AppLocalization.swift"
CAPTURE_SOURCE = "mobile-ios/UITests/LocalizationHelpUITests.swift"
CAPTURE_BODY_SHA256 = "8061fcc04f3f18379678bae35c063182d1d3503b1b258a1c0f6e30d3fdfd0a2d"
# Reviewed Replay copy now directs END-position readers to Recorded time > Start.
HELP_SOURCE_SHA256 = "245564cfac9be2b859c2f34a44e4f6716559fe296093d258cf9bc66fccc1720c"
LANGUAGE_PREFIX_SHA256 = "26c84edc11934f388e62b8d2bb27eadc8d6f1b35651507af3f5991506f4aa55c"


class PreparationError(RuntimeError):
    pass


def require(condition, message):
    if not condition:
        raise PreparationError(message)


def digest(source):
    return hashlib.sha256(source.encode("utf-8")).hexdigest()


def capture_body(source):
    start = "    private func captureScreens("
    end = "\n    func testCaptureEnglishGuideScreens"
    require(source.count(start) == source.count(end) == 1, "Capture function boundaries changed")
    return source[source.index(start):source.index(end)]


def language_store_source(source):
    end = "\n@MainActor\nenum AppLocalization"
    require(source.count(end) == 1, "Language store source changed; review the host harness seam")
    prefix = source[:source.index(end)]
    require(digest(prefix) == LANGUAGE_PREFIX_SHA256,
            "Language store source changed; do not execute unreviewed preference code")
    return prefix


def capture_contract(body, expected):
    aliases = dict(re.findall(r'let\s+(\w+)\s*=\s*app\.(?:buttons|sliders|staticTexts|otherElements)\["([^\"]+)"\]', body))
    calls = re.findall(r'capture\(app,"([a-z]+)",language,([0-9]+),([^\n]+?)\)', body)
    require(len(calls) == 14, "Exactly fourteen capture calls are required per language")
    rows = []
    names = set()
    states = {"live": "controls-before-recording-and-gps-start",
              "setup": "controls-before-verified-profile-import",
              "editor": "layout-editor-with-synthetic-fixture",
              "sessions": "closed-synthetic-session-selected",
              "replay": "selected-synthetic-recording-at-start",
              "signals": "selected-synthetic-replay-at-end"}
    for language in ("en", "ko"):
        for order, (guide, number, expression) in enumerate(calls, 1):
            match = re.fullmatch(r'app\.(?:buttons|sliders|staticTexts|otherElements)\["([^\"]+)"\]', expression)
            target = match.group(1) if match else aliases.get(expression)
            require(target is not None, "Unknown capture target: " + expression)
            name = "Help-" + guide + "-" + language + "-" + number
            require(name not in names, "Duplicate capture call: " + name)
            require(expected.get(name) == target, "Guide/capture anchor differs: " + name)
            require(guide in states, "Unreviewed screenshot state: " + guide)
            names.add(name)
            rows.append({"imageName": name, "language": language, "guideID": guide,
                         "stepNumber": int(number), "captureOrder": order, "targetID": target,
                         "stateContext": states[guide]})
    require(names == set(expected), "Capture calls do not cover the complete guide")
    return rows


NOTE_PROPERTY = '''    var screenshotStateNote: HelpCopy? {
        switch id {
        case "live":
            HelpCopy(en: "These examples show the controls before recording or GPS is started. Follow the steps in order, then check the Expected result after each action.",
                     ko: "이 예시는 기록과 GPS를 시작하기 전의 조작 위치를 보여줍니다. 순서대로 진행한 뒤 각 동작의 정상 결과를 확인하세요.")
        case "setup":
            HelpCopy(en: "These examples show the controls before a profile is imported. Start live adapter is disabled in the example; import your verified profile before connecting.",
                     ko: "이 예시는 프로필을 가져오기 전의 조작 위치를 보여줍니다. 예시의 실차 어댑터 시작은 비활성 상태입니다. 연결하기 전에 검증된 프로필을 가져오세요.")
        default:
            nil
        }
    }
'''


def proposed_help_source(original):
    require(digest(original) == HELP_SOURCE_SHA256, "Help source changed; re-review the copy proposal")
    field = "    let steps: [HelpStep]\n"
    button = "                Button { showingFullScreen=true } label: {\n"
    require(original.count(field) == original.count(button) == 1, "Help proposal anchors changed")
    candidate = original.replace(field, field + NOTE_PROPERTY, 1)
    note = '''                if let note = guide.screenshotStateNote {
                    Text(note.text).font(.footnote).foregroundStyle(TelemetryTheme.mutedText)
                        .accessibilityIdentifier("help-example-state-note")
                }
'''
    return candidate.replace(button, note + button, 1)


def proposal_patch(original):
    return "".join(difflib.unified_diff(original.splitlines(keepends=True),
                                      proposed_help_source(original).splitlines(keepends=True),
                                      fromfile="a/" + HELP_SOURCE, tofile="b/" + HELP_SOURCE))


def help_selectors(source):
    matches = []
    for node in ast.walk(ast.parse(source)):
        if not isinstance(node, ast.Assign):
            continue
        for target in node.targets:
            if isinstance(target, ast.Subscript) and isinstance(target.value, ast.Name) \
                    and target.value.id == "TEST_GROUPS" and isinstance(target.slice, ast.Constant) \
                    and target.slice.value == "help":
                matches.append(ast.literal_eval(node.value))
    require(len(matches) == 1 and isinstance(matches[0], list) and len(matches[0]) == 4
            and all(isinstance(value, str) for value in matches[0]), "Help regression selectors changed")
    return matches[0]


def build_plan(root):
    root = Path(root)
    help_source = (root / HELP_SOURCE).read_text(encoding="utf-8")
    capture_source = (root / CAPTURE_SOURCE).read_text(encoding="utf-8")
    body = capture_body(capture_source)
    require(digest(body) == CAPTURE_BODY_SHA256,
            "Capture body changed; review states and anchors before re-pinning")
    prefix = language_store_source((root / LANGUAGE_SOURCE).read_text(encoding="utf-8"))
    patch = proposal_patch(help_source)
    expected = assets.expected_capture_targets(help_source)
    rows = capture_contract(body, expected)
    selectors = help_selectors((root / "scripts/verify_offline_replay.py").read_text(encoding="utf-8"))
    capture_selectors = [selector for selector in selectors if selector.rsplit("/", 1)[-1]
                         in ("testCaptureEnglishGuideScreens", "testCaptureKoreanGuideScreens")]
    require(len(capture_selectors) == 2, "English/Korean capture selectors changed")
    for language, method in (("en", "English"), ("ko", "Korean")):
        require(re.search(r'func testCapture' + method + r'GuideScreens\(\)\s*\{captureScreens\("'
                          + language + r'"\)\}', capture_source) is not None,
                "Capture selector language changed")
    return {"schemaVersion": 1, "scope": "source-only-help-preparation",
            "nativeExecutionAllowed": False, "nativeRestorationCertified": False,
            "assetFilesModified": False, "fullAssetVerificationPerformed": False,
            "productProposalApplied": False, "proposalVisualAcceptanceRequired": True,
            "captureBodySHA256": digest(body), "languageStorePrefixSHA256": digest(prefix),
            "proposedPatchSHA256": digest(patch), "captureTargets": rows,
            "captureSelectors": capture_selectors, "regressionSelectors": selectors,
            "sourceAudit": assets.audit_source_provenance(root),
            "preferenceReview": {"initialOverrideScope": "initial-display-only",
                                 "explicitSelectionPersists": True,
                                 "retainedStoreRequiresFreshEffectiveStateObservation": True,
                                 "actualWriterCacheBoundaryImplemented": False,
                                 "acceptanceContract": "scripts/verify_preference_restoration.py"},
            "remainingNativeEvidence": ["authorized owned writer/cache lifecycle boundary",
                                        "unoverridden effective language plus post-lifecycle inventory",
                                        "genuine new PNG/marker/AX receipts and direct visual review"]}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    arguments = parser.parse_args(argv)
    report = build_plan(arguments.root)
    print(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if report["sourceAudit"]["sourceInputsMatch"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
