#!/usr/bin/with-contenv bash
# ================================================================
# Claude World — Container init script
# Runs on every container boot (linuxserver cont-init.d hook)
# Installs system packages + SSH + ttyd + nvm + Node + agent CLI
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

# ---- Agent selector (claude | codex | cline) ----
# Which coding agent to install and auto-launch. Default: claude (back-compat).
# AGENT is canonical; AGENT_CLI kept as back-compat alias.
AGENT="${AGENT:-${AGENT_CLI:-claude}}"
case "$AGENT" in
    claude|codex|cline)
        ;;
    *)
        echo "[claude-world] WARNING: Unknown AGENT='$AGENT' — falling back to 'claude'."
        echo "[claude-world] Valid options: claude | codex | cline"
        AGENT="claude"
        ;;
esac
if [ "$AGENT" = "codex" ]; then
    AGENT_BIN="codex"
elif [ "$AGENT" = "cline" ]; then
    AGENT_BIN="cline"
else
    AGENT_BIN="claude"
fi
echo "[claude-world] Agent: '$AGENT' (binary: '$AGENT_BIN')"

# ---- Generic BYOK resolution ----
# AGENT_API_KEY / AGENT_MODEL / AGENT_BASE_URL are canonical.
# Back-compat aliases: AI_API_KEY, AI_MODEL, AI_BASE_URL, AGENT_CLI.
# Per-agent keys take precedence; generic AGENT_* vars are the fallback.
# Empty string and CHANGE_ME_* placeholders both count as "not set".
_resolve_key() {
    local specific="$1" generic="$2"
    case "$specific" in
        ""|CHANGE_ME_*) echo "$generic" ;;
        *) echo "$specific" ;;
    esac
}
_GENERIC_API_KEY="${AGENT_API_KEY:-${AI_API_KEY:-}}"
_GENERIC_MODEL="${AGENT_MODEL:-${AI_MODEL:-}}"
_GENERIC_BASE_URL="${AGENT_BASE_URL:-${AI_BASE_URL:-}}"
# Generic key only maps to the SELECTED agent — this prevents an OpenAI key
# from leaking into ANTHROPIC_AUTH_TOKEN (and vice versa) when switching.
if [ "$AGENT" = "claude" ]; then _AGENT_SCOPED_KEY="${_GENERIC_API_KEY:-}"; else _AGENT_SCOPED_KEY=""; fi
if [ "$AGENT" = "codex" ]; then _CODEX_SCOPED_KEY="${_GENERIC_API_KEY:-}"; else _CODEX_SCOPED_KEY=""; fi
EFFECTIVE_ANTHROPIC_AUTH_TOKEN="$(_resolve_key "${ANTHROPIC_AUTH_TOKEN:-}" "${_AGENT_SCOPED_KEY:-}")"
EFFECTIVE_OPENAI_API_KEY="$(_resolve_key "${OPENAI_API_KEY:-}" "${_CODEX_SCOPED_KEY:-}")"
if [ "$AGENT" = "claude" ]; then _AGENT_SCOPED_BASE="${_GENERIC_BASE_URL:-}"; else _AGENT_SCOPED_BASE=""; fi
if [ "$AGENT" = "codex" ]; then _CODEX_SCOPED_MODEL="${_GENERIC_MODEL:-}"; else _CODEX_SCOPED_MODEL=""; fi
EFFECTIVE_ANTHROPIC_BASE_URL="${ANTHROPIC_BASE_URL:-${_AGENT_SCOPED_BASE:-}}"
EFFECTIVE_CODEX_MODEL="${CODEX_MODEL:-${_CODEX_SCOPED_MODEL:-}}"
# Warn if AGENT_BASE_URL is set but AGENT=codex (unsupported — silently ignored)
if [ "$AGENT" = "codex" ] && [ -n "${_GENERIC_BASE_URL:-}" ]; then
    echo "[claude-world] WARNING: AGENT_BASE_URL is set but AGENT=codex — Codex does not support custom base URLs. The value will be ignored."
fi
if [ "$AGENT" = "cline" ]; then _CLINE_SCOPED_KEY="${_GENERIC_API_KEY:-}"; else _CLINE_SCOPED_KEY=""; fi
EFFECTIVE_CLINE_API_KEY="$(_resolve_key "${CLINE_API_KEY:-}" "${_CLINE_SCOPED_KEY:-}")"
if [ "$AGENT" = "cline" ]; then _CLINE_SCOPED_MODEL="${_GENERIC_MODEL:-}"; else _CLINE_SCOPED_MODEL=""; fi
EFFECTIVE_CLINE_MODEL="${CLINE_MODEL:-${_CLINE_SCOPED_MODEL:-}}"
EFFECTIVE_CLINE_PROVIDER="${CLINE_PROVIDER:-anthropic}"
# Cline convenience: expose primary and secondary provider keys under
# standard env names (in addition to the providers.json pre-seed below).
# The values are spliced into an UNQUOTED heredoc when writing the shell env
# block, so escape \, `, $ (heredoc expansion at write time) and ' (breaks
# the single-quote wrapping at source time).
CLINE_STD_KEY_EXPORT=""
_CLINE_ESCAPED_KEY=""
if [ "$AGENT" = "cline" ]; then
    if [ -n "$EFFECTIVE_CLINE_API_KEY" ]; then
        _CLINE_ESCAPED_KEY="$(printf '%s' "$EFFECTIVE_CLINE_API_KEY" | sed -e 's/\\/\\\\/g' -e 's/`/\\`/g' -e 's/\$/\\$/g' -e "s/'/'\\\\''/g")"
        case "${EFFECTIVE_CLINE_PROVIDER:-anthropic}" in
            openai*|codex*) CLINE_STD_KEY_EXPORT="export OPENAI_API_KEY='${_CLINE_ESCAPED_KEY}'" ;;
            openrouter*) CLINE_STD_KEY_EXPORT="export OPENROUTER_API_KEY='${_CLINE_ESCAPED_KEY}'" ;;
            *) CLINE_STD_KEY_EXPORT="export ANTHROPIC_API_KEY='${_CLINE_ESCAPED_KEY}'" ;;
        esac
    fi
    # Dynamically export secondary providers and standard convenience keys if defined
    for _idx in $(env | grep -E '^CLINE_PROVIDER_[0-9]+=' | sed -E 's/^CLINE_PROVIDER_([0-9]+)=.*/\1/' | sort -n -u 2>/dev/null); do
        _p_var="CLINE_PROVIDER_${_idx}"
        _k_var="CLINE_API_KEY_${_idx}"
        _m_var="CLINE_MODEL_${_idx}"
        _p_val="${!_p_var:-}"
        _k_val="${!_k_var:-}"
        _m_val="${!_m_var:-}"
        if [ -n "$_p_val" ] && [ -n "$_k_val" ]; then
            _k_escaped="$(printf '%s' "$_k_val" | sed -e 's/\\/\\\\/g' -e 's/`/\\`/g' -e 's/\$/\\$/g' -e "s/'/'\\\\''/g")"
            _p_escaped="$(printf '%s' "$_p_val" | sed -e 's/\\/\\\\/g' -e 's/`/\\`/g' -e 's/\$/\\$/g' -e "s/'/'\\\\''/g")"
            CLINE_STD_KEY_EXPORT="${CLINE_STD_KEY_EXPORT}
