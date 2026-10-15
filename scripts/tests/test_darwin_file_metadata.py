"""Native metadata API tests; every path is a new synthetic temporary file."""
import ctypes
import errno
import os
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import darwin_file_metadata as metadata
from synthetic_data_preservation import SyntheticWorkspace


@unittest.skipUnless(sys.platform == "darwin", "Requires actual Darwin ACL/xattr support")
class DarwinMetadataTests(unittest.TestCase):
    def setUp(self):
        self.workspace = SyntheticWorkspace()
        self.addCleanup(self.workspace.cleanup)
        self.file = self.workspace.root / "fresh-synthetic.bin"
        self.file.write_bytes(b"synthetic metadata API test")

    @staticmethod
    def denied(*arguments):
        ctypes.set_errno(errno.EACCES)
        return -1

    def test_absent_acl_is_distinct_from_permission_denied(self):
        self.assertIsNone(metadata.snapshot(self.file)["acl"])
        fd = os.open(self.file, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            def unreadable(descriptor):
                ctypes.set_errno(errno.EACCES)
                return None
            with self.assertRaisesRegex(metadata.MetadataError, "ACL read"):
                metadata._acl(SimpleNamespace(acl_get_fd=unreadable), fd)
        finally:
            os.close(fd)

    def test_acl_write_error_is_not_reported_as_restored(self):
        expected = metadata.snapshot(self.file)
        lib = Mock(wraps=metadata._library())
        lib.acl_set_fd.side_effect = self.denied
        with patch.object(metadata, "_library", return_value=lib):
            with self.assertRaisesRegex(metadata.MetadataError, "ACL restoration"):
                metadata.apply(self.file, expected)

    def test_xattr_write_error_is_not_reported_as_restored(self):
        expected = metadata.snapshot(self.file)
        expected["xattrs"][b"org.webdashboard.synthetic.empty".hex()] = ""
        lib = Mock(wraps=metadata._library())
        lib.fsetxattr.side_effect = self.denied
        with patch.object(metadata, "_library", return_value=lib):
            with self.assertRaisesRegex(metadata.MetadataError, "Extended-attribute restoration"):
                metadata.apply(self.file, expected)

    def test_xattr_removal_error_is_not_reported_as_absence(self):
        expected = metadata.snapshot(self.file)
        name = b"org.webdashboard.synthetic.extra".hex()
        added = dict(expected, xattrs=dict(expected["xattrs"], **{name: "01"}))
        metadata.apply(self.file, added)
        lib = Mock(wraps=metadata._library())
        lib.fremovexattr.side_effect = self.denied
        with patch.object(metadata, "_library", return_value=lib):
            with self.assertRaisesRegex(metadata.MetadataError, "Extended-attribute removal"):
                metadata.apply(self.file, expected)
        self.assertEqual(metadata.snapshot(self.file), added)

    def test_malformed_and_duplicate_xattr_names_fail_closed(self):
        for values in ([b"unterminated"], [b"duplicate\0duplicate\0", b"value"]):
            with self.subTest(values=values):
                with patch.object(metadata, "_variable_bytes", side_effect=values):
                    with self.assertRaises(metadata.MetadataError):
                        metadata._attributes(metadata._library(), 0)

    def test_erange_retries_are_bounded(self):
        calls = []
        def growing(buffer, length):
            calls.append(length)
            if buffer is None:
                return 4
            ctypes.set_errno(errno.ERANGE)
            return -1
        with self.assertRaisesRegex(metadata.MetadataError, "changed repeatedly"):
            metadata._variable_bytes(growing, lambda buffer, length: (buffer, length))
        self.assertEqual(len(calls), 6)

    def test_metadata_race_during_snapshot_fails_closed(self):
        attributes = metadata._attributes
        def concurrent_write(lib, fd):
            result = attributes(lib, fd)
            self.file.write_bytes(b"synthetic concurrent write")
            return result
        with patch.object(metadata, "_attributes", side_effect=concurrent_write):
            with self.assertRaisesRegex(metadata.MetadataError, "changed during inventory"):
                metadata.snapshot(self.file)

    def test_path_replacement_during_snapshot_fails_closed(self):
        attributes = metadata._attributes
        def replace_target(lib, fd):
            result = attributes(lib, fd)
            self.file.rename(self.workspace.root / "retained-original")
            self.file.write_bytes(b"new synthetic inode")
            return result
        with patch.object(metadata, "_attributes", side_effect=replace_target):
            with self.assertRaisesRegex(metadata.MetadataError, "changed"):
                metadata.snapshot(self.file)

    def test_symlink_and_fifo_are_never_followed_or_blocked_on(self):
        link = self.workspace.root / "link"
        link.symlink_to(self.file)
        with self.assertRaises(OSError):
            metadata.snapshot(link)
        fifo = self.workspace.root / "fifo"
        os.mkfifo(fifo)
        with self.assertRaises(metadata.MetadataError):
            metadata.snapshot(fifo)
        self.assertEqual(self.file.read_bytes(), b"synthetic metadata API test")

    def test_unsupported_platform_has_no_partial_fallback(self):
        with patch.object(metadata.sys, "platform", "unsupported"):
            with self.assertRaisesRegex(metadata.MetadataError, "no partial fallback"):
                metadata._library()


if __name__ == "__main__":
    unittest.main(verbosity=2)
