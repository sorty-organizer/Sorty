# Push sync between Macs

The other Mac queues a signal after a successful `git push` in its Sorty checkout.
A laptop LaunchAgent receives signals over the existing `other-mac` SSH connection.
Both ends sleep waiting for kernel events. There is no GitHub polling, HTTP receiver,
incoming laptop SSH service, or automatic push from the laptop.

## Installed setup

Install or update from the laptop:

```sh
/usr/bin/python3 scripts/push_sync.py install --remote other-mac
```

The installer uses the current directory as the local repository. The default
remote repository is `~/Code Projects/Sorty`; override it with `--remote-repo`.
It installs private copies in `~/.local/share/sorty-push-sync` on both Macs, a
sender `~/.local/bin/git` wrapper, a managed PATH block in the sender's `.zshenv`,
the laptop's `~/.local/bin/sorty-sync` command, and the laptop LaunchAgent
`~/Library/LaunchAgents/com.sorty.push-sync.plist`. Existing unrelated wrappers
are not overwritten. The sender's `.local/bin` must precede the real Git on PATH.

New noninteractive and login zsh shells use the wrapper. Existing threads that
inherit a PATH without `.local/bin` need restarting. Explicit `/usr/bin/git`,
other absolute Git binaries, GUI Git clients, Git aliases for push, and pushes
to GitHub made outside the wrapper do not emit signals. Ordinary `git push`,
including `git -C <directory> push`, works unchanged. Non-push commands go directly
to the real Git. Failed pushes and dry runs do not queue signals. A successful
up-to-date push can queue a harmless update check.

## Update policy

Each received push triggers at most one successful fetch of `origin/main`.
Updates require `main`, a clean index and working tree including untracked files,
no merge/rebase or Git lock, and no detected coding/build runtime with a working
directory inside this checkout. A changed origin URL also stops updates.
Local commits ahead of or diverged from
`origin/main` are left alone. Updates use fast-forward merge with autostash and
local merge hooks disabled. Sync never resets, stashes, rebases, switches branches,
builds, or launches Sorty.

Pending updates retry on changes in the Git directory, detected busy-process exit,
explicit resume/sync commands, or SSH reconnection. A failed fetch is retained;
an explicit retry or reconnect permits another attempt. Nested working-file edits
without a Git directory event may need `sorty-sync sync` after cleanup.

Git cannot detect unsaved editor buffers, and process working directories do not
identify every active agent or editor. Pause before local editing if you need a
firm boundary. Git's own locks and repeated checks reduce races; the sync lock
does not lock out independent editors or Git processes.

```sh
~/.local/bin/sorty-sync status
~/.local/bin/sorty-sync pause
~/.local/bin/sorty-sync resume
~/.local/bin/sorty-sync sync
```

Pause persists across restarts and still accepts push signals. Resume and sync
request a guarded retry, never a force update. Sync does not remove a pause.

## Delivery and recovery

The sender saves one coalesced pending signal on disk. It removes that signal only
after the laptop acknowledges durable receipt. Newer pushes cannot be removed by
an older acknowledgement. The laptop retains its own pending signal until a safe
update succeeds. Signals carry an opaque event ID; files are fetched from GitHub.

While connected, the SSH channel waits for events. SSH sends a keepalive after
60 seconds without traffic to detect broken connections. If the channel drops,
launchd reconnects with a 60-second throttle. These are connection maintenance,
not GitHub polls. A sleeping/offline laptop catches queued events after reconnection.

Inspect `~/Library/Application Support/SortyPushSync/agent.log` on the laptop and
`sorty-sync status` for pending reasons. Configuration is in
`~/.local/share/sorty-push-sync/config.json`; state is private to each Mac under
`~/Library/Application Support/SortyPushSync`.

To stop without deleting queued state:

```sh
launchctl bootout gui/$(id -u)/com.sorty.push-sync
```

To uninstall, stop the agent, remove its plist and the installed `sorty-sync`
launcher on the laptop. On the sender, remove only the managed `git` wrapper and
the `# Sorty push sync` PATH block in `.zshenv`. Remove the private installation
and state directories on both machines only if you no longer need pending events.

## Focused validation

```sh
/usr/bin/python3 -m unittest discover -s scripts/tests -p test_push_sync.py
```

These checks use temporary repositories and cover dirty-file preservation,
fast-forward updates, divergence, pause/lock deferral, successful versus failed
pushes, disconnected delivery, and acknowledgement ordering.

Installation on 2026-10-04 verified the live SSH channel, durable acknowledgement,
and dirty-checkout deferral. The other Mac's normal HTTPS push failed because its
GitHub credentials were invalid; `gh auth status` reported an invalid token.
Restore authentication there with `gh auth login --hostname github.com`, then
`gh auth setup-git --hostname github.com`. Successful-push behavior was checked
against temporary repositories; a real GitHub push from that Mac remains to be
checked after authentication is restored.
