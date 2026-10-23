#!/usr/bin/env python3
"""Hold independent PostgreSQL MVCC snapshots while export + inventory run."""
import os
import re
import selectors
import signal
import subprocess
import sys
import tempfile


def run_payload(arguments, env):
    raw = env.get("BACKUP_MAX_RUNTIME_SECONDS", "1800")
    if not re.fullmatch(r"[0-9]+", raw) or not 60 <= int(raw) <= 7200:
        raise ValueError("invalid backup runtime limit")
    process = subprocess.Popen(arguments, env=env, start_new_session=True)
    try:
        return process.wait(timeout=int(raw))
    finally:
        if process.poll() is None:
            # Terminate the entire streaming pipeline before releasing its
            # exported snapshots. Docker's client forwards TERM to pg_dump.
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait()


def main():
    sessions = []
    env = os.environ.copy()
    env.setdefault("PGCONNECT_TIMEOUT", "10")
    def cancelled(_signum, _frame):
        raise InterruptedError("backup cancelled")
    signal.signal(signal.SIGTERM, cancelled)
    try:
        for name, snapshot_name in (("PRODUCT_DATABASE_URL", "BACKUP_PRODUCT_SNAPSHOT"),
                                     ("AUTH_DATABASE_URL", "BACKUP_AUTH_SNAPSHOT")):
            errors = tempfile.TemporaryFile()
            session = subprocess.Popen(["psql", "-X", "-qAt", "-v", "ON_ERROR_STOP=1", env[name]],
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                       stderr=errors, text=True, env=env)
            sessions.append((session, errors))
            session.stdin.write("BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;\nSELECT pg_export_snapshot();\n")
            session.stdin.flush()
            with selectors.DefaultSelector() as selector:
                selector.register(session.stdout, selectors.EVENT_READ)
                if not selector.select(20):
                    raise RuntimeError("snapshot timeout")
            snapshot = session.stdout.readline().strip()
            if not re.fullmatch(r"[A-Fa-f0-9]+-[A-Fa-f0-9]+-[0-9]+", snapshot):
                raise RuntimeError("snapshot setup failed")
            env[snapshot_name] = snapshot
        # Both snapshots stay alive until all pg_dump and manifest queries end.
        return run_payload(sys.argv[1:], env)
    except subprocess.TimeoutExpired:
        print("Paired backup exceeded its runtime limit; no complete set was published", file=sys.stderr)
        return 1
    except Exception:
        print("Paired backup snapshot/export failed; no complete set was published", file=sys.stderr)
        return 1
    finally:
        for session, errors in sessions:
            try:
                session.stdin.write("ROLLBACK;\n\\q\n")
                session.stdin.flush()
                session.wait(timeout=5)
            except (OSError, ValueError, subprocess.TimeoutExpired):
                session.kill()
                session.wait()
            errors.close()


if __name__ == "__main__":
    raise SystemExit(main())
