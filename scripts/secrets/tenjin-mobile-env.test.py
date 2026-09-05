import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("tenjin_env", Path(__file__).with_name("tenjin-mobile-env.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class TenjinEnvTest(unittest.TestCase):
    def test_never_reuses_bare_dev_keys_in_other_environments(self):
        values = {"UNSUFFIXED_VALUES_BELONG_TO": "dev", "TENJIN_IOS_SDK_KEY": "ios-dev", "TENJIN_ANDROID_SDK_KEY": "android-dev"}
        self.assertEqual(module.scoped_values(values, "dev")["TENJIN_CONFIG_ENV"], "dev")
        for environment in ("staging", "prod"):
            with self.assertRaises(ValueError):
                module.scoped_values(values, environment)

    def test_same_keys_and_resolution_for_each_environment(self):
        for environment in ("dev", "staging", "prod"):
            values = {f"{key}_{environment.upper()}": "platform-key" for key in module.KEYS}
            resolved = module.scoped_values(values, environment)
            self.assertEqual(set(resolved), {*module.KEYS, "TENJIN_CONFIG_ENV"})

    def test_explicit_blank_does_not_fall_back(self):
        with self.assertRaises(ValueError):
            module.scoped_values({"UNSUFFIXED_VALUES_BELONG_TO": "dev", "TENJIN_IOS_SDK_KEY": "other-key", "TENJIN_IOS_SDK_KEY_DEV": ""}, "dev")


unittest.main()