export ${_p_var}='${_p_escaped}'
export ${_k_var}='${_k_escaped}'"
            if [ -n "$_m_val" ]; then
                _m_escaped="$(printf '%s' "$_m_val" | sed -e 's/\\/\\\\/g' -e 's/`/\\`/g' -e 's/\$/\\$/g' -e "s/'/'\\\\''/g")"
                CLINE_STD_KEY_EXPORT="${CLINE_STD_KEY_EXPORT}
export ${_m_var}='${_m_escaped}'"
            fi
            case "$_p_val" in
                openai*|codex*)
                    [ -z "$EFFECTIVE_OPENAI_API_KEY" ] && CLINE_STD_KEY_EXPORT="${CLINE_STD_KEY_EXPORT}
export OPENAI_API_KEY='${_k_escaped}'"
                    ;;
                openrouter*)
                    [ -z "${OPENROUTER_API_KEY:-}" ] && CLINE_STD_KEY_EXPORT="${CLINE_STD_KEY_EXPORT}
export OPENROUTER_API_KEY='${_k_escaped}'"
                    ;;
                anthropic*)
                    [ -z "${ANTHROPIC_API_KEY:-}" ] && CLINE_STD_KEY_EXPORT="${CLINE_STD_KEY_EXPORT}
export ANTHROPIC_API_KEY='${_k_escaped}'"
                    ;;
            esac
        fi
    done
fi
# Webhook: AGENT_* is canonical, CLAUDE_* kept as back-compat alias.
EFFECTIVE_WEBHOOK_URL="${AGENT_WEBHOOK_URL:-${CLAUDE_WEBHOOK_URL:-}}"
EFFECTIVE_WEBHOOK_IDLE="${AGENT_WEBHOOK_IDLE:-${CLAUDE_WEBHOOK_IDLE:-60}}"

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
# Disable StrictModes so authorized_keys works across host volume bind-mounts
sed -i 's/#StrictModes.*/StrictModes no/' /etc/ssh/sshd_config 2>/dev/null || true
if ! grep -q "StrictModes" /etc/ssh/sshd_config 2>/dev/null; then
    echo "StrictModes no" >> /etc/ssh/sshd_config
fi
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

# ---- Claude Code (only when AGENT=claude) ----
# PINNED to 2.1.207: versions 2.1.214+ break the DeepSeek flash classifier
# (auto-mode safety checks fail with "deepseek-v4-flash[1m] is temporarily unavailable").
# To restore latest:
#   1. Comment out the 5 pinned lines below.
#   2. Uncomment the original install line:
#      su - "$USER" -c '... npm install -g @anthropic-ai/claude-code'
#   3. Remove "export ANTHROPIC_CLI_NO_UPDATE_CHECK=1" from the shell config section below.
#   4. Rebuild the container.
install_claude() {
    CLAUDE_CODE_VERSION="2.1.207"
    if [ -d /config/.nvm ]; then
        INSTALLED_VERSION=$(su - "$USER" -c 'export HOME=/config && export NVM_DIR="/config/.nvm" && [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" && claude --version 2>/dev/null | grep -oE "[0-9]+\.[0-9]+\.[0-9]+" | head -1 || echo "none"')
        if [ "$INSTALLED_VERSION" != "$CLAUDE_CODE_VERSION" ]; then
            echo "[claude-world] Installing Claude Code ${CLAUDE_CODE_VERSION} (found: ${INSTALLED_VERSION})..."
            # Original (latest version): npm install -g @anthropic-ai/claude-code
            # npm uninstall/install alone won't downgrade (cached) — nuke first
            su - "$USER" -c 'export HOME=/config && export NVM_DIR="/config/.nvm" && [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" && npm uninstall -g @anthropic-ai/claude-code 2>/dev/null; rm -rf "$(dirname "$(npm root -g)")/lib/node_modules/@anthropic-ai/claude-code" 2>/dev/null; npm cache clean --force 2>/dev/null; npm install -g @anthropic-ai/claude-code@'"${CLAUDE_CODE_VERSION}"
            echo "[claude-world] Claude Code ${CLAUDE_CODE_VERSION} installed."
        else
            echo "[claude-world] Claude Code ${CLAUDE_CODE_VERSION} already installed, skipping."
        fi
    fi
}

# ---- OpenAI Codex (only when AGENT=codex) ----
# Installed via npm (binary: codex). API-key auth only — no OAuth login headless.
# Pinned like Claude Code to prevent behavior changes between rebuilds.
CODEX_CLI_VERSION="${CODEX_VERSION:-0.160.1}"
install_codex() {
    if [ -d /config/.nvm ]; then
        INSTALLED_CODEX=$(su - "$USER" -c 'export HOME=/config && export NVM_DIR="/config/.nvm" && [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" && codex --version 2>/dev/null | grep -oE "[0-9]+\.[0-9]+\.[0-9]+" | head -1 || echo "none"')
        if [ "$CODEX_CLI_VERSION" = "latest" ]; then
            if ! su - "$USER" -c 'export HOME=/config && export NVM_DIR="/config/.nvm" && [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" && command -v codex >/dev/null 2>&1'; then
                echo "[claude-world] Installing Codex CLI latest (found: ${INSTALLED_CODEX})..."
                su - "$USER" -c 'export HOME=/config && export NVM_DIR="/config/.nvm" && [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" && npm install -g @openai/codex'
                echo "[claude-world] Codex CLI installed."
            else
                echo "[claude-world] Codex CLI already installed (${INSTALLED_CODEX}), skipping."
            fi
        else
            if [ "$INSTALLED_CODEX" != "$CODEX_CLI_VERSION" ]; then
                echo "[claude-world] Installing Codex CLI ${CODEX_CLI_VERSION} (found: ${INSTALLED_CODEX})..."
                su - "$USER" -c 'export HOME=/config && export NVM_DIR="/config/.nvm" && [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" && npm uninstall -g @openai/codex 2>/dev/null; rm -rf "$(dirname "$(npm root -g)")/lib/node_modules/@openai/codex" 2>/dev/null; npm cache clean --force 2>/dev/null; npm install -g @openai/codex@'"${CODEX_CLI_VERSION}"
                echo "[claude-world] Codex CLI ${CODEX_CLI_VERSION} installed."
            else
                echo "[claude-world] Codex CLI ${CODEX_CLI_VERSION} already installed, skipping."
            fi
        fi
    fi
}

