#!/usr/bin/env python3
"""Run a simulator command with a deadline; never leave the E2E hanging forever."""
import os
import subprocess
import sys


def main():
    timeout = float(os.environ.get("FOLIO_IOS_SIMCTL_TIMEOUT", "60"))
    command = ["xcrun", "simctl", *sys.argv[1:]]
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        print(f"TIMEOUT after {timeout:g}s: {' '.join(command)}", file=sys.stderr)
        if error.stdout:
            sys.stdout.write(error.stdout.decode(errors="replace") if isinstance(error.stdout, bytes) else error.stdout)
        if error.stderr:
            sys.stderr.write(error.stderr.decode(errors="replace") if isinstance(error.stderr, bytes) else error.stderr)
        return 124
    sys.stdout.write(result.stdout)
    sys.stderr.write(result.stderr)
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
