#!/usr/bin/env python3
"""Bound encrypted backup storage, preserving recent and proven recovery sets."""
import argparse
import fcntl
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path


def setting(name, default, minimum=1):
    value = int(os.environ.get(name, default))
    if value < minimum:
        raise ValueError(f"{name} must be at least {minimum}")
    return value


def limits():
    result = (setting("BACKUP_MAX_BYTES", 1073741824),
              setting("BACKUP_MIN_FREE_BYTES", 536870912),
              setting("BACKUP_MAX_USAGE_PERCENT", 85),
              setting("BACKUP_MAX_SETS", 7, 5),
              setting("RETENTION_DAYS", 7))
    if result[2] > 99:
        raise ValueError("BACKUP_MAX_USAGE_PERCENT must be between 1 and 99")
    return result


def size(path):
    # Count every file, including unfinished sets and operator-added files.
    if path.is_symlink():
        raise ValueError("backup storage must not contain symlinks")
    if path.is_file():
        return path.stat().st_size
    return sum(size(child) for child in path.iterdir()) if path.is_dir() else 0


def inventory(root):
    sets = []
    for path in root.iterdir():
        if not re.fullmatch(r"[a-f0-9]{32}", path.name) or path.is_symlink() or not path.is_dir():
            continue
        marker = path / "OFFSITE_COMPLETE"
        if not marker.is_file():
            marker = path / "LOCAL_COMPLETE"
        if not marker.is_file() or marker.is_symlink():
            continue
        values = dict(line.split("=", 1) for line in marker.read_text().splitlines() if "=" in line)
        if values.get("set_id") != path.name or not values.get("completed_epoch", "").isdigit():
            continue
        sets.append((int(values["completed_epoch"]), path))
    return sorted(sets, key=lambda row: (row[0], row[1].name), reverse=True)


def cleanup_incomplete(root):
    """Remove only generated set paths that never received a completion marker.

    Call while holding the backup root's advisory lock. The roots used by a
    paired backup are locked together before cleanup, so this cannot race an
    active publisher sharing either destination.
    """
    for path in root.iterdir():
        pending = re.fullmatch(r"\.pending-[a-f0-9]{32}", path.name)
        generated = re.fullmatch(r"[a-f0-9]{32}", path.name)
        if not pending and not generated:
            continue
        if path.is_symlink() or not path.is_dir():
            continue
        if (path / "OFFSITE_COMPLETE").exists() or (path / "LOCAL_COMPLETE").exists():
            continue
        shutil.rmtree(path)
        print(f"BACKUP_RETENTION_STATUS=set={path.name} status=incomplete_removed", flush=True)


def protected_sets(sets):
    protected = {path for _, path in sets[:2]}
    verified = [path for _, path in sets if (path / "RESTORE_VERIFIED").is_file()]
    protected.update(verified[:2])
    return protected


def check_capacity(root, additional=0):
    maximum, minimum_free, maximum_used, _, _ = limits()
    disk = shutil.disk_usage(root)
    if size(root) + additional > maximum:
        raise ValueError("encrypted backup storage cap reached; protected recovery sets are retained")
    if disk.free - additional < minimum_free or (disk.used + additional) * 100 > disk.total * maximum_used:
        raise ValueError("backup disk reserve reached; new backup stopped to protect the server")


def prepare(root, reserve=0, incoming=True):
    _, _, _, maximum_sets, days = limits()
    cleanup_incomplete(root)
    sets = inventory(root)
    protected = protected_sets(sets)
    cutoff = time.time() - days * 86400
    target = maximum_sets - int(incoming)
    for epoch, path in reversed(sets):
        if path in protected:
            continue
        count_exceeded = len(inventory(root)) > target
        try:
            check_capacity(root, reserve)
            space_needed = False
        except ValueError:
            space_needed = True
        if epoch < cutoff or count_exceeded or space_needed:
            shutil.rmtree(path)
            print(f"BACKUP_RETENTION_STATUS=set={path.name} status=pruned", flush=True)
    if len(inventory(root)) > target:
        raise ValueError("set limit cannot accommodate another backup without deleting protected recovery sets")
    check_capacity(root, reserve)


def limited_write(root, output):
    # Only ciphertext may enter this writer. Check the shared filesystem as
    # well as the backup directory before every bounded write.
    if output.parent.parent.resolve() != root.resolve():
        raise ValueError("ciphertext output must be in a backup set directory")
    with output.open("xb") as stream:
        while True:
            chunk = sys.stdin.buffer.read(1024 * 1024)
            if not chunk:
                break
            check_capacity(root, len(chunk) + 4096)
            stream.write(chunk)
            stream.flush()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("prepare", "prune", "write", "copy", "lock", "lock-many", "list"))
    parser.add_argument("root", type=Path)
    parser.add_argument("arguments", nargs="*")
    args = parser.parse_args()
    try:
        limits()  # Validate even a first run with no completed sets.
        if args.command == "list":
            for _, path in inventory(args.root):
                print(path.name)
            return 0
        if args.command == "lock":
            with (args.root / ".backup.lock").open("a") as lock:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    raise ValueError("another backup already holds the storage lock") from None
                return subprocess.call(args.arguments)
        if args.command == "lock-many":
            # Usage: lock-many ROOT [ROOT ...] cmd: PROGRAM [ARG ...]. Sort
            # roots by canonical path so overlapping publisher sets cannot
            # deadlock. Hold all locks until the child exits.
            try:
                separator = args.arguments.index("cmd:")
            except ValueError:
                raise ValueError("lock-many requires cmd: before the child command") from None
            roots = [args.root, *(Path(value) for value in args.arguments[:separator])]
            command = args.arguments[separator + 1:]
            if not command:
                raise ValueError("lock-many requires a child command")
            unique_roots = {str(path.resolve()): path for path in roots}
            locks = []
            try:
                for canonical in sorted(unique_roots):
                    path = unique_roots[canonical]
                    lock = (path / ".backup.lock").open("a")
                    try:
                        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    except BlockingIOError:
                        lock.close()
                        raise ValueError("another backup already holds a storage lock") from None
                    locks.append(lock)
                env = os.environ.copy()
                env["BACKUP_STORAGE_LOCK_HELD"] = "1"
                return subprocess.call(command, env=env)
            finally:
                for lock in reversed(locks):
                    lock.close()
        if args.command in ("prepare", "prune"):
            reserve = max((size(path) for _, path in inventory(args.root)), default=0)
            prepare(args.root, reserve if args.command == "prepare" else 0,
                    incoming=args.command == "prepare")
        elif args.command == "write":
            limited_write(args.root, Path(args.arguments[0]))
        else:
            source, output = map(Path, args.arguments)
            check_capacity(args.root, source.stat().st_size + 4096)
            with source.open("rb") as incoming, output.open("xb") as outgoing:
                while True:
                    chunk = incoming.read(1024 * 1024)
                    if not chunk:
                        break
                    check_capacity(args.root, len(chunk) + 4096)
                    outgoing.write(chunk)
                    outgoing.flush()
        return 0
    except (ValueError, OSError) as error:
        print(f"Backup storage guard: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
