#!/usr/bin/env python3

import errno
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import sorty_profile
import sorty_helper


class SortyHelperTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.base = Path(self.temporary.name)
        self.root = self.base / "root"
        self.state = self.base / "state"
        profile_patch = patch("sorty_profile.PROFILE_PATH", self.state / "profile.json")
        profile_patch.start()
        self.addCleanup(profile_patch.stop)
        self.root.mkdir()

    def tearDown(self):
        self.temporary.cleanup()

    def write_plan(self, mode, operations, **extra):
        prepared_operations = []
        for operation in operations:
            prepared = dict(operation)
            source = Path(prepared["source"])
            source = source if source.is_absolute() else self.root / source
            if source.exists() or source.is_symlink():
                prepared.setdefault("expected", sorty_helper.source_snapshot(source))
            else:
                prepared.setdefault("expected", {})
            prepared_operations.append(prepared)
        plan = {
            "version": 2,
            "source_root": str(self.root),
            "mode": mode,
            "operations": prepared_operations,
            "tags": [],
            "exclusions": [],
            "duplicate_groups": [],
            "unorganized": [],
            "warnings": [],
            **extra,
        }
        path = self.base / f"plan-{len(list(self.base.glob('plan-*')))}.json"
        path.write_text(json.dumps(plan), encoding="utf-8")
        return path

    def test_agent_preferences_survive_reimport_and_unset_restores_default(self):
        self.state.mkdir()
        profile = self.state / "profile.json"
        profile.write_text(json.dumps({"version": 1, "preferences": {
            "renameNamingOptions": {"separator": "spaces", "caseStyle": "natural"}
        }, "exclusions": [{"type": "Hidden Files"}]}))
        sorty_profile.update_preference("separator", "underscore")
        effective = sorty_profile.load_profile()
        self.assertEqual(effective["preferences"]["renameNamingOptions"],
                         {"separator": "underscore", "caseStyle": "natural"})
        self.assertEqual(effective["exclusions"], [{"type": "Hidden Files"}])
        profile.write_text(json.dumps({"version": 1, "preferences": {
            "renameNamingOptions": {"separator": "hyphen"}
        }}))
        self.assertEqual(sorty_profile.load_profile()["preferences"]["renameNamingOptions"]["separator"], "underscore")
        previous = sorty_profile.overrides_path().read_bytes()
        with self.assertRaises(ValueError):
            sorty_profile.update_preference("separator", "invalid")
        self.assertEqual(sorty_profile.overrides_path().read_bytes(), previous)
        sorty_profile.update_preference("separator")
        self.assertEqual(sorty_profile.load_profile()["preferences"]["renameNamingOptions"]["separator"], "hyphen")

    def test_scan_skips_hidden_excluded_and_package_contents(self):
        (self.root / "visible.txt").write_text("visible", encoding="utf-8")
        (self.root / ".hidden.txt").write_text("hidden", encoding="utf-8")
        (self.root / "skip.tmp").write_text("skip", encoding="utf-8")
        package = self.root / "Demo.app"
        package.mkdir()
        (package / "inside").write_text("inside", encoding="utf-8")
        result = sorty_helper.scan(self.root, ["*.tmp"], False, False)
        paths = [item["path"] for item in result["items"]]
        self.assertEqual(paths, ["Demo.app", "visible.txt"])

    def test_exact_duplicates_distinguish_hard_links(self):
        first = self.root / "first.txt"
        second = self.root / "second.txt"
        hard_link = self.root / "hard.txt"
        first.write_text("same", encoding="utf-8")
        second.write_text("same", encoding="utf-8")
        hard_link.hardlink_to(first)
        result = sorty_helper.exact_duplicates(self.root, [], False)
        self.assertEqual(len(result["duplicate_groups"]), 1)
        self.assertEqual(result["duplicate_groups"][0]["stored_objects"], 2)
        self.assertEqual(len(result["hard_link_groups"]), 1)

    def test_modes_reject_scope_changes(self):
        (self.root / "a.txt").write_text("a", encoding="utf-8")
        organize = self.write_plan("organize", [{"source": "a.txt", "destination": "Docs/b.txt"}])
        self.assertFalse(sorty_helper.validate_plan(organize)["valid"])
        rename = self.write_plan("renameOnly", [{"source": "a.txt", "destination": "Docs/a.txt"}])
        self.assertFalse(sorty_helper.validate_plan(rename)["valid"])

    def test_symlink_item_moves_without_following_target(self):
        outside = self.base / "outside.txt"
        outside.write_text("outside", encoding="utf-8")
        link = self.root / "link.txt"
        link.symlink_to(outside)
        plan = self.write_plan("renameOnly", [{"source": "link.txt", "destination": "renamed.txt"}])
        result = sorty_helper.apply_plan(plan, self.state)
        renamed = self.root / "renamed.txt"
        self.assertTrue(renamed.is_symlink())
        self.assertEqual(renamed.readlink(), outside)
        self.assertEqual(outside.read_text(encoding="utf-8"), "outside")
        sorty_helper.rollback(Path(result["journal"]))
        self.assertTrue(link.is_symlink())

    def test_collision_and_nested_overlap_are_rejected(self):
        folder = self.root / "folder"
        folder.mkdir()
        (folder / "a.txt").write_text("a", encoding="utf-8")
        (self.root / "occupied").write_text("x", encoding="utf-8")
        plan = self.write_plan("organizeAndRename", [
            {"source": "folder", "destination": "moved"},
            {"source": "folder/a.txt", "destination": "occupied"},
        ])
        result = sorty_helper.validate_plan(plan)
        self.assertFalse(result["valid"])
        self.assertTrue(any("overlapping sources" in error for error in result["errors"]))
        self.assertTrue(any("destination already exists" in error for error in result["errors"]))

    def test_destination_cannot_modify_a_directory_moved_later(self):
        folder = self.root / "folder"
        folder.mkdir()
        incoming = self.root / "incoming.txt"
        incoming.write_text("incoming", encoding="utf-8")
        plan = self.write_plan("organizeAndRename", [
            {"source": "incoming.txt", "destination": "folder/incoming.txt"},
            {"source": "folder", "destination": "archive/folder"},
        ])
        result = sorty_helper.validate_plan(plan)
        self.assertFalse(result["valid"])
        self.assertTrue(any("destination overlaps another source" in error for error in result["errors"]))

    def test_plan_cannot_move_an_excluded_item(self):
        (self.root / "private.txt").write_text("private", encoding="utf-8")
        plan = self.write_plan(
            "organize",
            [{"source": "private.txt", "destination": "Archive/private.txt"}],
            exclusions=["private.txt"],
        )
        result = sorty_helper.validate_plan(plan)
        self.assertFalse(result["valid"])
        self.assertTrue(any("matches an exclusion" in error for error in result["errors"]))

    def test_relative_destination_cannot_escape_through_symlinked_parent(self):
        source = self.root / "report.txt"
        source.write_text("report", encoding="utf-8")
        outside = self.base / "outside"
        outside.mkdir()
        (self.root / "linked").symlink_to(outside, target_is_directory=True)
        plan = self.write_plan(
            "organize",
            [{"source": "report.txt", "destination": "linked/report.txt"}],
        )
        result = sorty_helper.validate_plan(plan)
        self.assertFalse(result["valid"])
        self.assertTrue(any("symlinked parent" in error for error in result["errors"]))

    def test_apply_rejects_source_changed_after_plan(self):
        source = self.root / "draft.txt"
        source.write_text("first", encoding="utf-8")
        plan = self.write_plan(
            "renameOnly",
            [{"source": "draft.txt", "destination": "final.txt"}],
        )
        source.write_text("changed", encoding="utf-8")
        with self.assertRaises(sorty_helper.SortyError):
            sorty_helper.apply_plan(plan, self.state)
        self.assertTrue(source.exists())
        self.assertFalse((self.root / "final.txt").exists())

    def test_extension_change_requires_explicit_plan_field(self):
        source = self.root / "photo.jpg"
        source.write_text("image", encoding="utf-8")
        rejected = self.write_plan(
            "renameOnly",
            [{"source": "photo.jpg", "destination": "photo.png"}],
        )
        self.assertFalse(sorty_helper.validate_plan(rejected)["valid"])
        allowed = self.write_plan(
            "renameOnly",
            [{
                "source": "photo.jpg",
                "destination": "photo.png",
                "allow_extension_change": True,
            }],
        )
        self.assertTrue(sorty_helper.validate_plan(allowed)["valid"])

    def test_case_insensitive_destination_collisions_are_rejected(self):
        (self.root / "one.txt").write_text("one", encoding="utf-8")
        (self.root / "two.txt").write_text("two", encoding="utf-8")
        plan = self.write_plan("organizeAndRename", [
            {"source": "one.txt", "destination": "Reports/one.txt"},
            {"source": "two.txt", "destination": "reports/one.txt"},
        ])
        result = sorty_helper.validate_plan(plan)
        self.assertFalse(result["valid"])
        self.assertTrue(any("destination appears more than once" in error for error in result["errors"]))

    def test_apply_and_rollback(self):
        source = self.root / "Inbox" / "draft.txt"
        source.parent.mkdir()
        source.write_text("draft", encoding="utf-8")
        plan = self.write_plan("organizeAndRename", [
            {"source": "Inbox/draft.txt", "destination": "Documents/report.txt"}
        ])
        result = sorty_helper.apply_plan(plan, self.state)
        destination = self.root / "Documents" / "report.txt"
        self.assertFalse(source.exists())
        self.assertEqual(destination.read_text(encoding="utf-8"), "draft")
        rollback = sorty_helper.rollback(Path(result["journal"]))
        self.assertEqual(rollback["status"], "completed")
        self.assertEqual(source.read_text(encoding="utf-8"), "draft")
        self.assertFalse(destination.exists())

    def test_cross_volume_fallback_verifies_and_moves(self):
        source = self.root / "a.txt"
        destination = self.root / "elsewhere" / "a.txt"
        source.write_text("payload", encoding="utf-8")
        real_rename = sorty_helper.os.rename
        calls = 0

        def exdev_once(old, new):
            nonlocal calls
            calls += 1
            if calls == 1:
                raise OSError(errno.EXDEV, "cross-device")
            return real_rename(old, new)

        with patch.object(sorty_helper.os, "rename", side_effect=exdev_once):
            method = sorty_helper.guarded_move(source, destination)
        self.assertEqual(method, "verified-copy")
        self.assertEqual(destination.read_text(encoding="utf-8"), "payload")
        self.assertFalse(source.exists())

    def test_interrupted_apply_leaves_pending_journal(self):
        first = self.root / "one.txt"
        second = self.root / "two.txt"
        first.write_text("one", encoding="utf-8")
        second.write_text("two", encoding="utf-8")
        plan = self.write_plan("organize", [
            {"source": "one.txt", "destination": "A/one.txt"},
            {"source": "two.txt", "destination": "B/two.txt"},
        ])
        real_move = sorty_helper.guarded_move
        calls = 0

        def stop_second(source, destination):
            nonlocal calls
            calls += 1
            if calls == 2:
                raise OSError("simulated interruption")
            return real_move(source, destination)

        with patch.object(sorty_helper, "guarded_move", side_effect=stop_second):
            with self.assertRaises(OSError):
                sorty_helper.apply_plan(plan, self.state)
        journal = next((self.state / "journals").glob("*.jsonl"))
        rows = sorty_helper.read_journal(journal)
        statuses = [row.get("status") for row in rows if row.get("record") == "operation"]
        self.assertEqual(statuses, ["pending", "completed", "pending"])


if __name__ == "__main__":
    unittest.main()