# ---- Cline (only when AGENT=cline) ----
# Installed via npm (binary: cline). Headless BYOK via providers.json
# pre-seed below; `cline auth` remains available for OAuth/subscription
# providers. Per-run flags -P/--provider, -m/--model, -k/--key also work.
install_cline() {
    if [ -d /config/.nvm ]; then
        INSTALLED_CLINE=$(su - "$USER" -c 'export HOME=/config && export NVM_DIR="/config/.nvm" && [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" && cline --version 2>/dev/null | head -1 || echo "none"')
        if ! su - "$USER" -c 'export HOME=/config && export NVM_DIR="/config/.nvm" && [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" && command -v cline >/dev/null 2>&1'; then
            echo "[claude-world] Installing Cline CLI..."
            su - "$USER" -c 'export HOME=/config && export NVM_DIR="/config/.nvm" && [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" && npm install -g cline'
            echo "[claude-world] Cline CLI installed ($(su - "$USER" -c 'export HOME=/config && export NVM_DIR="/config/.nvm" && [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" && cline --version 2>/dev/null | head -1'))"
        else
            echo "[claude-world] Cline CLI already installed (${INSTALLED_CLINE}), skipping."
        fi
    fi
}

case "$AGENT" in
    claude) install_claude ;;
    codex) install_codex ;;
    cline) install_cline ;;
esac

# Disable Claude Code auto-updater (keep pinned version — remove when restoring latest)
# Harmless when AGENT=codex (kept for users switching back to claude).
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

# ---- Agent API & Session env vars (from Compose env) ----
# Written fresh on every boot — edit compose.yaml to change values.
# BYOK: per-agent keys win, generic AGENT_* vars are the fallback (resolved above).
for dsrcfile in /config/.bashrc /config/.zshrc; do
    sed -i '/^# >>> Agent CLI/,/^# <<< Agent CLI/d' "$dsrcfile" 2>/dev/null
    sed -i '/^# >>> Agent/,/^# <<< Agent/d' "$dsrcfile" 2>/dev/null
    sed -i '/^# >>> Claude Code/,/^# <<< Claude Code/d' "$dsrcfile" 2>/dev/null
    cat >> "$dsrcfile" << AGENTENV
# >>> Agent (set from Compose env — edit compose.yaml to change)
export AGENT=${AGENT:-claude}
export AGENT_BIN=${AGENT_BIN:-claude}
# Back-compat aliases
export AGENT_CLI=${AGENT:-claude}
export NO_AGENT=${NO_AGENT:-}
$( [ -n "${EFFECTIVE_ANTHROPIC_BASE_URL}" ] && echo "export ANTHROPIC_BASE_URL=${EFFECTIVE_ANTHROPIC_BASE_URL}" )
export ANTHROPIC_AUTH_TOKEN=${EFFECTIVE_ANTHROPIC_AUTH_TOKEN:-CHANGE_ME_ANTHROPIC_KEY}
export ANTHROPIC_MODEL=${ANTHROPIC_MODEL:-claude-opus-4-8}
export ANTHROPIC_DEFAULT_OPUS_MODEL=${ANTHROPIC_DEFAULT_OPUS_MODEL:-claude-opus-4-8}
export ANTHROPIC_DEFAULT_SONNET_MODEL=${ANTHROPIC_DEFAULT_SONNET_MODEL:-claude-sonnet-4-6}
export ANTHROPIC_DEFAULT_HAIKU_MODEL=${ANTHROPIC_DEFAULT_HAIKU_MODEL:-claude-haiku-4-5}
export CLAUDE_CODE_SUBAGENT_MODEL=${CLAUDE_CODE_SUBAGENT_MODEL:-claude-haiku-4-5}
export CLAUDE_CODE_EFFORT_LEVEL=${CLAUDE_CODE_EFFORT_LEVEL:-max}
export OPENAI_API_KEY=${EFFECTIVE_OPENAI_API_KEY:-}
export CODEX_MODEL=${EFFECTIVE_CODEX_MODEL:-}
export CLINE_API_KEY='${_CLINE_ESCAPED_KEY:-}'
export CLINE_PROVIDER=${EFFECTIVE_CLINE_PROVIDER:-anthropic}
export CLINE_MODEL=${EFFECTIVE_CLINE_MODEL:-}
${CLINE_STD_KEY_EXPORT:-}
export TMUX_AUTO=${TMUX_AUTO:-0}
export TMUX_TIMEOUT=${TMUX_TIMEOUT:--1}
export GITHUB_TOKEN=${GITHUB_TOKEN:-}
export GH_TOKEN=${GH_TOKEN:-${GITHUB_TOKEN}}
export AGENT_WEBHOOK_URL=${EFFECTIVE_WEBHOOK_URL:-}
export AGENT_WEBHOOK_IDLE=${EFFECTIVE_WEBHOOK_IDLE:-60}
export CLAUDE_WEBHOOK_URL=${EFFECTIVE_WEBHOOK_URL:-}
export CLAUDE_WEBHOOK_IDLE=${EFFECTIVE_WEBHOOK_IDLE:-60}
# <<< Agent
AGENTENV
done

