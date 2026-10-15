"""Lossless metadata comparison for disposable Darwin fixtures.

The transaction module restricts paths to its own temporary workspace. This
backend opens only regular files/directories, without following symlinks. It
does not stop writers or establish any Simulator/preferences-cache boundary.
Access/birth/change times are deliberately outside the restoration contract.
"""
import ctypes
import errno
import os
import stat
import sys
from contextlib import contextmanager


FIELDS = ("mode", "uid", "gid", "flags", "mtimeNS", "acl", "xattrs")


class MetadataError(RuntimeError):
    pass


def _library():
    if sys.platform != "darwin":
        raise MetadataError("Darwin metadata support is required; no partial fallback")
    lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    void, size, integer = ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int
    signatures = {
        "flistxattr": ([integer, void, size, integer], ctypes.c_ssize_t),
        "fgetxattr": ([integer, ctypes.c_char_p, void, size, ctypes.c_uint32, integer], ctypes.c_ssize_t),
        "fsetxattr": ([integer, ctypes.c_char_p, void, size, ctypes.c_uint32, integer], integer),
        "fremovexattr": ([integer, ctypes.c_char_p, integer], integer),
        "acl_get_fd": ([integer], void),
        "acl_set_fd": ([integer, void], integer),
        "acl_init": ([integer], void),
        "acl_to_text": ([void, ctypes.POINTER(ctypes.c_ssize_t)], void),
        "acl_from_text": ([ctypes.c_char_p], void),
        "acl_valid": ([void], integer),
        "acl_free": ([void], integer),
        "fchflags": ([integer, ctypes.c_uint32], integer),
    }
    for name, (arguments, result) in signatures.items():
        function = getattr(lib, name)
        function.argtypes, function.restype = arguments, result
    return lib


def _check(result, operation):
    if result < 0:
        number = ctypes.get_errno()
        raise MetadataError(operation + ": " + os.strerror(number))
    return result


def _identity(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_gid,
            info.st_size, info.st_mtime_ns, info.st_ctime_ns, info.st_nlink,
            info.st_flags)


@contextmanager
def _descriptor(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        if not (stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode)):
            raise MetadataError("Only real directories and regular files are supported")
        if _identity(info) != _identity(os.lstat(path)):
            raise MetadataError("Metadata target changed during open")
        yield fd, info
        if _identity(os.fstat(fd)) != _identity(os.lstat(path)):
            raise MetadataError("Metadata target changed during operation")
    finally:
        os.close(fd)


def _variable_bytes(function, arguments):
    # A writer racing the size/read pair cannot turn an error into empty data.
    for _ in range(3):
        length = _check(function(*arguments(None, 0)), "Metadata size read")
        buffer = ctypes.create_string_buffer(max(1, length))
        result = function(*arguments(buffer, length))
        if result < 0 and ctypes.get_errno() == errno.ERANGE:
            continue
        result = _check(result, "Metadata value read")
        if result > length:
            raise MetadataError("Metadata grew during read")
        return buffer.raw[:result]
    raise MetadataError("Metadata changed repeatedly during read")


def _attributes(lib, fd):
    names = _variable_bytes(lib.flistxattr, lambda buffer, length: (fd, buffer, length, 0))
    if names and not names.endswith(b"\0"):
        raise MetadataError("Malformed extended-attribute name list")
    result = {}
    for name in names.split(b"\0")[:-1]:
        if not name or name.hex() in result:
            raise MetadataError("Invalid or duplicate extended-attribute name")
        value = _variable_bytes(lib.fgetxattr,
                                lambda buffer, length: (fd, name, buffer, length, 0, 0))
        # Hex represents arbitrary name/value bytes, including a zero-byte value.
        result[name.hex()] = value.hex()
    return result


def _acl(lib, fd):
    ctypes.set_errno(0)
    acl = lib.acl_get_fd(fd)
    if not acl:
        number = ctypes.get_errno()
        # Darwin returns ENOENT for no extended ACL, even on an open valid fd.
        # EACCES/ENOTSUP and every other error fail closed; never infer absence.
        os.fstat(fd)
        if number == errno.ENOENT:
            return None
        raise MetadataError("ACL read: " + os.strerror(number))
    try:
        _check(lib.acl_valid(acl), "ACL validation")
        length = ctypes.c_ssize_t()
        text = lib.acl_to_text(acl, ctypes.byref(length))
        if not text:
            raise MetadataError("ACL serialization failed")
        try:
            if length.value < 0:
                raise MetadataError("Invalid ACL text length")
            # Preserve entry order and principal UUIDs; do not sort or map users.
            return ctypes.string_at(text, length.value).decode("utf-8")
        finally:
            lib.acl_free(text)
    finally:
        lib.acl_free(acl)


def snapshot(path):
    lib = _library()
    with _descriptor(path) as (fd, before):
        result = {"mode": stat.S_IMODE(before.st_mode), "uid": before.st_uid,
                  "gid": before.st_gid, "flags": before.st_flags,
                  "mtimeNS": before.st_mtime_ns,
                  "acl": _acl(lib, fd), "xattrs": _attributes(lib, fd)}
        if _identity(before) != _identity(os.fstat(fd)):
            raise MetadataError("Metadata changed during inventory")
        return result


def apply(path, expected):
    lib = _library()
    with _descriptor(path) as (fd, before):
        if (before.st_uid, before.st_gid) != (expected["uid"], expected["gid"]):
            raise MetadataError("Ownership differs; no privilege escalation is attempted")
        # Exact set replacement removes attributes introduced only by the trial.
        actual = _attributes(lib, fd)
        for name in actual.keys() - expected["xattrs"].keys():
            _check(lib.fremovexattr(fd, bytes.fromhex(name), 0), "Extended-attribute removal")
        for name, value in expected["xattrs"].items():
            if actual.get(name) == value:
                continue
            raw = bytes.fromhex(value)
            buffer = ctypes.create_string_buffer(raw)
            _check(lib.fsetxattr(fd, bytes.fromhex(name), buffer, len(raw), 0, 0),
                   "Extended-attribute restoration")
        acl = lib.acl_init(0) if expected["acl"] is None else lib.acl_from_text(expected["acl"].encode("utf-8"))
        if not acl:
            raise MetadataError("ACL reconstruction failed")
        try:
            _check(lib.acl_valid(acl), "Restored ACL validation")
            _check(lib.acl_set_fd(fd, acl), "ACL restoration")
        finally:
            lib.acl_free(acl)
        os.fchmod(fd, expected["mode"])
        if before.st_flags != expected["flags"]:
            _check(lib.fchflags(fd, expected["flags"]), "File flags restoration")
        os.utime(fd, ns=(before.st_atime_ns, expected["mtimeNS"]))
        os.fsync(fd)
    if snapshot(path) != expected:
        raise MetadataError("Applied metadata does not match expected state")
