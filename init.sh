#!/usr/bin/with-contenv bash
# ================================================================
# Claude World — Container init script
# Runs on every container boot (linuxserver cont-init.d hook)
# Installs system packages + SSH + ttyd + nvm + Node + Claude Code
# Forces all package managers to install into /config (persistent)
# ================================================================

# ---- User Setup ----
# We default to the linuxserver user 'abc'. If CUSTOM_USER is defined in the
# environment (and not 'abc'), we rename the 'abc' user and group accordingly.
USER="abc"
if [ -n "$CUSTOM_USER" ] && [ "$CUSTOM_USER" != "abc" ]; then
    echo "[claude-world] Custom username requested: '$CUSTOM_USER'"
    if id -u abc >/dev/null 2>&1; then
        echo "[claude-world] Renaming default user 'abc' to '$CUSTOM_USER'..."
        usermod -l "$CUSTOM_USER" abc
        groupmod -n "$CUSTOM_USER" abc
        sed -i "s/\babc\b/$CUSTOM_USER/g" /etc/subuid /etc/subgid 2>/dev/null
        USER="$CUSTOM_USER"
    else
        if id -u "$CUSTOM_USER" >/dev/null 2>&1; then
            USER="$CUSTOM_USER"
        else
            echo "[claude-world] ERROR: neither 'abc' nor '$CUSTOM_USER' found. Falling back to abc."
        fi
    fi
fi

# Ensure the user has a valid login shell (LSIO default is /bin/false)
echo "[claude-world] Configuring shell for '$USER' to /bin/bash..."
usermod -s /bin/bash "$USER"

# Explicitly set the home directory in /etc/passwd to /config
echo "[claude-world] Configuring home directory for '$USER' to /config..."
usermod -d /config "$USER"

echo "[claude-world] Running as user: '$USER'"

# ---- Helper: add line to file if not already present ----
add_line() {
    local line="$1" file="$2"
    if [ -f "$file" ] && grep -qF "$line" "$file" 2>/dev/null; then
        return 0
    fi
    echo "$line" >> "$file"
}

# ---- System packages (skips if already installed — fast) ----
REQUIRED_PACKAGES=(
    openssh-server
    build-essential
    python3-pip
    python3-venv
    python3-dev
    default-jdk
    git
    curl
    wget
    docker.io
    tmux
    zsh
    nano
)

echo "[claude-world] Checking system packages..."
if dpkg -s "${REQUIRED_PACKAGES[@]}" >/dev/null 2>&1; then
    echo "[claude-world] All system packages are already installed, skipping apt-get."
else
    echo "[claude-world] Some packages are missing. Installing system packages (this may take a few minutes)..."
    apt-get update -qq
    apt-get install -y -qq "${REQUIRED_PACKAGES[@]}"
fi

# ---- Docker-in-Docker: run a docker daemon inside the container ----
# The container gets its OWN isolated docker daemon — no host socket mount.
# docker.io is already installed via REQUIRED_PACKAGES above.
if command -v dockerd >/dev/null 2>&1; then
    if ! pgrep -f "dockerd" >/dev/null 2>&1; then
        echo "[claude-world] Starting Docker daemon inside container (DinD)..."
        # Try fuse-overlayfs first (faster), fall back to vfs (works everywhere)
        if apt-get install -y -qq fuse-overlayfs 2>/dev/null && [ -x /usr/bin/fuse-overlayfs ]; then
            STORAGE_DRIVER="fuse-overlayfs"
        else
            echo "[claude-world] fuse-overlayfs not available, using vfs (slower but reliable)"
            STORAGE_DRIVER="vfs"
        fi
        nohup dockerd --storage-driver="$STORAGE_DRIVER" > /var/log/dockerd.log 2>&1 &
        # Wait up to 5 seconds for the socket to appear
        for i in $(seq 1 10); do
            if [ -S /var/run/docker.sock ]; then
                echo "[claude-world] Docker daemon started (internal only, driver=$STORAGE_DRIVER, no host access)"
                break
            fi
            sleep 0.5
        done
    else
        echo "[claude-world] Docker daemon already running, skipping."
    fi
    # Add user to docker group for the internal daemon
    usermod -aG docker "$USER" 2>/dev/null && \
        echo "[claude-world] User '$USER' added to docker group (internal daemon)"
else
    echo "[claude-world] dockerd not found — skipping Docker setup"
fi

