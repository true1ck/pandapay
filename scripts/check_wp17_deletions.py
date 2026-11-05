#!/usr/bin/env python3
"""Read-only WP-17 deletion check. Never modifies or deletes anything.

For each deletion candidate in WP-17 item 3 (docs/sms-pipeline-v2/work-packages/WP-17.md)
this lists every Dart file that still imports, exports or `part`s it, and flags
any importer that belongs to the frozen Gmail / email / IMAP / card-discovery
code (WP-17: "If a Gmail, email or card-discovery file imports it, keep it and
record why"). It also prints where the legacy server routes and modules kept
until the cutoff (WP-17 item 4) are still referenced.

Usage:
    python3 scripts/check_wp17_deletions.py            # human report
    python3 scripts/check_wp17_deletions.py --json     # machine readable
    python3 scripts/check_wp17_deletions.py -v         # also list test importers
    python3 scripts/check_wp17_deletions.py --strict   # exit 1 if any frozen importer exists

Exit status is 0 unless --strict is given and a frozen-code importer is found.
"""
from __future__ import annotations

import json
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
APP_PACKAGE = "pandapay"  # app/pubspec.yaml name
DOMAIN_PACKAGE = "pandapay_domain"

# WP-17 item 3: whole-file deletion candidates (paths relative to the repo root).
CANDIDATES = [
    ("Parsers", "app/lib/data/local_sms_parser.dart"),
    ("Parsers", "app/lib/data/indian_narration_sanitizer.dart"),
    ("Parsers", "app/lib/data/flashtext_merchant_extractor.dart"),
    ("Parsers", "app/lib/data/sms_fact_scoring.dart"),
    ("Old AI and review", "app/lib/data/local/sms_auto_resolution_controller.dart"),
    ("Old AI and review", "app/lib/features/activity/needs_review_screen.dart"),
    ("Old AI and review", "app/lib/data/needs_review_repository.dart"),
    ("v1 rule bundles", "app/lib/data/local/sms_rule_bundle_store.dart"),
    ("v1 rule bundles", "app/lib/data/local/sms_rule_bundle.dart"),
    ("v1 learning outbox", "app/lib/data/local/sms_learning_feedback.dart"),
]
# Partial deletions listed in WP-17 item 3 that cannot be checked per file.
PARTIAL = [
    "app/lib/app/providers.dart: the 90-second AI timer, the AI reconcile and the legacy upload code",
    "app/lib/data/local/financial_store.dart and providers.dart: bank-account derivation and its 'ponytail' filters",
    "app/lib/features/sms_import/sms_import_store.dart: the v1-only branches (keep the gate, source key and capture bookkeeping)",
    "the tests of deleted code (map each to a golden case or v2 test via WP-03's handoff)",
]

# Frozen code: importing a candidate from any of these means "keep it and record why".
# Hub files that import nearly everything and that WP-17 itself trims; a chain through
# them proves nothing about the frozen code, so the transitive search does not pass them.
HUBS = {"app/lib/app/providers.dart", "app/lib/app/router.dart"}
FROZEN = re.compile(r"(gmail|email|imap|card_discovery|card_pipeline)", re.I)

DART_ROOTS = ["app/lib", "app/test", "app/integration_test", "packages", "tools", "console"]
SKIP_DIRS = {".dart_tool", "build", "node_modules", ".git", ".pub-cache", "ios", "android", "macos", "windows", "linux"}
DIRECTIVE = re.compile(r"""^\s*(?:import|export|part)\s+(?:r)?['"]([^'"]+)['"]""", re.M)

# Legacy server surface kept until the cutoff (WP-17 item 4).
ROUTES = [
    "/transactions/from-sms/batch",
    "/sms/facts",
    "/ai/jobs",
    "/sms/rules/active",
]
SERVER_MODULES = ["gemini_worker.js", "sms_parser.js", "merchant_category.js"]
API_DIRS = ["api/src", "api/scripts"]
CLIENT_DIRS = ["app/lib", "console/lib", "tools", "scripts"]


def walk(base, exts):
    start = os.path.join(ROOT, base)
    for dirpath, dirnames, filenames in os.walk(start):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in filenames:
            if name.endswith(exts):
                yield os.path.join(dirpath, name)


