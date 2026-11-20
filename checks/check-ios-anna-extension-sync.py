#!/usr/bin/env python3
"""Read-only diagnostic: compare the Anna source in repo/build/iOS simulator.

Does not download books, modify an app container, or print library titles.
Usage: python3 checks/check-ios-anna-extension-sync.py
"""

import hashlib
import json
from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "extensions/annas-archive.js"
BUILT = ROOT / "app/iOS/.build/Build/Products/Debug-iphonesimulator/Folio.app/annas-archive.js"
BUNDLE_ID = "app.folio.reader.ios"


def container(kind):
    try:
        result = subprocess.run(
            ["xcrun", "simctl", "get_app_container", "booted", BUNDLE_ID, kind],
            capture_output=True, text=True, timeout=8, check=False,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None
    return Path(result.stdout.strip()) if result.returncode == 0 else None


def fingerprint(label, path):
    if path is None or not path.is_file():
        print(f"{label}: unavailable")
        return None
    content = path.read_bytes()
    digest = hashlib.sha256(content).hexdigest()
    print(f"{label}: {len(content)} bytes · SHA256 {digest}")
    return digest


def main():
    app = container("app")
    data = container("data")
    locations = [
        ("Repository extension", SOURCE),
        ("Xcode Debug bundle", BUILT),
        ("Installed simulator app", app / "annas-archive.js" if app else None),
        ("Simulator runtime extension", data / "Library/Application Support/Folio/Extensions/annas-archive-free.js" if data else None),
    ]
    actual = [(label, fingerprint(label, path)) for label, path in locations]
    reference = actual[0][1]
    mismatched = [name for name, digest in actual[1:] if digest is not None and digest != reference]
    if data is not None:
        queue = data / "Library/Application Support/Folio/download-queue.json"
        if queue.is_file():
            try:
                jobs = json.loads(queue.read_text())
                by_stage = {}
                for job in jobs:
                    stage = str(job.get("stage", "unknown"))
                    by_stage[stage] = by_stage.get(stage, 0) + 1
                print(f"Queue: {len(jobs)} jobs (by stage: {by_stage})")
            except (OSError, ValueError, TypeError) as exc:
                print(f"Queue: could not read saved metadata ({type(exc).__name__})")
    if mismatched:
        print("\nSTALE_EXTENSION: " + ", ".join(mismatched))
        print("Regenerate the iOS build and reinstall the app to test the current extension.")
        return 1
    if not reference:
        print("Missing source extension file.")
        return 2
    print("\nAll available Anna's Archive extension copies match the repository source.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
