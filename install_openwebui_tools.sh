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
        if command -v npm &>/dev/null; then
            echo "Installing puppeteer dependencies for agentic-browser skill..."
            (cd "$HOME/.agents/skills/agentic-browser" && npm install --no-audit --no-fund 2>/dev/null || true)
        fi
    fi
fi

# 2. Check/Deploy Open WebUI repository
echo "[2/4] Detecting Open WebUI codebase..."
if [ ! -d "$TARGET_DIR" ] || [ ! -f "$TARGET_DIR/package.json" -a ! -d "$TARGET_DIR/backend" ]; then
    if [ -d "$SCRIPT_DIR/open-webui" ] && [ -f "$SCRIPT_DIR/open-webui/package.json" ]; then
        if [ "$TARGET_DIR" != "$SCRIPT_DIR/open-webui" ]; then
            echo "Found pre-downloaded open-webui in $SCRIPT_DIR/open-webui. Deploying to $TARGET_DIR..."
            mkdir -p "$TARGET_DIR"
            cp -r "$SCRIPT_DIR/open-webui/"* "$TARGET_DIR/"
        fi
    elif [ -d "$SCRIPT_DIR/open-webui-fork" ] && [ -f "$SCRIPT_DIR/open-webui-fork/package.json" ]; then
        echo "Found pre-downloaded open-webui-fork in $SCRIPT_DIR/open-webui-fork. Deploying to $TARGET_DIR..."
        mkdir -p "$TARGET_DIR"
        cp -r "$SCRIPT_DIR/open-webui-fork/"* "$TARGET_DIR/"
    elif [ -d "$SCRIPT_DIR/backend" ] && [ -f "$SCRIPT_DIR/package.json" ]; then
        echo "Running directly inside Open WebUI codebase ($SCRIPT_DIR)."
        TARGET_DIR="$SCRIPT_DIR"
    elif [ -d "$HOME/local-ai-stack/open-webui" ] && [ -f "$HOME/local-ai-stack/open-webui/package.json" ]; then
        echo "Using existing Open WebUI repository at $HOME/local-ai-stack/open-webui..."
        TARGET_DIR="$HOME/local-ai-stack/open-webui"
    elif command -v git &>/dev/null; then
        echo "Open WebUI not found locally. Cloning official repository..."
        git clone https://github.com/open-webui/open-webui.git "$TARGET_DIR" || {
            echo "Error: Failed to clone open-webui from GitHub and no local pre-downloaded folder found."
            exit 1
        }
    else
        echo "Error: Open WebUI repository not found at $TARGET_DIR, no pre-downloaded folder in $SCRIPT_DIR, and git is not installed."
        exit 1
    fi
else
    echo "Open WebUI repository found at $TARGET_DIR."
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

# Find / install Python runtime (Requires >= 3.10)
check_python_version() {
    local py_bin="$1"
    if [ -x "$py_bin" ]; then
        local ver=$("$py_bin" -c 'import sys; print(str(sys.version_info[0]) + "." + str(sys.version_info[1]))' 2>/dev/null || echo "0.0")
        local major=$(echo "$ver" | cut -d. -f1)
        local minor=$(echo "$ver" | cut -d. -f2)
        if [ "$major" -eq 3 ] && [ "$minor" -ge 10 ]; then
            return 0
        fi
    fi
    return 1
}

PY_CMD=""
for p in python3.12 python3.11 python3; do
    if command -v "$p" &>/dev/null && check_python_version "$(command -v "$p")"; then
        PY_CMD="$(command -v "$p")"
        break
    fi
done

if [ -z "$PY_CMD" ]; then
    if [ -x "$HOME/miniconda3/bin/python3" ] && check_python_version "$HOME/miniconda3/bin/python3"; then
        PY_CMD="$HOME/miniconda3/bin/python3"
    else
        echo "Python 3.10+ not found on system. Installing local Miniconda (compatible with older GLIBC, no root required)..."
        rm -rf "$HOME/miniconda3"
        rm -f miniconda.sh
        if [ -f "$SCRIPT_DIR/miniconda.sh" ]; then
            cp "$SCRIPT_DIR/miniconda.sh" miniconda.sh
        else
            curl -sL "https://repo.anaconda.com/miniconda/Miniconda3-py310_23.5.2-0-Linux-x86_64.sh" -o miniconda.sh
        fi
        bash miniconda.sh -b -p "$HOME/miniconda3"
        rm -f miniconda.sh
        PY_CMD="$HOME/miniconda3/bin/python3"
    fi