def rel(path):
    return os.path.relpath(path, ROOT)


def package_lib_dirs():
    """Map package name -> lib directory for first-party packages."""
    dirs = {APP_PACKAGE: os.path.join(ROOT, "app", "lib"),
            DOMAIN_PACKAGE: os.path.join(ROOT, "packages", "pandapay_domain", "lib")}
    pk = os.path.join(ROOT, "packages")
    if os.path.isdir(pk):
        for name in os.listdir(pk):
            lib = os.path.join(pk, name, "lib")
            if os.path.isdir(lib):
                dirs.setdefault(name, lib)
    return dirs


def resolve(importer, uri, pkg_dirs):
    if uri.startswith("dart:"):
        return None
    if uri.startswith("package:"):
        pkg, _, rest = uri[len("package:"):].partition("/")
        base = pkg_dirs.get(pkg)
        return os.path.normpath(os.path.join(base, rest)) if base else None
    return os.path.normpath(os.path.join(os.path.dirname(importer), uri))


def dart_files():
    seen = set()
    for base in DART_ROOTS:
        for path in walk(base, (".dart",)):
            if path not in seen:
                seen.add(path)
                yield path


def scan_importers():
    pkg_dirs = package_lib_dirs()
    targets = {os.path.join(ROOT, p): p for _, p in CANDIDATES}
    found = {p: [] for _, p in CANDIDATES}
    graph = {}
    for path in dart_files():
        try:
            with open(path, encoding="utf-8") as fh:
                text = fh.read()
        except (OSError, UnicodeDecodeError):
            continue
        for uri in DIRECTIVE.findall(text):
            resolved = resolve(path, uri, pkg_dirs)
            if resolved:
                graph.setdefault(rel(path), set()).add(rel(resolved))
            if resolved in targets and path != resolved:
                found[targets[resolved]].append(rel(path))
    return {k: sorted(set(v)) for k, v in found.items()}, graph


def frozen_reach(graph):
    """Candidates that frozen code reaches through any chain of imports.

    Deleting such a candidate breaks the frozen code even when no frozen file
    imports it directly. Chains through the HUBS (providers.dart, router.dart)
    are ignored. Returns {candidate: [frozen file, ..., candidate]}.
    """
    wanted = {p for _, p in CANDIDATES}
    reach = {}
    for start in sorted(f for f in graph if FROZEN.search(f) and not is_test(f) and f.startswith(("app/lib", "packages"))):
        parent = {start: None}
        queue = [start]
        while queue:
            cur = queue.pop(0)
            for nxt in graph.get(cur, ()):
                if nxt in parent or nxt in HUBS:
                    continue
                parent[nxt] = cur
                if nxt in wanted and nxt not in reach:
                    chain, node = [], nxt
                    while node:
                        chain.append(node)
                        node = parent[node]
                    reach[nxt] = chain[::-1]
                queue.append(nxt)
    return reach


def is_test(path):
    return path.startswith("app/test/") or "/test/" in path or path.startswith("app/integration_test/")


def grep_files(dirs, exts, needle):
    hits = []
    for base in dirs:
        for path in walk(base, exts):
            if os.path.abspath(path) == os.path.abspath(__file__):
                continue
            try:
                with open(path, encoding="utf-8") as fh:
                    for lineno, line in enumerate(fh, 1):
                        if needle in line:
                            hits.append((rel(path), lineno, line.strip()[:140]))
            except (OSError, UnicodeDecodeError):
                continue
    return hits


def route_report():
    out = {}
    for route in ROUTES:
        server = [h for h in grep_files(API_DIRS, (".js",), route) if "app." in h[2] or "router." in h[2] or "'" + route in h[2]]
        client = grep_files(CLIENT_DIRS, (".dart", ".js", ".py"), route)
        out[route] = {"server": server, "clients": client}
    mods = {}
    for mod in SERVER_MODULES:
        stem = mod[:-3]
        pattern = re.compile(r"require\(\s*['\"]\.{1,2}/(?:[\w./-]*/)?" + re.escape(stem) + r"(?:\.js)?['\"]\s*\)")
        refs = []
        for base in API_DIRS + ["db", "scripts", "deploy", "docker-compose.prod.yml"]:
            full = os.path.join(ROOT, base)
            paths = [full] if os.path.isfile(full) else list(walk(base, (".js", ".yml", ".sh", ".py")))
            for path in paths:
                if path.endswith(mod):
                    continue
                try:
                    with open(path, encoding="utf-8") as fh:
                        for lineno, line in enumerate(fh, 1):
                            if pattern.search(line) or (stem + ".js") in line and "require" not in line and "node " in line:
                                refs.append((rel(path), lineno, line.strip()[:140]))
                except (OSError, UnicodeDecodeError):
                    continue
        mods[mod] = refs
    return out, mods


