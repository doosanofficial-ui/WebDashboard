"""One-shot, read-only error-popup metadata guard; never verifies app readiness.

No activation, capture, prompt handling, permission request or daemon. Call at a
readiness boundary in an existing diagnostic; pause requires pixel/log review.
"""
import argparse
import ctypes
import datetime
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys

REPORTER_BUNDLE = 'com.apple.ProblemReporter'
REPORTER_PATH = Path('/System/Library/CoreServices/Problem Reporter.app')
REPORTER_EXECUTABLE = str(REPORTER_PATH / 'Contents/MacOS/Problem Reporter')
# Korean observed on this Mac; English verified in Apple's Localizable.loctable.
TITLE_PATTERNS = ((re.compile(r'(.+)에 대한 문제 리포트'), 'ko-observed'),
                  (re.compile(r'Problem Report for (.+)'), 'en-apple-resource'))


def classify_snapshot(snapshot, subjects):
    def decision(action, reason, candidates=()):
        return {'action': action, 'reason': reason, 'candidates': list(candidates),
                'screenVerified': False}

    if (not isinstance(subjects, (tuple, list)) or not subjects or
            any(not isinstance(s, str) or not s.strip() for s in subjects)):
        return decision('pause', 'invalid-target-scope')
    if (not isinstance(snapshot, dict) or snapshot.get('querySucceeded') is not True or
            not isinstance(snapshot.get('windows'), list)):
        return decision('pause', 'window-metadata-unavailable')
    candidates = []
    for window in snapshot['windows']:
        if not isinstance(window, dict):
            return decision('pause', 'window-metadata-unavailable')
        if window.get('ownerBundle') != REPORTER_BUNDLE:
            continue
        if window.get('onScreen') is False:
            continue
        title = window.get('title')
        if window.get('onScreen') is not True or not isinstance(title, str):
            return decision('pause', 'unclassified-error-window')
        parsed = next(((match.group(1), evidence) for pattern, evidence in TITLE_PATTERNS
                       if (match := pattern.fullmatch(title))), None)
        if parsed is None:
            return decision('pause', 'unclassified-error-window')
        subject, evidence = parsed
        if subject in subjects:
            candidates.append({key: window.get(key) for key in
                               ('ownerBundle', 'pid', 'windowNumber', 'title')})
            candidates[-1].update(subject=subject, patternEvidence=evidence)
    return decision('pause', 'matching-error-popup', candidates) if candidates else \
        decision('continue', 'no-matching-error-popup')


def read_snapshot(run=subprocess.run):
    """Bound the complete native query, including process identity reads, to 3s."""
    try:
        result = run([sys.executable, __file__, '--native-snapshot'],
                     stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=3)
        if result.returncode != 0:
            return {'querySucceeded': False, 'reason': 'native-query-failed'}
        snapshot = json.loads(result.stdout)
        if not isinstance(snapshot, dict):
            return {'querySucceeded': False, 'reason': 'invalid-native-metadata'}
        return snapshot
    except (OSError, subprocess.SubprocessError, ValueError):
        return {'querySucceeded': False, 'reason': 'native-query-unavailable'}


def native_snapshot():
    """Read CG windows and verify the reporter executable/bundle; no AX needed."""
    if sys.platform != 'darwin':
        return {'querySucceeded': False, 'reason': 'macos-only'}
    try:
        with (REPORTER_PATH / 'Contents/Info.plist').open('rb') as file:
            if plistlib.load(file).get('CFBundleIdentifier') != REPORTER_BUNDLE:
                return {'querySucceeded': False, 'reason': 'reporter-identity-unverified'}
        cg = ctypes.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
        cf = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
        cg.CGWindowListCopyWindowInfo.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
        cg.CGWindowListCopyWindowInfo.restype = ctypes.c_void_p
        cf.CFPropertyListCreateData.argtypes = [ctypes.c_void_p, ctypes.c_void_p,
                                              ctypes.c_long, ctypes.c_ulong, ctypes.c_void_p]
        cf.CFPropertyListCreateData.restype = ctypes.c_void_p
        cf.CFDataGetLength.argtypes = [ctypes.c_void_p]
        cf.CFDataGetLength.restype = ctypes.c_long
        cf.CFDataGetBytePtr.argtypes = [ctypes.c_void_p]
        cf.CFDataGetBytePtr.restype = ctypes.c_void_p
        cf.CFRelease.argtypes = [ctypes.c_void_p]
        cf.CFRelease.restype = None
        info = cg.CGWindowListCopyWindowInfo(1 | 16, 0)  # on-screen, exclude desktop
        if not info:
            return {'querySucceeded': False, 'reason': 'window-list-unavailable'}
        data = None
        try:
            data = cf.CFPropertyListCreateData(None, info, 100, 0, None)
            if not data:
                return {'querySucceeded': False, 'reason': 'window-list-unreadable'}
            windows = plistlib.loads(ctypes.string_at(cf.CFDataGetBytePtr(data),
                                                     cf.CFDataGetLength(data)))
        finally:
            if data:
                cf.CFRelease(data)
            cf.CFRelease(info)
        pids = sorted({w['kCGWindowOwnerPID'] for w in windows if w.get('kCGWindowOwnerPID')})
        identities = {}
        if pids:
            result = subprocess.run(['/bin/ps', '-p', ','.join(map(str, pids)), '-o', 'pid=,comm='],
                                    stdin=subprocess.DEVNULL, capture_output=True,
                                    text=True, timeout=1)
            if result.returncode != 0:
                return {'querySucceeded': False, 'reason': 'owner-identity-unavailable'}
            for line in result.stdout.splitlines():
                fields = line.strip().split(None, 1)
                if len(fields) == 2 and fields[0].isdigit():
                    identities[int(fields[0])] = fields[1]
        rows = []
        for w in windows:
            pid = w.get('kCGWindowOwnerPID')
            if identities.get(pid) == REPORTER_EXECUTABLE:
                rows.append({'ownerBundle': REPORTER_BUNDLE, 'pid': pid,
                             'windowNumber': w.get('kCGWindowNumber'),
                             'title': w.get('kCGWindowName'),
                             'onScreen': w.get('kCGWindowIsOnscreen')})
        return {'querySucceeded': True, 'windows': rows,
                'checkedUTC': datetime.datetime.now(datetime.timezone.utc).isoformat()}
    except (OSError, subprocess.SubprocessError, ValueError):
        return {'querySucceeded': False, 'reason': 'native-query-unavailable'}


def main():
    if sys.argv[1:] == ['--native-snapshot']:
        print(json.dumps(native_snapshot(), ensure_ascii=False))
        return 0
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--subject', action='append', required=True,
                        help='Exact target or prerequisite process name; repeat as needed')
    args = parser.parse_args()
    snapshot = read_snapshot()
    result = classify_snapshot(snapshot, args.subject)
    print(json.dumps({'snapshot': snapshot, **result}, ensure_ascii=False))
    return 0 if result['action'] == 'continue' else 2


if __name__ == '__main__':
    raise SystemExit(main())
