"""Generate a source-only Express route inventory; never import backend services."""
import json
from collections import Counter, defaultdict
from pathlib import Path
from tree_sitter import Language, Parser
import tree_sitter_javascript as javascript

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(__file__).resolve().parent
parser = Parser(Language(javascript.language()))
METHODS = {"get", "post", "put", "patch", "delete", "head", "options", "all"}


def walk(node):
    yield node
    for child in node.named_children:
        yield from walk(child)


def calls(relative):
    data = (ROOT / relative).read_bytes()
    tree = parser.parse(data)
    if tree.root_node.has_error:
        raise ValueError(f"JavaScript parse errors in {relative}")
    for node in walk(tree.root_node):
        if node.type != "call_expression":
            continue
        function = node.child_by_field_name("function")
        arguments = node.child_by_field_name("arguments")
        if function and arguments:
            yield node, function, arguments.named_children, data


def literal(node, data):
    value = data[node.start_byte:node.end_byte].decode()
    return value[1:-1] if node.type in ("string", "template_string") else value


def classify(service, path, guards):
    if service == "auth":
        if path.startswith("/admin/"):
            return "JWT + security_admin (feature flag)"
        if path.startswith("/users/me/recovery-contact/"):
            return "JWT + recent recovery proof + rate limit"
        if path.startswith("/users/"):
            return "JWT" + (" + step-up" if "requireRecentOtpOrReauth" in guards else "")
        if path in ("/auth/request-otp", "/auth/request-email-otp"):
            return "Public login: delivery/rate-limit checks"
        if path in ("/auth/verify-otp", "/auth/verify-email-otp"):
            return "OTP proof + rate limit (no existing JWT)"
        if path == "/auth/google":
            return "Google ID-token proof"
        if path in ("/auth/refresh", "/auth/logout"):
            return "Refresh-token proof"
        if path == "/auth/validate-token":
            return "Public token introspection (token in body)"
        if path in ("/auth/signup", "/auth/guest-login", "/auth/check-user"):
            return "Public legacy endpoint — review finding"
        return "Public health/debug page"
    if "requireAdmin" in guards:
        return "JWT + product admin DB membership"
    if "requireAuth" in guards:
        return "JWT (signature/issuer/audience/expiry only)"
    if path in ("/partner-conversions/webhook", "/inbound-emails/webhook"):
        return "Shared webhook secret inside handler"
    if path == "/analytics/events":
        return "Anonymous write allowed / optional JWT"
    return "Public read / optional JWT"


routes = []
sources = [
    ("api", "api/src/index.js", ""),
    ("api", "api/src/transaction_splits.js", ""),
    ("auth", "auth/src/index.js", ""),
    ("auth", "auth/src/routes/authRoutes.js", "/auth"),
    ("auth", "auth/src/routes/userRoutes.js", "/users"),
    ("auth", "auth/src/routes/recoveryContactRoutes.js", "/users/me/recovery-contact"),
    ("auth", "auth/src/routes/adminRoutes.js", "/admin"),
]
for service, source, prefix in sources:
    for node, fn, args, data in calls(source):
        if fn.type != "member_expression" or not args:
            continue
        obj = fn.child_by_field_name("object")
        prop = fn.child_by_field_name("property")
        if not obj or not prop or literal(obj, data) not in ("app", "router"):
            continue
        method = literal(prop, data)
        if method not in METHODS:
            continue
        path = prefix + literal(args[0], data)
        guards = [literal(arg, data) for arg in args[1:-1]]
        routes.append({"service": service, "method": method.upper(), "path": path,
                       "source": source, "line": node.start_point.row + 1,
                       "guards": guards, "access": classify(service, path, guards)})

# The declarative family writer generates additional admin routes.
for node, fn, args, data in calls("api/src/index.js"):
    if literal(fn, data) != "registerRuleFamilyRoutes":
        continue
    spec = {}
    for pair in args[2].named_children:
        if pair.type != "pair":
            continue
        key, value = pair.child_by_field_name("key"), pair.child_by_field_name("value")
        spec[literal(key, data)] = literal(value, data)
    segment = spec["urlSegment"]
    patterns = [("PUT", f"/admin/{segment}/by-card/:cardProductId")] if spec.get("singlePerCard") == "true" else [
        ("POST", f"/admin/{segment}"), ("PUT", f"/admin/{segment}/:id"),
        ("DELETE", f"/admin/{segment}/:id")]
    for method, path in patterns:
        routes.append({"service": "api", "method": method, "path": path,
                       "source": "api/src/index.js", "line": node.start_point.row + 1,
                       "guards": ["requireAdmin (factory)"],
                       "access": "JWT + product admin DB membership"})

routes.sort(key=lambda row: (row["service"], row["path"], row["method"]))
duplicates = {f"{s} {m} {p}": n for (s, m, p), n in Counter(
    (r["service"], r["method"], r["path"]) for r in routes).items() if n > 1}
summary = {service: {"total": sum(r["service"] == service for r in routes),
                    "access": dict(Counter(r["access"] for r in routes if r["service"] == service))}
           for service in ("api", "auth")}
report = {"source_commit": "c2e41d8", "date": "2026-10-20", "method": "Tree-sitter JavaScript AST; generated route families expanded; router mount guards manually resolved", "summary": summary, "duplicate_method_path_registrations": duplicates, "routes": routes}
(OUT / "route-inventory.json").write_text(json.dumps(report, indent=2) + "\n")
lines = ["# Backend API authentication inventory", "", "Source snapshot: 2026-10-20, HEAD c2e41d8. Runtime guard behavior is discussed in the security report; a JWT middleware label is not proof that session revocation or ownership checks are complete.", ""]
for service in ("api", "auth"):
    lines.extend([f"## {service} — {summary[service]['total']} method/path pairs", "", "| Method | Path | Access control | Source |", "|---|---|---|---|"])
    for row in routes:
        if row["service"] == service:
            lines.append(f"| {row['method']} | `{row['path']}` | {row['access']} | [{row['source']}:{row['line']}]({ROOT / row['source']}:{row['line']}) |")
    lines.append("")
lines.extend(["## Boundaries", "", "The auth service also mounts `express.static('public')` before the protected admin dashboard route. Thus `/test.html`, `/security-dashboard.html`, and any other files in `auth/public/` are public. These static resources are not included in the method/path count. Automatic Express HEAD/OPTIONS handling is also not counted separately.", "", "Product API global `optionalAuth` verifies the JWT before route guards. Auth `/admin/*` inherits `authMiddleware`, `adminAuth`, and `adminRateLimit` from its feature-gated mount. Recovery-contact routes inherit `auth`, a sensitive-operation limiter, and a recent recovery-proof guard from `router.use`.", "", f"Duplicate explicit method/path registrations detected: {len(duplicates)}.", ""])
(OUT / "route-inventory.md").write_text("\n".join(lines))
print(json.dumps({"summary": summary, "duplicates": duplicates}, indent=2))