# ---- GitHub CLI (gh) ----
if ! command -v gh >/dev/null 2>&1; then
    echo "[claude-world] Installing GitHub CLI..."
    mkdir -p -m 755 /etc/apt/keyrings
    wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        | tee /etc/apt/sources.list.d/github-cli.list > /dev/null
    apt-get update -qq
    apt-get install -y -qq gh
    echo "[claude-world] GitHub CLI installed ($(gh --version | head -1))"
else
    echo "[claude-world] GitHub CLI already installed, skipping."
fi

# ---- ttyd (web terminal) ----
if [ ! -f /usr/local/bin/ttyd ]; then
    echo "[claude-world] Installing ttyd..."
    ARCH=$(uname -m)
    if [ "$ARCH" = "x86_64" ]; then
        TTYD_ARCH="x86_64"
    elif [ "$ARCH" = "aarch64" ]; then
        TTYD_ARCH="aarch64"
    else
        echo "[claude-world] ERROR: Unsupported architecture: $ARCH"
        TTYD_ARCH="x86_64"
    fi
    TTYD_VERSION="1.7.7"
    curl -fsSL "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.${TTYD_ARCH}" \
        -o /usr/local/bin/ttyd
    chmod +x /usr/local/bin/ttyd
    echo "[claude-world] ttyd installed (version ${TTYD_VERSION})"
else
    echo "[claude-world] ttyd already installed, skipping."
fi

# Start ttyd if not already running
if ! pgrep -f "ttyd.*7681" >/dev/null 2>&1; then
    echo "[claude-world] Starting ttyd on port 7681..."
    if [ -n "$PASSWORD" ] && [ "$PASSWORD" != "CHANGE_ME_WEB_PASSWORD" ]; then
        su - "$USER" -c "export HOME=/config && nohup /usr/local/bin/ttyd -p 7681 -W -w /workplace -c \"${USER}:${PASSWORD}\" bash -l > /config/ttyd.log 2>&1 &"
        echo "[claude-world] ttyd running on http://0.0.0.0:7681"
    else
        echo "[claude-world] WARNING: PASSWORD is empty or still the placeholder — ttyd started WITHOUT auth!"
        su - "$USER" -c "export HOME=/config && nohup /usr/local/bin/ttyd -p 7681 -W -w /workplace bash -l > /config/ttyd.log 2>&1 &"
    fi
else
    echo "[claude-world] ttyd already running, skipping."
fi

# ---- SSH server ----
echo "[claude-world] Configuring SSH..."
sed -i 's/#PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
# Allow custom env vars from SSH clients (for tmux auto-attach + timeout)
if ! grep -q "AcceptEnv TMUX_AUTO" /etc/ssh/sshd_config 2>/dev/null; then
    echo "AcceptEnv TMUX_AUTO" >> /etc/ssh/sshd_config
    echo "AcceptEnv TMUX_TIMEOUT" >> /etc/ssh/sshd_config
fi

# Set user password for SSH (runs every boot — /etc/shadow is not persisted)
if [ -n "$SUDO_PASSWORD" ] && [ "$SUDO_PASSWORD" != "CHANGE_ME_SUDO_PASSWORD" ]; then
    printf '%s:%s' "$USER" "$SUDO_PASSWORD" | chpasswd 2>/dev/null && \
        echo "[claude-world] SSH password set for $USER" || \
        echo "[claude-world] ERROR: chpasswd failed for $USER"
elif [ -z "$SUDO_PASSWORD" ]; then
    echo "[claude-world] WARNING: SUDO_PASSWORD is empty — SSH password NOT set!"
    echo "[claude-world] Check that SUDO_PASSWORD is set in compose.yaml"
else
    echo "[claude-world] WARNING: SUDO_PASSWORD is still the placeholder — SSH password NOT set!"
fi

service ssh start
echo "[claude-world] SSH server started."

# ---- nvm + Node LTS (persists to /config/.nvm) ----
if [ ! -d /config/.nvm ]; then
    echo "[claude-world] Installing nvm + Node LTS..."
    su - "$USER" -c 'export HOME=/config && curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash'
    su - "$USER" -c 'export HOME=/config && export NVM_DIR="/config/.nvm" && [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" && nvm install --lts'
else
    echo "[claude-world] nvm already installed, skipping."
fi

