import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("cli", Path(__file__).with_name("funcdictionary.py"))
cli = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(cli)
FIXTURES = Path(__file__).resolve().parent.parent / "SupportingFiles/fixtures"


class CLITests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.exchange = self.root / ".funcdictionary"
        self.exchange.mkdir()
        self.snapshot = cli.read_json(FIXTURES / "00-empty-project.json")
        self.write(self.exchange / "project.json", self.snapshot["project"])
        self.write(self.exchange / "dictionary.json", self.snapshot)
        self.delta = {"schema_version": "1.0", "delta_id": "delta_cli_test",
                      "project_id": self.snapshot["project"]["id"],
                      "base_revision": self.snapshot["revision"], "target_revision": self.snapshot["revision"] + 1,
                      "created_at": "2026-09-24T00:00:00Z"}
        for key in ("changed_fields", "definitions_created", "definitions_evolved", "fuzzy_terms_added",
                    "relations_changed", "references_changed", "snapshots_changed", "proposals", "change_requests", "conflict_records"):
            self.delta[key] = []
        definition = copy.deepcopy(cli.read_json(FIXTURES / "01-complete-definition.json")["definitions"][0])
        definition["project_id"] = self.delta["project_id"]
        definition["snapshots"] = []
        definition["code_locator"]["func_comment"] = "上传本地词典"
        self.delta["definitions_created"] = [definition]
        self.source = self.root / "draft.json"

    @staticmethod
    def write(path, data):
        path.write_text(json.dumps(data), encoding="utf-8")

    def submit(self):
        self.write(self.source, self.delta)
        return cli.submit(self.root, self.source, 0)

    def test_publish_pending_then_acknowledge_applied(self):
        self.assertEqual(self.submit()["state"], "pending")
        pending = self.exchange / "deltas/delta_cli_test.json"
        self.assertEqual(cli.read_json(pending), self.delta)
        archive = self.exchange / "deltas/applied"
        archive.mkdir()
        pending.rename(archive / pending.name)
        self.assertEqual(self.submit()["state"], "pending")
        self.snapshot["revision"] = self.delta["target_revision"]
        self.write(self.exchange / "dictionary.json", self.snapshot)
        self.assertEqual(self.submit()["state"], "applied")
        self.delta["definitions_created"][0]["function"]["purpose"] = "changed"
        with self.assertRaisesRegex(ValueError, "reused"):
            self.submit()

    def test_reject_foreign_project_stale_revision_and_approval(self):
        original = copy.deepcopy(self.delta)
        self.delta["project_id"] = "project_foreign"
        with self.assertRaises(ValueError): self.submit()
        self.delta = copy.deepcopy(original)
        self.delta["base_revision"] += 2
        self.delta["target_revision"] += 2
        with self.assertRaisesRegex(ValueError, "Stale"): self.submit()
        self.delta = copy.deepcopy(original)
        self.delta["definitions_created"][0]["review_status"] = "approved"
        with self.assertRaisesRegex(ValueError, "unreviewed"): self.submit()

    def test_search_in_both_directions_and_comment(self):
        self.snapshot["definitions"] = self.delta["definitions_created"]
        for query, direction in [("startSync", "code"), ("执行当前项目", "purpose"), ("上传本地词典", "purpose")]:
            self.assertEqual(len(cli.search(self.snapshot, query, direction)), 1)
        self.assertEqual(cli.search(self.snapshot, "startSync", "purpose"), [])

    def test_reject_existing_identity_recreation(self):
        self.snapshot["definitions"] = self.delta["definitions_created"]
        self.write(self.exchange / "dictionary.json", self.snapshot)
        with self.assertRaisesRegex(ValueError, "evolve"):
            self.submit()

    def test_reject_escape_and_inbox_symlink(self):
        self.delta["definitions_created"][0]["code_locator"]["file"] = "../outside.swift"
        with self.assertRaisesRegex(ValueError, "inside the project"): self.submit()
        self.delta["definitions_created"][0]["code_locator"]["file"] = "source.swift"
        (self.exchange / "deltas").symlink_to(self.root, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symlinks"): self.submit()

    def test_pending_id_cannot_be_overwritten(self):
        self.submit()
        self.delta["definitions_created"][0]["function"]["purpose"] = "different"
        with self.assertRaisesRegex(ValueError, "different content"): self.submit()


if __name__ == "__main__":
    unittest.main()
