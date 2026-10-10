# Claude Code → macOS notifications (2-minute setup)

Get a **chime + a macOS banner** whenever Claude Code needs your attention — a permission prompt or when it's waiting on your input. Set it once, then look away and get pulled back exactly when it matters.

This page installs a standalone copy at `~/.claude/hooks/claude-notify.sh` titled "Claude Code", for any machine, ship or not. On a ship, prefer the module's [`hooks/claude-notify.sh`](hooks/claude-notify.sh): same script, but the banner title is the session's ship role. Register it with the module's [settings example](templates/settings-hooks.example.json) instead of step 3 below.

> **Might be built in already:** on **iTerm2, Ghostty, or Kitty**, Claude Code sends a desktop notification out of the box (the `preferredNotifChannel: "auto"` default). This setup still earns its keep — a sound, the project name in the banner, and it works in *every* terminal (Terminal.app, Warp, VS Code, …) — but on one of those three you'll get doubles unless you set `"preferredNotifChannel": "notifications_disabled"` in `~/.claude/settings.json`.

> **macOS only.** One Homebrew package; everything else is already on your machine.

## The plug-and-play way: let Claude set it up

Open Claude Code (any project) and paste this entire prompt. You'll approve a `brew install` if needed, click **Allow** once when macOS asks, and you're done.

<!-- The hook script is embedded twice in this doc (here and in the by-hand installer). Keep the two copies identical. -->

````
Set up macOS notifications for Claude Code on this machine: a chime + banner whenever Claude needs my input. The script and settings below are tested — use them exactly as written, don't rewrite or improvise.

1. Check for terminal-notifier (`command -v terminal-notifier`, also check /opt/homebrew/bin and /usr/local/bin). If missing, run `brew install terminal-notifier`.

2. Create ~/.claude/hooks/ if needed, write EXACTLY this to ~/.claude/hooks/claude-notify.sh, and chmod +x it:

```
#!/bin/bash
# Claude Code Notification hook: chime + macOS banner when Claude needs your input.
input=$(cat)
FALLBACK="${1:-needs your input}"

{ IFS= read -r MSG; IFS= read -r CWD; } < <(printf '%s' "$input" | /usr/bin/python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
for key, fallback in (("message", sys.argv[1]), ("cwd", "")):
    print((d.get(key) or fallback).replace("\n", " "))' "$FALLBACK")
MSG="${MSG:-$FALLBACK}"
PROJ=$(basename "$CWD" 2>/dev/null)

NOTIFIER=$(command -v terminal-notifier)
for p in /opt/homebrew/bin/terminal-notifier /usr/local/bin/terminal-notifier; do
  [ -z "$NOTIFIER" ] && [ -x "$p" ] && NOTIFIER="$p"
done

afplay /System/Library/Sounds/Glass.aiff &
[ -n "$NOTIFIER" ] && "$NOTIFIER" -title "Claude Code" -subtitle "$PROJ" -message "$MSG" >/dev/null 2>&1
exit 0
```

3. Merge this entry into the "hooks" → "Notification" array of ~/.claude/settings.json, replacing <HOME> with the absolute path to my home directory. Back the file up first and preserve everything already in it; create the file if it doesn't exist. If claude-notify.sh is already wired in, leave settings unchanged. (The matcher limits it to "Claude needs you" notifications — without it, auth events and MCP elicitation dialogs would chime too. The timeout keeps a wedged notifier from hanging around; the default is 10 minutes.)

{
  "matcher": "permission_prompt|idle_prompt|agent_needs_input",
  "hooks": [
    {
      "type": "command",
      "command": "<HOME>/.claude/hooks/claude-notify.sh",
      "timeout": 5
    }
  ]
}

4. Verify settings.json still parses as valid JSON, then fire a test:

echo '{"message":"Test notification — you are all set","cwd":"'"$PWD"'"}' | ~/.claude/hooks/claude-notify.sh

I should hear a Glass chime, and macOS will ask whether to allow notifications from terminal-notifier — tell me to click Allow, wait for me to confirm, then re-run the test so I see the banner. If I get the chime but no banner after allowing, check whether a Focus/Do Not Disturb mode is on, and System Settings → Notifications → terminal-notifier.

5. If this terminal is iTerm2, Ghostty, or Kitty, warn me that Claude Code's built-in notifications will double up with this, and offer to set "preferredNotifChannel": "notifications_disabled" in settings.json.

Finish with a short summary of exactly what you changed.
````

That's it. Everything below is the same setup done by hand, plus troubleshooting and tweaks.

## The by-hand way

### 1. Install the one dependency

```bash
brew install terminal-notifier
```

`afplay` (the chime) ships with macOS, and `python3` (payload parsing) comes with Apple's Command Line Tools — which Homebrew already requires, so if `brew` works you have both. No `jq`.

### 2. Run the installer

Paste this whole block into a terminal. It writes the hook script, wires it into `~/.claude/settings.json` (merging with any hooks you already have, backup taken first, aborts untouched if your JSON is broken), and fires a test notification so you know it works right now. Idempotent — safe to re-run.

