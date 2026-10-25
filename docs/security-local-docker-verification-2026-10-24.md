# Local Docker verification — 24–25 October 2026

Started 24 October; final local checks completed 25 October 2026 (IST). The owner requested local verification before deployment. These runs used sanitized source, synthetic accounts/databases and throwaway keys on this Mac. No hosted database, existing key, provider credential, live account or deployment was used. New recovery, retirement, maintenance and live device-storage encryption remain disabled.

[Machine-readable evidence](../artifacts/security-local-docker-verification-2026-10-24/batch-verification.json) records source hashes, environments, image identities and proof-log hashes. It supersedes the previous batch’s incomplete verification; previous evidence remains dated and unchanged.

## Results

| Check | Result |
| --- | --- |
| API in current Node 22 Docker image | 964 passed; two opt-in database cases skipped in the ordinary run |
| Supplemental fully migrated PostgreSQL API checks | Four passed, including both previously skipped database cases; two validation cases overlap the ordinary suite |
| Auth in current Node 22 Docker image | 300 passed |
| Database/tool and maintenance unit subset | 131 passed; some maintenance cases also appear in API/auth totals |
| Backup/setup | 45 passed |
| Deployment, including container default-port regression | 22 passed |
| Flutter app | 1,576 passed |
| Flutter console | 31 passed |
| Shared domain | 227 passed |
| Analysis and console CSP build | App: no errors/warnings, 72 existing infos. Console: no issues; release web build passed |
| PostgreSQL 18.4 | Complete 14-script/15-fresh-database fixture harness passed; includes one extra real encrypted journal scenario |
| Docker PostgreSQL 17.6 | OTP, lifecycle plus real age journal, permission repair and bounded maintenance passed |
| Paired encrypted v5 database recovery | Full migrations/repeats, encrypted export, independent-cluster restore, schema/ACL/grantor/key/UUID checks and verified-status publication passed with synthetic data |
| Current Docker images | API and auth built; all 88 API and 58 auth source files match and are readable by UID 1000 |
| Real local service startup | Both health/readiness endpoints returned 200 under separate non-superuser runtime logins; anonymous product access returned 401 |
| Dependency audits | Zero known vulnerabilities in the current locked API/auth production dependencies at run time |
| Existing notification work | All twelve file hashes unchanged |

Do not add these counts together: several unit subsets overlap. PostgreSQL fixture operators create/seed synthetic schema; restricted runtime identities are checked separately. The PostgreSQL 17 setup operator is NOSUPERUSER with CREATEDB/CREATEROLE/BYPASSRLS for fixture setup. Runtime login checks retain NOBYPASSRLS. The full harness ran on PostgreSQL 18; the four changed security areas were repeated in PostgreSQL 17 Docker. Real service smoke checks used development mode, real local PostgreSQL and synthetic keys; production TLS/proxy/provider acceptance remains separate.

## Fixes found during verification

1. The standalone auth image advertised/checked port 3210 while the Node entrypoint’s default was 3000. Set the image’s `PORT=3210`; Compose already explicitly sets 3210. A new deployment regression and real Docker startup check cover it. Direct non-container development behavior is preserved.
2. The macOS recovery harness required GNU `sha256sum` although the backup implementation already supports macOS `shasum`. Its preflight now accepts either.
3. The exact-grant repair fixture temporarily grants the new function owner schema CREATE while transferring ownership, then revokes it. This lets the fixture run with a non-superuser setup operator while keeping the final schema permissions narrow.
4. The opt-in SMS database test still tried to create profiles as `app_user`. It now seeds its synthetic profile as the fixture operator before switching roles and asserts that runtime profile insertion remains denied. Learning/RLS/worker separation/deletion tests pass without changing application grants.

Several early local attempts failed because of incomplete fixture mounts, missing synthetic settings or unit-test mode’s intentional DB-init suppression. The final passing runs and their exact scope are recorded in the evidence. No failed attempt is counted as a pass.

Temporary smoke-service containers and the memory-backed PostgreSQL fixture container are removed after verification. Current API/auth images remain available in Docker’s build cache. The existing local recovery backup schedule and its storage limits were not changed.

## Remaining acceptance

The release checker still reports `release_ready: false`. Local verification does not supply actual-data upgrade/cutover/failback, intended-provider/free-host resource measurements, browser cookie/CSP/operator acceptance, real OTP delivery, signed-device/process-death/key-loss recovery, complete native writer/orphan repair, independent off-host backup/journal custody or separate private-key custody. Remaining source work includes contact-replacement protocol transition, native key custody/resumable device-storage conversion and external operational notification delivery. New features must stay disabled until their applicable gates pass.