fi

if [ -n "$VENV_DIR" ] && [ -f "$VENV_DIR/bin/python" ]; then
    if ! check_python_version "$VENV_DIR/bin/python"; then
        echo "Existing virtual environment at $VENV_DIR uses an older Python. Recreating with $PY_CMD..."
        rm -rf "$VENV_DIR"
        "$PY_CMD" -m venv "$VENV_DIR"
    else
        echo "Found existing Python virtual environment at: $VENV_DIR"
    fi
else
    VENV_DIR="$TARGET_DIR/.venv"
    echo "Creating new Python virtual environment at: $VENV_DIR using $PY_CMD..."
    "$PY_CMD" -m venv "$VENV_DIR"
fi

# 3. Ensure Gemini-FastAPI Bridge, Cookie Fallbacks & Custom DNS (xbox-dns.ru) are Present
FASTAPI_DIR="$(dirname "$TARGET_DIR")/gemini-fastapi"
if [ ! -d "$FASTAPI_DIR" ]; then
    if [ -d "$HOME/local-ai-stack/gemini-fastapi" ]; then
        FASTAPI_DIR="$HOME/local-ai-stack/gemini-fastapi"
    elif [ -d "$SCRIPT_DIR/gemini-fastapi" ]; then
        FASTAPI_DIR="$SCRIPT_DIR/gemini-fastapi"
    elif [ -d "$SCRIPT_DIR/Gemini-FastAPI" ]; then
        FASTAPI_DIR="$SCRIPT_DIR/Gemini-FastAPI"
    fi
fi

# Apply DoH / SNI Proxy and StrEnum patches to all detected Python environments and Gemini-FastAPI
"$VENV_DIR/bin/python" -c '
import glob
from pathlib import Path

