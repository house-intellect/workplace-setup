#!/bin/bash
set -e

STACK_DIR="$HOME/local-ai-stack"
PROXY_DIR="$STACK_DIR/gemini-openai-proxy"
SMOL_DIR="$STACK_DIR/tool-calling-test"
PROXY_PORT=8085
PATCH_PATH="$HOME/.gemini-proxy-patch.js"
SKILL_DIR="$HOME/.agents/skills/agentic-browser"

echo "=== Smolagent & Skills One-Click Setup & Launcher ==="

# 1. System Dependency Checks
echo "[1/5] Checking system dependencies..."
for cmd in node npm python3 git nc; do
    if ! command -v $cmd &>/dev/null; then
        echo "Error: Required command '$cmd' is not installed."
        echo "Please install it using your package manager (e.g. sudo apt install $cmd)."
        exit 1
    fi
done

if ! command -v yandex-browser &>/dev/null && ! command -v yandex-browser-stable &>/dev/null && ! command -v google-chrome &>/dev/null; then
    echo "Warning: Neither Yandex Browser nor Google Chrome was found."
fi

# 2. Check/Install Proxy
echo "[2/5] Ensuring gemini-openai-proxy is set up..."
mkdir -p "$STACK_DIR"

if [ ! -d "$PROXY_DIR" ]; then
    echo "Cloning gemini-openai-proxy..."
    git clone https://github.com/zilliztech/gemini-openai-proxy.git "$PROXY_DIR" || {
        echo "Failed to clone proxy repo. Creating proxy directory structure..."
        mkdir -p "$PROXY_DIR"
    }
fi

if [ -f "$PROXY_DIR/package.json" ]; then
    if [ ! -d "$PROXY_DIR/node_modules" ]; then
        echo "Installing node dependencies for proxy..."
        (cd "$PROXY_DIR" && npm install)
    fi
fi

# Ensure proxy patch exists
if [ ! -f "$PATCH_PATH" ]; then
    echo "Creating proxy patch $PATCH_PATH..."
    cat << 'PATCH_EOF' > "$PATCH_PATH"
const http = require('http');
const originalRequest = http.request;
http.request = function(options, callback) {
    if (options && (options.host === '127.0.0.1' || options.hostname === '127.0.0.1' || options.host === 'localhost' || options.hostname === 'localhost')) {
        delete options.agent;
    }
    return originalRequest.call(this, options, callback);
};
PATCH_EOF
fi

# 3. Check/Install agentic-browser skill dependencies
echo "[3/5] Checking agentic-browser skill..."
mkdir -p "$SKILL_DIR"
if [ -d "$SCRIPT_DIR/agentic-browser" ]; then
    cp -r "$SCRIPT_DIR/agentic-browser/"* "$SKILL_DIR/"
fi

if [ ! -d "$SKILL_DIR/node_modules" ]; then
    echo "Installing puppeteer for agentic-browser skill..."
    (cd "$SKILL_DIR" && npm init -y >/dev/null 2>&1 || true)
    (cd "$SKILL_DIR" && npm install puppeteer --no-audit --no-fund)
fi

# Ensure agent.sh exists in $HOME
if [ -f "$SCRIPT_DIR/agent.sh" ]; then
    cp "$SCRIPT_DIR/agent.sh" "$HOME/agent.sh"
    chmod +x "$HOME/agent.sh"
fi

# 4. Virtual Environment Detection & Reuse Algorithm for Smolagent
echo "[4/5] Setting up Smolagent Python environment..."
VENV_DIR=""
SEARCH_CURR="$SMOL_DIR"

while [ "$SEARCH_CURR" != "/" ] && [ "$SEARCH_CURR" != "$HOME" ]; do
    if [ -d "$SEARCH_CURR/.venv" ]; then
        VENV_DIR="$SEARCH_CURR/.venv"
        break
    fi
    SEARCH_CURR="$(dirname "$SEARCH_CURR")"
done

if [ -z "$VENV_DIR" ] && [ -d "$STACK_DIR/.venv" ]; then
    VENV_DIR="$STACK_DIR/.venv"
elif [ -z "$VENV_DIR" ] && [ -d "$HOME/.venv" ]; then
    VENV_DIR="$HOME/.venv"
fi

if [ -n "$VENV_DIR" ]; then
    echo "Found existing Python virtual environment at: $VENV_DIR"
else
    VENV_DIR="$SMOL_DIR/.venv"
    echo "Creating new Python virtual environment at: $VENV_DIR"
    python3 -m venv "$VENV_DIR"
fi

# Ensure required Python libraries in venv
if ! "$VENV_DIR/bin/python" -c "import smolagents, PIL" 2>/dev/null; then
    echo "Installing smolagents dependencies in $VENV_DIR..."
    "$VENV_DIR/bin/pip" install --upgrade pip
    "$VENV_DIR/bin/pip" install smolagents pillow pydantic requests
fi

# 5. Start Proxy if not running
echo "[5/5] Ensuring gemini-openai-proxy is running on port $PROXY_PORT..."
if ! nc -z localhost $PROXY_PORT 2>/dev/null; then
    echo "Starting proxy..."
    (cd "$PROXY_DIR" && nohup env PORT=$PROXY_PORT NODE_OPTIONS="-r $PATCH_PATH" npm start > proxy_access.log 2>&1 &)
    
    for i in {1..10}; do
        if nc -z localhost $PROXY_PORT 2>/dev/null; then
            echo "Proxy is up and running!"
            break
        fi
        sleep 1
    done
else
    echo "Proxy is active on port $PROXY_PORT."
fi

echo ""
echo "=== Setup Complete! Launching Agent... ==="
echo ""

AGENT_BIN="$HOME/agent.sh"
if [ ! -f "$AGENT_BIN" ]; then
    AGENT_BIN="$SCRIPT_DIR/agent.sh"
fi

exec "$AGENT_BIN" "$@"
