"""Signing-team fixture tests never access certificates or private keys."""

import contextlib
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).parents[2] / "Scripts" / "read_development_team.py"
SPEC = importlib.util.spec_from_file_location("read_development_team", SCRIPT)
helper = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = helper
SPEC.loader.exec_module(helper)
PEM = "-----BEGIN CERTIFICATE-----\nfixture\n-----END CERTIFICATE-----"


def output(text="", status=0):
    return subprocess.CompletedProcess([], status, stdout=text, stderr="")


class DevelopmentTeamTests(unittest.TestCase):
    def test_override_prevents_certificate_discovery(self):
        with patch.object(helper.subprocess, "run") as run:
            self.assertEqual(helper.resolve_team(" ABCDE12345 "), "ABCDE12345")
        run.assert_not_called()

    def test_malformed_override_fails_without_discovery(self):
        for value in ["too-short", "abcde12345", "ABCDE12345;echo secret"]:
            with self.subTest(value=value), patch.object(helper.subprocess, "run") as run:
                with self.assertRaises(helper.DevelopmentTeamError):
                    helper.resolve_team(value)
                run.assert_not_called()

    def test_unique_team_is_inferred_and_duplicate_certificates_are_unambiguous(self):
        responses = [output(PEM + PEM),
                     output("subject=CN=Fixture,OU=ABCDE12345,O=Fixture,C=US\n"),
                     output("subject=CN=Renewed,OU=ABCDE12345,O=Fixture,C=US\n")]
        with patch.object(helper.subprocess, "run", side_effect=responses) as run:
            self.assertEqual(helper.resolve_team(), "ABCDE12345")
        self.assertEqual(run.call_args_list[0].args[0],
                         ["security", "find-certificate", "-a", "-c", "Apple Development", "-p"])
        for call in run.call_args_list[1:]:
            self.assertEqual(call.args[0], ["openssl", "x509", "-noout", "-subject", "-nameopt", "RFC2253"])
            self.assertIn("BEGIN CERTIFICATE", call.kwargs["input"])

    def test_ambiguous_teams_require_an_explicit_choice(self):
        responses = [output(PEM + PEM), output("subject=CN=One,OU=ABCDE12345"),
                     output("subject=CN=Two,OU=FGHIJ67890")]
        with patch.object(helper.subprocess, "run", side_effect=responses), \
                self.assertRaisesRegex(helper.DevelopmentTeamError, "Multiple"):
            helper.resolve_team()

    def test_missing_failed_or_malformed_certificate_metadata_is_actionable(self):
        fixtures = [[output("")], [output("", status=1)],
                    [output(PEM), output("not a certificate subject", status=1)],
                    [output(PEM), output("subject=CN=OU=ABCDE12345,O=Fixture")]]
        for responses in fixtures:
            with self.subTest(responses=responses), \
                    patch.object(helper.subprocess, "run", side_effect=responses), \
                    self.assertRaises(helper.DevelopmentTeamError):
                helper.resolve_team()

    def test_metadata_timeout_is_bounded_and_has_no_raw_details(self):
        with patch.object(helper.subprocess, "run", side_effect=subprocess.TimeoutExpired([], 30)), \
                self.assertRaisesRegex(helper.DevelopmentTeamError, "certificate metadata"):
            helper.resolve_team()

    def test_cli_outputs_only_override_and_no_certificate_metadata(self):
        stdout = io.StringIO()
        with patch.dict(os.environ, {"OESAP_DEVELOPMENT_TEAM": "ABCDE12345"}), \
                patch.object(helper.subprocess, "run") as run, contextlib.redirect_stdout(stdout):
            helper.main()
        self.assertEqual(stdout.getvalue(), "ABCDE12345\n")
        run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