# 1. Patch Gemini-FastAPI if present
fastapi_dir = Path("'"$FASTAPI_DIR"'")
if fastapi_dir.exists():
    # 1.1 Patch app/__init__.py for global BaseSession DoH default
    app_init = fastapi_dir / "app" / "__init__.py"
    if app_init.exists():
        atxt = app_init.read_text()
        if "CurlOpt.DOH_URL" not in atxt:
            doh_code = """try:
    from curl_cffi import CurlOpt
    from curl_cffi.requests.session import BaseSession

    _orig_base_init = BaseSession.__init__

    def _doh_base_init(self, *args, **kwargs):
        curl_opts = kwargs.get("curl_options")
        if curl_opts is None:
            curl_opts = {}
            kwargs["curl_options"] = curl_opts
        if isinstance(curl_opts, dict) and CurlOpt.DOH_URL not in curl_opts:
            curl_opts[CurlOpt.DOH_URL] = b"https://xbox-dns.ru/dns-query"
        _orig_base_init(self, *args, **kwargs)

    BaseSession.__init__ = _doh_base_init
except Exception:
    pass

"""
            app_init.write_text(doh_code + atxt)

    # 1.2 Patch app/services/client.py (GeminiClientWrapper curl_options)
    wrap_file = fastapi_dir / "app" / "services" / "client.py"
    if wrap_file.exists():
        wtxt = wrap_file.read_text()
        if "self.curl_options" not in wtxt:
            wtxt = wtxt.replace(
                "def __init__(self, client_id: str, **kwargs):\n        super().__init__(**kwargs)\n        self.id = client_id",
                """def __init__(self, client_id: str, **kwargs):
        super().__init__(**kwargs)
        self.id = client_id
        self.curl_options = kwargs.get("curl_options")
        if self.curl_options is None:
            try:
                from curl_cffi import CurlOpt
                self.curl_options = {CurlOpt.DOH_URL: b"https://xbox-dns.ru/dns-query"}
            except Exception:
                self.curl_options = {}"""
            )
            wtxt = wtxt.replace(
                "verbose=verbose,\n            )",
                """verbose=verbose,\n            )
            if self.client and hasattr(self, "curl_options") and self.curl_options:
                if not getattr(self.client, "curl_options", None):
                    self.client.curl_options = dict(self.curl_options)
                else:
                    for k, v in self.curl_options.items():
                        self.client.curl_options.setdefault(k, v)"""
            )
            wrap_file.write_text(wtxt)

    # 1.3 Patch app/utils/helper.py (save_url_to_tempfile DoH)
    helper_file = fastapi_dir / "app" / "utils" / "helper.py"
    if helper_file.exists():
        htxt = helper_file.read_text()
        if "h_opts" not in htxt and "async with AsyncSession(impersonate=\"chrome\")" in htxt:
            htxt = htxt.replace(
                "async with AsyncSession(impersonate=\"chrome\") as client:",
                """try:
            from curl_cffi import CurlOpt
            h_opts = {CurlOpt.DOH_URL: b"https://xbox-dns.ru/dns-query"}
        except Exception:
            h_opts = {}
        async with AsyncSession(impersonate="chrome", curl_options=h_opts) as client:"""
            )
            helper_file.write_text(htxt)

    # 1.4 Patch app/services/pool.py (Rookiepy extraction, prioritize Chrome, DoH)
    pool_file = fastapi_dir / "app" / "services" / "pool.py"
    if pool_file.exists():
        ptxt = pool_file.read_text()
        if "GeminiClientSettings" not in ptxt:
            ptxt = ptxt.replace("from app.utils import g_config", "from app.utils import g_config\nfrom app.utils.config import GeminiClientSettings")
        if "xbox-dns.ru" not in ptxt:
            old_init = """        if len(g_config.gemini.clients) == 0:\n            raise ValueError("No Gemini clients configured")\n\n        for c in g_config.gemini.clients:"""
            new_init = """        clients_to_load = list(g_config.gemini.clients)
        if len(clients_to_load) == 0 or (
            len(clients_to_load) == 1
            and (
                not clients_to_load[0].secure_1psid
                or "YOUR_SECURE" in str(clients_to_load[0].secure_1psid)
            )
        ):
            extracted_psid = None
            extracted_psidts = None
            try:
                import rookiepy
                for b_name in ["firefox", "chrome", "chromium", "brave", "edge", "opera"]:
                    fn = getattr(rookiepy, b_name, None)
                    if not fn:
                        continue
                    try:
                        cookies = fn([".google.com"])
                        cdict = {}
                        for c in cookies:
                            if c.get("domain") in [".google.com", "google.com"] and "1PSID" in c.get("name", ""):
                                cdict[c["name"]] = c["value"]
                        if "__Secure-1PSID" in cdict and "__Secure-1PSIDTS" in cdict:
                            extracted_psid = cdict["__Secure-1PSID"]
                            extracted_psidts = cdict["__Secure-1PSIDTS"]
                            break
                    except Exception:
                        continue
            except Exception:
                pass

            if extracted_psid and extracted_psidts:
                clients_to_load = [
                    GeminiClientSettings(
                        id="auto-browser",
                        secure_1psid=extracted_psid,
                        secure_1psidts=extracted_psidts,
                        proxy=None,
                    )
                ]

        if len(clients_to_load) == 0:
            raise ValueError("No Gemini clients configured and auto-extraction failed.")

        for c in clients_to_load:
            curl_opts = {}
            try:
                from curl_cffi import CurlOpt
                curl_opts[CurlOpt.DOH_URL] = b"https://xbox-dns.ru/dns-query"
            except Exception:
                pass

            client = GeminiClientWrapper(
                client_id=c.id,
                secure_1psid=c.secure_1psid,
                secure_1psidts=c.secure_1psidts,
                proxy=c.proxy,
                curl_options=curl_opts,
            )
            self._clients.append(client)
            self._id_map[c.id] = client
            self._round_robin.append(client)
            self._restart_locks[c.id] = asyncio.Lock()
        return"""
            if old_init in ptxt:
                ptxt = ptxt.replace(old_init, new_init)
        if "[\"chrome\", \"chromium\", \"firefox\"" in ptxt:
            ptxt = ptxt.replace("[\"chrome\", \"chromium\", \"firefox\"", "[\"firefox\", \"chrome\", \"chromium\"")
        pool_file.write_text(ptxt)

    # 1.5 Ensure config/config.yaml exists and does not hold expired dummy credentials
    cfg_file = fastapi_dir / "config" / "config.yaml"
    if not cfg_file.exists():
        cfg_file.parent.mkdir(parents=True, exist_ok=True)
        cfg_file.write_text("""server:
  host: "127.0.0.1"
  port: 8000
  api_key: null
  https:
    enabled: false
    key_file: "certs/privkey.pem"
    cert_file: "certs/fullchain.pem"

cors:
  enabled: true
  allow_origins: ["*"]
  allow_credentials: true
  allow_methods: ["*"]
  allow_headers: ["*"]

gemini:
  clients:
    - id: "primary-client"
      secure_1psid: ""
      secure_1psidts: ""
      proxy: null
  timeout: 600
""")
    else:
        c_txt = cfg_file.read_text()
        if "YOUR_SECURE" in c_txt or "g.a000CAm643nHGM8cJT" in c_txt:
            import re
            c_txt = re.sub(r'secure_1psid:\s*".*?"', 'secure_1psid: ""', c_txt)
            c_txt = re.sub(r'secure_1psidts:\s*".*?"', 'secure_1psidts: ""', c_txt)
            cfg_file.write_text(c_txt)

    # 1.6 Ensure FastAPI binds to localhost only (127.0.0.1)
    cfg_py = fastapi_dir / "app" / "utils" / "config.py"
    if cfg_py.exists():
        ctxt = cfg_py.read_text()
        if "host: str = Field(default=\"0.0.0.0\"" in ctxt:
            ctxt = ctxt.replace("host: str = Field(default=\"0.0.0.0\"", "host: str = Field(default=\"127.0.0.1\"")
            cfg_py.write_text(ctxt)

