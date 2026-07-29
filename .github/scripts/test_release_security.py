from __future__ import annotations

import importlib.util
import os
import tempfile
import unittest
from pathlib import Path


SCRIPT_ROOT = Path(__file__).resolve().parent


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to load {path.name}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


extract_version = load_module("extract_version", SCRIPT_ROOT / "extract_version.py")
remove_beta = load_module("remove_beta", SCRIPT_ROOT / "remove_beta.py")


class ExtractVersionTests(unittest.TestCase):
    def test_parses_release_versions_without_unbounded_regexes(self):
        self.assertEqual(
            extract_version.find_first_valid("please /release v2.7.1-beta.3"),
            ("2.7.1-beta.3", True),
        )
        self.assertEqual(
            extract_version.find_first_valid("/release 2.7"),
            ("2.7", False),
        )
        self.assertEqual(
            extract_version.find_first_valid("Ship version 1.2.3."),
            ("1.2.3", False),
        )
        self.assertEqual(
            extract_version.find_first_valid("/release 01.2.3"),
            (None, False),
        )

    def test_bounds_attacker_controlled_comment_length(self):
        malicious = "1." + ("a." * 200_000)
        self.assertEqual(extract_version.find_first_valid(malicious), (None, False))

    def test_github_output_must_be_runner_managed(self):
        with tempfile.TemporaryDirectory() as runner_temp:
            trusted_output = Path(runner_temp) / "github-output"
            trusted_output.touch()
            previous_output = os.environ.get("GITHUB_OUTPUT")
            previous_temp = os.environ.get("RUNNER_TEMP")
            try:
                os.environ["GITHUB_OUTPUT"] = str(trusted_output)
                os.environ["RUNNER_TEMP"] = runner_temp
                extract_version.write_github_output("1.2.3", False)
                self.assertEqual(
                    trusted_output.read_text(encoding="utf-8"),
                    "version=1.2.3\nis_beta=false\n",
                )

                outside = Path(runner_temp).parent / "outside-output"
                outside.touch()
                self.addCleanup(outside.unlink, missing_ok=True)
                os.environ["GITHUB_OUTPUT"] = str(outside)
                with self.assertRaises(RuntimeError):
                    extract_version.write_github_output("1.2.3", False)
            finally:
                if previous_output is None:
                    os.environ.pop("GITHUB_OUTPUT", None)
                else:
                    os.environ["GITHUB_OUTPUT"] = previous_output
                if previous_temp is None:
                    os.environ.pop("RUNNER_TEMP", None)
                else:
                    os.environ["RUNNER_TEMP"] = previous_temp


class RemoveBetaTests(unittest.TestCase):
    def test_rejects_paths_outside_workspace(self):
        with tempfile.TemporaryDirectory() as workspace, tempfile.NamedTemporaryFile() as outside:
            self.assertEqual(
                remove_beta.remove_last_beta_item(outside.name, workspace),
                2,
            )

    def test_updates_only_a_workspace_appcast(self):
        with tempfile.TemporaryDirectory() as workspace:
            appcast = Path(workspace) / "appcast.xml"
            appcast.write_text(
                """<?xml version="1.0"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <item><enclosure sparkle:version="1.0.0" /></item>
    <item><enclosure sparkle:version="1.1.0-beta.1" /></item>
  </channel>
</rss>
""",
                encoding="utf-8",
            )
            self.assertEqual(
                remove_beta.remove_last_beta_item(appcast, workspace),
                0,
            )
            self.assertNotIn("beta", appcast.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
