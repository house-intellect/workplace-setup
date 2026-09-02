#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${1:-$SCRIPT_DIR/open-webui}"

echo "=== Open WebUI Auto-Installer & Tool Sync ==="

# 1. Deploy agentic-browser skill to home directory
echo "[1/4] Deploying agentic-browser skill..."
mkdir -p "$HOME/.agents/skills/agentic-browser"
if [ -d "$SCRIPT_DIR/agentic-browser" ]; then
    cp -r "$SCRIPT_DIR/agentic-browser/"* "$HOME/.agents/skills/agentic-browser/"
fi

if [ -f "$HOME/.agents/skills/agentic-browser/package.json" ]; then
    if [ ! -d "$HOME/.agents/skills/agentic-browser/node_modules" ]; then
        echo "Installing puppeteer dependencies for agentic-browser skill..."
        (cd "$HOME/.agents/skills/agentic-browser" && npm install --no-audit --no-fund)
    fi
fi

# 2. Download Open WebUI if not present
if [ ! -d "$TARGET_DIR" ]; then
    echo "Open WebUI not found in $TARGET_DIR. Cloning official repository..."
    git clone https://github.com/open-webui/open-webui.git "$TARGET_DIR"
fi

# 2. Virtual Environment Detection & Open WebUI Package Installation
VENV_DIR=""
SEARCH_CURR="$TARGET_DIR"

while [ "$SEARCH_CURR" != "/" ] && [ "$SEARCH_CURR" != "$HOME" ]; do
    if [ -d "$SEARCH_CURR/.venv" ]; then
        VENV_DIR="$SEARCH_CURR/.venv"
        break
    fi
    SEARCH_CURR="$(dirname "$SEARCH_CURR")"
done

if [ -z "$VENV_DIR" ] && [ -d "$HOME/.venv" ]; then
    VENV_DIR="$HOME/.venv"
fi

