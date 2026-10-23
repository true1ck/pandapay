#!/usr/bin/env python3
"""Prepare password-free libpq URLs and a restrictive .pgpass for backup jobs."""
import argparse
import json
import os
import re
import ipaddress
import sys
import ssl
from pathlib import Path
from urllib.parse import parse_qsl, quote, unquote, urlencode, urlsplit, urlunsplit


def escape_pgpass(value):
    return value.replace("\\", "\\\\").replace(":", "\\:")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    parser.add_argument("--pgpass", required=True)
    parser.add_argument("--url-env", action="append", required=True)
    args = parser.parse_args()
    try:
        env_mode = os.environ.get("NODE_ENV", "production").lower()
        db_ssl = os.environ.get("DB_SSL", "true").lower()
        if db_ssl not in ("true", "false", "1", "0"):
            raise ValueError("invalid DB_SSL")
        if db_ssl in ("false", "0") and env_mode not in ("test", "development"):
            raise ValueError("unencrypted database transport is allowed only in local test/development")

        ca_path = os.environ.get("DB_SSL_CA_FILE", "").strip()
        inline_ca = os.environ.get("DB_SSL_CA", "")
        if ca_path and inline_ca:
            raise ValueError("configure DB_SSL_CA_FILE or DB_SSL_CA, not both")
        if ca_path and not Path(ca_path).is_file():
            raise ValueError("configured DB SSL CA is not a file")
        if db_ssl in ("false", "0") and (ca_path or inline_ca):
            raise ValueError("DB SSL CA cannot be used when DB_SSL=false")
        extra_ca = inline_ca or (Path(ca_path).read_text() if ca_path else "")

        urls = {}
        pass_lines = []
        for name in args.url_env:
            raw = os.environ.get(name, "")
            if not raw:
                raise ValueError("required database URL is missing")
            parts = urlsplit(raw)
            if parts.scheme not in ("postgres", "postgresql") or not parts.hostname:
                raise ValueError("database URL must use postgres/postgresql URI syntax")
            if "," in parts.hostname:
                raise ValueError("multi-host PostgreSQL URLs are not supported by this backup helper")
            host = parts.hostname
            if db_ssl in ("false", "0"):
                try:
                    local = ipaddress.ip_address(host).is_loopback
                except ValueError:
                    local = host.lower() in ("localhost", "db", "postgres")
                if not local:
                    raise ValueError("unencrypted transport requires a local test database")
            port = parts.port or 5432
            database = unquote(parts.path.lstrip("/"))
            username = unquote(parts.username or "")
            password = unquote(parts.password or "")
            if any("\n" in field or "\r" in field for field in (host, database, username, password)):
                raise ValueError("newlines are not permitted in libpq credentials")
            if not database:
                raise ValueError("database URL must specify a database")
            if password:
                pass_database = "*" if name in ("RESTORE_PRODUCT_DATABASE_URL", "RESTORE_AUTH_DATABASE_URL") else database
                pass_lines.append(":".join(escape_pgpass(field) for field in
                                             (host, str(port), pass_database, username, password)))
            query = []
            tls_options = {}
            for key, value in parse_qsl(parts.query, keep_blank_values=True):
                if key.lower().startswith("ssl"):
                    if key not in ("sslmode", "sslrootcert") or key in tls_options:
                        raise ValueError("unsupported or duplicate TLS URL option")
                    tls_options[key] = value
                elif key.lower() == 'password':
                    raise ValueError("query-string database passwords are unsupported")
                else:
                    query.append((key, value))
            mode = tls_options.get("sslmode", "").lower()
            if mode and mode not in ("require", "verify-ca", "verify-full", "prefer", "allow", "disable"):
                raise ValueError("unsupported TLS mode")
            if db_ssl in ("true", "1"):
                if mode == "disable":
                    raise ValueError("database URL disables required TLS")
                ca = extra_ca
                url_ca = tls_options.get("sslrootcert", "")
                if url_ca and url_ca != 'system':
                    ca += "\n" + Path(url_ca).read_text()
                rootcert = 'system'
                if ca.strip():
                    ca = ca.replace(r"\n", "\n")
                    blocks = re.findall(r"-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----", ca)
                    remainder = re.sub(r"-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----", "", ca)
                    if not blocks or remainder.strip():
                        raise ValueError("invalid CA certificate bundle")
                    context = ssl.create_default_context()
                    context.load_verify_locations(cadata=ca)
                    system_ca = "\n".join(ssl.DER_cert_to_PEM_cert(cert) for cert in context.get_ca_certs(binary_form=True))
                    rootcert = args.pgpass + f".{len(urls)}.ca.pem"
                    Path(rootcert).write_text(system_ca + "\n" + ca, encoding='utf-8')
                    os.chmod(rootcert, 0o600)
                query.extend((("sslmode", "verify-full"), ("sslrootcert", rootcert)))
            else:
                if tls_options.get('sslrootcert') or mode and mode != 'disable':
                    raise ValueError("TLS URL settings conflict with local plaintext mode")
                query.append(("sslmode", "disable"))
            # Do not put the password back into the libpq URI or process list.
            userinfo = quote(username, safe="") + "@" if username else ""
            netloc = userinfo + (f"[{host}]" if ":" in host else host) + (f":{port}" if parts.port else "")
            urls[name] = urlunsplit((parts.scheme, netloc, parts.path, urlencode(query), ""))

        pgpass = Path(args.pgpass)
        pgpass.write_text("\n".join(pass_lines) + ("\n" if pass_lines else ""), encoding="utf-8")
        os.chmod(pgpass, 0o600)
        with open(args.output, "w", encoding="utf-8") as output:
            json.dump(urls, output)
        os.chmod(args.output, 0o600)
        return 0
    except Exception as error:
        print(f"PostgreSQL backup connection setup failed: {type(error).__name__}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
