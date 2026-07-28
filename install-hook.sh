#!/bin/bash
# Wire Clawd into Claude Code's activity.
#   UserPromptSubmit -> "prompt"      : you send a message -> he climbs, then cooks
#   Stop             -> "done"        : Claude finished -> he serves the dish
#   SessionEnd       -> "session-end" : no session left -> he settles down
# Safe to re-run: existing Clawd entries are replaced, not duplicated.
set -euo pipefail

SETTINGS="$HOME/.claude/settings.json"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.bak-clawd"

python3 - "$SETTINGS" <<'PY'
import json, sys

path = sys.argv[1]
cfg = json.load(open(path))
hooks = cfg.setdefault("hooks", {})

EVENTS = {
    "UserPromptSubmit": "prompt",
    "Stop": "done",
    "SessionEnd": "session-end",
}
MARK = ".clawd-dock/trigger"

for event, word in EVENTS.items():
    entries = hooks.setdefault(event, [])
    # drop our previous entries before rewriting them
    entries[:] = [e for e in entries
                  if not any(MARK in h.get("command", "") for h in e.get("hooks", []))]
    entries.append({"hooks": [{
        "type": "command",
        "command": f"mkdir -p ~/.clawd-dock && echo {word} > ~/.clawd-dock/trigger",
    }]})
    if not entries:
        del hooks[event]

json.dump(cfg, open(path, "w"), indent=2, ensure_ascii=False)
print("hooks installed:", ", ".join(EVENTS))
PY

echo "Backup: $SETTINGS.bak-clawd"
