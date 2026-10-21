#!/usr/bin/env python3

import argparse
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import sorty_helper
import sorty_profile
import sorty_watch


class SortyWatchTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.base = Path(self.temporary.name)
        self.root = self.base / "Inbox"
        self.state = self.base / "state"
        self.root.mkdir()
        for target, value in (
            ("sorty_profile.PROFILE_PATH", self.state / "profile.json"),
            ("sorty_watch.STATE_DIR", self.state),
            ("sorty_watch.notify", lambda title, message: True),
        ):
            patcher = patch(target, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def tearDown(self):
        self.temporary.cleanup()

    def add(self, **overrides):
        values = dict(
            path=str(self.root), id="inbox", name=None, replace=False, rule=[], apply=False, exclude=[],
            prompt=None, settle=0, interval=1800, no_notify=True, include_existing=False, script=None,
        )
        values.update(overrides)
        return sorty_watch.add_watcher(argparse.Namespace(**values))

    def test_applies_approved_rules_queues_the_rest_and_reports_each_item_once(self):
        (self.root / "old.pdf").write_text("baseline", encoding="utf-8")
        self.add(rule=["*.PDF=Documents/PDFs"], apply=True)
        (self.root / "new.pdf").write_text("new", encoding="utf-8")
        (self.root / "notes.txt").write_text("notes", encoding="utf-8")
        (self.root / "Project").mkdir()

        result = sorty_watch.run_watcher("inbox")

        self.assertEqual(result["moved"], [{"source": "new.pdf", "destination": "Documents/PDFs/new.pdf"}])
        self.assertTrue((self.root / "Documents/PDFs/new.pdf").exists())
        self.assertTrue((self.root / "old.pdf").exists(), "baselined items stay put")
        self.assertEqual({entry["path"] for entry in result["queued"]}, {"notes.txt", "Project"})
        again = sorty_watch.run_watcher("inbox")
        self.assertEqual((again["moved"], again["queued"]), ([], []))
        rollback = sorty_helper.rollback(Path(result["journals"][0]))
        self.assertEqual(rollback["restored"], 1)
        self.assertTrue((self.root / "new.pdf").exists())

    def test_queue_only_watchers_never_move_and_collisions_are_queued(self):
        self.add(rule=["*.pdf=PDFs"])
        (self.root / "a.pdf").write_text("a", encoding="utf-8")
        result = sorty_watch.run_watcher("inbox")
        self.assertEqual(result["moved"], [])
        self.assertIn("queue-only", result["queued"][0]["reason"])

        self.add(rule=["*.pdf=PDFs"], apply=True, replace=True, id="second")
        (self.root / "PDFs").mkdir()
        (self.root / "PDFs/b.pdf").write_text("existing", encoding="utf-8")
        (self.root / "b.pdf").write_text("incoming", encoding="utf-8")
        result = sorty_watch.run_watcher("second")
        self.assertEqual(result["moved"], [])
        self.assertIn("destination already exists", result["queued"][0]["reason"])
        self.assertEqual((self.root / "PDFs/b.pdf").read_text(encoding="utf-8"), "existing")

    def test_unsettled_and_partial_downloads_wait(self):
        self.add(rule=["*=Sorted"], apply=True, settle=3600)
        (self.root / "fresh.pdf").write_text("fresh", encoding="utf-8")
        (self.root / "movie.mp4.crdownload").write_text("partial", encoding="utf-8")
        result = sorty_watch.run_watcher("inbox")
        self.assertEqual(sorted(result["waiting"]), ["fresh.pdf", "movie.mp4.crdownload"])
        self.assertEqual(result["moved"], [])

    def test_routing_script_output_is_validated_and_journaled(self):
        script = self.base / "route.py"
        script.write_text("\n".join([
            f"#!{sys.executable}",
            "import json, sys",
            "items = json.load(sys.stdin)['items']",
            "ops = [{'source': i['path'], 'destination': 'Invoices/' + i['path'].lower()} for i in items if 'Invoice' in i['path']]",
            "ops += [{'source': i['path'], 'destination': 'x.zip'} for i in items if i['path'].endswith('.txt')]",
            "print(json.dumps({'operations': ops}))",
        ]), encoding="utf-8")
        script.chmod(0o755)
        self.add(script=str(script), apply=True)
        (self.root / "Invoice A.pdf").write_text("invoice", encoding="utf-8")
        result = sorty_watch.run_watcher("inbox")
        self.assertEqual(result["moved"], [{"source": "Invoice A.pdf", "destination": "Invoices/invoice a.pdf"}])
        self.assertEqual(sorty_watch.run_watcher("inbox")["queued"], [], "script output folders are not re-queued")

        (self.root / "notes.txt").write_text("notes", encoding="utf-8")
        result = sorty_watch.run_watcher("inbox")
        self.assertEqual(result["status"], "error", "extension changes still need explicit approval")
        self.assertTrue((self.root / "notes.txt").exists())

    def test_agent_exclusions_and_learnings_work_without_an_import(self):
        sorty_profile.update_exclusion("*.key")
        sorty_profile.update_learning(text="Invoices go under Finance by year")
        profile = sorty_profile.load_profile()
        self.assertEqual(profile["agentExclusions"], ["*.key"])
        self.assertEqual(profile["agentLearnings"][0]["text"], "Invoices go under Finance by year")
        (self.root / "secret.key").write_text("key", encoding="utf-8")
        (self.root / "plain.txt").write_text("plain", encoding="utf-8")
        scanned = sorty_helper.scan(self.root, [], include_hidden=False, expand_packages=False)
        self.assertEqual([item["path"] for item in scanned["items"]], ["plain.txt"])
        sorty_profile.update_learning(remove_id=profile["agentLearnings"][0]["id"])
        self.assertEqual(sorty_profile.load_profile()["agentLearnings"], [])

    @unittest.skipUnless(sys.platform == "darwin", "Finder tags need macOS")
    def test_tags_change_and_restore(self):
        import sorty_tags
        target = self.root / "report.pdf"
        target.write_text("report", encoding="utf-8")
        changed = sorty_tags.change([str(target)], ["Red", "Client:blue"], [], self.state)
        self.assertEqual(sorty_tags.read_tags(target), ["Red\n6", "Client\n4"])
        restored = sorty_tags.restore(Path(changed["journal"]))
        self.assertEqual((restored["restored"], sorty_tags.read_tags(target)), (1, []))


if __name__ == "__main__":
    unittest.main()
