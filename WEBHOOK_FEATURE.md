# Webhook Notification Feature — Full Discussion & Implementation

## Overview

Feature request: when Claude Code finishes responding (goes idle, waiting for user input) and no one is connected to the container (neither via ttyd web terminal nor SSH), send a webhook notification with Claude's last output text.

**Status**: Implemented on branch `feat/webhook-notification`

---

## Initial Request (User)

> For the cloud world project I want that when claude terminate the process if there is no terminal connected to the interface or there is no one logged in via the webui to the terminal it send a notification to a webhook endpoint. is possible?

## Clarified Request (User)

> No what I mean is that I want a notification every time claude finish a task so it wait again for user input. from all connection like from webui or ssh. for example I connect to claude via ssh i give a prompt and it start running i close the terminal on my local env but since there is tmux it cuntinue running but detached. when claude complete the task so no more output from it's side i receive a webhook notification to an endpoint with last text message from claude. Is this feasible?

## Key Requirements

1. Detect when Claude Code **finishes responding** and waits for next input (NOT process exit)
2. Works for ALL connection types: ttyd web terminal AND SSH
3. Includes the **last text message** from Claude in the webhook payload
4. The primary scenario: start Claude in tmux, disconnect, Claude finishes task, get notified

---

## Exploration Phase

### Project Analysis (Explore Agent 1)

Claude World is a single Docker container with:
- ttyd web terminal on port 7681 (basic auth)
- SSH server on port 2222
- Claude Code auto-launches via `.bashrc` on every login
- tmux for persistent sessions (`TMUX_AUTO=1` wraps sessions in tmux)
- Container base: `linuxserver/baseimage-ubuntu:noble`
- No existing webhook or notification mechanism

### Claude Code Process Analysis (Explore Agent 2)

- Claude Code runs as a Node.js process inside the user's shell
- When inside tmux with `TMUX_AUTO=1`, Claude survives SSH/ttyd disconnects
- ttyd 1.7.7 has no built-in API for listing connected clients
- Connection detection works via `who` command or `ss` TCP socket checks

### Idle Detection Research (Explore Agent 3)

Three approaches were evaluated:

**Approach A: Claude Code Notification Hook (CHOSEN)**
- Claude Code has a built-in `idle_prompt` Notification hook matcher
- Fires when Claude has been waiting for input for 60+ seconds
- Documented in hooks-patterns.md reference
- Receives JSON via stdin with `session_id`, `transcript_path`, `cwd`, `hook_event_name`
- **Pros**: Native, zero-polling, reliable, accesses session metadata
- **Cons**: Fixed 60-second minimum idle threshold

**Approach B: `script` command + log polling**
- Run Claude under `script -q -f` to capture output to a log file
- Background process polls log file for changes
- If no changes for N seconds, Claude is idle
- **Pros**: Captures actual output, configurable idle threshold
- **Cons**: Complex, requires managing cleanup, polling overhead

**Approach C: /proc monitoring**
- Monitor `/proc/<pid>/wchan` for `ep_poll` (Claude waiting on stdin)
- Monitor `/proc/<pid>/io` write_bytes for activity
- **Pros**: No dependencies
- **Cons**: Less precise, wchan can be ep_poll for reasons other than idle

**Decision**: Approach A (Claude Code hooks) is the clear winner. It uses Claude's native idle detection, requires no background daemons, and is the most reliable.

### Tools Available in Container

| Tool | Status | Version |
|------|--------|---------|
| `script` | Installed | util-linux 2.39.3 |
| `tmux` | Installed | 3.4 |
| `curl` | Installed | system |
| `who` | Installed | coreutils |
| `python3` | Installed | system |
| `inotifywait` | Not installed | (would need apt) |

### Connection Detection

Use `who | wc -l` to count active login sessions. Both SSH and ttyd create login sessions that appear in `who` output. When count = 0, no one is connected.

### Transcript Format

Claude Code stores transcripts as JSONL files at `/config/.claude/projects/-workplace/<session-id>.jsonl`. Each line is a JSON object. Assistant messages have:
```json
{
  "message": {
    "role": "assistant",
    "content": [
      {"type": "text", "text": "..."},
      {"type": "tool_use", ...},
      {"type": "thinking", ...}
    ]
  }
}
```

We extract the last assistant message with `type: "text"` content blocks for the webhook payload.

---

## Architecture

```
User connects (SSH or ttyd)
  |
  v
.bashrc auto-launch → claude
  |
  v
Claude Code runs interactively
  |
  +-- User gives prompt → Claude processes (API calls, tools, etc.)
  |
  +-- Claude finishes responding → enters idle state (waiting for input)
  |
  +-- After 60s idle: Claude Code fires "idle_prompt" Notification hook
        |
        v
      /usr/local/bin/claude-idle-webhook.sh
        |
        +-- Reads hook JSON from stdin (session_id, transcript_path)
        +-- Checks 'who | wc -l' for active connections
        +-- If 0 connections:
        |     Extracts last assistant message from transcript
        |     Sends JSON POST to CLAUDE_WEBHOOK_URL
        +-- If > 0 connections: exits silently
```

---

## Implementation

### Files Modified

1. **`init.sh`** — 3 changes:
   - Updated settings.json template: added `idle_prompt` Notification hook
   - Added python3 hook injection: merges hook into existing settings.json on every boot
   - Created `/usr/local/bin/claude-idle-webhook.sh`: the webhook sender script
   - Added `CLAUDE_WEBHOOK_URL` and `CLAUDE_WEBHOOK_IDLE` to shell env block

