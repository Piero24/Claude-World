#!/bin/bash
# ================================================================
# Claude World — Interactive Installer
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/Piero24/Claude-World/main/install.sh | bash
# ================================================================
set -e

GITHUB_RAW="https://raw.githubusercontent.com/Piero24/Claude-World/main"
DEFAULT_PATH="/DATA/AppData/claude-world"

echo ""
echo "  ╔════════════════════════════════════════════════╗"
echo "  ║         Claude World — Installer               ║"
echo "  ╚════════════════════════════════════════════════╝"
echo ""

# ---- Ask for base path with confirmation loop ----
while true; do
    echo "Where should Claude World store its data?"
    echo "(Code, configs, and shell settings will live here)"
    echo ""
    read -p "Base path [$DEFAULT_PATH]: " BASE_PATH < /dev/tty
    BASE_PATH="${BASE_PATH:-$DEFAULT_PATH}"

    echo ""
    read -p "Confirm path '$BASE_PATH'? [y/N]: " CONFIRM < /dev/tty
    case "$CONFIRM" in
        [yY]|[yY][eE][sS])
            break
            ;;
        [nN]|[nN][oO]|"")
            echo ""
            echo "Let's try a different path..."
            echo ""
            ;;
        *)
            echo ""
            echo "Please answer y (yes) or n (no)."
            echo ""
            ;;
    esac
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Base path: $BASE_PATH"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ---- Ask which agent to use ----
echo "Which coding agent should the container install and auto-launch?"
echo "  1) claude  (Anthropic Claude Code — default)"
echo "  2) codex   (OpenAI Codex CLI)"
echo ""
AGENT_CHOICE="claude"
read -p "Agent [1]: " AGENT_NUM < /dev/tty
case "$AGENT_NUM" in
    2|[cC][oO][dD][eE][xX]) AGENT_CHOICE="codex" ;;
    ""|1|[cC][lL][aA][uU][dD][eE]) AGENT_CHOICE="claude" ;;
    *)
        echo "Unknown option '$AGENT_NUM' — using 'claude'."
        AGENT_CHOICE="claude"
        ;;
esac
echo "  Agent: $AGENT_CHOICE"
echo ""

# ---- Create directories ----
echo "[1/3] Creating directories..."
mkdir -p "$BASE_PATH"/{config,workplace}
echo "      ✓ $BASE_PATH/config"
echo "      ✓ $BASE_PATH/workplace"

# ---- Download init script ----
echo ""
echo "[2/3] Downloading container init script..."
curl -fsSL "$GITHUB_RAW/init.sh" -o "$BASE_PATH/init.sh"
chmod +x "$BASE_PATH/init.sh"
echo "      ✓ init.sh → $BASE_PATH/init.sh"

# ---- Download compose-casaos.yaml ----
echo ""
echo "[3/3] Downloading CasaOS Compose file..."
curl -fsSL "$GITHUB_RAW/compose-casaos.yaml" -o "$BASE_PATH/compose-casaos.yaml"
echo "      ✓ compose-casaos.yaml → $BASE_PATH/compose-casaos.yaml"

# ---- Apply agent choice (portable sed: works on GNU + BSD/macOS) ----
if [ "$AGENT_CHOICE" != "claude" ]; then
    sed -i.bak "s/^[ ]*AGENT:.*/      AGENT: $AGENT_CHOICE/" "$BASE_PATH/compose-casaos.yaml"
    rm -f "$BASE_PATH/compose-casaos.yaml.bak"
    echo "      ✓ AGENT set to '$AGENT_CHOICE' in compose-casaos.yaml"
fi

# ---- Done ----
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Installation complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Next steps:"
echo ""
echo "  1. Edit the values in the compose file:"
echo "     nano $BASE_PATH/compose-casaos.yaml"
echo ""
echo "     Replace (under the dev service):"
echo "       CHANGE_ME_WEB_PASSWORD   → your ttyd login password"
echo "       CHANGE_ME_SUDO_PASSWORD  → your sudo/SSH password"
if [ "$AGENT_CHOICE" = "codex" ]; then
echo "       OPENAI_API_KEY (or AGENT_API_KEY) → your OpenAI API key"
else
echo "       CHANGE_ME_ANTHROPIC_KEY  → your Anthropic API key"
fi
echo "       CHANGE_ME_GIT_NAME       → your Git name"
echo "       CHANGE_ME_GIT_EMAIL      → your Git email"
echo "       CHANGE_ME_GITHUB_TOKEN   → your GitHub fine-grained PAT"
echo ""
echo "  2. Import into CasaOS:"
echo "     App Store → Custom Install → Import"
echo "     Paste the content of $BASE_PATH/compose-casaos.yaml"
echo ""
echo "  3. Access your terminal:"
echo "     http://<your-server>:7681 → web terminal"
echo "     ssh abc@<your-server> -p 2222 → SSH"
echo ""
