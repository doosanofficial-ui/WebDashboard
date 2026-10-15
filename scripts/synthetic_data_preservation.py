"""Synthetic-only file-tree transaction; never a native execution gate.

Only fresh marked temporary roots are accepted. A successful receipt certifies
exactly its declared filesystem scope, never writer/cache or native behavior.
The original root inode and all original/trial evidence are retained. Catchable
signals restore before propagation; abrupt termination needs explicit recovery.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import stat
import threading
import uuid
import tempfile
import subprocess
import darwin_file_metadata as metadata


VERIFICATION_SCOPE = "synthetic-tree-bytes-namespace-root-and-entry-metadata"
UNCERTIFIED_DIMENSIONS = ("accessBirthChangeTimes", "externalStores",
                          "actualWriterQuiescence", "effectivePreferencesCache")


class PreservationError(RuntimeError):
    pass


class RecoveryRequired(PreservationError):
    """Restoration is unverified; keep the app stopped and all evidence intact."""


class SignalInterrupted(BaseException):
    def __init__(self, number):
        self.number = number
        super().__init__("Interrupted by " + signal.Signals(number).name)


def _require(condition, message):
    if not condition:
        raise PreservationError(message)


def _sha(path):
    value = hashlib.sha256()
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as source:
        before = os.fstat(source.fileno())
        _require(stat.S_ISREG(before.st_mode), "Not a regular file: " + str(path))
        for block in iter(lambda: source.read(1024 * 1024), b""):
            value.update(block)
        after = os.fstat(source.fileno())
    current = path.lstat()
    keys = lambda item: (item.st_dev, item.st_ino, item.st_size, item.st_mtime_ns,
                         item.st_ctime_ns, item.st_mode, item.st_nlink)
    _require(keys(before) == keys(after) == keys(current), "File changed while hashing: " + str(path))
    return value.hexdigest()


def inventory(root, *, workspace, trial=False):
    """Exact namespace plus bytes and metadata, including the root itself."""
    root = workspace.check(root, must_exist=True)
    _require(not root.is_symlink() and root.is_dir(), "Data root must be a real directory")
    result = {}

    def visit(item, relative):
        info = item.lstat()
        mode = stat.S_IMODE(info.st_mode)
        if stat.S_ISDIR(info.st_mode) or (stat.S_ISREG(info.st_mode) and info.st_nlink == 1):
            value = metadata.snapshot(item)
            if not trial:
                _require(value["uid"] == os.geteuid(), "Original ownership is unsupported")
                _require(value["flags"] == 0, "Original file flags are unsupported")
            value["type"] = "directory" if stat.S_ISDIR(info.st_mode) else "file"
            if value["type"] == "file":
                value.update(bytes=info.st_size, sha256=_sha(item))
                _require(metadata.snapshot(item) == {key: entry for key, entry in value.items()
                         if key not in ("type", "bytes", "sha256")}, "File metadata changed while hashing")
            result[relative] = value
            if value["type"] == "directory":
                for child in sorted(item.iterdir()):
                    visit(child, child.relative_to(root).as_posix())
                _require(metadata.snapshot(item) == {key: entry for key, entry in value.items()
                         if key != "type"}, "Directory changed during inventory")
        elif trial:
            # Never open trial links or special files: they may point outside.
            result[relative] = {"type": "hardlink" if stat.S_ISREG(info.st_mode)
                                else stat.S_IFMT(info.st_mode), "mode": mode,
                                "device": info.st_dev, "inode": info.st_ino,
                                "links": info.st_nlink, "mtimeNS": info.st_mtime_ns}
            if stat.S_ISLNK(info.st_mode):
                result[relative]["target"] = os.readlink(item)
        else:
            raise PreservationError("Link, hardlink or special file is unsupported: " + relative)
    visit(root, ".")
    return result


def _sync_directory(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _sync_tree(path):
    for item in path.rglob("*"):
        if item.is_file():
            with item.open("rb") as source:
                os.fsync(source.fileno())
    for directory, _, _ in os.walk(path, topdown=False):
        _sync_directory(directory)


def _write_json(path, value):
    temporary = path.parent / ("." + path.name + "-" + uuid.uuid4().hex + ".tmp")
    with temporary.open("x", encoding="utf-8") as destination:
        os.chmod(temporary, 0o600)
        json.dump(value, destination, indent=2, ensure_ascii=False)
        destination.write("\n")
        destination.flush()
        os.fsync(destination.fileno())
    os.replace(temporary, path)
    _sync_directory(path.parent)


def _error(error):
    return {"type": type(error).__name__, "message": str(error)}


class SyntheticWorkspace:
    """Disposable fixture scope, never an adopter of an app/container root.

    resume() accepts only a marked immediate child of the OS temporary directory
    created by this class; it is solely for recovery of interrupted unit tests.
    This is an accidental-use boundary, not a security sandbox for hostile code.
    """
    PREFIX = "help-preservation-synthetic-"

    def __init__(self):
        self.root = Path(tempfile.mkdtemp(prefix=self.PREFIX)).resolve()
        info = self.root.stat()
        self.identity = {"device": info.st_dev, "inode": info.st_ino, "uid": info.st_uid}
        _write_json(self.root / ".synthetic-workspace.json", self.identity)

    @classmethod
    def resume(cls, root):
        raw = Path(root)
        base = Path(tempfile.gettempdir()).resolve()
        _require(raw.is_absolute() and ".." not in raw.parts and raw.parent == base
                 and raw.name.startswith(cls.PREFIX), "Not a synthetic workspace path")
        _require(not raw.is_symlink(), "Workspace symlinks are unsupported")
        item = cls.__new__(cls)
        item.root = raw
        marker = raw / ".synthetic-workspace.json"
        _require(not marker.is_symlink(), "Workspace marker must be a real file")
        item.identity = json.loads(marker.read_text())
        item.check(raw, must_exist=True)
        return item

    def check(self, path, *, must_exist=False):
        raw = Path(path)
        # Reject outsiders lexically, before resolve/stat/open on their paths.
        _require(raw.is_absolute() and ".." not in raw.parts
                 and (raw == self.root or self.root in raw.parents),
                 "Only this fresh synthetic workspace may be accessed")
        info = self.root.lstat()
        _require(stat.S_ISDIR(info.st_mode) and not stat.S_ISLNK(info.st_mode), "Workspace root changed")
        identity = {"device": info.st_dev, "inode": info.st_ino, "uid": info.st_uid}
        _require(identity == self.identity, "Workspace identity changed")
        current = self.root
        for part in raw.relative_to(self.root).parts:
            current = current / part
            try:
                entry = current.lstat()
            except FileNotFoundError:
                continue
            _require(not stat.S_ISLNK(entry.st_mode), "Workspace ancestor symlinks are unsupported")
        if must_exist:
            _require(raw.exists(), "Synthetic path is missing")
        return raw

    def cleanup(self):
        self.check(self.root, must_exist=True)
        shutil.rmtree(self.root)


def _entry_metadata(entry):
    return {key: entry[key] for key in metadata.FIELDS}


def _copy_tree(source, destination, expected):
    _require(not Path(destination).exists(), "Copy destination must be new")
    subprocess.run(["/usr/bin/ditto", "--rsrc", "--extattr", "--acl", str(source), str(destination)],
                   check=True, capture_output=True, timeout=30)
    # ditto omits zero-byte xattrs on directories on this Darwin version.
    # Restore the recorded metadata explicitly, then independently inventory it.
    for relative in sorted(expected, key=lambda value: value.count("/") + (value != "."), reverse=True):
        metadata.apply(Path(destination) / relative, _entry_metadata(expected[relative]))


class PreservedSyntheticData:
    def __init__(self, data, evidence, *, workspace, quiesce):
        _require(isinstance(workspace, SyntheticWorkspace), "A fresh synthetic workspace is required")
        self.workspace = workspace
        workspace.check(data, must_exist=True)
        workspace.check(evidence)
        raw_data, raw_evidence = Path(data), Path(evidence)
        _require(not raw_data.is_symlink() and not raw_evidence.is_symlink(), "Root symlinks are unsupported")
        self.data = raw_data.resolve(strict=True)
        self.evidence = raw_evidence.resolve()
        _require(self.data.is_dir(), "Data root is missing")
        _require(self.data != self.evidence and self.data not in self.evidence.parents
                 and self.evidence not in self.data.parents, "Data and evidence must be disjoint")
        _require(callable(quiesce), "Explicit writer-quiescence callback is required")
        self.quiesce = quiesce
        self.original = self.evidence / "original"
        self.before = None
        self.restoring = False
        self.deferred = []
        self.previous_handlers = {}
        self.record = {"schema": 2, "syntheticOnly": True, "dataRoot": str(self.data), "backupVerified": False,
                       "verificationScope": VERIFICATION_SCOPE,
                       "nativeRestorationCertified": False,
                       "uncertifiedDimensions": list(UNCERTIFIED_DIMENSIONS),
                       "status": "NOT_STARTED", "attempts": [], "operationError": None}

    def _save(self):
        self.workspace.check(self.evidence, must_exist=True)
        _write_json(self.evidence / "transaction.json", self.record)

    def _signals_on(self):
        _require(threading.current_thread() is threading.main_thread(), "Run on the main thread")
        for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            self.previous_handlers[number] = signal.getsignal(number)
            signal.signal(number, self._signal)

    def _signals_off(self):
        for number, handler in self.previous_handlers.items():
            signal.signal(number, handler)
        self.previous_handlers.clear()

    def _signal(self, number, frame):
        if self.restoring:
            self.deferred.append(number)
        else:
            raise SignalInterrupted(number)

    def _root_identity(self):
        _require(not self.data.is_symlink(), "Data root changed to a symlink")
        self.workspace.check(self.data, must_exist=True)
        value = self.data.lstat()
        return {"device": value.st_dev, "inode": value.st_ino}

    def __enter__(self):
        _require(not self.evidence.exists(), "Evidence already exists; never replace an earlier backup")
        self._signals_on()
        try:
            _require(self.quiesce("before-backup") is True, "Writer quiescence not confirmed before backup")
            root_mode = stat.S_IMODE(self.data.stat().st_mode)
            _require(root_mode & 0o700 == 0o700, "Data root must permit owner read/write/search before trial")
            self.before = inventory(self.data, workspace=self.workspace)
            self.evidence.mkdir(mode=0o700)
            _sync_directory(self.evidence.parent)
            _require(self.evidence.stat().st_dev == self.data.stat().st_dev,
                     "Data and evidence must share a filesystem for lossless quarantine moves")
            self.record.update(status="COPYING_BACKUP", rootIdentity=self._root_identity(), rootMode=root_mode)
            self._save()
            _copy_tree(self.data, self.original, self.before)
            _sync_tree(self.original)
            _require(inventory(self.original, workspace=self.workspace) == self.before, "Backup hash/metadata inventory mismatch")
            _require(inventory(self.data, workspace=self.workspace) == self.before, "Original changed during backup")
            _require(stat.S_IMODE(self.data.stat().st_mode) == root_mode
                     == stat.S_IMODE(self.original.stat().st_mode), "Root mode changed during backup")
            manifest = self.evidence / "before.json"
            _write_json(manifest, self.before)
            self.record.update(status="BACKUP_VERIFIED", backupVerified=True,
                               beforeManifestSHA256=_sha(manifest))
            self._save()
            return self
        except BaseException as error:
            self._signals_off()
            if self.evidence.exists():
                self.record.update(status="BACKUP_FAILED", backupVerified=False, operationError=_error(error))
                self._save()
            if isinstance(error, (PreservationError, SignalInterrupted, KeyboardInterrupt, SystemExit)):
                raise
            raise PreservationError("Backup failed before action: " + str(error)) from error

    def _verified_original(self):
        _require(self.record.get("schema") == 2 and self.record.get("syntheticOnly") is True,
                 "Not a synthetic metadata receipt")
        _require(self.record.get("nativeRestorationCertified") is False
                 and self.record.get("verificationScope") == VERIFICATION_SCOPE
                 and self.record.get("uncertifiedDimensions") == list(UNCERTIFIED_DIMENSIONS),
                 "Receipt scope differs from synthetic-only metadata contract")
        _require(self.record.get("backupVerified") is True, "No verified backup receipt")
        _require(self.record.get("dataRoot") == str(self.data), "Recovery target differs from original")
        _require(self._root_identity() == self.record.get("rootIdentity"), "Data root inode changed")
        manifest = self.evidence / "before.json"
        _require(_sha(manifest) == self.record.get("beforeManifestSHA256"), "Original manifest changed")
        self.before = json.loads(manifest.read_text())
        _require(inventory(self.original, workspace=self.workspace) == self.before, "Original backup no longer matches its manifest")
        _require(stat.S_IMODE(self.original.stat().st_mode) == self.record.get("rootMode"),
                 "Original root mode no longer matches its receipt")

    def _move(self, source, destination, attempt):
        # Journal intention first; a process kill between rename and receipt leaves
        # both absolute paths available for inspection, never an untracked delete.
        move = {"source": str(source), "destination": str(destination), "complete": False}
        attempt["moves"].append(move)
        self._save()
        os.replace(source, destination)
        _sync_directory(source.parent)
        _sync_directory(destination.parent)
        move["complete"] = True
        self._save()

    def _restore(self):
        _require(self.quiesce("before-restore") is True, "Writer quiescence not confirmed before restoration")
        self._verified_original()
        token = uuid.uuid4().hex
        stage = self.evidence / ("stage-" + token)
        trial = self.evidence / ("trial-" + token)
        attempt = {"stage": stage.name, "trial": trial.name, "moves": [], "verified": False,
                   "rootModeBeforeRestore": stat.S_IMODE(self.data.stat().st_mode)}
        self.record["attempts"].append(attempt)
        self.record.update(status="PREPARING_RESTORE")
        self._save()
        # Do all copy/hash checks before moving any live data. A disk-full error
        # here leaves the current trial state and original backup untouched.
        _copy_tree(self.original, stage, self.before)
        _sync_tree(stage)
        _require(inventory(stage, workspace=self.workspace) == self.before, "Restoration staging verification failed")
        trial_manifest = inventory(self.data, workspace=self.workspace, trial=True)
        _write_json(self.evidence / ("trial-before-" + token + ".json"), trial_manifest)
        trial.mkdir(mode=0o700)
        os.chmod(self.data, self.record["rootMode"])
        self.record.update(status="RESTORING")
        self._save()
        for current in sorted(self.data.iterdir()):
            self._move(current, trial / current.name, attempt)
        metadata.apply(trial, _entry_metadata(trial_manifest["."]))
        _require(inventory(trial, workspace=self.workspace, trial=True) == trial_manifest, "Trial quarantine differs from pre-restore data")
        for saved in sorted(stage.iterdir()):
            self._move(saved, self.data / saved.name, attempt)
        metadata.apply(self.data, _entry_metadata(self.before["."]))
        _require(inventory(self.data, workspace=self.workspace) == self.before, "Restored file/absence/hash/metadata verification failed")
        _require(stat.S_IMODE(self.data.stat().st_mode) == self.record["rootMode"], "Restored root mode mismatch")
        self._verified_original()
        attempt["verified"] = True
        self.record.update(status="RESTORED_VERIFIED", deferredSignals=self.deferred.copy())
        self._save()

    def _finish(self):
        self.restoring = True
        try:
            self._restore()
        except BaseException as error:
            self.record.update(status="RECOVERY_REQUIRED", recoveryError=_error(error))
            try:
                self._save()
            except BaseException:
                pass  # Original backup plus last durable journal remain authoritative.
            raise RecoveryRequired("Restore not verified; keep data stopped and evidence at "
                                   + str(self.evidence) + ": " + str(error)) from error
        finally:
            self.restoring = False

    def __exit__(self, kind, error, traceback):
        self.restoring = True
        try:
            if error is not None:
                self.record["operationError"] = _error(error)
            self._finish()
        finally:
            self._signals_off()
        if error is None and self.deferred:
            raise SignalInterrupted(self.deferred[0])
        return False


def recover(data, evidence, *, workspace, quiesce):
    """Explicit recovery only; not a CLI or automatic native retry."""
    transaction = PreservedSyntheticData(data, evidence, workspace=workspace, quiesce=quiesce)
    transaction.record = json.loads((transaction.evidence / "transaction.json").read_text())
    transaction._signals_on()
    try:
        transaction._finish()
    finally:
        transaction._signals_off()
    if transaction.deferred:
        raise SignalInterrupted(transaction.deferred[0])
    return transaction.record
