"""Exercise mirror updates and refusal paths without network or Git mutations."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "ci" / "sync-upstream-mirror.sh"
OLD = "1" * 40
NEW = "2" * 40
OTHER = "3" * 40
TARGET = "repos/austery/legado/git/ref/heads/master"
UPSTREAM = "repos/huajideshutiao/legado/git/ref/heads/master"
METADATA = ["api", "repos/austery/legado", "--jq", "[.default_branch, .parent.full_name] | @tsv"]
READ_TARGET = ["api", TARGET, "--jq", ".object.sha"]
READ_UPSTREAM = ["api", UPSTREAM, "--jq", ".object.sha"]
COMPARE = ["api", f"repos/huajideshutiao/legado/compare/{OLD}...{NEW}",
           "--jq", "[.status, .ahead_by, .behind_by] | @tsv"]
UPDATE = ["api", "--method", "PATCH", "repos/austery/legado/git/refs/heads/master",
          "-f", f"sha={NEW}", "-F", "force=false", "--silent"]

# Each fake request must exactly match the expected endpoint, method and options.
FAKE_GH = '''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys
root = Path(os.environ["MIRROR_TEST_ROOT"])
log = root / "requests.jsonl"
previous = log.read_text().splitlines() if log.exists() else []
with log.open("a") as output:
    output.write(json.dumps(sys.argv[1:]) + "\\n")
responses = json.loads((root / "responses.json").read_text())
index = len(previous)
if index >= len(responses) or sys.argv[1:] != responses[index][0]:
    print("Unexpected API request: " + repr(sys.argv[1:]), file=sys.stderr)
    sys.exit(90)
print(responses[index][1])
sys.exit(responses[index][2])
'''


class UpstreamMirrorTests(unittest.TestCase):
    def run_script(self, responses: list[tuple[list[str], str, int]],
                   args: tuple[str, ...] = ()) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            fake = root / "gh"
            fake.write_text(FAKE_GH)
            fake.chmod(0o700)
            (root / "responses.json").write_text(json.dumps(responses))
            summary = root / "summary.md"
            result = subprocess.run(["bash", str(SCRIPT), *args], text=True, capture_output=True,
                                    env={**os.environ, "PATH": f"{root}:{os.environ['PATH']}",
                                         "MIRROR_TEST_ROOT": folder, "GITHUB_STEP_SUMMARY": str(summary)})
            self.assertNotEqual(result.returncode, 90, result.stderr)
            log = root / "requests.jsonl"
            self.assertEqual(len(log.read_text().splitlines()) if log.exists() else 0,
                             len(responses), result.stderr)
            if result.returncode != 0:
                self.assertFalse(summary.exists())
            if result.returncode == 0 and args == ("--apply",) and responses[-1][0] == READ_TARGET:
                self.assertIn(f"{OLD} -> {NEW}", summary.read_text())
            return result

    def prefix(self) -> list[tuple[list[str], str, int]]:
        return [(METADATA, "native-reader\thuajideshutiao/legado", 0),
                (READ_TARGET, OLD, 0), (READ_UPSTREAM, NEW, 0)]

    def test_default_is_dry_run_and_never_writes(self) -> None:
        result = self.run_script(self.prefix() + [(COMPARE, "ahead\t43\t0", 0)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Dry run: master can advance by 43", result.stdout)

    def test_apply_updates_only_master_without_force_and_verifies_readback(self) -> None:
        result = self.run_script(self.prefix() + [(COMPARE, "ahead\t43\t0", 0),
                                                (UPDATE, "", 0), (READ_TARGET, NEW, 0)], ("--apply",))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_equal_refs_do_not_compare_or_write(self) -> None:
        result = self.run_script([(METADATA, "native-reader\thuajideshutiao/legado", 0),
                                  (READ_TARGET, NEW, 0), (READ_UPSTREAM, NEW, 0)], ("--dry-run",))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("already matches", result.stdout)

    def test_wrong_default_or_parent_stops_before_reading_refs(self) -> None:
        for metadata in ("master\thuajideshutiao/legado", "native-reader\tgedoor/legado"):
            with self.subTest(metadata=metadata):
                result = self.run_script([(METADATA, metadata, 0)], ("--apply",))
                self.assertEqual(result.returncode, 1)

    def test_divergence_rewind_and_inconsistent_comparisons_never_write(self) -> None:
        for comparison in ("diverged\t43\t1", "behind\t0\t2", "identical\t0\t0",
                           "ahead\t43\t1", "ahead\t0\t0", "ahead\tunknown\t0", ""):
            with self.subTest(comparison=comparison):
                result = self.run_script(self.prefix() + [(COMPARE, comparison, 0)], ("--apply",))
                self.assertNotEqual(result.returncode, 0)

    def test_invalid_sha_never_compares_or_writes(self) -> None:
        result = self.run_script(self.prefix()[:2] + [(READ_UPSTREAM, "not-a-sha", 0)], ("--apply",))
        self.assertEqual(result.returncode, 1)

    def test_api_failure_stops_without_retry_or_write(self) -> None:
        for index in range(4):
            with self.subTest(index=index):
                replies = self.prefix() + [(COMPARE, "ahead\t43\t0", 0)]
                request, _, _ = replies[index]
                result = self.run_script(replies[:index] + [(request, "API unavailable", 1)], ("--apply",))
                self.assertNotEqual(result.returncode, 0)

    def test_update_rejection_is_not_retried_or_forced(self) -> None:
        result = self.run_script(self.prefix() + [(COMPARE, "ahead\t43\t0", 0),
                                                (UPDATE, "Update rejected", 1)], ("--apply",))
        self.assertNotEqual(result.returncode, 0)

    def test_readback_mismatch_or_failure_is_reported(self) -> None:
        for readback, code in ((OTHER, 0), ("API unavailable", 1)):
            with self.subTest(readback=readback):
                result = self.run_script(self.prefix() + [(COMPARE, "ahead\t43\t0", 0),
                                                        (UPDATE, "", 0), (READ_TARGET, readback, code)], ("--apply",))
                self.assertNotEqual(result.returncode, 0)

    def test_unknown_or_extra_arguments_never_access_api(self) -> None:
        for args in (("--force",), ("--apply", "native-reader")):
            with self.subTest(args=args):
                self.assertEqual(self.run_script([], args).returncode, 2)


if __name__ == "__main__":
    unittest.main()
