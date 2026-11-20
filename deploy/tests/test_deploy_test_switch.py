"""The production deploy can run with full tests, server tests only, or none (owner's request, 21 Nov 2026).

A prod deploy waited ~20 min for the 8 Flutter app-test shards, which test only the phone app, not the server it
deploys; every server check finishes in ~6 min. The switch:
  - a tag in the pushed tip commit's message: [deploy-tests:full] / [deploy-tests:server] / [deploy-tests:none]
  - otherwise the repository variable DEPLOY_TESTS (full|server|none), a standing "for now" setting
  - otherwise full, as before
A manual run can also skip the "this exact commit passed Build and test" check (require_tested_commit=false).
The branch allow-list and the tip check stay in every mode.
"""
import os
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PICK = ROOT / "deploy" / "pick_deploy_tests.sh"
DEPLOY = (ROOT / ".github/workflows/deploy-prod.yml").read_text()
BUILD = (ROOT / ".github/workflows/build-and-test.yml").read_text()


def pick(message="", default=None):
    env = {"PATH": os.environ["PATH"], "MESSAGE": message}
    if default is not None:
        env["DEFAULT_TESTS"] = default
    out = subprocess.run(["bash", str(PICK)], env=env, capture_output=True, text=True, check=True)
    return out.stdout.strip().splitlines()[-1]


def job(text, name):
    start = text.index(f"\n  {name}:\n")
    rest = text[start + 1:]
    nxt = rest.find("\n  ", 1)
    while nxt != -1 and (rest[nxt + 3] == " " or rest[nxt + 3] == "#"):
        nxt = rest.find("\n  ", nxt + 1)
    return rest if nxt == -1 else rest[:nxt]


class PickTests(unittest.TestCase):
    def test_default_is_full(self):
        self.assertEqual(pick("fix: something"), "full")
        self.assertEqual(pick("fix: something", ""), "full")

    def test_repository_default_applies_when_no_tag(self):
        self.assertEqual(pick("fix", "server"), "server")
        self.assertEqual(pick("fix", "none"), "none")
        self.assertEqual(pick("fix", "full"), "full")

    def test_unknown_repository_value_falls_back_to_full(self):
        self.assertEqual(pick("fix", "off"), "full")
        self.assertEqual(pick("fix", "NONE"), "full")

    def test_commit_tag_wins_over_repository_default(self):
        self.assertEqual(pick("deploy [deploy-tests:none]", "full"), "none")
        self.assertEqual(pick("deploy\n\nbody [deploy-tests:server]", "none"), "server")
        self.assertEqual(pick("release [deploy-tests:full]", "none"), "full")

    def test_only_exact_tags_count(self):
        self.assertEqual(pick("deploy [deploy-tests: none]"), "full")
        self.assertEqual(pick("deploy deploy-tests:none"), "full")


class WorkflowTests(unittest.TestCase):
    def test_build_and_test_can_skip_only_the_app_shards(self):
        call = BUILD.split("  workflow_call:", 1)[1].split("\nconcurrency:", 1)[0]
        self.assertIn("scope:", call)
        self.assertIn("default: full", call)
        self.assertIn("if: ${{ inputs.scope != 'server' }}", job(BUILD, "app-test"))
        for kept in ("security-recovery", "api", "postgres-suites", "flutter", "app-bundle", "smoke", "anonymization-audit"):
            self.assertNotIn("inputs.scope", job(BUILD, kept), kept)

    def test_deploy_picks_the_mode_from_the_tag_or_the_repository_variable(self):
        mode = job(DEPLOY, "mode")
        self.assertIn("bash deploy/pick_deploy_tests.sh", mode)
        self.assertIn("MESSAGE: ${{ github.event.head_commit.message }}", mode)
        self.assertIn("DEFAULT_TESTS: ${{ vars.DEPLOY_TESTS }}", mode)
        test = job(DEPLOY, "test")
        self.assertIn("needs.mode.outputs.tests != 'none'", test)
        self.assertIn("scope: ${{ needs.mode.outputs.tests }}", test)

    def test_deploy_runs_after_skipped_tests_only_in_none_mode(self):
        deploy = job(DEPLOY, "deploy")
        self.assertIn("needs: [mode, test]", deploy)
        self.assertIn("needs.test.result == 'success'", deploy)
        self.assertIn("needs.mode.outputs.tests == 'none' && needs.test.result == 'skipped'", deploy)

    def test_manual_run_can_skip_the_tested_commit_check(self):
        dispatch = DEPLOY.split("  workflow_dispatch:", 1)[1].split("\nconcurrency:", 1)[0]
        self.assertIn("require_tested_commit:", dispatch)
        self.assertIn("default: true", dispatch)
        verify = DEPLOY.split("- name: Verify exact commit passed Build and test", 1)[1].split("- name:", 1)[0]
        self.assertIn("REQUIRE_TESTED_COMMIT", verify)

    def test_branch_allow_list_and_tip_check_stay(self):
        self.assertIn("prod) ;;", DEPLOY)
        self.assertIn("Confirm the tested target is still the current branch tip", DEPLOY)


if __name__ == "__main__":
    unittest.main()
