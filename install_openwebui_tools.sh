#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${1:-$SCRIPT_DIR/open-webui}"

echo "=== Open WebUI Auto-Installer & Tool Sync ==="

# 1. Download Open WebUI if not present
if [ ! -d "$TARGET_DIR" ]; then
    echo "Open WebUI not found in $TARGET_DIR. Cloning official repository..."
    git clone https://github.com/open-webui/open-webui.git "$TARGET_DIR"
fi

# 2. Virtual Environment Detection & Reuse Algorithm
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

if [ -n "$VENV_DIR" ]; then
    echo "Found existing Python virtual environment at: $VENV_DIR"
else
    VENV_DIR="$TARGET_DIR/.venv"
    echo "Creating new Python virtual environment at: $VENV_DIR"
    python3 -m venv "$VENV_DIR"
fi

# 3. Detect Open WebUI webui.db Database
DB_PATH=""
POSSIBLE_DBS=(
    "$TARGET_DIR/backend/data/webui.db"
    "$TARGET_DIR/.venv/lib/python3.12/site-packages/open_webui/data/webui.db"
    "$HOME/.open-webui/data/webui.db"
    "/home/grapeonwheels/local-ai-stack/open-webui/.venv/lib/python3.12/site-packages/open_webui/data/webui.db"
)

for db in "${POSSIBLE_DBS[@]}"; do
    if [ -f "$db" ]; then
        DB_PATH="$db"
        break
    fi
done

if [ -z "$DB_PATH" ]; then
    echo "Database webui.db not found yet. Creating data directory structure..."
    DB_DIR="$(dirname "${POSSIBLE_DBS[0]}")"
    mkdir -p "$DB_DIR"
    DB_PATH="${POSSIBLE_DBS[0]}"
fi

echo "Target database path: $DB_PATH"

# 4. Inject/Sync Tools via Python SQLite script
"$VENV_DIR/bin/python" - "$DB_PATH" << 'PY_EOF'
import sqlite3
import json
import os
import sys

db_path = sys.argv[1]
conn = sqlite3.connect(db_path)
cursor = conn.cursor()

# Ensure table exists if fresh installation
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

bash_content = '''"""
title: Native Bash Tool
author: Local AI Stack
version: 1.0.0
description: Direct local bash execution tool for Open WebUI
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
                capture_output=True,
                text=True,
                timeout=60
            )
            output = result.stdout
            if result.stderr:
                output = output + chr(10) + result.stderr
            if output and output.strip():
                return output
            return "Command executed successfully with no output."
        except Exception as e:
            return str(e)
'''

bash_specs = [{
    "name": "bash_tool",
    "description": "Execute a bash command directly on the local system.",
    "parameters": {
        "type": "object",
        "properties": {
            "command": {
                "type": "string",
                "description": "The shell command line to execute."
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

conn.commit()
conn.close()
print("Successfully registered native_bash_tool and agentic_browser_tool in Open WebUI!")
PY_EOF

echo "Open WebUI installation and tool sync complete!"
