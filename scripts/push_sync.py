#!/usr/bin/python3
"""Send successful-push events over SSH and apply them only to a safe checkout."""

import argparse
import contextlib
import fcntl
import json
import os
from pathlib import Path
import plistlib
import select
import shlex
import subprocess
import sys
import tempfile
import time
import uuid

INSTALL = Path.home() / ".local/share/sorty-push-sync"
STATE = Path.home() / "Library/Application Support/SortyPushSync"
LABEL = "com.sorty.push-sync"
GIT = "/usr/bin/git"


def run(args, **kwargs):
    return subprocess.run(args, text=True, **kwargs)


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as file:
        json.dump(value, file)
        file.flush()
        os.fsync(file.fileno())
    os.replace(file.name, path)
    directory = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def read_json(path, default=None):
    try:
        return json.loads(path.read_text())
    except FileNotFoundError:
        return default


@contextlib.contextmanager
def lock(name):
    STATE.mkdir(parents=True, exist_ok=True)
    with (STATE / name).open("a") as file:
        fcntl.flock(file, fcntl.LOCK_EX)
        yield


def log(message):
    print(time.strftime("%Y-%m-%d %H:%M:%S") + " " + message, file=sys.stderr, flush=True)


def git(config, *args):
    env = dict(os.environ, GIT_OPTIONAL_LOCKS="0", GIT_TERMINAL_PROMPT="0")
    return run([GIT, "-C", config["repo"], *args], capture_output=True, env=env, timeout=60)


def push_prefix(args):
    """Find the Git command after global options, preserving -C/-c context."""
    index = 0
    while index < len(args):
        arg = args[index]
        if arg in ("-C", "-c", "--git-dir", "--work-tree", "--namespace", "--config-env"):
            index += 2
        elif arg.startswith("-"):
            index += 1
        else:
            return args[:index] if arg == "push" else None
    return None


def notify(config):
    with lock("sender.lock"):
        write_json(STATE / "outbox/pending.json", {"id": uuid.uuid4().hex})


def wrap(config, args):
    # Forward terminal I/O and the real push's exit status unchanged.
    result = run([GIT, *args])
    prefix = push_prefix(args)
    if result.returncode == 0 and prefix is not None and "--dry-run" not in args and "-n" not in args:
        root = run([GIT, *prefix, "rev-parse", "--show-toplevel"], capture_output=True)
        if root.returncode == 0 and Path(root.stdout.strip()).resolve() == Path(config["repo"]).resolve():
            try:
                notify(config)
            except OSError as error:
                log("Push succeeded, but sync signal could not be queued: " + str(error))
    return result.returncode if result.returncode >= 0 else 128 - result.returncode


def watch_sender():
    """Sleep in kqueue; acknowledge only the exact event durably received."""
    outbox = STATE / "outbox"
    outbox.mkdir(parents=True, exist_ok=True)
    fd = os.open(outbox, os.O_RDONLY)
    queue = select.kqueue()
    queue.control([
        select.kevent(fd, filter=select.KQ_FILTER_VNODE,
                      flags=select.KQ_EV_ADD | select.KQ_EV_CLEAR, fflags=select.KQ_NOTE_WRITE),
        select.kevent(0, filter=select.KQ_FILTER_READ, flags=select.KQ_EV_ADD),
    ], 0)
    sent = None
    buffer = b""
    try:
        while True:
            with lock("sender.lock"):
                pending = read_json(outbox / "pending.json")
            if pending and pending["id"] != sent:
                print(json.dumps(pending), flush=True)
                sent = pending["id"]
            for event in queue.control(None, 2):
                if event.ident == 0:
                    data = os.read(0, 4096)
                    if not data:
                        return 0
                    buffer += data
                    while b"\n" in buffer:
                        line, buffer = buffer.split(b"\n", 1)
                        with lock("sender.lock"):
                            pending = read_json(outbox / "pending.json")
                            if pending and line.decode() == pending["id"]:
                                (outbox / "pending.json").unlink()
    finally:
        queue.close()
        os.close(fd)


