#!/usr/bin/env python3
"""Derive safe throwaway DB names from explicit recovery-host URLs."""
import argparse
import json
from urllib.parse import urlsplit, urlunsplit


def parse_url(value, label):
    parts = urlsplit(value)
    if parts.scheme not in ("postgres", "postgresql") or not parts.hostname or not parts.path.strip("/"):
        raise ValueError(f"{label} must be a PostgreSQL URI with a database name")
    return parts


def endpoint(parts):
    return parts.scheme, parts.hostname.lower(), parts.port or 5432


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--admin", required=True)
    parser.add_argument("--product", required=True)
    parser.add_argument("--auth", required=True)
    parser.add_argument("--set-id", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    try:
        admin = parse_url(args.admin, "restore admin URL")
        product = parse_url(args.product, "restore product URL")
        auth = parse_url(args.auth, "restore auth URL")
        if endpoint(admin) != endpoint(product) or endpoint(admin) != endpoint(auth):
            raise ValueError("all RESTORE_* URLs must identify the same independent PostgreSQL recovery host")
        if product.path == auth.path:
            raise ValueError("restore product and auth URLs must name distinct databases")
        if not args.set_id.isalnum() or len(args.set_id) != 32:
            raise ValueError("invalid generated backup set ID")
        product_db = f"pprestore_{args.set_id[:20]}_p"
        auth_db = f"pprestore_{args.set_id[:20]}_a"

        def database_url(parts, db_name):
            path = "/" + db_name
            return urlunsplit((parts.scheme, parts.netloc, path, parts.query, parts.fragment))

        result = {
            "product_db": product_db,
            "auth_db": auth_db,
            "product_url": database_url(product, product_db),
            "auth_url": database_url(auth, auth_db),
        }
        with open(args.output, "w", encoding="utf-8") as output:
            json.dump(result, output)
        return 0
    except Exception as error:
        # URLs may embed credentials; never include the exception text.
        print(f"restore URL validation failed: {type(error).__name__}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
