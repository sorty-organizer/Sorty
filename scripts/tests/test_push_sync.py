"""Exercise guarded updates and push delivery against real temporary repositories."""

import importlib.util
import json
import os
from pathlib import Path
import select
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "push_sync.py"
spec = importlib.util.spec_from_file_location("push_sync", SCRIPT)
sync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sync)


class PushSyncTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.previous_state = sync.STATE
        sync.STATE = self.root / "state"
        self.origin = self.root / "origin.git"
        self.sender = self.root / "sender"
        self.local = self.root / "local"
        self.git(self.root, "init", "--bare", "--initial-branch=main", str(self.origin))
        self.git(self.root, "clone", str(self.origin), str(self.sender))
        self.configure(self.sender)
        (self.sender / "file.txt").write_text("initial\n")
        self.commit(self.sender, "initial")
        self.git(self.sender, "push", "origin", "main")
        self.git(self.root, "clone", str(self.origin), str(self.local))
        self.configure(self.local)
        self.config = {"repo": str(self.local)}
        self.initial = self.git(self.local, "rev-parse", "HEAD")
        (self.sender / "file.txt").write_text("remote update\n")
        self.commit(self.sender, "remote update")
        self.git(self.sender, "push", "origin", "main")
        sync.write_json(sync.STATE / "pending.json", {"id": "a" * 32})

    def tearDown(self):
        sync.STATE = self.previous_state
        self.temp.cleanup()

    def git(self, repo, *args):
        return subprocess.run([sync.GIT, "-C", str(repo), *args], check=True,
                              capture_output=True, text=True).stdout.strip()

    def configure(self, repo):
        self.git(repo, "config", "user.name", "Sync test")
        self.git(repo, "config", "user.email", "sync@example.invalid")

    def commit(self, repo, message):
        self.git(repo, "add", ".")
        self.git(repo, "commit", "-m", message)

    def test_dirty_checkout_waits_then_fast_forwards_without_stashing(self):
        (self.local / "local-only.txt").write_text("do not overwrite\n")
        sync.apply_pending(self.config)
        self.assertEqual(self.git(self.local, "rev-parse", "HEAD"), self.initial)
        self.assertEqual((self.local / "local-only.txt").read_text(), "do not overwrite\n")
        self.assertFalse(sync.read_json(sync.STATE / "pending.json").get("fetch_attempted"))
        (self.local / "local-only.txt").unlink()
        sync.apply_pending(self.config)
        self.assertEqual((self.local / "file.txt").read_text(), "remote update\n")
        self.assertFalse((sync.STATE / "pending.json").exists())
        self.assertEqual(self.git(self.local, "stash", "list"), "")

    def test_divergence_keeps_both_histories_and_pending_event(self):
        (self.local / "local.txt").write_text("local commit\n")
        self.commit(self.local, "local work")
        local_head = self.git(self.local, "rev-parse", "HEAD")
        sync.apply_pending(self.config)
        self.assertEqual(self.git(self.local, "rev-parse", "HEAD"), local_head)
        self.assertTrue((sync.STATE / "pending.json").exists())
        self.assertIn("diverged", sync.read_json(sync.STATE / "status.json")["reason"])
        self.assertEqual((self.local / "local.txt").read_text(), "local commit\n")

    def test_pause_and_git_operation_prevent_fetch_and_update(self):
        paused = sync.STATE / "control/paused"
        paused.parent.mkdir(parents=True)
        paused.touch()
        sync.apply_pending(self.config)
        self.assertEqual(self.git(self.local, "rev-parse", "HEAD"), self.initial)
        self.assertFalse(sync.read_json(sync.STATE / "pending.json").get("fetch_attempted"))
        paused.unlink()
        (self.local / ".git/index.lock").touch()
        sync.apply_pending(self.config)
        self.assertEqual(self.git(self.local, "rev-parse", "HEAD"), self.initial)
        self.assertIn("in progress", sync.read_json(sync.STATE / "status.json")["reason"])

    def test_failed_and_dry_run_pushes_do_not_queue_successful_push_does(self):
        config = {"repo": str(self.sender)}
        self.assertNotEqual(sync.wrap(config, ["-C", str(self.sender), "push", "missing-remote", "main"]), 0)
        self.assertFalse((sync.STATE / "outbox/pending.json").exists())
        self.assertEqual(sync.wrap(config, ["-C", str(self.sender), "push", "--dry-run", "origin", "main"]), 0)
        self.assertFalse((sync.STATE / "outbox/pending.json").exists())
        self.assertEqual(sync.wrap(config, ["-C", str(self.sender), "push", "origin", "main"]), 0)
        self.assertEqual(len(sync.read_json(sync.STATE / "outbox/pending.json")["id"]), 32)

    def test_active_git_process_defers_until_it_exits(self):
        process = subprocess.Popen([sync.GIT, "cat-file", "--batch"], cwd=self.local,
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        try:
            self.assertIn(process.pid, sync.apply_pending(self.config))
            self.assertEqual(self.git(self.local, "rev-parse", "HEAD"), self.initial)
            self.assertFalse(sync.read_json(sync.STATE / "pending.json").get("fetch_attempted"))
        finally:
            process.stdin.close()
            process.wait(timeout=5)
            process.stdout.close()
        sync.apply_pending(self.config)
        self.assertEqual((self.local / "file.txt").read_text(), "remote update\n")

    @unittest.skipUnless(hasattr(select, "kqueue"), "macOS event transport")
    def test_disconnect_redelivers_and_old_ack_cannot_drop_new_push(self):
        home = self.root / "home"
        state = home / "Library/Application Support/SortyPushSync"
        sync.write_json(state / "outbox/pending.json", {"id": "a" * 32})
        env = dict(os.environ, HOME=str(home))

        def connect():
            return subprocess.Popen(["/usr/bin/python3", str(SCRIPT), "watch"],
                                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=env)

        def receive(child):
            self.assertTrue(select.select([child.stdout], [], [], 5)[0], "event delivery timed out")
            return json.loads(child.stdout.readline())["id"]

        child = connect()
        try:
            self.assertEqual(receive(child), "a" * 32)
        finally:
            child.stdin.close()
            child.wait(timeout=5)
            child.stdout.close()
        child = connect()
        try:
            self.assertEqual(receive(child), "a" * 32)
            sync.write_json(state / "outbox/pending.json", {"id": "b" * 32})
            child.stdin.write(("a" * 32 + "\n").encode())
            child.stdin.flush()
            self.assertEqual(receive(child), "b" * 32)
            self.assertEqual(sync.read_json(state / "outbox/pending.json")["id"], "b" * 32)
        finally:
            child.stdin.close()
            child.wait(timeout=5)
            child.stdout.close()


if __name__ == "__main__":
    unittest.main()