# 2. Patch gemini_webapi in all site-packages across stack and target venv
search_roots = [
    "'"$VENV_DIR"'",
    "'"$TARGET_DIR"'/.venv",
    "'"$HOME"'/local-ai-stack/tool-calling-test/.venv",
    "'"$HOME"'/local-ai-stack/open-webui/.venv"
]
for root in search_roots:
    for sp in glob.glob(f"{root}/lib/python*/site-packages"):
        # StrEnum compatibility
        for f in glob.glob(f"{sp}/gemini_webapi/**/*.py", recursive=True):
            p = Path(f)
            txt = p.read_text()
            if "from enum import Enum, IntEnum, StrEnum" in txt:
                txt = txt.replace(
                    "from enum import Enum, IntEnum, StrEnum",
                    "from enum import Enum, IntEnum\ntry:\n    from enum import StrEnum\nexcept ImportError:\n    class StrEnum(str, Enum):\n        pass"
                )
                p.write_text(txt)

        # Patch get_access_token.py
        # Patch gemini_webapi/__init__.py for global BaseSession DoH
        init_file = Path(f"{sp}/gemini_webapi/__init__.py")
        if init_file.exists():
            txt = init_file.read_text()
            if "CurlOpt.DOH_URL" not in txt:
                doh_code = """try:
    from curl_cffi import CurlOpt
    from curl_cffi.requests.session import BaseSession

    _orig_base_init = BaseSession.__init__

    def _doh_base_init(self, *args, **kwargs):
        curl_opts = kwargs.get("curl_options")
        if curl_opts is None:
            curl_opts = {}
            kwargs["curl_options"] = curl_opts
        if isinstance(curl_opts, dict) and CurlOpt.DOH_URL not in curl_opts:
            curl_opts[CurlOpt.DOH_URL] = b"https://xbox-dns.ru/dns-query"
        _orig_base_init(self, *args, **kwargs)

    BaseSession.__init__ = _doh_base_init
except Exception:
    pass

"""
                init_file.write_text(doh_code + txt)

        gat_file = Path(f"{sp}/gemini_webapi/utils/get_access_token.py")
        if gat_file.exists():
            txt = gat_file.read_text()
            if "curl_options: dict | None = None" not in txt:
                txt = txt.replace(
                    "verify: bool = True,",
                    "verify: bool = True,\n    curl_options: dict | None = None,"
                )
                txt = txt.replace(
                    "client = AsyncSession(\n        impersonate=\"chrome\", proxy=proxy, allow_redirects=True, verify=verify\n    )",
                    "try:\n        from curl_cffi import CurlOpt\n        if curl_options is None:\n            curl_options = {CurlOpt.DOH_URL: b\"https://xbox-dns.ru/dns-query\"}\n    except Exception:\n        pass\n    client = AsyncSession(\n        impersonate=\"chrome\", proxy=proxy, allow_redirects=True, verify=verify, curl_options=curl_options\n    )"
                )
                gat_file.write_text(txt)

        # Patch client.py
        client_file = Path(f"{sp}/gemini_webapi/client.py")
        if client_file.exists():
            txt = client_file.read_text()
            if "self.curl_options" not in txt:
                txt = txt.replace(
                    "self.kwargs = kwargs",
                    "self.kwargs = kwargs\n        self.curl_options = kwargs.get(\"curl_options\")\n        if self.curl_options is None:\n            try:\n                from curl_cffi import CurlOpt\n                self.curl_options = {CurlOpt.DOH_URL: b\"https://xbox-dns.ru/dns-query\"}\n            except Exception:\n                pass"
                )
                txt = txt.replace(
                    "verify=self.kwargs.get(\"verify\", True),",
                    "verify=self.kwargs.get(\"verify\", True),\n                    curl_options=self.curl_options,"
                )
                client_file.write_text(txt)

        # Patch image.py and video.py
        for fname in ["image.py", "video.py"]:
            type_file = Path(f"{sp}/gemini_webapi/types/{fname}")
            if type_file.exists():
                txt = type_file.read_text()
                if "req_curl_opts" not in txt:
                    txt = txt.replace(
                        "req_client = AsyncSession(\n            impersonate=\"chrome\", proxy=proxy, allow_redirects=True, verify=verify\n        )",
                        "req_curl_opts = getattr(self.client, \"curl_options\", None)\n        if req_curl_opts is None:\n            try:\n                from curl_cffi import CurlOpt\n                req_curl_opts = {CurlOpt.DOH_URL: b\"https://xbox-dns.ru/dns-query\"}\n            except Exception:\n                pass\n        req_client = AsyncSession(\n            impersonate=\"chrome\", proxy=proxy, allow_redirects=True, verify=verify, curl_options=req_curl_opts\n        )"
                    )
                    type_file.write_text(txt)

        # Patch curl_cffi/requests/utils.py to guarantee DoH on ALL curl requests
        utils_file = Path(f"{sp}/curl_cffi/requests/utils.py")
        if utils_file.exists():
            utxt = utils_file.read_text()
            if "https://xbox-dns.ru/dns-query" not in utxt and "if curl_options:" in utxt:
                utxt = utxt.replace(
                    "    if curl_options:\n        for option, setting in curl_options.items():\n            c.setopt(option, setting)",
                    """    if curl_options is None:
        curl_options = {}
    else:
        curl_options = dict(curl_options)
    if CurlOpt.DOH_URL not in curl_options:
        curl_options[CurlOpt.DOH_URL] = b"https://xbox-dns.ru/dns-query"
    for option, setting in curl_options.items():
        c.setopt(option, setting)"""
                )
                utils_file.write_text(utxt)
