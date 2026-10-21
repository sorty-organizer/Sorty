#!/usr/bin/env python3

import argparse
import json
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
            path=str(self.root), id="inbox", name=None, replace=False, handler=None, handler_timeout=60, apply=False,
            exclude=[], prompt=None, settle=0, interval=1800, no_notify=True, include_existing=False,
        )
        values.update(overrides)
        return sorty_watch.add_watcher(argparse.Namespace(**values))

    def handler(self, body):
        """A stand-in AI handler: reads the request, records it, and prints prose-wrapped JSON."""
        script = self.base / "handler.py"
        script.write_text("\n".join([
            f"#!{sys.executable}",
            "import json, sys",
            "request = json.load(sys.stdin)",
            f"open({str(self.base / 'request.json')!r}, 'w').write(json.dumps(request))",
            "items = [item['path'] for item in request['items']]",
            body,
            "print('Here is the plan:\\n```json\\n' + json.dumps(reply) + '\\n```')",
        ]), encoding="utf-8")
        script.chmod(0o755)
        return str(script)

    def test_without_a_handler_new_items_wait_for_the_agent_once(self):
        (self.root / "old.pdf").write_text("baseline", encoding="utf-8")
        self.add()
        (self.root / "new.pdf").write_text("new", encoding="utf-8")
        result = sorty_watch.run_watcher("inbox")
        self.assertEqual(result["moved"], [])
        self.assertEqual([entry["path"] for entry in result["queued"]], ["new.pdf"])
        self.assertEqual(sorty_watch.run_watcher("inbox")["queued"], [], "items are reported once")
        self.assertEqual([entry["path"] for entry in sorty_watch.update_queue("inbox", [], False)["queue"]], ["new.pdf"])

    def test_handler_sees_existing_style_and_its_placements_are_journaled(self):
        (self.root / "Finance").mkdir()
        (self.root / "Finance/2025 invoice acme.pdf").write_text("old", encoding="utf-8")
        handler = self.handler("reply = {'operations': [{'source': p, 'destination': 'Finance/2026 ' + p.lower()} for p in items if 'Invoice' in p]}")
        self.add(handler=handler, apply=True, prompt="Keep finance tidy")
        (self.root / "Invoice Acme.pdf").write_text("invoice", encoding="utf-8")
        (self.root / "notes.txt").write_text("notes", encoding="utf-8")

        result = sorty_watch.run_watcher("inbox")

        request = json.loads((self.base / "request.json").read_text(encoding="utf-8"))
        self.assertIn("Finance/2025 invoice acme.pdf", request["structure"])
        self.assertNotIn("notes.txt", request["structure"], "new items are not presented as existing style")
        self.assertEqual(request["prompt"], "Keep finance tidy")
        self.assertEqual(result["moved"], [{"source": "Invoice Acme.pdf", "destination": "Finance/2026 invoice acme.pdf"}])
        self.assertEqual(result["queued"], [{"path": "notes.txt", "reason": "AI did not place it"}])
        rollback = sorty_helper.rollback(Path(result["journals"][0]))
        self.assertEqual(rollback["restored"], 1)
        self.assertTrue((self.root / "Invoice Acme.pdf").exists())

    def test_review_only_handlers_never_move_and_unsafe_placements_are_refused(self):
        handler = self.handler("reply = {'operations': [{'source': p, 'destination': 'Sorted/' + p.replace('.txt', '.zip')} for p in items]}")
        self.add(handler=handler)
        (self.root / "a.txt").write_text("a", encoding="utf-8")
        result = sorty_watch.run_watcher("inbox")
        self.assertEqual(result["moved"], [])
        self.assertIn("review-only", result["queued"][0]["reason"])

        self.add(handler=handler, apply=True, id="second", include_existing=True)
        result = sorty_watch.run_watcher("second")
        self.assertEqual(result["status"], "error", "extension changes still need explicit approval")
        self.assertTrue((self.root / "a.txt").exists())

    def test_handler_failures_and_collisions_queue_items(self):
        (self.root / "PDFs").mkdir()
        (self.root / "PDFs/b.pdf").write_text("existing", encoding="utf-8")
        handler = self.handler("reply = {'operations': [{'source': p, 'destination': 'PDFs/' + p} for p in items]}")
        self.add(handler=handler, apply=True)
        (self.root / "b.pdf").write_text("incoming", encoding="utf-8")
        result = sorty_watch.run_watcher("inbox")
        self.assertIn("destination already exists", result["queued"][0]["reason"])
        self.assertEqual((self.root / "PDFs/b.pdf").read_text(encoding="utf-8"), "existing")

        self.add(handler=self.handler("raise SystemExit(4)"), apply=True, id="broken", include_existing=True)
        result = sorty_watch.run_watcher("broken")
        self.assertEqual((result["status"], result["queued"][0]["reason"]), ("error", "handler failed"))

    def test_unsettled_and_partial_downloads_wait(self):
        self.add(settle=3600)
        (self.root / "fresh.pdf").write_text("fresh", encoding="utf-8")
        (self.root / "movie.mp4.crdownload").write_text("partial", encoding="utf-8")
        result = sorty_watch.run_watcher("inbox")
        self.assertEqual(sorted(result["waiting"]), ["fresh.pdf", "movie.mp4.crdownload"])
        self.assertEqual(result["queued"], [])

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
