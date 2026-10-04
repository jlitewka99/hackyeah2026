"""Download only during setup/build; verify pinned bytes before accepting requests."""
import hashlib
import json
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

MANIFEST = json.loads(Path(__file__).with_name("models.v1.json").read_text())
DOWNLOAD_ATTEMPTS = 4
TRANSIENT_HTTP = {429, 500, 502, 503, 504}


GRANITE_MANIFEST = json.loads(Path(__file__).with_name("granite.v1.json").read_text())


def verify(directory, manifest=None):
    manifest = MANIFEST if manifest is None else manifest
    for entry in manifest["files"]:
        verify_file(Path(directory) / entry["path"], entry)


def verify_file(path, entry):
    if not path.is_file() or path.stat().st_size != entry["bytes"]:
        raise RuntimeError("tokenizer_files_unavailable")
    with path.open("rb") as source:
        if hashlib.file_digest(source, "sha256").hexdigest() != entry["sha256"]:
            raise RuntimeError("tokenizer_checksum_mismatch")


def download_file(path, entry):
    # Setup/build only: each attempt starts fresh, verifies bytes, then publishes.
    for attempt in range(DOWNLOAD_ATTEMPTS):
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(dir=path.parent, prefix=f".{path.name}.",
                                             suffix=".part", delete=False) as target:
                temporary = Path(target.name)
                with urllib.request.urlopen(entry["url"], timeout=120) as response:
                    while chunk := response.read(1024 * 1024):
                        target.write(chunk)
            verify_file(temporary, entry)
            # Build runs as root; the offline service runs as UID 10001.
            temporary.chmod(0o644)
            temporary.replace(path)
            return
        except urllib.error.HTTPError as error:
            if error.code not in TRANSIENT_HTTP or attempt == DOWNLOAD_ATTEMPTS - 1:
                raise
        except (urllib.error.URLError, TimeoutError, ConnectionError):
            if attempt == DOWNLOAD_ATTEMPTS - 1:
                raise
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)
        time.sleep(2 ** attempt)


def download(directory, manifest=None):
    manifest = MANIFEST if manifest is None else manifest
    for entry in manifest["files"]:
        path = Path(directory) / entry["path"]
        path.parent.mkdir(parents=True, exist_ok=True)
        download_file(path, entry)
    verify(directory, manifest)


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[1] not in {"download", "verify", "download-granite", "verify-granite"}:
        raise SystemExit("Usage: models.py download|verify|download-granite|verify-granite DIRECTORY")
    operation = sys.argv[1].removesuffix("-granite")
    manifest = GRANITE_MANIFEST if sys.argv[1].endswith("-granite") else MANIFEST
    {"download": download, "verify": verify}[operation](sys.argv[2], manifest)
