"""Pinned artifacts downloaded at build time and verified before offline loading."""
import hashlib
import json
import sys
import urllib.request
from pathlib import Path

MANIFEST = json.loads(Path(__file__).with_name("models.v1.json").read_text())


def verify(directory):
    for item in MANIFEST["files"]:
        path = Path(directory) / item["path"]
        if not path.is_file() or path.stat().st_size != item["bytes"]:
            raise RuntimeError("model_files_unavailable")
        with path.open("rb") as source:
            if hashlib.file_digest(source, "sha256").hexdigest() != item["sha256"]:
                raise RuntimeError("model_checksum_mismatch")


def download(directory):
    for item in MANIFEST["files"]:
        path = Path(directory) / item["path"]
        path.parent.mkdir(parents=True, exist_ok=True)
        if path.is_file() and path.stat().st_size == item["bytes"]:
            with path.open("rb") as source:
                if hashlib.file_digest(source, "sha256").hexdigest() == item["sha256"]:
                    continue
        with urllib.request.urlopen(item["url"], timeout=120) as response, path.open("wb") as target:
            while chunk := response.read(1024 * 1024):
                target.write(chunk)
    verify(directory)


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[1] not in {"download", "verify"}:
        raise SystemExit("Usage: models.py download|verify DIRECTORY")
    {"download": download, "verify": verify}[sys.argv[1]](sys.argv[2])