2. **`compose.yaml`** — Added `CLAUDE_WEBHOOK_URL` and `CLAUDE_WEBHOOK_IDLE` env vars

3. **`compose-casaos.yaml`** — Same env vars + CasaOS metadata entries

4. **`cloud-dev-docs/docs/env-vars.mdx`** — Added "Webhook Notifications" section with full documentation

### Webhook Sender Script (`/usr/local/bin/claude-idle-webhook.sh`)

```bash
#!/bin/bash
# Called by Claude Code's idle_prompt Notification hook
# Receives JSON on stdin: {session_id, transcript_path, cwd, hook_event_name}

CLAUDE_WEBHOOK_URL="${CLAUDE_WEBHOOK_URL:-}"
[ -z "$CLAUDE_WEBHOOK_URL" ] && exit 0

# Read hook metadata
HOOK_DATA=$(cat)
SESSION_ID=$(echo "$HOOK_DATA" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('session_id',''))")
TRANSCRIPT=$(echo "$HOOK_DATA" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('transcript_path',''))")

# Check connections
ACTIVE=$(who | wc -l)
[ "$ACTIVE" -gt 0 ] && exit 0

# Extract last assistant message from transcript
LAST_OUTPUT=$(python3 -c "
import json
with open('$TRANSCRIPT') as f:
    lines = f.readlines()
for line in reversed(lines):
    msg = json.loads(line.strip())
    if msg.get('message',{}).get('role') == 'assistant':
        texts = [b.get('text','') for b in msg['message'].get('content',[]) if b.get('type')=='text']
        if texts:
            print(''.join(texts))
            break
")

# Send webhook
curl -s --connect-timeout 10 --max-time 30 \
    -X POST "$CLAUDE_WEBHOOK_URL" \
    -H "Content-Type: application/json" \
    -d "{...}" > /dev/null 2>&1 &
```

### Hook Configuration (in settings.json)

```json
{
  "hooks": {
    "Notification": [
      {
        "matcher": "idle_prompt",
        "hooks": [
          {
            "type": "command",
            "command": "/usr/local/bin/claude-idle-webhook.sh"
          }
        ]
      }
    ]
  }
}
```

### Webhook Payload

```json
{
  "event": "claude_idle",
  "timestamp": "2026-07-24T15:30:00Z",
  "hostname": "claude-world",
  "session_id": "35e6a910-e088-4f87-bbbf-9bd207e652a6",
  "last_output": "The fix has been applied to utils.py.\n\nAll tests pass."
}
```

### Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `CLAUDE_WEBHOOK_URL` | *(empty)* | Webhook endpoint URL. Empty = disabled |
| `CLAUDE_WEBHOOK_IDLE` | `60` | Idle seconds before hook fires (min 60, dictated by Claude Code) |

---

## Edge Cases

| Scenario | Behavior |
|----------|----------|
| Claude finishes, all users disconnected | Webhook fires with last output |
| Claude finishes, user still connected (SSH or ttyd) | `who` shows active → no webhook |
| User reconnects before hook fires | `who` now shows active → hook runs but exits silently |
| Claude is idle but user is at shell prompt | `who` shows them → no webhook (correct: someone could type a new prompt) |
| Multiple Claude sessions, some idle | Each session has its own hook; each checks `who` independently |
| `CLAUDE_WEBHOOK_URL` not set | Hook script exits immediately, no overhead |
| Webhook URL unreachable | curl times out after 30s in background, no impact |
| No transcript file found | `last_output` is empty string, webhook still sends |

---

## Verification

1. Set `CLAUDE_WEBHOOK_URL=https://webhook.site/test-id` in compose.yaml
2. Recreate container: `docker compose up -d --force-recreate`
3. **Test 1 (webhook fires)**: SSH in → give Claude a quick prompt → wait for response → close SSH → wait 60s → check webhook.site
   - Expected: JSON payload with Claude's last output text
4. **Test 2 (no webhook, user connected)**: SSH in → give prompt → wait for response → stay connected → wait 60s
   - Expected: no webhook fires
5. **Test 3 (disabled)**: Set `CLAUDE_WEBHOOK_URL=""` → use normally
   - Expected: no hook activity, normal operation

---

## Key Design Decisions

1. **Claude Code hooks over external monitoring**: The `idle_prompt` hook is Claude Code's own mechanism for detecting idle state. It's more reliable than external polling of log files or process state.

2. **`who` for connection detection**: Simple, reliable, covers both SSH and ttyd. No need for separate `ss` checks per port.

3. **Transcript parsing for last output**: Reads Claude's own transcript file to extract the last assistant text message. More reliable than scraping terminal output with ANSI codes.

4. **Hook injection on every boot**: Uses python3 to safely merge the hook config into settings.json, respecting any custom hooks the user has added.

5. **60-second minimum idle**: Dictated by Claude Code's hook timing. Not configurable (the `CLAUDE_WEBHOOK_IDLE` env var is present for documentation but the actual timing is fixed by Claude Code).

---

## Backward Compatibility

- Both env vars default to empty/60: feature is fully disabled unless explicitly configured
- `NO_CLAUDE=1` still works as before
- No wrapper script modifies Claude's execution
- No background daemons or polling processes
- Hook injection is idempotent: won't add duplicate hooks
- The hook script exits immediately if `CLAUDE_WEBHOOK_URL` is empty