' 2>/dev/null || true

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
import os

class Tools:
    def __init__(self):
        pass

    async def agentic_browser(self, action: str, target: str = "", value: str = "") -> str:
        try:
            script_path = os.path.expanduser("~/.agents/skills/agentic-browser/scripts/agent.js")
            cmd = ["node", script_path, action]
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
        VALUES ('openai.api_configs', '{"0": {"enable": true, "tags": [], "prefix_id": "", "model_ids": ["gemini-3-flash", "gemini-3-flash-thinking", "gemini-3-pro", "gemini-3.7-flash", "gemini-3.7-flash-thinking", "gemini-3.1-pro"], "connection_type": "local", "auth_type": "none", "passthrough_params": []}}', strftime('%s', 'now'))
        ON CONFLICT(key) DO UPDATE SET value='{"0": {"enable": true, "tags": [], "prefix_id": "", "model_ids": ["gemini-3-flash", "gemini-3-flash-thinking", "gemini-3-pro", "gemini-3.7-flash", "gemini-3.7-flash-thinking", "gemini-3.1-pro"], "connection_type": "local", "auth_type": "none", "passthrough_params": []}}', updated_at=strftime('%s', 'now')
    """)
    cursor.execute("""
        INSERT INTO config (key, value, updated_at)
        VALUES ('ui.default_models', '"gemini-3-flash"', strftime('%s', 'now'))
        ON CONFLICT(key) DO UPDATE SET value='"gemini-3-flash"', updated_at=strftime('%s', 'now')
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
        "description": "3.8 Flash - Fast multimodal all-around model",
        "capabilities": {
            "vision": True, "file_upload": True, "web_search": True,
            "code_interpreter": True, "terminal": True, "builtin_tools": True
        }
    })
    meta_lite = json.dumps({
        "profile_image_url": "/static/favicon.png",
        "description": "3.5 Flash-Lite - Fastest answers with lightweight inference",
        "capabilities": {
            "vision": True, "file_upload": True, "web_search": True,
            "code_interpreter": True, "terminal": True, "builtin_tools": True
        }
    })
    meta_thinking = json.dumps({
        "profile_image_url": "/static/favicon.png",
        "description": "Extended Thinking - Multimodal reasoning with internal chain-of-thought",
        "capabilities": {
            "vision": True, "file_upload": True, "web_search": True,
            "code_interpreter": True, "terminal": True, "builtin_tools": True
        }
    })
    meta_pro = json.dumps({
        "profile_image_url": "/static/favicon.png",
        "description": "3.1 Pro - Flagship advanced reasoning and complex problem solving",
        "capabilities": {
            "vision": True, "file_upload": True, "web_search": True,
            "code_interpreter": True, "terminal": True, "builtin_tools": True
        }
    })

    models_to_register = [
        ("gemini-3.8-flash", "3.8 Flash", meta_flash),
        ("gemini-3.5-flash-lite", "3.5 Flash-Lite", meta_lite),
        ("gemini-3.1-pro", "3.1 Pro", meta_pro),
        ("gemini-extended-thinking", "Extended Thinking", meta_thinking),
        ("gemini-3-flash", "Flash (Default)", meta_flash),
        ("gemini-3-flash-thinking", "Flash Thinking", meta_thinking),
        ("gemini-3-pro", "Pro", meta_pro),
        ("flash", "Flash", meta_flash),
        ("thinking", "Thinking", meta_thinking),
        ("pro", "Pro", meta_pro),
    ]

    for m_id, m_name, m_meta in models_to_register:
        cursor.execute("""
            INSERT INTO model (id, user_id, base_model_id, name, params, meta, updated_at, created_at, is_active)
            VALUES (?, 'system', ?, ?, '{}', ?, strftime('%s', 'now'), strftime('%s', 'now'), 1)
            ON CONFLICT(id) DO UPDATE SET
                name=excluded.name,
                meta=excluded.meta,
                is_active=1,
                updated_at=strftime('%s', 'now')
        """, (m_id, m_id, m_name, m_meta))

except Exception as e:
    print(f"Notice: Config / Model table update returned {e}")

conn.commit()
conn.close()
print("Successfully registered native_bash_tool, agentic_browser_tool, and Gemini-FastAPI true models in DB!")
PY_EOF
done

echo "Open WebUI installation and tool sync complete!"