```bash
mkdir -p ~/.claude/hooks

cat > ~/.claude/hooks/claude-notify.sh <<'HOOK'
#!/bin/bash
# Claude Code Notification hook: chime + macOS banner when Claude needs your input.
input=$(cat)
FALLBACK="${1:-needs your input}"

{ IFS= read -r MSG; IFS= read -r CWD; } < <(printf '%s' "$input" | /usr/bin/python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
for key, fallback in (("message", sys.argv[1]), ("cwd", "")):
    print((d.get(key) or fallback).replace("\n", " "))' "$FALLBACK")
MSG="${MSG:-$FALLBACK}"
PROJ=$(basename "$CWD" 2>/dev/null)

NOTIFIER=$(command -v terminal-notifier)
for p in /opt/homebrew/bin/terminal-notifier /usr/local/bin/terminal-notifier; do
  [ -z "$NOTIFIER" ] && [ -x "$p" ] && NOTIFIER="$p"
done

afplay /System/Library/Sounds/Glass.aiff &
[ -n "$NOTIFIER" ] && "$NOTIFIER" -title "Claude Code" -subtitle "$PROJ" -message "$MSG" >/dev/null 2>&1
exit 0
HOOK
chmod +x ~/.claude/hooks/claude-notify.sh

/usr/bin/python3 - <<'PY'
import json, os, shutil, sys
p = os.path.expanduser("~/.claude/settings.json")
cmd = os.path.expanduser("~/.claude/hooks/claude-notify.sh")
try:
    with open(p) as f:
        s = json.load(f)
except FileNotFoundError:
    s = {}
except ValueError:
    sys.exit(f"ERROR: {p} is not valid JSON — fix it first, nothing was changed.")
wired = any(
    "claude-notify.sh" in h.get("command", "")
    for m in s.get("hooks", {}).get("Notification", [])
    for h in m.get("hooks", [])
)
if wired:
    print("Already wired into settings.json — nothing to change.")
else:
    backed_up = os.path.exists(p)
    if backed_up:
        shutil.copy2(p, p + ".bak")
    s.setdefault("hooks", {}).setdefault("Notification", []).append(
        {
            "matcher": "permission_prompt|idle_prompt|agent_needs_input",
            "hooks": [{"type": "command", "command": cmd, "timeout": 5}],
        }
    )
    with open(p, "w") as f:
        json.dump(s, f, indent=2)
        f.write("\n")
    print("Wired into settings.json" + (" (backup at settings.json.bak)." if backed_up else "."))
PY

echo '{"message":"Test notification — you are all set","cwd":"'"$PWD"'"}' | ~/.claude/hooks/claude-notify.sh
```

Two details in the settings entry it writes:

- The **matcher** (`permission_prompt|idle_prompt|agent_needs_input`) limits the hook to "Claude needs you" notifications. Without it, the hook fires on *every* notification type — including auth events and MCP elicitation dialogs, which would mean spurious chimes.
- The **`"timeout": 5`** keeps a wedged notifier from lingering — the default hook timeout is 10 minutes.

If you'd rather edit `settings.json` yourself: the entry is the JSON block shown in the prompt above, with `<HOME>` as an absolute path or `$HOME` (hook commands run through a shell, so environment variables expand).

### 3. Allow notifications (one time)

The test notification at the end of step 2 triggers the macOS permission prompt for **terminal-notifier** — click **Allow**. If you missed it: **System Settings → Notifications → terminal-notifier → Allow Notifications**. Without this you'll hear the chime but see no banner.

To confirm the banner shows after allowing, re-run just the test line:

```bash
echo '{"message":"Test notification","cwd":"'"$PWD"'"}' | ~/.claude/hooks/claude-notify.sh
```

## Done

Start any Claude Code session. When Claude needs input you'll get a Glass chime and a banner titled **"Claude Code"** showing the project folder and the prompt.

> **Privacy heads-up:** the banner — and its entry in Notification Center history — shows the project folder name and Claude's message text. Worth knowing if you screen-share or work in sensitive repos; adjust the `-title`/`-subtitle`/`-message` fields (or turn off Notification Center persistence for terminal-notifier) if that matters to you.

## Troubleshooting

- **Chime but no banner** — almost always one of two things: notifications not allowed (step 3), or a **Focus / Do Not Disturb mode** silently suppressing banners. Check the menu-bar Focus status first.
- **Nothing at all** — run the test line from step 3. If it errors, the output will say why. If it's silent, run `/hooks` inside a Claude Code session and select `Notification` — your hook should be listed. Settings edits are picked up automatically; there's no restart step.
- **Intel vs Apple Silicon** — already handled; the script checks both Homebrew locations (`/usr/local/bin` and `/opt/homebrew/bin`).
- **Double notifications on iTerm2 / Ghostty / Kitty** — that's Claude Code's built-in channel overlapping with this one; see the note at the top.

## Tweaks

- **Different sound** — swap `Glass.aiff` for any file in `/System/Library/Sounds/` (`Ping`, `Hero`, `Submarine`, …).
- **Notify when Claude *finishes*** — the `Stop` hook fires at the end of **every** response turn, not just "task done", and it largely overlaps with the idle notification, so running both means two banners per exchange. If you want finish-pings, use this *instead of* the `idle_prompt` part of the matcher. Stop payloads carry no message, so pass a fallback as an argument (this is what `$1` in the script is for):

  ```json
  "Stop": [
    {
      "hooks": [
        {
          "type": "command",
          "command": "$HOME/.claude/hooks/claude-notify.sh 'finished — ready for review'",
          "timeout": 5
        }
      ]
    }
  ]
  ```

- **Chime only, no banner** — delete the `NOTIFIER` lines.
- **Custom title** — change `-title "Claude Code"` to whatever you like. The session-ux module's copy uses the session's ship role.
