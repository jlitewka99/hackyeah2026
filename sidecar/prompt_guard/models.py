"""Verify pinned Git blobs/LFS hashes before loading manually gated artifacts offline."""
import hashlib
import json
import os
import shutil
import sys
from pathlib import Path

MANIFEST = json.loads(Path(__file__).with_name("models.v1.json").read_text())


def verify(directory):
    for item in MANIFEST["files"]:
        path = Path(directory) / item["path"]
        if not path.is_file() or path.stat().st_size != item["bytes"]:
            raise RuntimeError("model_files_unavailable")
        with path.open("rb") as source:
            if "sha256" in item:
                digest = hashlib.file_digest(source, "sha256").hexdigest()
                expected = item["sha256"]
            else:
                content = source.read()
                digest = hashlib.sha1(b"blob " + str(len(content)).encode() + b"\0" + content).hexdigest()
                expected = item["git_blob_sha1"]
        if digest != expected:
            raise RuntimeError("model_checksum_mismatch")


def download(directory):
    # Use only the operator's already approved credential. Never submit an access form.
    from huggingface_hub import hf_hub_download
    token = os.environ.get("HF_TOKEN")
    if not token:
        raise RuntimeError("approved_huggingface_token_required")
    for item in MANIFEST["files"]:
        cached = hf_hub_download(MANIFEST["model_id"], item["path"],
                                revision=MANIFEST["revision"], token=token)
        target = Path(directory) / item["path"]
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(cached, target)
    verify(directory)
    shutil.copyfile(Path(__file__).with_name("NOTICE.md"), Path(directory) / "NOTICE.md")


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[1] not in {"download", "verify"}:
        raise SystemExit("Usage: models.py download|verify DIRECTORY")
    try:
        {"download": download, "verify": verify}[sys.argv[1]](sys.argv[2])
    except Exception:
        # Transport exceptions may contain signed URLs or credentials.
        raise SystemExit("Pinned Prompt Guard artifacts unavailable; approved access and complete verified files are required") from None
