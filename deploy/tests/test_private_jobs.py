"""The SMS v2 rule job and AI worker run only on the private admin host."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
PRIVATE = (ROOT / 'deploy/admin/compose.private.yml').read_text()
PUBLIC = (ROOT / 'docker-compose.prod.yml').read_text()


def service(source, name):
    match = re.search(
        rf'(?ms)^  {re.escape(name)}:\n(.*?)(?=^  [a-z0-9_-]+:\n|^[a-z]|\Z)', source)
    return match.group(1) if match else None


class PrivateJobsTest(unittest.TestCase):
    def test_rule_jobs_run_hourly_on_the_private_host(self):
        body = service(PRIVATE, 'sms-v2-rule-jobs')
        self.assertIsNotNone(body)
        self.assertIn('src/sms_v2/jobs/rule_jobs_main.js', body)
        self.assertIn('--loop', body)
        self.assertIn('restart: unless-stopped', body)
        self.assertIn('profiles: [admin]', body)
        self.assertIn('networks: [admin_private]', body)
        for key in ('SMS_RULES_SIGNING_KEY', 'SMS_RULES_KEY_ID', 'SMS_V2_JOB_ADMIN_ID'):
            self.assertIn(key, body)
        # The rule job never needs the AI key.
        self.assertNotIn('GEMINI_', body)

    def test_template_worker_runs_on_the_private_host(self):
        body = service(PRIVATE, 'sms-v2-template-worker')
        self.assertIsNotNone(body)
        self.assertIn('src/sms_v2/jobs/template_worker_main.js', body)
        self.assertIn('restart: unless-stopped', body)
        self.assertIn('profiles: [admin]', body)
        self.assertIn('networks: [admin_private]', body)
        for key in ('GEMINI_API_KEY', 'SMS_V2_AI_MODEL', 'SMS_V2_AI_TPM', 'SMS_V2_JOB_ADMIN_ID',
                    'SMS_V2_AI_INPUT_USD_PER_MILLION', 'SMS_V2_AI_OUTPUT_USD_PER_MILLION'):
            self.assertIn(key, body)
        # The AI worker never signs rule sets.
        self.assertNotIn('SMS_RULES_SIGNING_KEY', body)

    def test_jobs_are_hardened_like_admin_api(self):
        for name in ('sms-v2-rule-jobs', 'sms-v2-template-worker'):
            body = service(PRIVATE, name)
            for line in ('read_only: true', 'cap_drop: [ALL]', 'security_opt: [no-new-privileges:true]',
                         'NODE_ENV: production', "DB_SSL: 'true'"):
                self.assertIn(line, body, name)
            self.assertNotIn('ports:', body, name)

    def test_admin_api_can_sign_published_rules(self):
        body = service(PRIVATE, 'admin-api')
        self.assertIn('SMS_RULES_SIGNING_KEY', body)
        self.assertIn('SMS_RULES_KEY_ID', body)
        self.assertNotIn('GEMINI_', body)

    def test_public_compose_never_holds_the_signing_key(self):
        self.assertNotIn('SMS_RULES_SIGNING_KEY', PUBLIC)

    def test_public_compose_gives_the_ai_key_to_the_opt_in_drafts_worker_only(self):
        worker = service(PUBLIC, 'sms-v2-template-worker')
        self.assertIsNotNone(worker)
        self.assertIn('GEMINI_API_KEY', worker)
        self.assertIn('SMS_AI_WORKER_DATABASE_URL', worker)
        self.assertIn('profiles: [sms-ai]', worker)
        self.assertNotIn('SMS_RULES_SIGNING_KEY', worker)
        rest = PUBLIC.replace(worker, '')
        for key in ('GEMINI_', 'SMS_AI_WORKER_DATABASE_URL'):
            self.assertNotIn(key, rest)


if __name__ == '__main__':
    unittest.main()