def main(argv):
    as_json = "--json" in argv
    strict = "--strict" in argv
    verbose = "-v" in argv or "--verbose" in argv
    importers, graph = scan_importers()
    reach = frozen_reach(graph)
    exists = {p: os.path.isfile(os.path.join(ROOT, p)) for _, p in CANDIDATES}
    routes, modules = route_report()

    report = {"candidates": [], "frozenReach": reach, "partial": PARTIAL, "routes": routes, "serverModules": modules}
    blocked_by_frozen = False
    for group, path in CANDIDATES:
        users = importers[path]
        lib_users = [u for u in users if not is_test(u)]
        test_users = [u for u in users if is_test(u)]
        frozen = [u for u in lib_users if FROZEN.search(u)]
        candidate_users = [u for u in lib_users if u in {p for _, p in CANDIDATES}]
        other = [u for u in lib_users if u not in frozen and u not in candidate_users]
        blocked_by_frozen = blocked_by_frozen or bool(frozen) or path in reach
        report["candidates"].append({
            "group": group, "file": path, "exists": exists[path],
            "frozenImporters": frozen, "otherCandidateImporters": candidate_users,
            "otherLibImporters": other, "testImporters": test_users,
            "verdict": "KEEP (frozen importer)" if frozen else
                       "KEEP (reachable from frozen code)" if path in reach else
                       ("blocked by live importers" if other else "deletable once only candidates/tests remain"),
        })

    if as_json:
        print(json.dumps(report, indent=2))
    else:
        print("WP-17 deletion check (read-only; nothing is deleted)\n")
        for c in report["candidates"]:
            print(f"[{c['group']}] {c['file']}" + ("" if c["exists"] else "   <-- file not found"))
            print(f"    verdict: {c['verdict']}")
            for label, key in (("FROZEN Gmail/email/card-discovery importer", "frozenImporters"),
                               ("also a deletion candidate", "otherCandidateImporters"),
                               ("live importer", "otherLibImporters")):
                for u in c[key]:
                    print(f"      {label}: {u}")
            if verbose:
                for u in c["testImporters"]:
                    print(f"      test importer: {u}")
            else:
                print(f"      test importers: {len(c['testImporters'])} (use -v to list)")
            print()
        print("Candidates reachable from frozen Gmail/email/card-discovery code (shortest import chain):")
        if reach:
            for cand, chain in sorted(reach.items()):
                print(f"  {cand}\n      " + "  ->  ".join(chain))
        else:
            print("  (none)")
        print()
        print("Partial deletions (check by hand):")
        for p in PARTIAL:
            print(f"  - {p}")
        print("\nLegacy server routes kept until the cutoff:")
        for route, data in routes.items():
            print(f"  {route}")
            for f, n, line in data["server"]:
                print(f"      server  {f}:{n}  {line}")
            for f, n, line in data["clients"]:
                print(f"      client  {f}:{n}  {line}")
            if not data["server"] and not data["clients"]:
                print("      (no references found)")
        print("\nLegacy server modules (importers):")
        for mod, refs in modules.items():
            print(f"  {mod}")
            for f, n, line in refs:
                note = "   <-- frozen email/IMAP/card code" if FROZEN.search(f) else ""
                print(f"      {f}:{n}  {line}{note}")
            if not refs:
                print("      (no importers found)")
        print()
        if blocked_by_frozen:
            print("RESULT: at least one candidate is imported (directly or transitively) by frozen Gmail/email/card-discovery code; keep it and record why.")
        else:
            print("RESULT: no frozen-code importer found (live importers above still block deletion).")
    return 1 if strict and blocked_by_frozen else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
