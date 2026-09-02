#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STACK_DIR="$HOME/local-ai-stack"
FASTAPI_DIR="$STACK_DIR/gemini-fastapi"
SMOL_DIR="$STACK_DIR/tool-calling-test"
FASTAPI_PORT=8000
REAL_HOME="$HOME"
SKILL_DIR="$HOME/.agents/skills/agentic-browser"

echo "=== Smolagent & Skills One-Click Setup (Gemini-FastAPI / Gemini 3.7 Flash) ==="

# 1. System Dependency Checks
echo "[1/4] Checking system dependencies..."
for cmd in python3 git nc curl; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: Required command '$cmd' is not installed or not in PATH."
        exit 1
    fi
done

mkdir -p "$STACK_DIR" "$SMOL_DIR"

# 2. Python Virtual Environment Setup
echo "[2/4] Configuring Python environment..."
VENV_DIR="$SMOL_DIR/.venv"
if [ ! -f "$VENV_DIR/bin/python" ] || [ ! -f "$VENV_DIR/bin/pip" ]; then
    rm -rf "$VENV_DIR"
    echo "Creating virtual environment at $VENV_DIR..."
    python3 -m venv "$VENV_DIR"
fi

PYTHON_EXEC="$VENV_DIR/bin/python"
PIP_EXEC="$VENV_DIR/bin/pip"

CHECK_DEPS="import smolagents, openai, PIL, pydantic, requests, gemini_webapi, rookiepy, fastapi, uvicorn, lmdb, pydantic_settings; from smolagents import OpenAIServerModel"
if ! "$PYTHON_EXEC" -c "$CHECK_DEPS" 2>/dev/null; then
    echo "Installing smolagents, gemini-webapi, rookiepy, and server dependencies..."
    "$PIP_EXEC" install --upgrade pip
    "$PIP_EXEC" install "smolagents[openai]" openai pillow pydantic requests rookiepy "gemini-webapi==2.0.0" uvicorn fastapi lmdb pydantic-settings pyyaml
fi

# 3. Check/Install Gemini-FastAPI Server
echo "[3/4] Setting up Gemini-FastAPI server..."
if [ ! -d "$FASTAPI_DIR" ]; then
    echo "Cloning Gemini-FastAPI..."
    git clone https://github.com/Nativu5/Gemini-FastAPI.git "$FASTAPI_DIR"
fi

# Ensure Firefox cookie extraction fallback and gemini-3.7-flash alias are patched in Gemini-FastAPI
if [ -f "$FASTAPI_DIR/app/services/pool.py" ]; then
    if ! grep -q "rookiepy" "$FASTAPI_DIR/app/services/pool.py"; then
        "$PYTHON_EXEC" -c '
from pathlib import Path
p = Path("'"$FASTAPI_DIR"'/app/services/pool.py")
txt = p.read_text()
if "GeminiClientSettings" not in txt:
    txt = txt.replace("from app.utils import g_config", "from app.utils import g_config\nfrom app.utils.config import GeminiClientSettings")
old_init = """        if len(g_config.gemini.clients) == 0:
            raise ValueError("No Gemini clients configured")

        for c in g_config.gemini.clients:"""
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
                        cdict = {c["name"]: c["value"] for c in cookies if "1PSID" in c["name"]}
                        if "__Secure-1PSID" in cdict and "__Secure-1PSIDTS" in cdict:
                            extracted_psid = cdict["__Secure-1PSID"]
                            extracted_psidts = cdict["__Secure-1PSIDTS"]
                            logger.info(f"Auto-extracted Gemini session cookies from {b_name}.")
                            break
                    except Exception:
                        continue
            except Exception as e:
                logger.warning(f"Could not import rookiepy or extract cookies: {e}")

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
                curl_opts[CurlOpt.DOH_URL] = b"https://dns.comss.one/dns-query"
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
if old_init in txt:
    txt = txt.replace(old_init, new_init)
    p.write_text(txt)
' 2>/dev/null || true
    fi
fi

if [ -f "$FASTAPI_DIR/app/server/chat.py" ]; then
    if ! grep -q "gemini-3.7-flash" "$FASTAPI_DIR/app/server/chat.py"; then
        "$PYTHON_EXEC" -c '
