#!/usr/bin/with-contenv bash
# ================================================================
# Claude World — Container init script
# Runs on every container boot (linuxserver cont-init.d hook)
# Installs system packages + SSH + ttyd + nvm + Node + Claude Code
# Forces all package managers to install into /config (persistent)
# ================================================================

# ---- User Setup ----
# We use the default linuxserver user 'abc' for everything to ensure maximum
# compatibility with the pre-configured desktop and services.
USER="abc"
echo "[claude-world] Running as default user: '$USER'"

# ---- Helper: add line to file if not already present ----
add_line() {
    local line="$1" file="$2"
    if [ -f "$file" ] && grep -qF "$line" "$file" 2>/dev/null; then
        return 0
    fi
    echo "$line" >> "$file"
}

# ---- System packages (reinstalled every boot — fast) ----
echo "[claude-world] Installing system packages..."
apt-get update -qq
apt-get install -y -qq \
    openssh-server \
    build-essential \
    python3-pip \
    python3-venv \
    python3-dev \
    default-jdk \
    git \
    curl \
    wget \
    docker.io \
    tmux \
    zsh \
    nano

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
        su - "$USER" -c "nohup ttyd -p 7681 -c \"${USER}:${PASSWORD}\" bash -l > /dev/null 2>&1 &"
        echo "[claude-world] ttyd running on http://0.0.0.0:7681"
    else
        echo "[claude-world] WARNING: PASSWORD is empty or still the placeholder — ttyd started WITHOUT auth!"
        su - "$USER" -c "nohup ttyd -p 7681 bash -l > /dev/null 2>&1 &"
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
    su - "$USER" -c 'curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash'
    su - "$USER" -c 'export NVM_DIR="$HOME/.nvm" && [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" && nvm install --lts'
else
    echo "[claude-world] nvm already installed, skipping."
fi

# ---- npm global prefix → /config (env var, not .npmrc — avoids nvm conflict) ----
su - "$USER" -c 'mkdir -p ~/.npm-global'

# ---- Claude Code ----
if [ -d /config/.nvm ]; then
    if ! su - "$USER" -c 'export NVM_DIR="$HOME/.nvm" && [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" && which claude 2>/dev/null'; then
        echo "[claude-world] Installing Claude Code..."
        su - "$USER" -c 'export NVM_DIR="$HOME/.nvm" && [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" && npm install -g @anthropic-ai/claude-code'
    else
        echo "[claude-world] Claude Code already installed, skipping."
    fi
fi

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

# ---- Claude Code API env vars (from Compose env) ----
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
# <<< Claude Code
CLAUDECODE
done

# ---- Git / GitHub config (from Compose env) ----
if [ -n "${GIT_USER_NAME}" ] && [ "${GIT_USER_NAME}" != "CHANGE_ME_GIT_NAME" ]; then
    su - "$USER" -c "git config --global user.name '${GIT_USER_NAME}'"
    su - "$USER" -c "git config --global user.email '${GIT_USER_EMAIL}'"
    echo "[claude-world] Git configured: ${GIT_USER_NAME} <${GIT_USER_EMAIL}>"
fi

if [ -n "${GITHUB_TOKEN}" ] && [ "${GITHUB_TOKEN}" != "CHANGE_ME_GITHUB_TOKEN" ]; then
    su - "$USER" -c "git config --global url.'https://oauth2:${GITHUB_TOKEN}@github.com/'.insteadOf 'https://github.com/'"
    echo "[claude-world] GitHub token configured (fine-grained PAT)"
fi

# ---- Default to /workplace on SSH login (not inside tmux) ----
add_line 'if [ -z "$TMUX" ]; then cd /workplace; fi' /config/.bashrc
add_line 'if [ -z "$TMUX" ]; then cd /workplace; fi' /config/.zshrc

# ---- tmux: auto-attach only when client sets TMUX_AUTO=1 (e.g. iPhone/Termius) ----
# TMUX_TIMEOUT: hours before killing a detached session (-1=never, 0=on detach, N=after N hours)
add_line 'if [ "$TMUX_AUTO" = "1" ] && [ -z "$TMUX" ]; then exec tmux new -A -s main; fi' /config/.bashrc
add_line 'if [ "$TMUX_AUTO" = "1" ] && [ -z "$TMUX" ]; then exec tmux new -A -s main; fi' /config/.zshrc
add_line 'alias ta="tmux new -A -s main"' /config/.bashrc
add_line 'alias ta="tmux new -A -s main"' /config/.zshrc
add_line 'alias tmux-keep="tmux setenv TMUX_KEEP 1 && echo \"Session marked keep — will never be auto-cleaned\""' /config/.bashrc
add_line 'alias tmux-keep="tmux setenv TMUX_KEEP 1 && echo \"Session marked keep — will never be auto-cleaned\""' /config/.zshrc

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