# Find best Python version for Open WebUI (Requires >=3.11)
PY_CMD=""
for p in python3.12 python3.11 python3; do
    if command -v "$p" &>/dev/null; then
        VER=$("$p" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
        MAJOR=$(echo "$VER" | cut -d. -f1)
        MINOR=$(echo "$VER" | cut -d. -f2)
        if [ "$MAJOR" -eq 3 ] && [ "$MINOR" -ge 11 ] && [ "$MINOR" -le 12 ]; then
            PY_CMD="$p"
            break
        fi
    fi
done

if [ -z "$PY_CMD" ]; then
    PY_CMD="python3"
fi

if [ -n "$VENV_DIR" ] && [ -f "$VENV_DIR/bin/python" ]; then
    echo "Found existing Python virtual environment at: $VENV_DIR"
else
    VENV_DIR="$TARGET_DIR/.venv"
    echo "Creating new Python virtual environment at: $VENV_DIR using $PY_CMD..."
    "$PY_CMD" -m venv "$VENV_DIR"
fi

# 3. Ensure Gemini-FastAPI Bridge & Custom DNS (dns.comss.one) are Present
FASTAPI_DIR="$(dirname "$TARGET_DIR")/gemini-fastapi"
SMOL_DIR="$(dirname "$TARGET_DIR")/tool-calling-test"

if [ -d "$FASTAPI_DIR" ] && [ -f "$FASTAPI_DIR/app/services/pool.py" ]; then
    if ! grep -q "dns.comss.one" "$FASTAPI_DIR/app/services/pool.py"; then
        echo "Configuring custom DNS (dns.comss.one) in Gemini-FastAPI..."
        sed -i 's/client = GeminiClientWrapper(/curl_opts = {CurlOpt.DOH_URL: b"https:\/\/dns.comss.one\/dns-query"} if "CurlOpt" in dir() else {}\n            client = GeminiClientWrapper(\n                curl_options=curl_opts,/g' "$FASTAPI_DIR/app/services/pool.py" 2>/dev/null || true
    fi
fi

# 4. Detect All Open WebUI webui.db Databases
FOUND_DBS=()

for db_pattern in \
    "$VENV_DIR"/lib/python*/site-packages/open_webui/data/webui.db \
    "$TARGET_DIR"/.venv/lib/python*/site-packages/open_webui/data/webui.db \
    "$HOME"/local-ai-stack/open-webui/.venv/lib/python*/site-packages/open_webui/data/webui.db \
    "$TARGET_DIR"/backend/data/webui.db \
    "$HOME"/.open-webui/data/webui.db; do
    for f in $db_pattern; do
        if [ -f "$f" ]; then
            FOUND_DBS+=("$f")
        fi
    done
done

if [ ${#FOUND_DBS[@]} -eq 0 ]; then
    DEFAULT_DB="$TARGET_DIR/backend/data/webui.db"
    mkdir -p "$(dirname "$DEFAULT_DB")"
    FOUND_DBS+=("$DEFAULT_DB")
fi

# Detect Ollama presence on system
OLLAMA_PRESENT="false"
if command -v ollama &>/dev/null; then
    OLLAMA_PRESENT="true"
    echo "Ollama detected on system: will keep Ollama integration enabled."
else
    echo "Ollama not detected on system: disabling Ollama in Open WebUI config to avoid connection errors."
fi

for DB_PATH in "${FOUND_DBS[@]}"; do
    echo "Syncing tools, configs, and models into: $DB_PATH"
    "$VENV_DIR/bin/python" - "$DB_PATH" "$OLLAMA_PRESENT" << 'PY_EOF'
import sqlite3
import json
import os
import sys

db_path = sys.argv[1]
ollama_present = sys.argv[2] == "true"
conn = sqlite3.connect(db_path)
cursor = conn.cursor()

# Ensure tables exist if fresh installation
cursor.execute("""
CREATE TABLE IF NOT EXISTS tool (
    id TEXT PRIMARY KEY,
    user_id TEXT,
    name TEXT,
    content TEXT,
    specs TEXT,
    meta TEXT,
    valves TEXT,
    updated_at INTEGER,
    created_at INTEGER
)
""")
cursor.execute("""
CREATE TABLE IF NOT EXISTS config (
    key TEXT PRIMARY KEY,
    value TEXT,
    updated_at INTEGER
)
""")

bash_content = '''"""
title: Native Bash Tool
author: Local AI Stack
version: 1.1.0
description: Real Bash terminal execution tool supporting piping, sequencing, redirects, and multiline scripts
"""

import subprocess

class Tools:
    def __init__(self):
        pass

    async def bash_tool(self, command: str) -> str:
        try:
            result = subprocess.run(
                command,
                shell=True,
                executable="/bin/bash",
                capture_output=True,
                text=True,
                timeout=120
            )
            output = result.stdout
            if result.stderr:
                output = output + chr(10) + result.stderr
            if output and output.strip():
                return output
            return f"Command executed successfully with return code {result.returncode} and no output."
        except subprocess.TimeoutExpired:
            return "Command timed out after 120 seconds."
        except Exception as e:
            return str(e)
'''

bash_specs = [{
    "name": "bash_tool",
    "description": "Execute any command or script in a full Bash terminal environment. Fully supports command piping (|), redirection (>, >>), chaining (&&, ||, ;), background jobs, subshells, environment variables, and multiline shell scripts.",
    "parameters": {
        "type": "object",
        "properties": {
            "command": {
                "type": "string",
                "description": "The bash command line or multiline script to execute in /bin/bash."
            }
        },
        "required": ["command"]
    }
}]

browser_content = '''"""
title: Agentic Browser Tool
author: Local AI Stack
version: 1.0.0
description: Autonomous semantic browser navigation tool using Puppeteer on port 9222
"""

import subprocess

class Tools:
    def __init__(self):
        pass

    async def agentic_browser(self, action: str, target: str = "", value: str = "") -> str:
        try:
            cmd = ["node", "/home/grapeonwheels/.agents/skills/agentic-browser/scripts/agent.js", action]
            if target:
                cmd.append(target)
            if value:
                cmd.append(value)

            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=30
            )
            output = result.stdout
            if result.stderr:
                output = output + chr(10) + result.stderr
            if output and output.strip():
                return output
            return "Browser action completed with no output."
        except Exception as e:
            return str(e)
'''

browser_specs = [{
    "name": "agentic_browser",
    "description": "Interact with the browser autonomously using semantic mapping.",
    "parameters": {
        "type": "object",
        "properties": {
            "action": {
                "type": "string",
                "description": "Action to perform: map, click, input, goto, screenshot"
            },
            "target": {
                "type": "string",
                "description": "Target element text, placeholder, or URL"
            },
            "value": {
                "type": "string",
                "description": "Text value to enter for input action"
            }
        },
        "required": ["action"]
    }
}]

cursor.execute("""
    INSERT INTO tool (id, user_id, name, content, specs, meta, updated_at, created_at)
    VALUES ('native_bash_tool', 'system', 'Native Bash Tool', ?, ?, '{}', strftime('%s', 'now'), strftime('%s', 'now'))
    ON CONFLICT(id) DO UPDATE SET
        content=excluded.content,
        specs=excluded.specs,
        updated_at=strftime('%s', 'now')
""", (bash_content, json.dumps(bash_specs)))

cursor.execute("""
    INSERT INTO tool (id, user_id, name, content, specs, meta, updated_at, created_at)
    VALUES ('agentic_browser_tool', 'system', 'Agentic Browser Tool', ?, ?, '{}', strftime('%s', 'now'), strftime('%s', 'now'))
    ON CONFLICT(id) DO UPDATE SET
        content=excluded.content,
        specs=excluded.specs,
        updated_at=strftime('%s', 'now')
""", (browser_content, json.dumps(browser_specs)))

# Configure Open WebUI endpoint and default model to Gemini-FastAPI
try:
    if ollama_present:
        cursor.execute("""
            INSERT INTO config (key, value, updated_at)
            VALUES ('ollama.enable', 'true', strftime('%s', 'now'))
            ON CONFLICT(key) DO UPDATE SET value='true', updated_at=strftime('%s', 'now')
        """)
    else:
        cursor.execute("""
            INSERT INTO config (key, value, updated_at)
            VALUES ('ollama.enable', 'false', strftime('%s', 'now'))
            ON CONFLICT(key) DO UPDATE SET value='false', updated_at=strftime('%s', 'now')
        """)

    cursor.execute("""
        INSERT INTO config (key, value, updated_at)
        VALUES ('openai.enable', 'true', strftime('%s', 'now'))
        ON CONFLICT(key) DO UPDATE SET value='true', updated_at=strftime('%s', 'now')
    """)
    cursor.execute("""
        INSERT INTO config (key, value, updated_at)
        VALUES ('openai.api_base_urls', '["http://localhost:8000/v1"]', strftime('%s', 'now'))
        ON CONFLICT(key) DO UPDATE SET value='["http://localhost:8000/v1"]', updated_at=strftime('%s', 'now')
    """)
    cursor.execute("""
        INSERT INTO config (key, value, updated_at)
        VALUES ('openai.api_keys', '["not-needed"]', strftime('%s', 'now'))
        ON CONFLICT(key) DO UPDATE SET value='["not-needed"]', updated_at=strftime('%s', 'now')
    """)
    cursor.execute("""
        INSERT INTO config (key, value, updated_at)
        VALUES ('openai.api_configs', '{"0": {"enable": true, "tags": [], "prefix_id": "", "model_ids": ["gemini-3.7-flash", "gemini-3.1-pro", "gemini-3.5-flash-lite"], "connection_type": "local", "auth_type": "none", "passthrough_params": []}}', strftime('%s', 'now'))
        ON CONFLICT(key) DO UPDATE SET value='{"0": {"enable": true, "tags": [], "prefix_id": "", "model_ids": ["gemini-3.7-flash", "gemini-3.1-pro", "gemini-3.5-flash-lite"], "connection_type": "local", "auth_type": "none", "passthrough_params": []}}', updated_at=strftime('%s', 'now')
    """)
    cursor.execute("""
        INSERT INTO config (key, value, updated_at)
        VALUES ('ui.default_models', '"gemini-3.7-flash"', strftime('%s', 'now'))
        ON CONFLICT(key) DO UPDATE SET value='"gemini-3.7-flash"', updated_at=strftime('%s', 'now')
    """)

    # Ensure model table exists and pre-populate true presets
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS model (
            id TEXT PRIMARY KEY,
            user_id TEXT,
            base_model_id TEXT,
            name TEXT,
            params TEXT,
            meta TEXT,
            updated_at INTEGER,
            created_at INTEGER,
            is_active INTEGER DEFAULT 1
        )
    """)

    meta_flash = json.dumps({
        "profile_image_url": "/static/favicon.png",
        "description": "Gemini 3.7 Flash - Fast multimodal all-around model",
        "capabilities": {
            "vision": True, "file_upload": True, "web_search": True,
            "code_interpreter": True, "terminal": True, "builtin_tools": True
        }
    })
    meta_pro = json.dumps({
        "profile_image_url": "/static/favicon.png",
        "description": "Gemini 3.1 Pro - Flagship advanced reasoning with thinking process",
        "capabilities": {
            "vision": True, "file_upload": True, "web_search": True,
            "code_interpreter": True, "terminal": True, "builtin_tools": True
        }
    })
    meta_lite = json.dumps({
        "profile_image_url": "/static/favicon.png",
        "description": "Gemini 3.5 Flash-Lite - Fastest response model",
        "capabilities": {
            "vision": True, "file_upload": True, "web_search": True,
            "code_interpreter": True, "terminal": True, "builtin_tools": True
        }
    })

    cursor.execute("""
        INSERT INTO model (id, user_id, base_model_id, name, params, meta, updated_at, created_at, is_active)
        VALUES ('gemini-3.7-flash', 'system', 'gemini-3.7-flash', 'Gemini 3.7 Flash', '{}', ?, strftime('%s', 'now'), strftime('%s', 'now'), 1)
        ON CONFLICT(id) DO UPDATE SET
            name=excluded.name,
            meta=excluded.meta,
            is_active=1,
            updated_at=strftime('%s', 'now')
    """, (meta_flash,))

    cursor.execute("""
        INSERT INTO model (id, user_id, base_model_id, name, params, meta, updated_at, created_at, is_active)
        VALUES ('gemini-3.1-pro', 'system', 'gemini-3.1-pro', 'Gemini 3.1 Pro', '{}', ?, strftime('%s', 'now'), strftime('%s', 'now'), 1)
        ON CONFLICT(id) DO UPDATE SET
            name=excluded.name,
            meta=excluded.meta,
            is_active=1,
            updated_at=strftime('%s', 'now')
    """, (meta_pro,))

    cursor.execute("""
        INSERT INTO model (id, user_id, base_model_id, name, params, meta, updated_at, created_at, is_active)
        VALUES ('gemini-3.5-flash-lite', 'system', 'gemini-3.5-flash-lite', 'Gemini 3.5 Flash-Lite', '{}', ?, strftime('%s', 'now'), strftime('%s', 'now'), 1)
        ON CONFLICT(id) DO UPDATE SET
            name=excluded.name,
            meta=excluded.meta,
            is_active=1,
            updated_at=strftime('%s', 'now')
    """, (meta_lite,))

except Exception as e:
    print(f"Notice: Config / Model table update returned {e}")

conn.commit()
conn.close()
print("Successfully registered native_bash_tool, agentic_browser_tool, and Gemini-FastAPI true models in DB!")
PY_EOF
done

echo "Open WebUI installation and tool sync complete!"
