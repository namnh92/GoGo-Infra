import importlib.util
from pathlib import Path
import tempfile
import unittest

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


unittest.main()
