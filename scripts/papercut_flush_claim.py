#!/usr/bin/env python3
"""Locked claim step for papercut-flush.sh.

Acquires fcntl.flock on the SAME lock file papercut_append.py uses, and
while holding it, renames the spool to a uniquely-named batch file if (and
only if) the spool is still non-empty at that point. Held only across the
check+rename; released immediately after. Prints the new batch path on
stdout if a claim happened, otherwise prints nothing.

argv: <lock_path> <spool_path> <batch_dir>
"""

import fcntl
import os
import secrets
import sys
import time


def main() -> None:
    lock_path, spool_path, batch_dir = sys.argv[1:4]

    os.makedirs(os.path.dirname(lock_path) or ".", mode=0o700, exist_ok=True)
    os.makedirs(batch_dir, mode=0o700, exist_ok=True)

    lock_fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX)  # blocks until any in-flight append releases
        if os.path.isfile(spool_path) and os.path.getsize(spool_path) > 0:
            ts = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
            # A random token guarantees uniqueness even if the clock repeats a
            # second and a PID is reused across reboots — os.rename() would
            # otherwise silently overwrite (and lose) a matching stale batch.
            while True:
                token = secrets.token_hex(4)
                batch_path = os.path.join(
                    batch_dir, f"spool.batch.{ts}.{os.getpid()}.{token}.jsonl"
                )
                if not os.path.exists(batch_path):
                    break
            os.rename(spool_path, batch_path)
            print(batch_path)
    finally:
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
        os.close(lock_fd)


if __name__ == "__main__":
    main()