# ---- npm global prefix → /config (env var, not .npmrc — avoids nvm conflict) ----
su - "$USER" -c 'export HOME=/config && mkdir -p ~/.npm-global'

# ---- Claude Code ----
# PINNED to 2.1.207: versions 2.1.214+ break the DeepSeek flash classifier
# (auto-mode safety checks fail with "deepseek-v4-flash[1m] is temporarily unavailable").
# To restore latest:
#   1. Comment out the 5 pinned lines below.
#   2. Uncomment the original install line:
#      su - "$USER" -c '... npm install -g @anthropic-ai/claude-code'
#   3. Remove "export ANTHROPIC_CLI_NO_UPDATE_CHECK=1" from the shell config section below.
#   4. Rebuild the container.
CLAUDE_CODE_VERSION="2.1.207"
if [ -d /config/.nvm ]; then
    INSTALLED_VERSION=$(su - "$USER" -c 'export HOME=/config && export NVM_DIR="/config/.nvm" && [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" && claude --version 2>/dev/null | grep -oE "[0-9]+\.[0-9]+\.[0-9]+" | head -1 || echo "none"')
    if [ "$INSTALLED_VERSION" != "$CLAUDE_CODE_VERSION" ]; then
        echo "[claude-world] Installing Claude Code ${CLAUDE_CODE_VERSION} (found: ${INSTALLED_VERSION})..."
        # Original (latest version): npm install -g @anthropic-ai/claude-code
        # npm install alone won't downgrade — uninstall first to force clean install
        su - "$USER" -c 'export HOME=/config && export NVM_DIR="/config/.nvm" && [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" && npm uninstall -g @anthropic-ai/claude-code 2>/dev/null; npm install -g @anthropic-ai/claude-code@'"${CLAUDE_CODE_VERSION}"
        echo "[claude-world] Claude Code ${CLAUDE_CODE_VERSION} installed."
    else
        echo "[claude-world] Claude Code ${CLAUDE_CODE_VERSION} already installed, skipping."
    fi
fi

# Disable Claude Code auto-updater (keep pinned version — remove when restoring latest)
add_line 'export ANTHROPIC_CLI_NO_UPDATE_CHECK=1' /config/.bashrc
add_line 'export ANTHROPIC_CLI_NO_UPDATE_CHECK=1' /config/.zshrc

# ---- Shell config: force pip/npm/Go to install into /config ----
for rcfile in /config/.bashrc /config/.zshrc; do
    add_line 'export PIP_USER=yes' "$rcfile"
    add_line 'export PIP_BREAK_SYSTEM_PACKAGES=1' "$rcfile"
    add_line 'export GOPATH=~/go' "$rcfile"
    add_line 'export NVM_DIR="$HOME/.nvm"' "$rcfile"
    add_line '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"' "$rcfile"
    add_line 'export PATH=~/go/bin:~/.npm-global/bin:$PATH' "$rcfile"
done

# ---- .bash_profile: SSH login shells source this, NOT .bashrc ----
cat > "/config/.bash_profile" << 'BASH_PROFILE'
# Source .bashrc for login shells (SSH)
if [ -f ~/.bashrc ]; then
    . ~/.bashrc
fi
BASH_PROFILE

# ---- Claude Code API & Session env vars (from Compose env) ----
# Written fresh on every boot — edit compose.yaml to change values
for dsrcfile in /config/.bashrc /config/.zshrc; do
    sed -i '/^# >>> Claude Code/,/^# <<< Claude Code/d' "$dsrcfile" 2>/dev/null
    cat >> "$dsrcfile" << CLAUDECODE
# >>> Claude Code (set from Compose env — edit compose.yaml to change)
$( [ -n "${ANTHROPIC_BASE_URL}" ] && echo "export ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL}" )
export ANTHROPIC_AUTH_TOKEN=${ANTHROPIC_AUTH_TOKEN:-CHANGE_ME_ANTHROPIC_KEY}
export ANTHROPIC_MODEL=${ANTHROPIC_MODEL:-claude-opus-4-8}
export ANTHROPIC_DEFAULT_OPUS_MODEL=${ANTHROPIC_DEFAULT_OPUS_MODEL:-claude-opus-4-8}
export ANTHROPIC_DEFAULT_SONNET_MODEL=${ANTHROPIC_DEFAULT_SONNET_MODEL:-claude-sonnet-4-6}
export ANTHROPIC_DEFAULT_HAIKU_MODEL=${ANTHROPIC_DEFAULT_HAIKU_MODEL:-claude-haiku-4-5}
export CLAUDE_CODE_SUBAGENT_MODEL=${CLAUDE_CODE_SUBAGENT_MODEL:-claude-haiku-4-5}
export CLAUDE_CODE_EFFORT_LEVEL=${CLAUDE_CODE_EFFORT_LEVEL:-max}
export TMUX_AUTO=${TMUX_AUTO:-0}
export TMUX_TIMEOUT=${TMUX_TIMEOUT:--1}
export GITHUB_TOKEN=${GITHUB_TOKEN:-}
export GH_TOKEN=${GH_TOKEN:-${GITHUB_TOKEN}}
# <<< Claude Code
CLAUDECODE
done

