"""Download only during setup/build; verify pinned bytes before accepting requests."""
import hashlib
import json
import sys
import urllib.request
from pathlib import Path

MANIFEST = json.loads(Path(__file__).with_name("models.v1.json").read_text())


GRANITE_MANIFEST = json.loads(Path(__file__).with_name("granite.v1.json").read_text())


def verify(directory, manifest=MANIFEST):
    for entry in manifest["files"]:
        path = Path(directory) / entry["path"]
        if not path.is_file() or path.stat().st_size != entry["bytes"]:
            raise RuntimeError("tokenizer_files_unavailable")
        with path.open("rb") as source:
            if hashlib.file_digest(source, "sha256").hexdigest() != entry["sha256"]:
                raise RuntimeError("tokenizer_checksum_mismatch")


def download(directory, manifest=MANIFEST):
    for entry in manifest["files"]:
        path = Path(directory) / entry["path"]
        path.parent.mkdir(parents=True, exist_ok=True)
        with urllib.request.urlopen(entry["url"], timeout=120) as response, path.open("wb") as target:
            while chunk := response.read(1024 * 1024):
                target.write(chunk)
    verify(directory, manifest)


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[1] not in {"download", "verify", "download-granite", "verify-granite"}:
        raise SystemExit("Usage: models.py download|verify DIRECTORY")
    operation = sys.argv[1].removesuffix("-granite")
    manifest = GRANITE_MANIFEST if sys.argv[1].endswith("-granite") else MANIFEST
    {"download": download, "verify": verify}[operation](sys.argv[2], manifest)