def busy_processes(config):
    """Treat coding runtimes and builds with a cwd in this repo as busy."""
    result = run(["/usr/sbin/lsof", "-a", "-d", "cwd", "-Fpcn"], capture_output=True, timeout=15)
    if result.returncode not in (0, 1):
        raise RuntimeError("Could not inspect active checkout users")
    repo = Path(config["repo"]).resolve()
    busy = []
    pid, command = None, ""
    for line in result.stdout.splitlines():
        if line.startswith("p"):
            pid = int(line[1:])
        elif line.startswith("c"):
            command = line[1:].lower()
        elif line.startswith("n"):
            cwd = Path(line[1:])
            if (cwd == repo or repo in cwd.parents) and any(
                name in command for name in ("codex", "claude", "opencode", "node", "swift", "xcode", "make", "git")
            ):
                busy.append(pid)
    return busy


def apply_pending(config):
    """Never stash, reset, rebase, switch branches, or force an update."""
    with lock("receiver.lock"):
        pending = read_json(STATE / "pending.json")
        if not pending:
            return []
        reason, busy = "", []
        try:
            git_dir = Path(git(config, "rev-parse", "--absolute-git-dir").stdout.strip())
            if (STATE / "control/paused").exists():
                reason = "paused"
            elif config.get("origin_url") and git(config, "remote", "get-url", "origin").stdout.strip() != config["origin_url"]:
                reason = "origin changed since installation"
            elif git(config, "symbolic-ref", "--quiet", "--short", "HEAD").stdout.strip() != "main":
                reason = "checkout is not on main"
            elif any((git_dir / name).exists() for name in (
                "index.lock", "HEAD.lock", "MERGE_HEAD", "rebase-merge", "rebase-apply", "CHERRY_PICK_HEAD", "REVERT_HEAD", "sequencer"
            )):
                reason = "Git operation is in progress"
            else:
                status = git(config, "status", "--porcelain", "--untracked-files=all")
                if status.returncode or status.stdout:
                    reason = "checkout has local changes or cannot be inspected"
                else:
                    busy = busy_processes(config)
                    if busy:
                        reason = "coding/build process is using the checkout"
            if not reason:
                # Fetch at most once per delivered push, even if local file events repeat.
                if not pending.get("fetch_attempted"):
                    pending["fetch_attempted"] = True
                    write_json(STATE / "pending.json", pending)
                    fetched = git(config, "fetch", "--no-tags", "origin", "main")
                    pending["fetched"] = fetched.returncode == 0
                    write_json(STATE / "pending.json", pending)
                    if fetched.returncode:
                        reason = "fetch failed: " + fetched.stderr.strip()
                if not reason and not pending.get("fetched"):
                    reason = "fetch failed; use sorty-sync sync to retry"
                if not reason:
                    head = git(config, "rev-parse", "HEAD").stdout.strip()
                    target = git(config, "rev-parse", "refs/remotes/origin/main").stdout.strip()
                    if git(config, "merge-base", "--is-ancestor", head, target).returncode:
                        reason = "local main is ahead or diverged"
                    else:
                        # Recheck after network I/O before changing files.
                        status = git(config, "status", "--porcelain", "--untracked-files=all")
                        if (STATE / "control/paused").exists():
                            reason = "paused during fetch"
                        elif status.returncode or status.stdout or busy_processes(config):
                            reason = "checkout became busy during fetch"
                        elif git(config, "symbolic-ref", "--short", "HEAD").stdout.strip() != "main":
                            reason = "branch changed during fetch"
                        elif git(config, "rev-parse", "HEAD").stdout.strip() != head:
                            reason = "HEAD changed during fetch"
                        else:
                            merged = git(config, "-c", "core.hooksPath=/dev/null", "merge", "--ff-only", "--no-autostash", target)
                            if merged.returncode:
                                reason = "fast-forward refused: " + merged.stderr.strip()
                            else:
                                (STATE / "pending.json").unlink()
                                log("Updated main to " + target[:12])
        except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
            reason = str(error)
        old = read_json(STATE / "status.json", {})
        if old.get("reason") != reason or old.get("event") != pending["id"]:
            write_json(STATE / "status.json", {"event": pending["id"], "reason": reason or "updated", "time": time.time()})
            if reason:
                log("Update pending: " + reason)
        return busy