# ---- Claude Code CLAUDE.md (global instructions injected into every prompt) ----
# Written on first boot ONLY — edit /config/.claude/CLAUDE.md to customize.
# To force regeneration, delete the file and restart the container.
CLAUDE_MD="/config/.claude/CLAUDE.md"
if [ ! -f "$CLAUDE_MD" ]; then
    echo "[claude-world] Creating Claude Code CLAUDE.md with global instructions..."
    mkdir -p /config/.claude
    cat > "$CLAUDE_MD" << 'CLAUDE_MD_EOF'
# CLAUDE.md — Global Instructions

## Communication Style
- Do not use "-" in normal paragraphs. It must be avoided.
- Use ":" as a separator instead.
  Example: "The fix is in utils.py: it handles the edge case"
- Bullet points may start with "-" as normal.
- Stay strict to facts. Do not make assumptions or speculate.
- If you don't know something, search online rather than guessing.
- If stuck or the task is unclear, ask for clarification before proceeding.
- If unsure whether a command is safe to run, ask for permission.

## Git Conventions
- Follow standard git conventions.
- Branch naming: `feat/<description>` for features, `fix/<description>` for fixes.
- Commit messages: `feat: <description>` for features, `fix: <description>` for fixes.
- When committing, do NOT add "Co-Authored-By: Claude" or any mention of Claude/AI.
- When opening a PR or doing a code review, do NOT mention Claude Code or AI involvement.

## Code Quality
- Act as a senior Google engineer.
- Follow language-specific best practices and style guides.
- Code must be scalable: consider growth in data volume, traffic, and team size.
- Code must be reusable: extract shared logic, avoid duplication, prefer composition.
- No redundant code: keep it DRY, delete dead code, consolidate near-duplicates.
- Code must be self-explanatory. Write clear, self-documenting names.
- Comments must be concise. Comment only on complex functions/methods.
- Add comments around code only for parameters or when something is difficult to understand.
- Comments explain "why", not "what".

## Environment
- Always use a virtual environment for package installation (Python venv, Node nvm, etc.).
- Never install packages globally at the OS level (`pip install`, `npm install -g`, etc.).
CLAUDE_MD_EOF
    chown "$USER:$USER" "$CLAUDE_MD"
    echo "[claude-world] CLAUDE.md created (edit /config/.claude/CLAUDE.md to customize)"
else
    echo "[claude-world] CLAUDE.md already exists, skipping."
fi

# ---- Claude Code settings.json (permissions + autonomy) ----
# Written on first boot ONLY — edit /config/.claude/settings.json to customize.
# To force regeneration, delete the file and restart the container.
CLAUDE_SETTINGS="/config/.claude/settings.json"
if [ ! -f "$CLAUDE_SETTINGS" ]; then
    echo "[claude-world] Creating Claude Code settings.json with pre-approved permissions..."
    mkdir -p /config/.claude
    cat > "$CLAUDE_SETTINGS" << 'CLAUDE_SETTINGS_EOF'
{
  "permissions": {
    "allow": [
      "Bash",
      "WebSearch",
      "WebFetch",
      "Edit",
      "Write",
      "Read",
      "NotebookEdit"
    ],
    "deny": [
      "Bash(rm -rf /:*)",
      "Bash(rm -rf /config:*)",
      "Bash(rm -rf /etc:*)",
      "Bash(sudo rm -rf /:*)",
      "Bash(sudo rm -rf /config:*)",
      "Bash(sudo rm -rf /etc:*)",
      "Bash(:(){ :|:& };::*)",
      "Bash(> /dev/sda:*)",
      "Bash(dd if=* of=/dev/:*)",
      "Bash(mkfs:*)",
      "Bash(gh repo delete:*)"
    ]
  }
}
CLAUDE_SETTINGS_EOF
    chown "$USER:$USER" "$CLAUDE_SETTINGS"
    echo "[claude-world] Claude Code permissions pre-approved (edit /config/.claude/settings.json to customize)"
