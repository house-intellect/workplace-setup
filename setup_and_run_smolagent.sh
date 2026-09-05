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
for cmd in nc curl; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: Required command '$cmd' is not installed or not in PATH."
        exit 1
    fi
done

if ! command -v git &>/dev/null; then
    echo "Notice: 'git' is not found in PATH; using local offline repository folders if present."
fi

mkdir -p "$STACK_DIR" "$SMOL_DIR"

# 1.5 Python Version Check & Local Install (handles systems without root / old Python)
echo "[1.5/4] Checking Python version (need >= 3.10)..."
BASE_PYTHON=""

check_python_version() {
    local py_bin="$1"
    if [ -x "$py_bin" ]; then
        local ver=$("$py_bin" -c 'import sys; print(str(sys.version_info[0]) + "." + str(sys.version_info[1]))' 2>/dev/null || echo "0.0")
        local major=$(echo "$ver" | cut -d. -f1)
        local minor=$(echo "$ver" | cut -d. -f2)
        if [ "$major" -eq 3 ] && [ "$minor" -ge 10 ]; then
            return 0 # Success
        fi
    fi
    return 1 # Fail
}

if command -v python3 >/dev/null 2>&1 && check_python_version "$(command -v python3)"; then
    BASE_PYTHON="$(command -v python3)"
    echo "Found system Python >= 3.10: $BASE_PYTHON"
elif [ -x "$HOME/miniconda3/bin/python3" ] && check_python_version "$HOME/miniconda3/bin/python3"; then
    BASE_PYTHON="$HOME/miniconda3/bin/python3"
    echo "Found local Miniconda Python >= 3.10: $BASE_PYTHON"
else
    echo "Python 3.10+ not found in system. Installing local Miniconda (compatible with older GLIBC, no root required)..."
    rm -rf "$HOME/miniconda3"
    rm -f miniconda.sh
    if [ -f "$SCRIPT_DIR/miniconda.sh" ]; then
        cp "$SCRIPT_DIR/miniconda.sh" miniconda.sh
    else
        curl -sL "https://repo.anaconda.com/miniconda/Miniconda3-py310_23.5.2-0-Linux-x86_64.sh" -o miniconda.sh
    fi
    bash miniconda.sh -b -p "$HOME/miniconda3"
    rm -f miniconda.sh
    
    BASE_PYTHON="$HOME/miniconda3/bin/python3"
    if ! check_python_version "$BASE_PYTHON"; then
        echo "Error: Failed to install local Python 3.10."
        exit 1
    fi
    echo "Successfully installed local Miniconda Python 3.10."
fi

# 2. Python Virtual Environment Setup
echo "[2/4] Configuring Python environment..."
VENV_DIR="$SMOL_DIR/.venv"

# Ensure existing venv uses the correct python version
if [ -f "$VENV_DIR/bin/python" ]; then
    if ! check_python_version "$VENV_DIR/bin/python"; then
        echo "Existing virtual environment uses an old Python version. Recreating..."
        rm -rf "$VENV_DIR"
    fi
fi

if [ ! -f "$VENV_DIR/bin/python" ] || [ ! -f "$VENV_DIR/bin/pip" ]; then
    rm -rf "$VENV_DIR"
    echo "Creating virtual environment at $VENV_DIR using $BASE_PYTHON..."
    "$BASE_PYTHON" -m venv "$VENV_DIR"
fi

PYTHON_EXEC="$VENV_DIR/bin/python"
PIP_EXEC="$VENV_DIR/bin/pip"

CHECK_DEPS="import smolagents, openai, PIL, pydantic, requests, gemini_webapi, rookiepy, fastapi, uvicorn, lmdb, pydantic_settings; from smolagents import OpenAIServerModel"
if ! "$PYTHON_EXEC" -c "$CHECK_DEPS" 2>/dev/null; then
    echo "Installing smolagents, gemini-webapi, rookiepy, and server dependencies..."
    "$PIP_EXEC" install --upgrade pip 2>/dev/null || true
    "$PIP_EXEC" install "smolagents[openai]" openai pillow pydantic requests rookiepy "gemini-webapi==2.0.0" uvicorn fastapi lmdb pydantic-settings pyyaml
fi