def receive(config):
    control = STATE / "control"
    control.mkdir(parents=True, exist_ok=True)
    command = shlex.join(["/usr/bin/python3", config["remote_script"], "watch"])
    child = subprocess.Popen([
        "/usr/bin/ssh", "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
        "-o", "ServerAliveInterval=60", "-o", "ServerAliveCountMax=2", config["remote"], command,
    ], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    queue = select.kqueue()
    fds = []
    watched_pids = set()
    buffer = b""

    def retry():
        for pid in apply_pending(config):
            if pid not in watched_pids:
                try:
                    queue.control([select.kevent(pid, filter=select.KQ_FILTER_PROC,
                                  flags=select.KQ_EV_ADD | select.KQ_EV_ONESHOT,
                                  fflags=select.KQ_NOTE_EXIT)], 0)
                    watched_pids.add(pid)
                except ProcessLookupError:
                    pass

    try:
        for directory in (control, Path(config["repo"]) / ".git"):
            fd = os.open(directory, os.O_RDONLY)
            fds.append(fd)
            queue.control([select.kevent(fd, filter=select.KQ_FILTER_VNODE,
                          flags=select.KQ_EV_ADD | select.KQ_EV_CLEAR, fflags=select.KQ_NOTE_WRITE)], 0)
        queue.control([select.kevent(child.stdout.fileno(), filter=select.KQ_FILTER_READ,
                      flags=select.KQ_EV_ADD)], 0)
        # A reconnect retries a previously failed fetch, but never fetches with no pending push.
        with lock("receiver.lock"):
            pending = read_json(STATE / "pending.json")
            if pending and not pending.get("fetched"):
                pending.pop("fetch_attempted", None)
                write_json(STATE / "pending.json", pending)
        retry()
        log("Listening for successful pushes from " + config["remote"])
        while True:
            for event in queue.control(None, 16):
                if event.filter == select.KQ_FILTER_PROC:
                    watched_pids.discard(event.ident)
                if event.filter == select.KQ_FILTER_READ:
                    data = os.read(child.stdout.fileno(), 4096)
                    if not data:
                        log("SSH event channel disconnected; launchd will reconnect")
                        return 1
                    buffer += data
                    while b"\n" in buffer:
                        line, buffer = buffer.split(b"\n", 1)
                        incoming = json.loads(line)
                        if not isinstance(incoming.get("id"), str) or len(incoming["id"]) != 32:
                            raise ValueError("Invalid push event")
                        with lock("receiver.lock"):
                            pending = read_json(STATE / "pending.json")
                            if not pending or pending["id"] != incoming["id"]:
                                write_json(STATE / "pending.json", incoming)
                        child.stdin.write((incoming["id"] + "\n").encode())
                        child.stdin.flush()
                retry()
    finally:
        queue.close()
        for fd in fds:
            os.close(fd)
        child.terminate()
        child.wait()


def install_sender(repo):
    root = run([GIT, "-C", repo, "rev-parse", "--show-toplevel"], check=True, capture_output=True).stdout.strip()
    if Path(root).resolve() != Path(repo).resolve():
        raise RuntimeError("Sender repository must be its checkout root")
    INSTALL.mkdir(parents=True, exist_ok=True)
    STATE.mkdir(parents=True, exist_ok=True)
    (STATE / "outbox").mkdir(exist_ok=True)
    write_json(INSTALL / "config.json", {"repo": str(Path(repo).resolve())})
    wrapper = Path.home() / ".local/bin/git"
    marker = "# Sorty push sync"
    if wrapper.exists() and marker not in wrapper.read_text():
        raise RuntimeError("Refusing to replace existing " + str(wrapper))
    wrapper.parent.mkdir(parents=True, exist_ok=True)
    script = shlex.quote(str(INSTALL / "push_sync.py"))
    wrapper.write_text("#!/bin/sh\n" + marker + "\nfor arg in \"$@\"; do\n"
                       "  if [ \"$arg\" = push ]; then\n    exec /usr/bin/python3 " + script +
                       " wrap \"$@\"\n  fi\ndone\nexec /usr/bin/git \"$@\"\n")
    wrapper.chmod(0o755)
    profile = Path.home() / ".zshenv"
    contents = profile.read_text() if profile.exists() else ""
    if marker not in contents:
        with profile.open("a") as file:
            file.write("\n" + marker + "\ncase \":$PATH:\" in\n"
                       "  *\":$HOME/.local/bin:\"*) ;;\n"
                       "  *) export PATH=\"$HOME/.local/bin:$PATH\" ;;\nesac\n")
    print("Installed sender for " + repo)


def install_local(args):
    # Install private copies so pending signals also work while the checkout is dirty.
    repo = str(Path(args.repo).resolve())
    root = run([GIT, "-C", repo, "rev-parse", "--show-toplevel"], check=True, capture_output=True).stdout.strip()
    if Path(root).resolve() != Path(repo):
        raise RuntimeError("Run install from the checkout root or pass --repo")
    origin = run([GIT, "-C", repo, "remote", "get-url", "origin"], check=True, capture_output=True).stdout.strip()
    INSTALL.mkdir(parents=True, exist_ok=True)
    installed = INSTALL / "push_sync.py"
    if Path(__file__).resolve() != installed:
        installed.write_bytes(Path(__file__).read_bytes())
    remote_home = run(["ssh", "-o", "BatchMode=yes", args.remote, "printf '%s' \"$HOME\""],
                      check=True, capture_output=True).stdout
    remote_script = remote_home + "/.local/share/sorty-push-sync/push_sync.py"
    remote_repo = args.remote_repo or remote_home + "/Code Projects/Sorty"
    run(["ssh", "-o", "BatchMode=yes", args.remote, "mkdir -p ~/.local/share/sorty-push-sync"], check=True)
    run(["scp", "-q", str(installed), args.remote + ":.local/share/sorty-push-sync/push_sync.py"], check=True)
    run(["ssh", "-o", "BatchMode=yes", args.remote,
         shlex.join(["/usr/bin/python3", remote_script, "install-sender", "--repo", remote_repo])], check=True)
    write_json(INSTALL / "config.json", {"repo": repo, "origin_url": origin,
               "remote": args.remote, "remote_script": remote_script})
    (STATE / "control").mkdir(parents=True, exist_ok=True)
    launcher = Path.home() / ".local/bin/sorty-sync"
    if launcher.exists() and "# Sorty push sync" not in launcher.read_text():
        raise RuntimeError("Refusing to replace existing " + str(launcher))
    launcher.parent.mkdir(parents=True, exist_ok=True)
    launcher.write_text("#!/bin/sh\n# Sorty push sync\nexec /usr/bin/python3 " + shlex.quote(str(installed)) + " \"$@\"\n")
    launcher.chmod(0o755)
    plist = Path.home() / "Library/LaunchAgents" / (LABEL + ".plist")
    plist.parent.mkdir(parents=True, exist_ok=True)
    agent = {"Label": LABEL, "ProgramArguments": ["/usr/bin/python3", str(installed), "receive"],
             "RunAtLoad": True, "KeepAlive": True, "ThrottleInterval": 60,
             "ProcessType": "Background", "WorkingDirectory": str(INSTALL),
             "StandardOutPath": str(STATE / "agent.log"), "StandardErrorPath": str(STATE / "agent.log")}
    plist.write_bytes(plistlib.dumps(agent))
    domain = "gui/" + str(os.getuid())
    run(["launchctl", "bootout", domain + "/" + LABEL], capture_output=True)
    run(["launchctl", "bootstrap", domain, str(plist)], check=True)
    print("Installed push sync. Use sorty-sync status, pause, resume, or sync.")


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("install", "install-sender", "wrap", "watch", "receive", "status", "pause", "resume", "sync"))
    parser.add_argument("--repo", default=os.getcwd())
    parser.add_argument("--remote", default="other-mac")
    parser.add_argument("--remote-repo")
    # Git options must pass through untouched, including -C and -c.
    if len(sys.argv) > 1 and sys.argv[1] == "wrap":
        return wrap(read_json(INSTALL / "config.json"), sys.argv[2:])
    args = parser.parse_args()
    if args.command == "install":
        install_local(args)
    elif args.command == "install-sender":
        install_sender(args.repo)
    elif args.command == "watch":
        return watch_sender()
    else:
        config = read_json(INSTALL / "config.json")
        if not config:
            parser.error("Run install first")
        if args.command == "receive":
            return receive(config)
        if args.command == "status":
            print(json.dumps({"config": config, "paused": (STATE / "control/paused").exists(),
                              "pending": read_json(STATE / "pending.json"),
                              "last_result": read_json(STATE / "status.json")}, indent=2))
        else:
            control = STATE / "control"
            control.mkdir(parents=True, exist_ok=True)
            if args.command == "pause":
                with lock("receiver.lock"):
                    (control / "paused").touch()
                print("Paused. Push events will still be queued.")
            else:
                if args.command == "resume":
                    (control / "paused").unlink(missing_ok=True)
                with lock("receiver.lock"):
                    pending = read_json(STATE / "pending.json")
                    if pending and not pending.get("fetched"):
                        pending.pop("fetch_attempted", None)
                        write_json(STATE / "pending.json", pending)
                write_json(control / "retry.json", {"id": uuid.uuid4().hex})
                print("Requested a guarded retry. Use sorty-sync status for the result.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
