"""Execute host Swift checks with memory-only preferences and temporary files.

No Simulator, UIKit view, application, preference domain or native XCTest runner
is launched. The actual language-store prefix is hash-pinned before compilation;
module-local UserDefaults/Locale test doubles replace Foundation access. This
does not implement or certify the real cfprefsd/lifecycle boundary.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

import verify_help_preparation as preparation
import verify_preference_restoration as restoration


def checked(command, *, timeout=90):
    result = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        detail = (result.stderr or result.stdout)[-3000:]
        raise preparation.PreparationError("Host check failed (exit " + str(result.returncode) + "): " + detail)
    return result.stdout


def run(root):
    root = Path(root)
    prefix = preparation.language_store_source((root / preparation.LANGUAGE_SOURCE).read_text(encoding="utf-8"))
    candidate = preparation.proposed_help_source((root / preparation.HELP_SOURCE).read_text(encoding="utf-8"))
    compiler = shutil.which("swiftc")
    preparation.require(compiler is not None, "Host swiftc is unavailable; no native fallback")
    scripts = Path(__file__).resolve().parent
    language_harness = (scripts / "tests/offline_language_restoration.swift").read_text(encoding="utf-8")
    marker = "@main struct LanguageRestorationChecks"
    preparation.require(language_harness.count(marker) == 1, "Memory harness boundary changed")
    start = "@MainActor struct HelpCopy"
    end = "\nstruct AppHelpView: View"
    preparation.require(candidate.count(start) == candidate.count(end) == 1, "Help data boundary changed")
    with tempfile.TemporaryDirectory(prefix="help-host-memory-checks-") as directory:
        temporary = Path(directory)
        sources = {"LanguageStore.swift": prefix, "LanguageChecks.swift": language_harness,
                   "MemoryPreferences.swift": language_harness.split(marker, 1)[0],
                   "ProposedHelp.swift": candidate,
                   "HelpData.swift": "import Foundation\n\n" + candidate[candidate.index(start):candidate.index(end)],
                   "HelpChecks.swift": (scripts / "tests/offline_help_copy.swift").read_text(encoding="utf-8")}
        for name, source in sources.items():
            (temporary / name).write_text(source, encoding="utf-8")
        common = [compiler, "-swift-version", "6", "-parse-as-library", "-module-cache-path",
                  str(temporary / "module-cache")]
        language_binary = str(temporary / "language-checks")
        checked(common + [str(temporary / "LanguageStore.swift"), str(temporary / "LanguageChecks.swift"),
                          "-o", language_binary])
        languages = {language: json.loads(checked([language_binary, "--app-language", language], timeout=10))
                     for language in ("en", "ko")}
        checked([compiler, "-frontend", "-parse", str(temporary / "ProposedHelp.swift")], timeout=30)
        help_binary = str(temporary / "help-data-checks")
        checked(common + [str(temporary / name) for name in
                          ("LanguageStore.swift", "MemoryPreferences.swift", "HelpData.swift", "HelpChecks.swift")]
                + ["-o", help_binary])
        help_data = json.loads(checked([help_binary], timeout=10))
        expected = preparation.assets.expected_capture_targets(candidate)
        preparation.require({row["imageName"]: row["targetID"] for row in help_data["targets"]} == expected,
                            "Compiled Help data differs from the guide/capture contract")
        preparation.require(all(report["failed"] == 0 and report["passed"] == 11
                                and report["actualUserDefaultsUsed"] is False
                                and report["realCFPreferencesCacheTested"] is False
                                for report in languages.values()) and not help_data["errors"],
                            "Host memory assertions failed")
        acceptance = {}
        for language, report in languages.items():
            observations = report["restorationObservations"]
            preparation.require(set(observations) == {"fresh-restored", "retained-store", "queued-writer",
                                                       "override-masking", "originally-absent"},
                                "Restoration observations are incomplete")
            acceptance[language] = {}
            for name, evidence in observations.items():
                result = restoration.evaluate(evidence, expected_domain="synthetic.telemetry.preferences")
                expected = name in ("fresh-restored", "originally-absent")
                preparation.require(result["syntheticContractSatisfied"] == expected
                                    and result["nativeRestorationCertified"] is False,
                                    "Restoration acceptance contract failed: " + name)
                acceptance[language][name] = result
        return {"schemaVersion": 1, "scope": "host-memory-preparation-only", "languages": languages,
                "restorationAcceptance": acceptance,
                "proposedHelp": help_data, "proposedHelpSyntaxParsed": True,
                "languageStorePrefixSHA256": preparation.digest(prefix),
                "proposedPatchSHA256": preparation.digest(preparation.proposal_patch(
                    (root / preparation.HELP_SOURCE).read_text(encoding="utf-8"))),
                "actualAppDataAccess": False, "realCFPreferencesCacheTested": False,
                "nativeRestorationCertified": False, "nativeUiVerified": False,
                "productProposalApplied": False}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    arguments = parser.parse_args(argv)
    print(json.dumps(run(arguments.root), ensure_ascii=False, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
