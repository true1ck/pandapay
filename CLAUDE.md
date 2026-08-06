# PandaPay — Skill Usage Guide

This project has a curated set of Claude Code skills installed globally (`~/.claude/skills/`). This file tells Claude which ones apply here and when, so they're invoked automatically instead of needing to be asked for by name.

Stack: Flutter app in `app/` on **Riverpod 2.6.1** (codegen) + **go_router 14.x**. Backend auth service in `auth/`.

## Building features (default path)

| Skill | Use whenever the request is... |
|---|---|
| `flutter-riverpod-gorouter` | Any Riverpod provider, go_router route, or general Flutter/Dart widget work. **This is the default state-management/navigation skill for this project** — it matches the actual pubspec versions. |
| `dagovalsusa-flutter-dev` | Same domain as above (Riverpod+Freezed+go_router); use as a secondary reference. Note: its examples assume **Riverpod 3.0** — if a generated pattern doesn't compile against 2.6.1, that's why; adapt rather than upgrading the package on its say-so. |
| `dagovalsusa-flutter-feature` / `-provider` / `-model` / `-screen` | Scaffolding a new feature end-to-end, or generating a single provider/model/screen from scratch. |
| `flutter-development` | Fallback for general Flutter/Dart questions outside Riverpod/go_router scope. |
| `flutter-arcturus` | **Only** if the request specifically involves BLoC/Cubit, Firebase Auth/FCM push, `flow_builder`, `formz`, or `flutter_map` — this skill's default patterns (BLoC, flow_builder) don't match this project's Riverpod/go_router architecture, so don't let it steer state-management or navigation choices by default. |
| `dagovalsusa-flutter-game` | Only if building a game or gamified feature (Flame engine, Rive). Not expected to come up in a payments app. |

## Seeing / verifying work visually

| Skill | Use whenever the request is... |
|---|---|
| `preview-widget` | "Show me this widget", isolated component iteration, dark mode / tablet-width checks on one widget. |
| `android-emulator` | "Run the app", "try this on Android", reproducing a bug, checking a layout live. |
| `design-polish` | "Make this look better", "polish this screen", visual hierarchy/spacing/typography passes. |

## Testing

| Skill | Use whenever the request is... |
|---|---|
| `flutter-tester` | Writing/fixing unit, widget, or integration tests; Riverpod provider testing; Mockito mocking. |
| `dagovalsusa-flutter-test` | Generating comprehensive tests for providers/repositories/widgets with Riverpod overrides — pairs with `flutter-tester`. |
| `alchemist-golden-testing` | Visual regression / golden tests (`goldenTest`, `GoldenTestGroup`). This project uses **Alchemist**, not `golden_toolkit` (removed). |
| `maestro-mobile-testing` | Full E2E flows on a simulator/emulator/real device — login, checkout, multi-screen journeys. |

## Security (payments app — check proactively, not just on request)

| Skill | Use whenever the request is... |
|---|---|
| `owasp-mobile-security-checker` | Security audits, before releases, when touching auth/storage/networking code, or reviewing anything that handles cards/PII/tokens. Covers OWASP Mobile Top 10 — hardcoded secrets, insecure storage, weak crypto, network issues. **Since this is a payments app, lean toward running this proactively on security-sensitive changes (auth, card storage, token handling) even without an explicit ask.** |

## CI/CD & release

| Skill | Use whenever the request is... |
|---|---|
| `codemagic-ci-cd-onboarding` | First-time CI setup, "how do I get this building". |
| `codemagic-yaml-quickstart` | Generating/editing `codemagic.yaml`. |
| `codemagic-testing` | Tests failing or misconfigured in CI. |
| `codemagic-ios-signing` | iOS build fails on certificates/provisioning profiles/TestFlight. |
| `codemagic-android-signing` | Android build fails on keystore/Gradle signing. |
| `symbolize-android-stacktrace` | Debugging a crash/ANR from the Play Console on a Codemagic-built release. |

## Workflow discipline (apply throughout, not tied to a specific ask)

| Skill | Use whenever... |
|---|---|
| `brainstorming` | The request is ambiguous or a new feature/design needs exploring before code. |
| `writing-plans` → `executing-plans` / `subagent-driven-development` | The task is multi-step and non-trivial. |
| `test-driven-development` | User wants tests-first discipline on a new feature/bugfix. |
| `systematic-debugging` | Something's broken and the cause isn't obvious — before proposing a fix. |
| `requesting-code-review` / `receiving-code-review` | Before merging, or when acting on review feedback. |
| `verification-before-completion` | Before claiming anything is done, fixed, or passing. |

## Explicitly not for this project

- `dagovalsusa-flutter-game` — no game features planned; ignore unless the user explicitly asks for one.
- `flutter-arcturus`'s BLoC/flow_builder patterns — reference only, don't default to them over Riverpod/go_router.