# ---- Codex config (API-key auth + model) ----
# Codex reads ~/.codex/config.toml and authenticates via OPENAI_API_KEY.
# Written fresh on every boot when AGENT=codex — safe to re-run.
if [ "$AGENT" = "codex" ]; then
    if [ -n "$EFFECTIVE_OPENAI_API_KEY" ] && [ "$EFFECTIVE_OPENAI_API_KEY" != "CHANGE_ME_OPENAI_KEY" ]; then
        echo "[claude-world] Configuring Codex API key auth..."
        mkdir -p /config/.codex
        if [ -n "$EFFECTIVE_CODEX_MODEL" ]; then
            # Validate model string to prevent special characters in config
            if echo "$EFFECTIVE_CODEX_MODEL" | grep -qE '^[A-Za-z0-9._-]+$'; then
                printf 'model = "%s"\nmodel_provider = "openai"\n' "$EFFECTIVE_CODEX_MODEL" > /config/.codex/config.toml
                echo "[claude-world] Codex model set to '${EFFECTIVE_CODEX_MODEL}' in /config/.codex/config.toml"
            else
                echo "[claude-world] WARNING: CODEX_MODEL contains invalid characters — must match [A-Za-z0-9._-]+. Skipping model override."
                [ -f /config/.codex/config.toml ] || printf 'model_provider = "openai"\n' > /config/.codex/config.toml
            fi
        else
            # Ensure a config exists so Codex skips onboarding but keeps its default model.
            [ -f /config/.codex/config.toml ] || printf 'model_provider = "openai"\n' > /config/.codex/config.toml
        fi
        chown -R "$USER:$USER" /config/.codex
    else
        echo "[claude-world] WARNING: No OpenAI key found (OPENAI_API_KEY or AGENT_API_KEY) — Codex will prompt for auth on first run."
    fi
fi

# ---- Cline auth pre-seed (headless BYOK, only when AGENT=cline) ----
# Writes the configured provider(s) into /config/.cline/data/settings/providers.json:
#   providers.<id>.settings = {provider, apiKey, model?}, lastUsedProvider, tokenSource "manual".
# Shape confirmed from a real providers.json (v1, manual token source).
# Supports primary provider (CLINE_PROVIDER, CLINE_API_KEY, CLINE_MODEL)
# and indexed secondary providers (CLINE_PROVIDER_2, CLINE_API_KEY_2, CLINE_MODEL_2, ...).
# Compose environment variables take precedence on container boot: init.sh merges the
# configured provider(s) into providers.json and sets lastUsedProvider so changes in
# compose.yaml take effect immediately. Any other providers or settings configured
# via `cline auth` or the UI are preserved in the file.
if [ "$AGENT" = "cline" ]; then
    CLINE_SETTINGS_DIR="/config/.cline/data/settings"
    CLINE_PROVIDERS_PATH="${CLINE_SETTINGS_DIR}/providers.json"
    mkdir -p "$CLINE_SETTINGS_DIR"
    if python3 - "$CLINE_PROVIDERS_PATH" "${EFFECTIVE_CLINE_PROVIDER:-anthropic}" "${EFFECTIVE_CLINE_API_KEY:-}" "${EFFECTIVE_CLINE_MODEL:-}" << 'PYEOF'
import sys, json, os, re
from datetime import datetime, timezone

path = sys.argv[1]
primary_provider = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] else "anthropic"
primary_api_key = sys.argv[3] if len(sys.argv) > 3 else ""
primary_model = sys.argv[4] if len(sys.argv) > 4 else ""

configured_providers = []
if primary_api_key:
    configured_providers.append((primary_provider, primary_api_key, primary_model, True))

indices = set()
for k in os.environ:
    m = re.match(r"^CLINE_PROVIDER_([0-9]+)$", k)
    if m:
        indices.add(int(m.group(1)))
    m_key = re.match(r"^CLINE_API_KEY_([0-9]+)$", k)
    if m_key:
        indices.add(int(m_key.group(1)))

for idx in sorted(indices):
    prov = os.environ.get(f"CLINE_PROVIDER_{idx}", "").strip()
    key = os.environ.get(f"CLINE_API_KEY_{idx}", "").strip()
    model = os.environ.get(f"CLINE_MODEL_{idx}", "").strip()
    if prov and key:
        configured_providers.append((prov, key, model, False))

if not configured_providers:
    print("[claude-world] WARNING: No Cline key found (CLINE_API_KEY, AGENT_API_KEY, or CLINE_API_KEY_*) — run 'cline auth' on first login.")
    sys.exit(0)

try:
    with open(path) as f:
        data = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    data = {"version": 1, "modes": {}}

if not isinstance(data, dict):
    data = {"version": 1, "modes": {}}

data.setdefault("version", 1)
data.setdefault("modes", {})
providers = data.setdefault("providers", {})
if not isinstance(providers, dict):
    providers = {}
    data["providers"] = providers

now_iso = datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")
updated_names = []

for prov, key, model, is_primary in configured_providers:
    entry = providers.get(prov)
    if not isinstance(entry, dict):
        entry = {}
    settings = entry.get("settings")
    if not isinstance(settings, dict):
        settings = {}
    settings["provider"] = prov
    settings["apiKey"] = key
    if model:
        settings["model"] = model
    else:
        settings.pop("model", None)
    entry["settings"] = settings
    entry["updatedAt"] = now_iso
    entry["tokenSource"] = "manual"
    providers[prov] = entry
    if is_primary:
        data["lastUsedProvider"] = prov
    updated_names.append(prov)

if "lastUsedProvider" not in data and updated_names:
    data["lastUsedProvider"] = updated_names[0]

os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")

prov_list = ", ".join(updated_names)
default_prov = data.get("lastUsedProvider", "anthropic")
print(f"[claude-world] Cline providers.json updated ({len(updated_names)} provider(s): {prov_list}; default={default_prov})")
PYEOF
    then
        chown -R "$USER:$USER" /config/.cline
    else
        echo "[claude-world] WARNING: Failed to update Cline providers.json"
    fi
fi

# ---- Agent global instructions (injected into every session) ----
# Global instructions injected into every prompt/session.
# Written on first boot ONLY — edit the file to customize.
# To force regeneration, delete the file and restart the container.
# Destination depends on the selected agent:
#   claude → /config/.claude/CLAUDE.md
#   cline  → /config/.cline/rules/claude-world.md
#   codex  → /config/.codex/AGENTS.md
case "$AGENT" in
    claude) AGENT_INSTRUCTIONS="/config/.claude/CLAUDE.md" ;;
    cline)  AGENT_INSTRUCTIONS="/config/.cline/rules/claude-world.md" ;;
    codex)  AGENT_INSTRUCTIONS="/config/.codex/AGENTS.md" ;;
