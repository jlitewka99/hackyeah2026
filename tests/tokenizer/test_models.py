"""Build downloads retry transient failures without accepting unverified bytes."""
import hashlib
import io
import tempfile
import unittest
import urllib.error
from pathlib import Path
from unittest.mock import patch

from models import download


class DownloadTest(unittest.TestCase):
    def setUp(self):
        self.data = b"pinned-tokenizer"
        self.entry = {"path": "tokenizer.json", "url": "https://example.test/tokenizer.json",
                      "bytes": len(self.data), "sha256": hashlib.sha256(self.data).hexdigest()}
        self.manifest = patch("models.MANIFEST", {"files": [self.entry]})
        self.manifest.start()
        self.addCleanup(self.manifest.stop)
        self.delay = patch("models.time.sleep")
        self.sleep = self.delay.start()
        self.addCleanup(self.delay.stop)

    def error(self, status):
        return urllib.error.HTTPError(self.entry["url"], status, "test error", {}, None)

    def test_transient_http_failures_retry_then_publish_verified_bytes(self):
        for status in (429, 500, 502, 503, 504):
            with self.subTest(status=status), tempfile.TemporaryDirectory() as directory:
                self.sleep.reset_mock()
                with patch("models.urllib.request.urlopen",
                           side_effect=[self.error(status), io.BytesIO(self.data)]) as request:
                    download(directory)
                self.assertEqual(Path(directory, "tokenizer.json").read_bytes(), self.data)
                self.assertEqual(len(list(Path(directory).iterdir())), 1)
                self.assertEqual(request.call_count, 2)
                self.sleep.assert_called_once_with(1)

    def test_transient_failure_exhausts_four_attempts_and_removes_partial_files(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch("models.urllib.request.urlopen", side_effect=self.error(503)) as request:
                with self.assertRaises(urllib.error.HTTPError):
                    download(directory)
            self.assertEqual(request.call_count, 4)
            self.assertEqual([call.args[0] for call in self.sleep.call_args_list], [1, 2, 4])
            self.assertEqual(list(Path(directory).iterdir()), [])

    def test_permanent_http_errors_are_not_retried(self):
        for status in (400, 401, 403, 404):
            with self.subTest(status=status), tempfile.TemporaryDirectory() as directory:
                with patch("models.urllib.request.urlopen", side_effect=self.error(status)) as request:
                    with self.assertRaises(urllib.error.HTTPError):
                        download(directory)
                self.assertEqual(request.call_count, 1)
                self.assertEqual(list(Path(directory).iterdir()), [])
        self.sleep.assert_not_called()

    def test_partial_connection_failure_restarts_without_mixing_bytes(self):
        class Interrupted(io.BytesIO):
            def read(self, size):
                if self.tell():
                    raise ConnectionResetError("interrupted")
                return super().read(3)

        with tempfile.TemporaryDirectory() as directory:
            with patch("models.urllib.request.urlopen",
                       side_effect=[Interrupted(self.data), io.BytesIO(self.data)]) as request:
                download(directory)
            self.assertEqual(request.call_count, 2)
            self.assertEqual(Path(directory, "tokenizer.json").read_bytes(), self.data)
            self.assertEqual(len(list(Path(directory).iterdir())), 1)

    def test_invalid_bytes_fail_without_retry_or_replacing_existing_artifact(self):
        for invalid in (b"short", b"x" * len(self.data)):
            with self.subTest(invalid=invalid), tempfile.TemporaryDirectory() as directory:
                artifact = Path(directory, "tokenizer.json")
                artifact.write_bytes(self.data)
                with patch("models.urllib.request.urlopen", return_value=io.BytesIO(invalid)) as request:
                    with self.assertRaises(RuntimeError):
                        download(directory)
                self.assertEqual(request.call_count, 1)
                self.assertEqual(artifact.read_bytes(), self.data)
                self.assertEqual(len(list(Path(directory).iterdir())), 1)
        self.sleep.assert_not_called()


if __name__ == "__main__":
    unittest.main()