else
    echo "[claude-world] Claude Code settings.json already exists, skipping."
fi

# ---- cleanup-merged skill ----
# Written on first boot ONLY — edit /config/.claude/skills/cleanup-merged.md to customize.
# To force regeneration, delete the file and restart the container.
CLEANUP_SKILL="/config/.claude/skills/cleanup-merged.md"
if [ ! -f "$CLEANUP_SKILL" ]; then
    echo "[claude-world] Creating cleanup-merged skill..."
    mkdir -p /config/.claude/skills
    cat > "$CLEANUP_SKILL" << 'CLEANUP_SKILL_EOF'
---
name: cleanup-merged
description: Delete merged branches and close resolved issues
---

Delete local and remote branches that have been merged into main, and close
any GitHub issues that were resolved by those merged PRs.

## Steps

### 1. Fetch latest and prune
```
git fetch origin --prune
```

### 2. Delete merged local branches
```
git branch --merged main | grep -v "main\|master\|^*" | xargs -r git branch -d
```

### 3. Identify merged remote branches
```
gh pr list --state merged --json headRefName --jq '.[].headRefName' | sort -u
```

### 4. Delete merged remote branches
```
gh pr list --state merged --json headRefName --jq '.[].headRefName' | sort -u | xargs -r -I {} git push origin --delete {}
```

### 5. Close completed GitHub issues
```
gh pr list --state merged --json body,closingIssuesReferences --jq '.[].closingIssuesReferences[].number' | sort -u | while read issue; do
  state=$(gh issue view "$issue" --json state --jq '.state')
  if [ "$state" = "OPEN" ]; then
    gh issue close "$issue" --comment "Completed via merged PR. Closing automatically."
  fi
done
```

### 6. Report summary
Print how many local branches, remote branches, and issues were cleaned up.
CLEANUP_SKILL_EOF
    chown "$USER:$USER" "$CLEANUP_SKILL"
    echo "[claude-world] cleanup-merged skill created (edit /config/.claude/skills/cleanup-merged.md to customize)"
else
    echo "[claude-world] cleanup-merged skill already exists, skipping."
fi

# ---- Git / GitHub config (from Compose env) ----
if [ -n "${GIT_USER_NAME}" ] && [ "${GIT_USER_NAME}" != "CHANGE_ME_GIT_NAME" ]; then
    su - "$USER" -c "export HOME=/config && git config --global user.name '${GIT_USER_NAME}'"
    su - "$USER" -c "export HOME=/config && git config --global user.email '${GIT_USER_EMAIL}'"
    echo "[claude-world] Git configured: ${GIT_USER_NAME} <${GIT_USER_EMAIL}>"
fi

if [ -n "${GITHUB_TOKEN}" ] && [ "${GITHUB_TOKEN}" != "CHANGE_ME_GITHUB_TOKEN" ]; then
    su - "$USER" -c "export HOME=/config && export GITHUB_TOKEN='${GITHUB_TOKEN}' && gh auth setup-git --hostname github.com"
    echo "[claude-world] Git credential helper configured via gh (uses GITHUB_TOKEN)"
fi

# ---- Auto-launch: cd + tmux + claude ----
# Written fresh on every boot (marker-based, same pattern as Claude Code env block).
# Order: cd /workplace → tmux (if requested) → claude.
#   - [ -z "$TMUX" ] prevents tmux-inside-tmux recursion.
#   - `claude` (not `exec claude`) so exiting Claude returns to a shell prompt.
#   - NO_CLAUDE=1 skips Claude (e.g. NO_CLAUDE=1 ssh ...).
for rcfile in /config/.bashrc /config/.zshrc; do
    # Clean up legacy add_line entries from older init.sh versions
    sed -i '/^cd \/workplace$/d' "$rcfile" 2>/dev/null
    sed -i '/if \[ -z "\$NO_CLAUDE" \]; then exec claude/d' "$rcfile" 2>/dev/null
    sed -i '/TMUX_AUTO.*exec tmux new/d' "$rcfile" 2>/dev/null

    # Remove old marker block, then rewrite
    sed -i '/^# >>> Claude World Auto-Launch/,/^# <<< Claude World Auto-Launch/d' "$rcfile" 2>/dev/null
    cat >> "$rcfile" << 'AUTOLAUNCH'