esac
if [ ! -f "$AGENT_INSTRUCTIONS" ]; then
    echo "[claude-world] Creating global instructions for '$AGENT' ($AGENT_INSTRUCTIONS)..."
    mkdir -p "$(dirname "$AGENT_INSTRUCTIONS")"
    cat > "$AGENT_INSTRUCTIONS" << 'CLAUDE_MD_EOF'
# Global Instructions — Claude World

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
    chown "$USER:$USER" "$AGENT_INSTRUCTIONS"
    echo "[claude-world] Global instructions created (edit $AGENT_INSTRUCTIONS to customize)"
else
    echo "[claude-world] Global instructions already exist ($AGENT_INSTRUCTIONS), skipping."
fi

# ---- Claude Code settings.json (only when AGENT=claude: permissions + autonomy) ----
# Written on first boot ONLY — edit /config/.claude/settings.json to customize.
# To force regeneration, delete the file and restart the container.
if [ "$AGENT" = "claude" ]; then
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
      "Bash(ulimit -u 0:*)",
      "Bash(> /dev/sda:*)",
      "Bash(dd if=* of=/dev/*)",
      "Bash(mkfs:*)",
      "Bash(gh repo delete:*)"
    ]
  },
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
CLAUDE_SETTINGS_EOF
    chown "$USER:$USER" "$CLAUDE_SETTINGS"
    echo "[claude-world] Claude Code permissions pre-approved (edit /config/.claude/settings.json to customize)"
else
    echo "[claude-world] Claude Code settings.json already exists, skipping."
fi

# ---- Ensure idle_prompt webhook hook is configured in settings.json ----
# Runs every boot (not just first) so existing installations get the hook too.
# Only for AGENT=claude (native idle_prompt hook). AGENT_* is canonical,
# CLAUDE_* kept as back-compat alias.
if [ "$AGENT" = "claude" ] && [ -n "$EFFECTIVE_WEBHOOK_URL" ] && [ "$EFFECTIVE_WEBHOOK_URL" != "CHANGE_ME_WEBHOOK_URL" ]; then
    echo "[claude-world] Configuring idle_prompt webhook hook..."
    python3 -c "
import json, os
settings_path = '/config/.claude/settings.json'
try:
    with open(settings_path) as f:
        settings = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    settings = {}

hooks = settings.setdefault('hooks', {})
notifications = hooks.setdefault('Notification', [])

# Check if idle_prompt with our webhook script already exists
has_idle_webhook = any(
    h.get('matcher') == 'idle_prompt' and
    any(c.get('command', '') == '/usr/local/bin/claude-idle-webhook.sh'
        for c in h.get('hooks', []))
    for h in notifications
)

if not has_idle_webhook:
    notifications.append({
        'matcher': 'idle_prompt',
        'hooks': [{
            'type': 'command',
            'command': '/usr/local/bin/claude-idle-webhook.sh'
        }]
    })
    with open(settings_path, 'w') as f:
        json.dump(settings, f, indent=2)
    print('[claude-world] idle_prompt webhook hook added to settings.json')
else:
    print('[claude-world] idle_prompt webhook hook already configured')
"
fi
fi # end AGENT=claude gate for settings.json + hook injection

# ---- Agent idle webhook sender ----
# Called by the idle_prompt Notification hook in settings.json (AGENT=claude).
# Reads session info from stdin (JSON from Claude Code hook system).
# AGENT_WEBHOOK_URL is canonical; CLAUDE_WEBHOOK_URL kept as back-compat alias.
cat > /usr/local/bin/claude-idle-webhook.sh << 'IDLEWEBHOOK'
#!/bin/bash
# ================================================================
# claude-idle-webhook.sh — Send webhook when the agent goes idle
# Called by Claude Code's idle_prompt Notification hook.
# Receives JSON on stdin: {session_id, transcript_path, cwd, ...}
# ================================================================

WEBHOOK_URL="${AGENT_WEBHOOK_URL:-${CLAUDE_WEBHOOK_URL:-}}"
[ -z "$WEBHOOK_URL" ] && exit 0
AGENT_NAME="${AGENT:-${AGENT_CLI:-claude}}"

# Read hook metadata from stdin (sent by Claude Code)
HOOK_DATA=$(cat 2>/dev/null)
SESSION_ID=$(echo "$HOOK_DATA" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('session_id',''))" 2>/dev/null)
TRANSCRIPT=$(echo "$HOOK_DATA" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('transcript_path',''))" 2>/dev/null)

# ---- Check if anyone is connected ----
# If tmux is running, use tmux list-clients (ttyd and tmux disconnects drop client count to 0).
# If tmux is not running (e.g. TMUX_AUTO=0), fall back to who for SSH sessions.
if tmux list-sessions >/dev/null 2>&1; then
    ACTIVE=$(tmux list-clients 2>/dev/null | wc -l)
else
    ACTIVE=$(who 2>/dev/null | wc -l)
fi
if [ "$ACTIVE" -gt 0 ]; then
    exit 0
fi