from pathlib import Path
p = Path("'"$FASTAPI_DIR"'/app/server/chat.py")
txt = p.read_text()
old_fn = """def _get_model_by_name(name: str) -> Model:
    \"\"\"Retrieve a Model instance by name.\"\"\"
    strategy = g_config.gemini.model_strategy
    custom_models = {m.model_name: m for m in g_config.gemini.models if m.model_name}

    if name in custom_models:
        return Model.from_dict(custom_models[name].model_dump())

    if strategy == "overwrite":
        raise ValueError(f"Model \x27{name}\x27 not found in custom models (strategy=\x27overwrite\x27).")

    return Model.from_name(name)"""

new_fn = """MODEL_ALIASES = {
    "gemini-3.7-flash": "gemini-3-flash",
    "gemini-3.7-pro": "gemini-3-pro",
    "gemini-2.5-flash": "gemini-3-flash",
    "gemini-2.5-pro": "gemini-3-pro",
    "gemini-1.5-flash": "gemini-3-flash",
    "gemini-1.5-pro": "gemini-3-pro",
    "gemini-flash": "gemini-3-flash",
    "gemini-pro": "gemini-3-pro",
    "gpt-4o": "gemini-3-flash",
    "gpt-4": "gemini-3-pro",
    "gpt-3.5-turbo": "gemini-3-flash",
}

def _get_model_by_name(name: str) -> Model:
    \"\"\"Retrieve a Model instance by name.\"\"\"
    strategy = g_config.gemini.model_strategy
    custom_models = {m.model_name: m for m in g_config.gemini.models if m.model_name}

    if name in custom_models:
        return Model.from_dict(custom_models[name].model_dump())

    resolved_name = MODEL_ALIASES.get(name, name)
    if resolved_name in custom_models:
        return Model.from_dict(custom_models[resolved_name].model_dump())

    if strategy == "overwrite":
        raise ValueError(f"Model \x27{name}\x27 not found in custom models (strategy=\x27overwrite\x27).")

    try:
        return Model.from_name(resolved_name)
    except Exception:
        return Model.BASIC_FLASH"""

if old_fn in txt:
    txt = txt.replace(old_fn, new_fn)
    p.write_text(txt)
' 2>/dev/null || true
    fi
fi
# Ensure StrEnum compatibility for Python 3.10 in installed dependencies
"$PYTHON_EXEC" -c '
import glob
from pathlib import Path
for sp in glob.glob("'"$SMOL_DIR"'/.venv/lib/python*/site-packages"):
    for f in glob.glob(f"{sp}/gemini_webapi/**/*.py", recursive=True):
        p = Path(f)
        txt = p.read_text()
        if "from enum import Enum, IntEnum, StrEnum" in txt:
            txt = txt.replace(
                "from enum import Enum, IntEnum, StrEnum",
                "from enum import Enum, IntEnum\ntry:\n    from enum import StrEnum\nexcept ImportError:\n    class StrEnum(str, Enum):\n        pass"
            )
            p.write_text(txt)
' 2>/dev/null || true

# Check/Install agentic-browser skill dependencies
mkdir -p "$SKILL_DIR"
if [ -d "$SCRIPT_DIR/agentic-browser" ]; then
    cp -r "$SCRIPT_DIR/agentic-browser/"* "$SKILL_DIR/"
fi
if [ ! -d "$SKILL_DIR/node_modules" ]; then
    if command -v npm &>/dev/null; then
        (cd "$SKILL_DIR" && npm init -y >/dev/null 2>&1 || true)
        (cd "$SKILL_DIR" && npm install puppeteer --no-audit --no-fund 2>/dev/null || true)
    fi
fi

# 4. Generate Runner and Launcher
echo "[4/4] Generating agent runner and ~/agent.sh..."

cat << 'PY_EOF' > "$SMOL_DIR/smolagent.py"
import sys
import os
import glob
import json
import argparse
import subprocess
from smolagents import ToolCallingAgent, OpenAIServerModel, tool

