"""Evaluate synthetic restoration observations, never collect real preferences.

This is an acceptance-contract checker for the future owned-domain adapter.
It has no file/defaults/daemon/Simulator operations. A passing memory contract
does not establish that the real writer/cache boundary has been implemented.
"""
from datetime import datetime
import plistlib

PHASE_ORDER = ["original", "quiesce-before-backup", "trial", "quiesce-before-restore",
               "restored", "relaunch", "post-lifecycle"]
LANGUAGE_ARGUMENTS = ("--app-language", "-AppleLanguages", "-AppleLocale", "-telemetry.appLanguage")


def _typed_value(value, ancestors=None):
    """Compare plist values, ignoring dictionary order and container sharing."""
    kind = type(value)
    if kind in (dict, list, tuple):
        ancestors = set() if ancestors is None else ancestors
        identity = id(value)
        if identity in ancestors:
            raise ValueError("Cyclic plist container")
        ancestors.add(identity)
        try:
            if kind is dict:
                if any(type(key) is not str for key in value):
                    raise ValueError("Plist dictionary keys must be strings")
                return "dictionary", tuple((key, _typed_value(value[key], ancestors)) for key in sorted(value))
            return "array", tuple(_typed_value(item, ancestors) for item in value)
        finally:
            ancestors.remove(identity)
    if kind is bool:
        return "boolean", value
    if kind is int:
        if not -(2 ** 63) <= value < 2 ** 64:
            raise OverflowError("Plist integer out of range")
        return "integer", value
    if kind is float:
        return "real", value.hex()
    if kind is str:
        value.encode("utf-8")
        return "string", value
    if kind in (bytes, bytearray):
        return "data", bytes(value)
    if kind is datetime:
        return "date", value
    if kind is plistlib.UID:
        return "uid", value.data
    raise ValueError("Unsupported plist value type: " + kind.__name__)


def _snapshot(value):
    if not isinstance(value, dict) or type(value.get("present")) is not bool \
            or not isinstance(value.get("values"), dict):
        raise ValueError("Preference domain requires explicit presence and full values")
    if not value["present"] and value["values"]:
        raise ValueError("An absent domain cannot contain preference values")
    # Typed values preserve bool/int distinctions, array order and domain
    # absence without treating binary-plist object references as value data.
    return value["present"], _typed_value(value["values"])


def evaluate(observations, *, expected_domain):
    if not isinstance(observations, dict):
        raise ValueError("Restoration observations must be a dictionary")
    issues = []
    if observations.get("scope") != "synthetic-preference-restoration":
        issues.append("unsupported-observation-scope")
    if observations.get("domain") != expected_domain or not expected_domain:
        issues.append("wrong-preference-domain")
    if observations.get("phaseOrder") != PHASE_ORDER:
        issues.append("missing-duplicated-or-out-of-order-phase")
    barriers = observations.get("barriers")
    barriers = barriers if isinstance(barriers, dict) else {}
    for phase in ("beforeBackup", "beforeRestore"):
        barrier = barriers.get(phase)
        barrier = barrier if isinstance(barrier, dict) else {}
        if barrier.get("acknowledged") is not True or type(barrier.get("pendingWrites")) is not int \
                or barrier["pendingWrites"] != 0:
            issues.append("writer-boundary-unconfirmed-" + phase)
    arguments = observations.get("launchArguments")
    if not isinstance(arguments, list) or not all(isinstance(value, str) for value in arguments):
        issues.append("missing-unoverridden-launch-observation")
    elif any(value == flag or value.startswith(flag + "=") for value in arguments for flag in LANGUAGE_ARGUMENTS):
        issues.append("language-override-masks-restoration")
    original, restored, after = (observations.get(key) for key in ("original", "restored", "postLifecycle"))
    try:
        baseline = _snapshot(original)
        if _snapshot(restored) != baseline:
            issues.append("restored-domain-drift")
        if _snapshot(after) != baseline:
            issues.append("post-lifecycle-domain-drift")
    except (ValueError, TypeError, OverflowError) as error:
        issues.append("invalid-domain-observation: " + str(error))
    if not isinstance(after, dict) or after.get("freshStore") is not True:
        issues.append("fresh-effective-state-required")
    if not isinstance(original, dict) or original.get("effectiveLanguage") not in ("en", "ko") \
            or not isinstance(after, dict) or after.get("effectiveLanguage") != original.get("effectiveLanguage"):
        issues.append("effective-language-mismatch")
    if observations.get("fileInventoryMatches") is not True:
        issues.append("file-inventory-not-restored")
    return {"scope": "synthetic-restoration-acceptance-only", "issues": issues,
            "syntheticContractSatisfied": not issues, "nativeRestorationCertified": False,
            "nativeExecutionAllowed": False, "realWriterCacheBoundaryVerified": False,
            "remainingNativeEvidence": "Implement and qualify the owned-domain writer/cache lifecycle adapter"}