# ---- Extract last assistant message from transcript ----
LAST_OUTPUT=""
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
    LAST_OUTPUT=$(python3 -c "
import json, sys
try:
    with open('$TRANSCRIPT') as f:
        lines = f.readlines()
    # Find the last assistant message with text content
    for line in reversed(lines):
        try:
            msg = json.loads(line.strip())
            if msg.get('message',{}).get('role') == 'assistant':
                content = msg['message'].get('content', [])
                texts = []
                for block in content:
                    if block.get('type') == 'text':
                        texts.append(block.get('text', ''))
                if texts:
                    print(''.join(texts))
                    break
        except:
            continue
except:
    pass
" 2>/dev/null)
fi

# ---- Build and send webhook ----
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
HOST=$(hostname 2>/dev/null || echo "claude-world")

# Escape the last output for JSON
ESCAPED_OUTPUT=$(echo "$LAST_OUTPUT" | python3 -c "
import sys, json
print(json.dumps(sys.stdin.read()))
" 2>/dev/null)
# Guard against empty ESCAPED_OUTPUT (python3 missing/failed) to avoid malformed JSON
[ -z "$ESCAPED_OUTPUT" ] && ESCAPED_OUTPUT='""'

curl -s --connect-timeout 10 --max-time 30 \
    -X POST "$WEBHOOK_URL" \
    -H "Content-Type: application/json" \
    -d "{\"event\":\"${AGENT_NAME}_idle\",\"agent\":\"$AGENT_NAME\",\"timestamp\":\"$TS\",\"hostname\":\"$HOST\",\"session_id\":\"$SESSION_ID\",\"last_output\":$ESCAPED_OUTPUT}" \
    > /dev/null 2>&1 &

exit 0
IDLEWEBHOOK
chmod +x /usr/local/bin/claude-idle-webhook.sh
echo "[claude-world] Agent idle webhook sender created at /usr/local/bin/claude-idle-webhook.sh"

# ---- Generic agent idle watcher (AGENT != claude only) ----
# Fallback for agents without a native idle hook: watches the agent's tmux pane
# for output silence. When the pane is silent for AGENT_WEBHOOK_IDLE seconds and
# nobody is connected, sends one webhook per idle episode.
# Claude uses its own native idle_prompt hook — no watcher needed.
cat > /usr/local/bin/agent-idle-watcher.sh << 'AGENTWATCHER'
#!/bin/bash
# ================================================================
# agent-idle-watcher.sh — Generic idle webhook for non-Claude agents
# Usage: agent-idle-watcher.sh [poll_seconds]
# Env: AGENT, AGENT_BIN, AGENT_WEBHOOK_URL, AGENT_WEBHOOK_IDLE
# ================================================================

WEBHOOK_URL="${AGENT_WEBHOOK_URL:-${CLAUDE_WEBHOOK_URL:-}}"
[ -z "$WEBHOOK_URL" ] && exit 0
AGENT_NAME="${AGENT:-${AGENT_CLI:-claude}}"
AGENT_BINARY="${AGENT_BIN:-$AGENT_NAME}"
IDLE_SECS="${AGENT_WEBHOOK_IDLE:-${CLAUDE_WEBHOOK_IDLE:-60}}"
POLL="${1:-15}"
# Validate IDLE_SECS is numeric, default to 60 if not
case "$IDLE_SECS" in ''|*[!0-9]*) IDLE_SECS=60;; esac
# Never fire faster than 60s (matches Claude native hook timing).
[ "$IDLE_SECS" -lt 60 ] && IDLE_SECS=60

TMUX_SOCKET=""
find_tmux_socket() {
    if [ -n "$TMUX_SOCKET" ] && [ -S "$TMUX_SOCKET" ]; then
        return 0
    fi
    local sock
    sock=$(find /tmp -maxdepth 2 -name default -path '*/tmux-*' 2>/dev/null | head -n 1)
    if [ -n "$sock" ] && [ -S "$sock" ]; then
        TMUX_SOCKET="$sock"
        return 0
    fi
    return 1
}

tmux() {
    find_tmux_socket
    if [ -n "$TMUX_SOCKET" ]; then
        command tmux -S "$TMUX_SOCKET" "$@"
    else
        command tmux "$@"
    fi
}

declare -A LAST_HASH
declare -A LAST_CHANGE
declare -A NOTIFIED

hash_pane() {
    tmux capture-pane -p -t "$1" 2>/dev/null | tail -n 50 | md5sum | cut -d' ' -f1
}

# Check if a pane is running the agent binary (by foreground process)
pane_runs_agent() {
    local pane="$1"
    # Fast check: if the pane is at a plain shell prompt, agent is not running
    local cmd
    cmd=$(tmux display-message -p -t "$pane" '#{pane_current_command}' 2>/dev/null)
    case "$cmd" in bash|zsh|sh) return 1;; esac

    local tty
    tty=$(tmux display-message -p -t "$pane" '#{pane_tty}' 2>/dev/null)
    [ -z "$tty" ] && return 1
    local dev_tty="${tty#/dev/}"
    # Check both comm and args to detect direct binaries, scripts, or node-wrapped CLI tools
    ps -o comm=,args= -t "$dev_tty" 2>/dev/null | grep -qiE "(^|[ /])${AGENT_BINARY}([ -]|$)"
}

while true; do
    sleep "$POLL"
    # Use tmux list-clients instead of 'who' for accurate connection detection
    ACTIVE=$(tmux list-clients 2>/dev/null | wc -l)
    [ "$ACTIVE" -gt 0 ] && continue
    NOW=$(date +%s)
    while read -r pane; do
        # Only watch panes that are actually running the agent binary
        pane_runs_agent "$pane" || continue
        H=$(hash_pane "$pane")
        [ -z "$H" ] && continue
        if [ "${LAST_HASH[$pane]:-}" != "$H" ]; then
            LAST_HASH[$pane]="$H"
            LAST_CHANGE[$pane]="$NOW"
            NOTIFIED[$pane]=0
        else
            # On first discovery (no prior LAST_CHANGE), seed with NOW to avoid
            # instant-firing after a watcher restart on already-idle panes.
            if [ -z "${LAST_CHANGE[$pane]:-}" ]; then
                LAST_CHANGE[$pane]="$NOW"
                NOTIFIED[$pane]=0
                continue
            fi
            SINCE=$(( NOW - ${LAST_CHANGE[$pane]} ))
            if [ "$SINCE" -ge "$IDLE_SECS" ] && [ "${NOTIFIED[$pane]:-0}" != "1" ]; then
                NOTIFIED[$pane]=1
                OUTPUT=$(tmux capture-pane -p -t "$pane" 2>/dev/null | tail -n 50)
                ESCAPED=$(printf '%s' "$OUTPUT" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))" 2>/dev/null)
                # Guard against empty ESCAPED (python3 missing/failed)
                [ -z "$ESCAPED" ] && ESCAPED='""'
                TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
                HOST=$(hostname 2>/dev/null || echo "claude-world")
                echo "[agent-idle-watcher] Agent ${AGENT_NAME} in pane ${pane} is idle (${SINCE}s). Sending webhook..."
                HTTP_STATUS=$(curl -s -w "%{http_code}" -o /tmp/webhook-last-response.json --connect-timeout 10 --max-time 30 \
                    -X POST "$WEBHOOK_URL" \
                    -H "Content-Type: application/json" \
                    -d "{\"event\":\"${AGENT_NAME}_idle\",\"agent\":\"$AGENT_NAME\",\"timestamp\":\"$TS\",\"hostname\":\"$HOST\",\"session_id\":\"${AGENT_NAME}:${pane}\",\"last_output\":$ESCAPED}")
                echo "[agent-idle-watcher] Webhook dispatched to ${WEBHOOK_URL} (HTTP status: ${HTTP_STATUS})"
            fi
        fi
    done < <(tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null)
