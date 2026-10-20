import base64
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch, Mock

spec = importlib.util.spec_from_file_location("account_secrets", Path(__file__).parent / "auth/load-secrets.py")
secrets = importlib.util.module_from_spec(spec)
spec.loader.exec_module(secrets)


class AccountSecretsTest(unittest.TestCase):
    def test_disabled_mode_needs_no_aws_connection(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(secrets.subprocess, "run") as run:
            destination = Path(directory) / "app.env"
            destination.write_text("OTHER=preserved\n")
            secrets.load(destination, "/test", "us-east-1")
            run.assert_not_called()
            self.assertEqual(destination.read_text(), "OTHER=preserved\n")

    def test_atomic_replacement_preserves_other_settings_and_protects_file(self):
        response = {"Parameters": [
            {"Name": "/test/client-secret", "Value": "fixture-only"},
            {"Name": "/test/session-key", "Value": base64.b64encode(b"k" * 32).decode()},
        ]}
        with tempfile.TemporaryDirectory() as directory, patch.object(secrets.subprocess, "run") as run:
            run.return_value = Mock(stdout=json.dumps(response))
            destination = Path(directory) / "app.env"
            destination.write_text("OTHER=preserved\nMUNI_AUTH_MODE=pilot\nMUNI_COGNITO_CLIENT_SECRET=old\n")
            secrets.load(destination, "/test", "us-east-1")
            self.assertIn("OTHER=preserved\n", destination.read_text())
            self.assertNotIn("=old", destination.read_text())
            self.assertEqual(destination.stat().st_mode & 0o777, 0o600)
            command = run.call_args.args[0]
            self.assertNotIn("fixture-only", command)

    def test_missing_parameter_leaves_previous_configuration_intact(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(secrets.subprocess, "run") as run:
            run.return_value = Mock(stdout='{"Parameters":[],"InvalidParameters":["/test/session-key"]}')
            destination = Path(directory) / "app.env"
            original = "MUNI_AUTH_MODE=pilot\nOTHER=preserved\n"
            destination.write_text(original)
            with self.assertRaises(ValueError):
                secrets.load(destination, "/test", "us-east-1")
            self.assertEqual(destination.read_text(), original)


if __name__ == "__main__":
    unittest.main()