# 3. Check/Install Gemini-FastAPI Server
echo "[3/4] Setting up Gemini-FastAPI server..."
if [ ! -f "$FASTAPI_DIR/run.py" ]; then
    if [ -d "$SCRIPT_DIR/Gemini-FastAPI" ] && [ -f "$SCRIPT_DIR/Gemini-FastAPI/run.py" ]; then
        echo "Found pre-downloaded Gemini-FastAPI in $SCRIPT_DIR/Gemini-FastAPI. Deploying..."
        mkdir -p "$FASTAPI_DIR"
        cp -r "$SCRIPT_DIR/Gemini-FastAPI/"* "$FASTAPI_DIR/"
    elif [ -d "$SCRIPT_DIR/gemini-fastapi" ] && [ -f "$SCRIPT_DIR/gemini-fastapi/run.py" ]; then
        echo "Found pre-downloaded gemini-fastapi in $SCRIPT_DIR/gemini-fastapi. Deploying..."
        mkdir -p "$FASTAPI_DIR"
        cp -r "$SCRIPT_DIR/gemini-fastapi/"* "$FASTAPI_DIR/"
    elif [ -f "$SCRIPT_DIR/run.py" ] && [ -d "$SCRIPT_DIR/app" ]; then
        echo "Running directly inside Gemini-FastAPI folder. Deploying to $FASTAPI_DIR..."
        mkdir -p "$FASTAPI_DIR"
        cp -r "$SCRIPT_DIR/"* "$FASTAPI_DIR/"
    elif command -v git &>/dev/null; then
        echo "Cloning Gemini-FastAPI from GitHub..."
        git clone https://github.com/Nativu5/Gemini-FastAPI.git "$FASTAPI_DIR" || {
            echo "Error: Failed to clone Gemini-FastAPI and no pre-downloaded folder found."
            exit 1
        }
    else
        echo "Error: Gemini-FastAPI not found at $FASTAPI_DIR, no pre-downloaded folder in $SCRIPT_DIR, and git is not installed."
        exit 1
    fi
else
    echo "Gemini-FastAPI is already present at $FASTAPI_DIR."
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
    # Live Gemini Web UI names & aliases
    "gemini-3.8-flash": "gemini-3-flash",
    "3.8-flash": "gemini-3-flash",
    "3.8-Flash": "gemini-3-flash",
    "gemini-3.5-flash-lite": "gemini-3-flash",
    "3.5-flash-lite": "gemini-3-flash",
    "3.5-Flash-Lite": "gemini-3-flash",
    "gemini-3.1-pro": "gemini-3-pro",
    "3.1-pro": "gemini-3-pro",
    "3.1-Pro": "gemini-3-pro",
    "gemini-extended-thinking": "gemini-3-flash-thinking",
    "extended-thinking": "gemini-3-flash-thinking",
    "Extended thinking": "gemini-3-flash-thinking",
    "gemini-3.7-flash": "gemini-3-flash",
    "gemini-3.7-pro": "gemini-3-pro",
    "gemini-3-flash": "gemini-3-flash",
    "gemini-3-flash-thinking": "gemini-3-flash-thinking",
    "gemini-3-pro": "gemini-3-pro",
    "flash": "gemini-3-flash",
    "thinking": "gemini-3-flash-thinking",
    "pro": "gemini-3-pro",
    "gemini-flash": "gemini-3-flash",
    "gemini-thinking": "gemini-3-flash-thinking",
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
        return Model.BASIC_FLASH