done
AGENTWATCHER
chmod +x /usr/local/bin/agent-idle-watcher.sh
echo "[claude-world] Generic agent idle watcher created at /usr/local/bin/agent-idle-watcher.sh"

# Start the generic watcher only for non-Claude agents (Claude uses its native hook).
if [ "$AGENT" != "claude" ] && [ -n "$EFFECTIVE_WEBHOOK_URL" ] && [ "$EFFECTIVE_WEBHOOK_URL" != "CHANGE_ME_WEBHOOK_URL" ]; then
    if ! pgrep -f "agent-idle-watcher" >/dev/null 2>&1; then
        echo "[claude-world] Starting generic agent idle watcher (idle=${EFFECTIVE_WEBHOOK_IDLE}s)..."
        nohup /usr/local/bin/agent-idle-watcher.sh > /var/log/agent-idle-watcher.log 2>&1 &
    fi
fi

# ---- cleanup-merged skill (path depends on AGENT) ----
# Agent Skills standard: a folder containing SKILL.md (name + description).
# Written on first boot ONLY — edit SKILL.md to customize.
# To force regeneration, delete the folder and restart the container.
# Destination depends on the selected agent:
#   claude → /config/.claude/skills/cleanup-merged/SKILL.md
#   cline  → /config/.cline/skills/cleanup-merged/SKILL.md
#   codex  → /config/.codex/skills/cleanup-merged/SKILL.md
case "$AGENT" in
    claude) CLEANUP_SKILL_DIR="/config/.claude/skills/cleanup-merged" ;;
    cline)  CLEANUP_SKILL_DIR="/config/.cline/skills/cleanup-merged" ;;
    codex)  CLEANUP_SKILL_DIR="/config/.codex/skills/cleanup-merged" ;;
esac
CLEANUP_SKILL="$CLEANUP_SKILL_DIR/SKILL.md"

# Migrate the legacy flat-file layout (skills/cleanup-merged.md) if present
LEGACY_CLEANUP_SKILL="${CLEANUP_SKILL_DIR%/*}/cleanup-merged.md"
if [ -f "$LEGACY_CLEANUP_SKILL" ] && [ ! -f "$CLEANUP_SKILL" ]; then
    echo "[claude-world] Migrating legacy cleanup-merged.md to SKILL.md layout..."
    mkdir -p "$CLEANUP_SKILL_DIR"
    mv "$LEGACY_CLEANUP_SKILL" "$CLEANUP_SKILL"
fi

if [ ! -f "$CLEANUP_SKILL" ]; then
    echo "[claude-world] Creating cleanup-merged skill for '$AGENT'..."
    mkdir -p "$CLEANUP_SKILL_DIR"
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
    chown -R "$USER:$USER" "$CLEANUP_SKILL_DIR"
    echo "[claude-world] cleanup-merged skill created (edit $CLEANUP_SKILL to customize)"
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

# ---- Auto-launch: cd + tmux + agent ----
# Written fresh on every boot (marker-based, same pattern as agent env block).
# Order: cd /workplace → tmux (if requested) → agent binary.
#   - [ -z "$TMUX" ] prevents tmux-inside-tmux recursion.
#   - `$AGENT_BIN` (not `exec`) so exiting the agent returns to a shell prompt.
#   - NO_AGENT=1 skips auto-launch (NO_CLAUDE=1 kept as back-compat alias).
for rcfile in /config/.bashrc /config/.zshrc; do
    # Clean up legacy add_line entries from older init.sh versions
    sed -i '/^cd \/workplace$/d' "$rcfile" 2>/dev/null
    sed -i '/if \[ -z "\$NO_CLAUDE" \]; then exec claude/d' "$rcfile" 2>/dev/null
    sed -i '/TMUX_AUTO.*exec tmux new/d' "$rcfile" 2>/dev/null

    # Remove old marker block, then rewrite
    sed -i '/^# >>> Claude World Auto-Launch/,/^# <<< Claude World Auto-Launch/d' "$rcfile" 2>/dev/null
    cat >> "$rcfile" << 'AUTOLAUNCH'
# >>> Claude World Auto-Launch (written by init.sh — do not edit)
# Only run in an interactive shell with an attached terminal (skips subshells, scripts, and background helpers)
case "$-" in
    *i*) ;;
    *) return 0 2>/dev/null || exit 0 ;;
esac
if [ -n "$BASH_EXECUTION_STRING" ] || [ ! -t 0 ] || [ ! -t 1 ]; then
    return 0 2>/dev/null || exit 0
fi

# Clean up forwarded/stale tmux sockets from SSH client forwarding
if [ -n "$TMUX" ] && [ ! -S "$(echo "$TMUX" | cut -d, -f1)" ]; then
    unset TMUX
fi

cd /workplace
if [ "$TMUX_AUTO" = "1" ] && [ -z "$TMUX" ]; then
    exec tmux new-session -A -s main
fi
if [ -z "$NO_AGENT" ] && [ -z "$NO_CLAUDE" ]; then
    __AGENT_BIN__
fi
# <<< Claude World Auto-Launch
AUTOLAUNCH
    # Inject the selected agent binary (AGENT_BIN is resolved at boot time)
    sed -i "s/__AGENT_BIN__/${AGENT_BIN:-claude}/" "$rcfile"
done

# ---- Cline connector: Telegram bridge (AGENT=cline only) ----
# When CLINE_TELEGRAM_TOKEN is set in compose.yaml, start the hub daemon and
# bring the Telegram connector up on every boot. The registration itself lives
# in the hub DB (/config/.cline/data/db/connectors.db), so it survives rebuilds:
# this block only has to re-attach the connector after a restart.
# Empty token (or CHANGE_ME_*) disables the feature.
_EFFECTIVE_TELEGRAM_TOKEN="${CLINE_TELEGRAM_TOKEN:-${TELEGRAM_BOT_TOKEN:-}}"
case "$_EFFECTIVE_TELEGRAM_TOKEN" in
    ""|CHANGE_ME_*) _EFFECTIVE_TELEGRAM_TOKEN="" ;;
esac
TELEGRAM_STATE="/config/.cline/.telegram-connector.state"

