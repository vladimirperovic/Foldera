"""Validate the portable harness/report, not Foldera's macOS implementation."""
import contextlib
import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent


def module(name):
    spec = importlib.util.spec_from_file_location(name, HERE / (name + ".py"))
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


builder = module("build_campaign")
reporter = module("report")


class HarnessTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="foldera-harness-validation-")
        self.root = Path(self.temp.name)
        with contextlib.redirect_stdout(io.StringIO()):
            builder.build(self.root)

    def tearDown(self):
        self.temp.cleanup()

    def report(self):
        with contextlib.redirect_stdout(io.StringIO()):
            return reporter.generate(self.root)

    def row(self, index, passed=True, attempt=1):
        spec = builder.matrix()[index]
        return {**spec, "status": "passed" if passed else "needs_reproduction",
                "attempt": attempt, "seconds": 0.01, "error": "" if passed else '<bad & "input">'}

    def write(self, rows):
        (self.root / "cases.jsonl").write_text("\n".join(json.dumps(row) for row in rows), encoding="utf-8")

    def test_exact_unique_matrix_and_generated_source(self):
        cases = builder.matrix()
        self.assertEqual(len(cases), 2000)
        self.assertEqual(len({(c["operation"], c["name"], c["fixture"]) for c in cases}), 2000)
        for op in builder.OPERATIONS:
            self.assertEqual(sum(c["operation"] == op for c in cases), 100)
        source = (self.root / "FolderaCampaignTests.swift").read_text(encoding="utf-8")
        self.assertNotIn("__CASES_BASE64__", source)
        self.assertIn("@testable import Foldera", source)

    def test_prepared_is_not_pass(self):
        status = self.report()
        self.assertEqual(status["status"], "prepared_not_run")
        self.assertEqual(status["cases_executed"], 0)
        self.assertEqual(status["untested"], 2000)

    def test_compile_failure_is_not_test_success(self):
        (self.root / "attempt-1.exit").write_text("1")
        self.assertEqual(self.report()["status"], "harness_or_build_failure")

    def test_all_completed(self):
        self.write([self.row(i) for i in range(2000)])
        (self.root / "attempt-1.exit").write_text("0")
        status = self.report()
        self.assertEqual(status["status"], "completed")
        self.assertEqual(status["initial_passes"], 2000)
        self.assertEqual(status["untested"], 0)

    def test_repeat_and_intermittent_stay_candidates(self):
        self.write([self.row(0, False), self.row(0, False, 2),
                    self.row(1, False), self.row(1, True, 2)])
        status = self.report()
        self.assertEqual(status["failed_again_on_fresh_fixture"], 1)
        self.assertEqual(status["passed_on_retry"], 1)
        self.assertEqual(status["confirmed_product_bugs"], 0)
        self.assertIn("&lt;bad &amp; &quot;input&quot;&gt;", (self.root / "report.html").read_text(encoding="utf-8"))

    def test_duplicate_record_blocks_completed(self):
        self.write([self.row(0), self.row(0)])
        status = self.report()
        self.assertEqual(status["duplicate_records"], 1)
        self.assertNotEqual(status["status"], "completed")

    def test_unknown_and_malformed_records_count_as_harness_errors(self):
        (self.root / "cases.jsonl").write_text('{"id":"not-a-case","attempt":1}\nnot json', encoding="utf-8")
        self.assertEqual(len(self.report()["malformed_records"]), 2)


if __name__ == "__main__":
    unittest.main()