@tool
def execute_bash(command: str) -> str:
    """
    Executes a shell command in a full Bash environment on the local machine and returns the stdout and stderr output.
    Supports complex shell features including pipelines (|), redirects (>, >>), chained commands (&&, ||, ;), process substitution, environment variables, and multiline scripts.

    Args:
        command: The bash command string or multiline script to execute in /bin/bash.
    """
    import subprocess
    try:
        res = subprocess.run(
            command,
            shell=True,
            executable="/bin/bash",
            capture_output=True,
            text=True,
            timeout=120
        )
        out = res.stdout.strip()
        err = res.stderr.strip()
        if out and err:
            return f"STDOUT:\n{out}\n\nSTDERR:\n{err}"
        if not out and not err:
            return f"Command executed successfully with return code {res.returncode} and no output."
        return out or err
    except subprocess.TimeoutExpired:
        return "Command timed out after 120 seconds."
    except Exception as e:
        return f"Execution error: {str(e)}"

def get_auth_token():
    if os.environ.get("GEMINI_API_KEY"):
        return os.environ["GEMINI_API_KEY"]
    return "not-needed"

def main():
    parser = argparse.ArgumentParser(description="Smolagent Runner")
    parser.add_argument("-f", "--file", help="Input text file path", default=None)
    parser.add_argument("-i", "--image", help="Input image path or folder", default=None)
    parser.add_argument("prompt", nargs="*", help="Prompt string")
    args = parser.parse_args()

    full_prompt = " ".join(args.prompt).strip()
    if args.file and os.path.exists(args.file):
        with open(args.file, "r", encoding="utf-8") as f:
            full_prompt = f.read() + "\n" + full_prompt

    if not full_prompt:
        print("Error: No prompt provided.")
        sys.exit(1)

    for k in ["all_proxy", "ALL_PROXY", "http_proxy", "HTTP_PROXY", "https_proxy", "HTTPS_PROXY"]:
        os.environ.pop(k, None)

    auth_token = get_auth_token()

    model = OpenAIServerModel(
        model_id="gemini-3.7-flash",
        api_base="http://127.0.0.1:8000/v1",
        api_key=auth_token or "not-needed"
    )
    agent = ToolCallingAgent(
        tools=[execute_bash],
        model=model
    )
    response = agent.run(full_prompt)
    print(response)

if __name__ == "__main__":
    main()
PY_EOF

cat << 'AGENT_EOF' > "$HOME/agent.sh"
#!/bin/bash
if [ "$#" -eq 0 ]; then
    echo "Error: No prompt, text file, or image provided."
    echo "Usage: $0 [-f file] [-i image_or_folder] \"Your prompt here\""
    exit 1
fi
STACK_DIR="$HOME/local-ai-stack"
FASTAPI_DIR="$STACK_DIR/gemini-fastapi"
SMOL_DIR="$STACK_DIR/tool-calling-test"
FASTAPI_PORT=8000
PYTHON_EXEC="$SMOL_DIR/.venv/bin/python"
export MODEL="gemini-3.7-flash"
unset all_proxy ALL_PROXY http_proxy HTTP_PROXY https_proxy HTTPS_PROXY

if [ -f "$HOME/.bashrc" ]; then
    source "$HOME/.bashrc" 2>/dev/null || true
fi

if ! nc -z localhost $FASTAPI_PORT 2>/dev/null; then
    echo "Starting Gemini-FastAPI server on port $FASTAPI_PORT..."
    (cd "$FASTAPI_DIR" && nohup "$PYTHON_EXEC" run.py > "$STACK_DIR/proxy_access.log" 2>&1 &)
    
    PROXY_READY=0
    for i in {1..20}; do
        if nc -z localhost $FASTAPI_PORT 2>/dev/null; then
            PROXY_READY=1
            break
        fi
        sleep 1
    done

    if [ $PROXY_READY -eq 0 ]; then
        echo "Error: Gemini-FastAPI server failed to start on port $FASTAPI_PORT."
        tail -n 20 "$STACK_DIR/proxy_access.log"
        exit 1
    fi
fi

exec env -u all_proxy -u ALL_PROXY -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY "$PYTHON_EXEC" "$SMOL_DIR/smolagent.py" "$@"
AGENT_EOF

chmod +x "$HOME/agent.sh"

echo ""
echo "=== Setup Complete! ==="
echo "You can now run agent queries using:  ~/agent.sh \"Your prompt here\""
echo ""

if [ $# -gt 0 ]; then
    exec "$HOME/agent.sh" "$@"
fi