if [ "$AGENT" = "cline" ]; then
if [ -n "$_EFFECTIVE_TELEGRAM_TOKEN" ]; then
    TELEGRAM_CWD="${CLINE_TELEGRAM_CWD:-/workplace}"
    TELEGRAM_TOOLS="${CLINE_TELEGRAM_TOOLS:-on}"

    # Helper: bring up hub + connector as the container user. Kept out of the
    # init process so it can run detached and log on its own.
    cat > /usr/local/bin/cline-telegram-start.sh << 'TELEGRAMSTART'
#!/bin/bash
# ================================================================
# cline-telegram-start.sh — bring up the Cline hub + Telegram connector
# Runs as the container user (HOME=/config) so it shares the CLI state
# (providers.json, hub DB) written by init.sh.
# Env: CLINE_TELEGRAM_TOKEN, CLINE_TELEGRAM_ALLOWED_USER_ID,
#      CLINE_TELEGRAM_BOT_USERNAME, CLINE_TELEGRAM_CWD, CLINE_TELEGRAM_TOOLS
# ================================================================
set -u

export HOME=/config
export NVM_DIR="/config/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
export PATH="/config/.npm-global/bin:$PATH"

LOG="/config/cline-telegram.log"
touch "$LOG" 2>/dev/null || LOG="/tmp/cline-telegram.log"
STATE="/config/.cline/.telegram-connector.state"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >> "$LOG"; }

TOKEN="${CLINE_TELEGRAM_TOKEN:-}"
if [ -z "$TOKEN" ]; then
    log "no CLINE_TELEGRAM_TOKEN set, skipping"
    exit 0
fi
if ! command -v cline >/dev/null 2>&1; then
    log "cline binary not found on PATH, skipping"
    exit 0
fi

# Connector arguments. NOTE: no -i, so the connector detaches and the hub
# supervises/restarts it. Sessions run in CLINE_TELEGRAM_CWD (default /workplace).
ARGS=(telegram -k "$TOKEN")
[ -n "${CLINE_TELEGRAM_BOT_USERNAME:-}" ] && ARGS+=(-m "$CLINE_TELEGRAM_BOT_USERNAME")
[ -n "${CLINE_TELEGRAM_ALLOWED_USER_ID:-}" ] && ARGS+=(--allowed-user-id "$CLINE_TELEGRAM_ALLOWED_USER_ID")
ARGS+=(--cwd "${CLINE_TELEGRAM_CWD:-/workplace}")
case "${CLINE_TELEGRAM_TOOLS:-on}" in
    off|false|0) ARGS+=(--no-tools) ;;
esac

# 1. Ensure the hub daemon is running (it owns and supervises connectors)
log "starting hub daemon"
cline hub start >> "$LOG" 2>&1 || true
sleep 2

# 2. Register on first boot, re-attach (restart) on later boots
if [ -f "$STATE" ]; then
    log "re-attaching telegram connector (--restart)"
    cline connect --restart "${ARGS[@]}" >> "$LOG" 2>&1 || log "restart failed"
else
    log "registering telegram connector (first run)"
    if cline connect "${ARGS[@]}" >> "$LOG" 2>&1; then
        touch "$STATE" 2>/dev/null || true
    else
        log "connect failed"
    fi
fi

log "telegram connector launch finished"
TELEGRAMSTART
    chmod +x /usr/local/bin/cline-telegram-start.sh

    # Escape values for single-quoted embedding in the su command below.
    # Inside single quotes everything is literal, so only ' needs escaping.
    _tg_esc() { printf '%s' "$1" | sed "s/'/'\\\\''/g"; }
    _TG_TOKEN="$(_tg_esc "$_EFFECTIVE_TELEGRAM_TOKEN")"
    _TG_USER="$(_tg_esc "${CLINE_TELEGRAM_ALLOWED_USER_ID:-}")"
    _TG_BOT="$(_tg_esc "${CLINE_TELEGRAM_BOT_USERNAME:-}")"
    _TG_CWD="$(_tg_esc "$TELEGRAM_CWD")"
    _TG_TOOLS="$(_tg_esc "$TELEGRAM_TOOLS")"

    # Launch in the background as the container user (mirrors the ttyd pattern)
    su - "$USER" -c "export HOME=/config && export CLINE_TELEGRAM_TOKEN='${_TG_TOKEN}' && export CLINE_TELEGRAM_ALLOWED_USER_ID='${_TG_USER}' && export CLINE_TELEGRAM_BOT_USERNAME='${_TG_BOT}' && export CLINE_TELEGRAM_CWD='${_TG_CWD}' && export CLINE_TELEGRAM_TOOLS='${_TG_TOOLS}' && nohup /usr/local/bin/cline-telegram-start.sh > /dev/null 2>&1 &"

    if [ -n "${CLINE_TELEGRAM_ALLOWED_USER_ID:-}" ]; then
        echo "[claude-world] Telegram connector: enabled (allowed user ${CLINE_TELEGRAM_ALLOWED_USER_ID}, cwd ${TELEGRAM_CWD})"
    else
        echo "[claude-world] WARNING: Telegram connector enabled with NO allowed user id — anyone who finds the bot can drive the agent. Set CLINE_TELEGRAM_ALLOWED_USER_ID in compose.yaml."
    fi
elif [ -f "$TELEGRAM_STATE" ]; then
    # Token removed from compose.yaml → disable the previously enabled connector
    echo "[claude-world] Telegram connector: token removed — disabling."
    su - "$USER" -c "export HOME=/config && export NVM_DIR=/config/.nvm && [ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\" && cline hub start >/dev/null 2>&1; cline connect --stop telegram" >> /config/cline-telegram.log 2>&1 || true
    rm -f "$TELEGRAM_STATE"
else
    echo "[claude-world] Telegram connector: disabled (set CLINE_TELEGRAM_TOKEN in compose.yaml to enable)."
fi
fi # end AGENT=cline gate for the Telegram connector

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

# ---- Fix ownership and SSH permissions ----
chown -R "$USER:$USER" /config
chmod 755 /config
if [ -d /config/.ssh ]; then
    chmod 700 /config/.ssh
    [ -f /config/.ssh/authorized_keys ] && chmod 600 /config/.ssh/authorized_keys
fi

# ---- Workplace: allow mkdir at root (mount owned by PUID, user may differ) ----
if [ -d /workplace ]; then
    chown "$USER:$USER" /workplace
    chmod 755 /workplace
fi

echo "[claude-world] Init complete. SSH is running as '$USER'. ttyd on :7681. nvm, Node, $AGENT_BIN are ready."