# >>> Claude World Auto-Launch (written by init.sh — do not edit)
# Clean up forwarded/stale tmux sockets from SSH client forwarding
if [ -n "$TMUX" ] && [ ! -S "$(echo "$TMUX" | cut -d, -f1)" ]; then
    unset TMUX
fi

cd /workplace
if [ "$TMUX_AUTO" = "1" ] && [ -z "$TMUX" ]; then
    exec tmux new-session -A -s main
fi
if [ -z "$NO_CLAUDE" ]; then
    claude
fi
# <<< Claude World Auto-Launch
AUTOLAUNCH
done

# ---- tmux aliases ----
add_line 'alias ta="tmux new -A -s main"' /config/.bashrc
add_line 'alias ta="tmux new -A -s main"' /config/.zshrc
add_line 'alias tmux-keep="tmux setenv TMUX_KEEP 1 && echo \"Session marked keep — will never be auto-cleaned\""' /config/.bashrc
add_line 'alias tmux-keep="tmux setenv TMUX_KEEP 1 && echo \"Session marked keep — will never be auto-cleaned\""' /config/.zshrc

# ---- tmux config (persists in /config/.tmux.conf) ----
add_line 'set -g mouse on' /config/.tmux.conf
# Toggle mouse on/off with Prefix + m (Ctrl+B then m)
add_line 'bind m set -g mouse\; display-message "Mouse: #{?mouse,on,off}"' /config/.tmux.conf

# ---- tmux cleanup daemon: kills detached sessions after TMUX_TIMEOUT hours ----
cat > /usr/local/bin/tmux-cleanup.sh << 'TMUXCLEANUP'
#!/bin/bash
TIMEOUT="${TMUX_TIMEOUT:--1}"
# -1 = never kill, skip entirely
[ "$TIMEOUT" = "-1" ] && exit 0

echo "[tmux-cleanup] Watching detached sessions (timeout=${TIMEOUT}h)"

while true; do
    sleep 300  # check every 5 minutes
    tmux list-sessions -F '#{session_name} #{session_attached} #{session_activity}' 2>/dev/null | \
    while read name attached activity; do
        if [ "$attached" = "0" ]; then
            # Skip sessions marked with tmux-keep
            keep=$(tmux showenv -t "$name" TMUX_KEEP 2>/dev/null | cut -d= -f2)
            [ "$keep" = "1" ] && continue
            now=$(date +%s)
            idle_hours=$(( (now - activity) / 3600 ))
            if [ "$TIMEOUT" = "0" ] || [ "$idle_hours" -ge "$TIMEOUT" ]; then
                tmux kill-session -t "$name" 2>/dev/null && \
                echo "[tmux-cleanup] Killed session '$name' (detached ${idle_hours}h, limit ${TIMEOUT}h)"
            fi
        fi
    done
done
TMUXCLEANUP
chmod +x /usr/local/bin/tmux-cleanup.sh

# Start the cleanup daemon if not already running (only when TMUX_TIMEOUT is set)
add_line 'if [ -n "$TMUX_TIMEOUT" ] && [ "$TMUX_TIMEOUT" != "-1" ] && ! pgrep -f "tmux-cleanup" >/dev/null 2>&1; then nohup /usr/local/bin/tmux-cleanup.sh > /dev/null 2>&1 & fi' /config/.bashrc
add_line 'if [ -n "$TMUX_TIMEOUT" ] && [ "$TMUX_TIMEOUT" != "-1" ] && ! pgrep -f "tmux-cleanup" >/dev/null 2>&1; then nohup /usr/local/bin/tmux-cleanup.sh > /dev/null 2>&1 & fi' /config/.zshrc

# ---- Force English locale ----
for locfile in /config/.bashrc /config/.zshrc; do
    add_line 'export LANG=en_US.UTF-8' "$locfile"
    add_line 'export LANGUAGE=en_US:en' "$locfile"
    add_line 'export LC_ALL=en_US.UTF-8' "$locfile"
done

# ---- Fix ownership ----
chown -R "$USER:$USER" /config

echo "[claude-world] Init complete. SSH is running as '$USER'. ttyd on :7681. nvm, Node, Claude Code are ready."