def _get_available_models() -> list[ModelData]:
    \"\"\"Return a list of available models based on configuration strategy.\"\"\"
    now = int(datetime.now(tz=UTC).timestamp())
    strategy = g_config.gemini.model_strategy
    models_data = []

    custom_models = [m for m in g_config.gemini.models if m.model_name]
    for m in custom_models:
        models_data.append(
            ModelData(
                id=m.model_name,
                created=now,
                owned_by="custom",
            )
        )

    priority_aliases = [
        "gemini-3.8-flash",
        "gemini-3.5-flash-lite",
        "gemini-3.1-pro",
        "gemini-extended-thinking",
        "gemini-3-flash",
        "gemini-3-flash-thinking",
        "gemini-3-pro",
        "flash",
        "thinking",
        "pro",
    ]
    for a in priority_aliases:
        models_data.append(
            ModelData(
                id=a,
                created=now,
                owned_by="gemini-web",
            )
        )

    if strategy == "append":
        custom_ids = {m.model_name for m in custom_models} | set(priority_aliases)
        for model in Model:
            m_name = model.model_name
            if not m_name or m_name == "unspecified":
                continue
            if m_name in custom_ids:
                continue

            models_data.append(
                ModelData(
                    id=m_name,
                    created=now,
                    owned_by="gemini-web",
                )
            )

    return models_data"""

if old_fn in txt:
    txt = txt.replace(old_fn, new_fn)
    p.write_text(txt)
' 2>/dev/null || true
    fi
fi
# Ensure StrEnum compatibility & DNS / SNI Proxy (dns.comss.one) support in gemini_webapi
"$PYTHON_EXEC" -c '
import glob
from pathlib import Path

for sp in glob.glob("'"$SMOL_DIR"'/.venv/lib/python*/site-packages"):
    # 1. StrEnum compatibility for Python 3.10
    for f in glob.glob(f"{sp}/gemini_webapi/**/*.py", recursive=True):
        p = Path(f)
        txt = p.read_text()
        if "from enum import Enum, IntEnum, StrEnum" in txt:
            txt = txt.replace(
                "from enum import Enum, IntEnum, StrEnum",
                "from enum import Enum, IntEnum\ntry:\n    from enum import StrEnum\nexcept ImportError:\n    class StrEnum(str, Enum):\n        pass"
            )
            p.write_text(txt)

    # 2. Patch get_access_token.py to forward and default curl_options with DoH
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
                "try:\n        from curl_cffi import CurlOpt\n        if curl_options is None:\n            curl_options = {CurlOpt.DOH_URL: b\"https://dns.comss.one/dns-query\"}\n    except Exception:\n        pass\n    client = AsyncSession(\n        impersonate=\"chrome\", proxy=proxy, allow_redirects=True, verify=verify, curl_options=curl_options\n    )"
            )
            gat_file.write_text(txt)

    # 3. Patch client.py to store and pass curl_options
    client_file = Path(f"{sp}/gemini_webapi/client.py")
    if client_file.exists():
        txt = client_file.read_text()
        if "self.curl_options" not in txt:
            txt = txt.replace(
                "self.kwargs = kwargs",
                "self.kwargs = kwargs\n        self.curl_options = kwargs.get(\"curl_options\")\n        if self.curl_options is None:\n            try:\n                from curl_cffi import CurlOpt\n                self.curl_options = {CurlOpt.DOH_URL: b\"https://dns.comss.one/dns-query\"}\n            except Exception:\n                pass"
            )
            txt = txt.replace(
                "verify=self.kwargs.get(\"verify\", True),",
                "verify=self.kwargs.get(\"verify\", True),\n                    curl_options=self.curl_options,"
            )
            client_file.write_text(txt)

    # 4. Patch image.py and video.py for file uploads
    for fname in ["image.py", "video.py"]:
        type_file = Path(f"{sp}/gemini_webapi/types/{fname}")
        if type_file.exists():
            txt = type_file.read_text()
            if "req_curl_opts" not in txt:
                txt = txt.replace(
                    "req_client = AsyncSession(\n            impersonate=\"chrome\", proxy=proxy, allow_redirects=True, verify=verify\n        )",
                    "req_curl_opts = getattr(self.client, \"curl_options\", None)\n        if req_curl_opts is None:\n            try:\n                from curl_cffi import CurlOpt\n                req_curl_opts = {CurlOpt.DOH_URL: b\"https://dns.comss.one/dns-query\"}\n            except Exception:\n                pass\n        req_client = AsyncSession(\n            impersonate=\"chrome\", proxy=proxy, allow_redirects=True, verify=verify, curl_options=req_curl_opts\n        )"
                )
                type_file.write_text(txt)
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

def get_available_models(api_base="http://127.0.0.1:8000/v1"):
    import urllib.request
    try:
        req = urllib.request.Request(f"{api_base}/models", headers={"User-Agent": "smolagent-client"})
        with urllib.request.urlopen(req, timeout=5) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            return [m["id"] for m in data.get("data", []) if "id" in m]
    except Exception:
        return []

def main():
    parser = argparse.ArgumentParser(description="Smolagent Runner")
    parser.add_argument("-m", "--model", help="Model name (or alias, e.g. flash, thinking, pro, 3.8-flash, 3.1-pro)", default=None)
    parser.add_argument("-f", "--file", help="Input text file path", default=None)
    parser.add_argument("-i", "--image", help="Input image path or folder", default=None)
    parser.add_argument("-l", "--list-models", action="store_true", help="List available models from running FastAPI server")
    parser.add_argument("prompt", nargs="*", help="Prompt string")
    args = parser.parse_args()

    api_base = "http://127.0.0.1:8000/v1"

    if args.list_models:
        models = get_available_models(api_base)
        if models:
            print("Available models from Gemini-FastAPI:")
            for m in models:
                print(f"  - {m}")
        else:
            print("No models returned or FastAPI server is unreachable at " + api_base)
        sys.exit(0)

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

    # Dynamic model resolution from FastAPI
    chosen_model = args.model or os.environ.get("MODEL")
    if not chosen_model:
        avail = get_available_models(api_base)
        chosen_model = avail[0] if avail else "gemini-3-flash"

    model = OpenAIServerModel(
        model_id=chosen_model,
        api_base=api_base,
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
#!/bin/sh
FASTAPI_PORT=8000
STACK_DIR="$HOME/local-ai-stack"
FASTAPI_DIR="$STACK_DIR/gemini-fastapi"
SMOL_DIR="$STACK_DIR/tool-calling-test"
SCRIPT_PATH="$SMOL_DIR/smolagent.py"
PYTHON_EXEC="$SMOL_DIR/.venv/bin/python"

# 1. Capture prompt, text files, image, and model arguments (POSIX compatible)
PROMPT_TEXT=""
FILE_ARG=""
IMAGE_ARG=""
MODEL_ARG=""
LIST_MODELS=0

while [ $# -gt 0 ]; do
    case "$1" in
        -f|--file)
            FILE_ARG="$2"
            shift 2
            ;;
        -i|--image)
            IMAGE_ARG="$2"
            shift 2
            ;;
        -m|--model)
            MODEL_ARG="$2"
            shift 2
            ;;
        -l|--list-models)
            LIST_MODELS=1
            shift
            ;;
        *)
            if [ -z "$PROMPT_TEXT" ]; then
                PROMPT_TEXT="$1"
            else
                PROMPT_TEXT="$PROMPT_TEXT $1"
            fi
            shift
            ;;
    esac
done

if [ $LIST_MODELS -eq 0 ]; then
    if [ -z "$PROMPT_TEXT" ] && [ ! -t 0 ]; then
        PROMPT_TEXT=$(cat)
    fi

    if [ -z "$PROMPT_TEXT" ] && [ -z "$FILE_ARG" ] && [ -z "$IMAGE_ARG" ]; then
        echo "Error: No prompt, text file, or image provided."
        echo "Usage: $0 [-m model] [-f file] [-i image_or_folder] [-l] \"Your prompt here\""
        echo "Use '$0 -l' to list available models dynamically from the FastAPI server."
        exit 1
    fi
fi

TASK_PROMPT="$PROMPT_TEXT"

if [ -n "$FILE_ARG" ]; then
    if [ -f "$FILE_ARG" ]; then
        FILE_CONTENT=$(cat "$FILE_ARG")
        TASK_PROMPT="$TASK_PROMPT

--- File: $FILE_ARG ---
$FILE_CONTENT"
    else
        echo "Warning: File '$FILE_ARG' not found."
    fi
fi

unset all_proxy ALL_PROXY http_proxy HTTP_PROXY https_proxy HTTPS_PROXY

if [ -f "$HOME/.bashrc" ]; then
    . "$HOME/.bashrc" 2>/dev/null || true
fi

if ! nc -z localhost $FASTAPI_PORT 2>/dev/null; then
    echo "Starting Gemini-FastAPI server on port $FASTAPI_PORT..."
    (cd "$FASTAPI_DIR" && nohup "$PYTHON_EXEC" run.py > "$STACK_DIR/proxy_access.log" 2>&1 &)
    
    PROXY_READY=0
    i=1
    while [ $i -le 20 ]; do
        if nc -z localhost $FASTAPI_PORT 2>/dev/null; then
            PROXY_READY=1
            break
        fi
        sleep 1
        i=$((i + 1))
    done

    if [ $PROXY_READY -eq 0 ]; then
        echo "Error: Gemini-FastAPI server failed to start on port $FASTAPI_PORT."
        tail -n 20 "$STACK_DIR/proxy_access.log"
        exit 1
    fi
fi

# 3. Run Python agent (POSIX compatible argument passing)
if [ $LIST_MODELS -eq 1 ]; then
    exec env -u all_proxy -u ALL_PROXY -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY "$PYTHON_EXEC" "$SCRIPT_PATH" -l
elif [ -n "$MODEL_ARG" ] && [ -n "$IMAGE_ARG" ]; then
    exec env -u all_proxy -u ALL_PROXY -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY "$PYTHON_EXEC" "$SCRIPT_PATH" -m "$MODEL_ARG" -i "$IMAGE_ARG" "$TASK_PROMPT"
elif [ -n "$MODEL_ARG" ]; then
    exec env -u all_proxy -u ALL_PROXY -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY "$PYTHON_EXEC" "$SCRIPT_PATH" -m "$MODEL_ARG" "$TASK_PROMPT"
elif [ -n "$IMAGE_ARG" ]; then
    exec env -u all_proxy -u ALL_PROXY -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY "$PYTHON_EXEC" "$SCRIPT_PATH" -i "$IMAGE_ARG" "$TASK_PROMPT"
else
    exec env -u all_proxy -u ALL_PROXY -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY "$PYTHON_EXEC" "$SCRIPT_PATH" "$TASK_PROMPT"
fi
AGENT_EOF

chmod +x "$HOME/agent.sh"

echo ""
echo "=== Setup Complete! ==="
echo "You can now run agent queries using:  ~/agent.sh \"Your prompt here\""
echo ""

if [ $# -gt 0 ]; then
    exec "$HOME/agent.sh" "$@"
fi


