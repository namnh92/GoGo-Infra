import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location("mobile_env", Path(__file__).with_name("mobile-env.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class MobileEnvTest(unittest.TestCase):
    def test_same_contract_all_environments_and_no_server_secrets(self):
        for environment, flavor in module.FLAVORS.items():
            values = module.mobile_values(environment, "00000000-0000-4000-8000-000000000001", "https://api.example.com", "https://go.example.com", "production")
            self.assertEqual(values["EXPO_PUBLIC_ENV"], flavor)
            self.assertEqual(values["ONESIGNAL_CONFIG_ENV"], environment)
            self.assertEqual(values["ONESIGNAL_APNS_MODE"], "production")
            self.assertFalse(any("KEY" in key or "SECRET" in key for key in values))

    def test_rejects_credentials_in_client_urls(self):
        for url in ("http://example.com", "https://user:secret@example.com", "https://example.com?token=secret"):
            with self.assertRaises(ValueError):
                module.https_url(url)

    def test_atomic_invalid_output_preserves_existing_config(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / ".env"
            path.write_text("previous\n")
            with self.assertRaises(ValueError):
                module.write_env(path, {"CONFIG": "$(bad)"})
            self.assertEqual(path.read_text(), "previous\n")
            module.write_env(path, {"CONFIG": "valid"})
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)


DSN = "https://0123456789abcdef0123456789abcdef@o0.ingest.us.sentry.io/1"


def ssm(values):
    """A stand-in for `aws ssm get-parameter`: `values` maps name -> value, or
    -> None for ParameterNotFound, or -> "DENIED" for any other failure."""
    def run(command, **_kwargs):
        name = command[command.index("--name") + 1]
        value = values.get(name)
        if value is None:
            return subprocess.CompletedProcess(command, 254, "", "An error occurred (ParameterNotFound)")
        if value == "DENIED":
            return subprocess.CompletedProcess(command, 254, "", "An error occurred (AccessDeniedException)")
        return subprocess.CompletedProcess(command, 0, json.dumps({"Parameter": {"Value": value}}), "")
    return run


class SentryDsnTest(unittest.TestCase):
    """GoGo-Infra#208, ADR-0011: EXPO_PUBLIC_SENTRY_DSN is a DSN or the literal off."""

    def test_accepts_a_dsn_or_the_literal_off(self):
        for environment in module.FLAVORS:
            self.assertEqual(module.sentry_dsn(environment, DSN), DSN)
            self.assertEqual(module.sentry_dsn(environment, "off"), "off")

    def test_rejects_every_other_spelling(self):
        for value in ("OFF", "Off", "false", "0", "", "http://k@o0.ingest.sentry.io/1", "https://o0.ingest.sentry.io/1", f"{DSN}?x=1", f"{DSN}/"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                module.sentry_dsn("dev", value)

    def test_missing_parameter_is_allowed_only_on_dev(self):
        self.assertEqual(module.sentry_dsn("dev", None), "")
        for environment in ("staging", "prod"):
            with self.subTest(environment=environment), self.assertRaises(ValueError):
                module.sentry_dsn(environment, None)

    def test_dsn_is_part_of_the_public_values(self):
        values = module.mobile_values("dev", "00000000-0000-4000-8000-000000000001", "https://api.example.com", "https://go.example.com", "development", DSN)
        self.assertEqual(values["EXPO_PUBLIC_SENTRY_DSN"], DSN)

    def test_only_parameter_not_found_counts_as_missing(self):
        args = mock.Mock(region="ap-southeast-1", profile=None)
        with mock.patch.object(module.subprocess, "run", ssm({"/a": None, "/b": "DENIED", "/c": "v"})):
            with self.assertRaises(module.ParameterMissing):
                module.read_parameter(args, "/a")
            with self.assertRaises(RuntimeError):
                module.read_parameter(args, "/b")
            self.assertEqual(module.read_parameter(args, "/c"), "v")


class MainTest(unittest.TestCase):
    APP_ID = "00000000-0000-4000-8000-000000000001"

    def run_main(self, environment, parameters):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory) / ".env"
            argv = ["mobile-env.py", environment, "--api-url", "https://api.example.com", "--web-url", "https://go.example.com", "--apns-mode", "development", "--out", str(out)]
            stdout, stderr = io.StringIO(), io.StringIO()
            code = 0
            with mock.patch.object(sys, "argv", argv), mock.patch.object(module.subprocess, "run", ssm(parameters)), \
                    contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                try:
                    module.main()
                except SystemExit as exit_:
                    code = exit_.code
            return code, out.read_text() if out.exists() else None, stderr.getvalue()

    def app_id(self, environment):
        return {f"/gogo/{environment}/backend/onesignal/app-id": self.APP_ID}

    def test_writes_the_dsn(self):
        code, text, _ = self.run_main("dev", {**self.app_id("dev"), "/gogo/dev/mobile/sentry/dsn": DSN})
        self.assertEqual(code, 0)
        self.assertIn(f"EXPO_PUBLIC_SENTRY_DSN={DSN}\n", text)

    def test_dev_without_a_dsn_builds_with_reporting_off_and_says_so(self):
        code, text, stderr = self.run_main("dev", self.app_id("dev"))
        self.assertEqual(code, 0)
        self.assertIn("EXPO_PUBLIC_SENTRY_DSN=\n", text)
        self.assertIn("crash reporting is off", stderr)

    def test_staging_and_prod_without_a_dsn_write_nothing(self):
        for environment in ("staging", "prod"):
            with self.subTest(environment=environment):
                code, text, _ = self.run_main(environment, self.app_id(environment))
                self.assertEqual(code, 1)
                self.assertIsNone(text)

    def test_a_denied_read_is_not_treated_as_missing(self):
        code, text, _ = self.run_main("dev", {**self.app_id("dev"), "/gogo/dev/mobile/sentry/dsn": "DENIED"})
        self.assertEqual(code, 1)
        self.assertIsNone(text)

    def test_a_malformed_value_writes_nothing(self):
        code, text, _ = self.run_main("dev", {**self.app_id("dev"), "/gogo/dev/mobile/sentry/dsn": "OFF"})
        self.assertEqual(code, 1)
        self.assertIsNone(text)


unittest.main()
