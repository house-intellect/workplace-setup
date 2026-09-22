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

# Ensure Gemini-FastAPI patches: DoH, cookie extraction, client wrapper, and localhost binding
if [ -d "$FASTAPI_DIR" ]; then
    "$PYTHON_EXEC" -c '
from pathlib import Path
fastapi_dir = Path("'"$FASTAPI_DIR"'")

# 1. Patch app/__init__.py for global BaseSession DoH default
app_init = fastapi_dir / "app" / "__init__.py"
if app_init.exists():
    txt = app_init.read_text()
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
        app_init.write_text(doh_code + txt)

# 2. Patch app/services/client.py (GeminiClientWrapper curl_options & AccountStatus check)
wrap_file = fastapi_dir / "app" / "services" / "client.py"
if wrap_file.exists():
    wtxt = wrap_file.read_text()
    if "hard_blocks" not in wtxt or "GEMINI_DOH_URL" not in wtxt:
        new_client_code = """class GeminiClientWrapper(GeminiClient):
    \"\"\"Gemini client with helper methods.\"\"\"

    def __init__(self, client_id: str, **kwargs):
        super().__init__(**kwargs)
        self.id = client_id
        import os
        doh_endpoint = os.environ.get("GEMINI_DOH_URL", "https://xbox-dns.ru/dns-query")
        if isinstance(doh_endpoint, str):
            doh_endpoint = doh_endpoint.encode()
        if secure_1psidcc := kwargs.get("secure_1psidcc"):
            self._cookies.set("__Secure-1PSIDCC", secure_1psidcc, domain=".google.com")
        self.curl_options = kwargs.get("curl_options")
        if self.curl_options is None:
            try:
                from curl_cffi import CurlOpt
                self.curl_options = {CurlOpt.DOH_URL: doh_endpoint}
            except Exception:
                self.curl_options = {}
        elif isinstance(self.curl_options, dict):
            try:
                from curl_cffi import CurlOpt
                if CurlOpt.DOH_URL not in self.curl_options:
                    self.curl_options[CurlOpt.DOH_URL] = doh_endpoint
            except Exception:
                pass

    async def init(
        self,
        timeout: float = cast(float, _UNSET),
        watchdog_timeout: float = cast(float, _UNSET),
        auto_close: bool = False,
        close_delay: float = cast(float, _UNSET),
        auto_refresh: bool = cast(bool, _UNSET),
        refresh_interval: float = cast(float, _UNSET),
        verbose: bool = cast(bool, _UNSET),
    ) -> None:
        config = g_config.gemini
        timeout = cast(float, _resolve(timeout, config.timeout))
        watchdog_timeout = cast(float, _resolve(watchdog_timeout, config.watchdog_timeout))
        close_delay = timeout
        auto_refresh = cast(bool, _resolve(auto_refresh, config.auto_refresh))
        refresh_interval = cast(float, _resolve(refresh_interval, config.refresh_interval))
        verbose = cast(bool, _resolve(verbose, config.verbose))

        try:
            await super().init(
                timeout=timeout,
                watchdog_timeout=watchdog_timeout,
                auto_close=auto_close,
                close_delay=close_delay,
                auto_refresh=auto_refresh,
                refresh_interval=refresh_interval,
                verbose=verbose,
            )
            from gemini_webapi.constants import AccountStatus
            hard_blocks = [
                AccountStatus.LOCATION_REJECTED,
                AccountStatus.ACCOUNT_REJECTED,
                AccountStatus.ACCESS_TEMPORARILY_UNAVAILABLE,
                AccountStatus.ACCOUNT_REJECTED_BY_GUARDIAN,
                AccountStatus.GUARDIAN_APPROVAL_REQUIRED,
            ]
            if hasattr(self, "account_status") and self.account_status in hard_blocks:
                self._running = False
                logger.warning(
                    f"Gemini client {self.id} account status is {self.account_status}, marking client not running."
                )
            elif self.client and hasattr(self, "curl_options") and self.curl_options:
                if not getattr(self.client, "curl_options", None):
                    self.client.curl_options = dict(self.curl_options)
                else:
                    for k, v in self.curl_options.items():
                        self.client.curl_options.setdefault(k, v)
        except Exception:
            logger.exception(f"Failed to initialize GeminiClient {self.id}")
            raise

    def running(self) -> bool:
        from gemini_webapi.constants import AccountStatus
        hard_blocks = [
            AccountStatus.LOCATION_REJECTED,
            AccountStatus.ACCOUNT_REJECTED,
            AccountStatus.ACCESS_TEMPORARILY_UNAVAILABLE,
            AccountStatus.ACCOUNT_REJECTED_BY_GUARDIAN,
            AccountStatus.GUARDIAN_APPROVAL_REQUIRED,
        ]
        if hasattr(self, "account_status") and self.account_status in hard_blocks:
            return False
        return self._running
"""
        import re
        wtxt = re.sub(r'class GeminiClientWrapper\(GeminiClient\):.*?def running\(self\) -> bool:\s+return self\._running', new_client_code.strip(), wtxt, flags=re.DOTALL)
        wrap_file.write_text(wtxt)

# 3. Patch app/utils/helper.py (save_url_to_tempfile DoH)
helper_file = fastapi_dir / "app" / "utils" / "helper.py"
if helper_file.exists():
    htxt = helper_file.read_text()
    if "h_opts" not in htxt and "async with AsyncSession(impersonate=\"chrome\")" in htxt:
        htxt = htxt.replace(
            "async with AsyncSession(impersonate=\"chrome\") as client:",
            """try:
            from curl_cffi import CurlOpt
            import os
            _doh = os.environ.get("GEMINI_DOH_URL", "https://xbox-dns.ru/dns-query")
            if isinstance(_doh, str):
                _doh = _doh.encode()
            h_opts = {CurlOpt.DOH_URL: _doh}
        except Exception:
            h_opts = {}
        async with AsyncSession(impersonate="chrome", curl_options=h_opts) as client:"""
        )
        helper_file.write_text(htxt)

# 4. Patch app/services/pool.py (Rookiepy multi-browser extraction, fallback, DoH)
pool_file = fastapi_dir / "app" / "services" / "pool.py"
if pool_file.exists():
    ptxt = pool_file.read_text()
    if "GeminiClientSettings" not in ptxt:
        ptxt = ptxt.replace("from app.utils import g_config", "from app.utils import g_config\nfrom app.utils.config import GeminiClientSettings")
    new_pool_code = """class GeminiClientPool(metaclass=Singleton):
    \"\"\"Pool of GeminiClient instances identified by unique ids.\"\"\"

    def __init__(self) -> None:
        self._clients: list[GeminiClientWrapper] = []
        self._id_map: dict[str, GeminiClientWrapper] = {}
        self._round_robin: deque[GeminiClientWrapper] = deque()
        self._restart_locks: dict[str, asyncio.Lock] = {}

        clients_to_load = list(g_config.gemini.clients)
        if len(clients_to_load) == 0 or (
            len(clients_to_load) == 1
            and (
                not clients_to_load[0].secure_1psid
                or "YOUR_SECURE" in str(clients_to_load[0].secure_1psid)
            )
        ):
            # Prioritize Firefox first: reads cookies.sqlite directly without triggering OS keyring / KWallet / SecretService GUI prompts.
            found_clients = []
            try:
                import rookiepy
                for b_name in ["firefox"]:
                    fn = getattr(rookiepy, b_name, None)
                    if not fn:
                        continue
                    try:
                        cookies = fn([".google.com"])
                        cdict = {c["name"]: c["value"] for c in cookies if c.get("domain") in [".google.com", "google.com"]}
                        psid = cdict.get("__Secure-1PSID")
                        psidts = cdict.get("__Secure-1PSIDTS")
                        psidcc = cdict.get("__Secure-1PSIDCC") or cdict.get("__Secure-3PSIDCC") or cdict.get("SIDCC")
                        if psid and psidts:
                            logger.info(f"Auto-extracted Gemini session cookies from {b_name} (no keyring required).")
                            found_clients.append(
                                GeminiClientSettings(
                                    id=f"auto-{b_name}",
                                    secure_1psid=psid,
                                    secure_1psidts=psidts,
                                    secure_1psidcc=psidcc,
                                    proxy=None,
                                )
                            )
                    except Exception as e:
                        logger.debug(f"Firefox extraction failed: {e}")

                if not found_clients:
                    for b_name in ["chrome", "chromium", "brave", "edge", "opera"]:
                        fn = getattr(rookiepy, b_name, None)
                        if not fn:
                            continue
                        try:
                            cookies = fn([".google.com"])
                            cdict = {c["name"]: c["value"] for c in cookies if c.get("domain") in [".google.com", "google.com"]}
                            psid = cdict.get("__Secure-1PSID")
                            psidts = cdict.get("__Secure-1PSIDTS")
                            psidcc = cdict.get("__Secure-1PSIDCC") or cdict.get("__Secure-3PSIDCC") or cdict.get("SIDCC")
                            if psid and psidts:
                                logger.info(f"Auto-extracted Gemini session cookies from {b_name}.")
                                found_clients.append(
                                    GeminiClientSettings(
                                        id=f"auto-{b_name}",
                                        secure_1psid=psid,
                                        secure_1psidts=psidts,
                                        secure_1psidcc=psidcc,
                                        proxy=None,
                                    )
                                )
                                break
                        except Exception:
                            continue
            except Exception as e:
                logger.warning(f"Could not import rookiepy or extract cookies: {e}")

            if found_clients:
                clients_to_load = found_clients

        if len(clients_to_load) == 0:
            raise ValueError("No Gemini clients configured and auto-extraction failed.")

        import os
        doh_url = os.environ.get("GEMINI_DOH_URL", "https://xbox-dns.ru/dns-query")
        if isinstance(doh_url, str):
            doh_url = doh_url.encode()

        for c in clients_to_load:
            curl_opts = {}
            try:
                from curl_cffi import CurlOpt
                curl_opts[CurlOpt.DOH_URL] = doh_url
            except Exception:
                pass

            client = GeminiClientWrapper(
                client_id=c.id,
                secure_1psid=c.secure_1psid,
                secure_1psidts=c.secure_1psidts,
                secure_1psidcc=getattr(c, "secure_1psidcc", None),
                proxy=c.proxy,
                curl_options=curl_opts,
            )
            self._clients.append(client)
            self._id_map[c.id] = client
            self._round_robin.append(client)
            self._restart_locks[c.id] = asyncio.Lock()

    async def init(self) -> None:
        \"\"\"Initialize all clients in the pool.\"\"\"
        success_count = 0
        for client in self._clients:
            if not client.running():
                try:
                    await client.init(
                        timeout=g_config.gemini.timeout,
                        watchdog_timeout=g_config.gemini.watchdog_timeout,
                        auto_refresh=g_config.gemini.auto_refresh,
                        verbose=g_config.gemini.verbose,
                        refresh_interval=g_config.gemini.refresh_interval,
                    )
                except Exception:
                    logger.exception(f"Failed to initialize client {client.id}")

            if client.running():
                success_count += 1

        if success_count == 0:
            logger.warning("No configured Gemini clients available. Attempting live browser re-extraction...")
            try:
                import rookiepy
                import os
                from curl_cffi import CurlOpt
                doh_url = os.environ.get("GEMINI_DOH_URL", "https://xbox-dns.ru/dns-query")
                if isinstance(doh_url, str):
                    doh_url = doh_url.encode()
                for b_name in ["firefox", "chrome", "chromium", "brave"]:
                    fn = getattr(rookiepy, b_name, None)
                    if not fn:
                        continue
                    try:
                        cookies = fn([".google.com"])
                        cdict = {c["name"]: c["value"] for c in cookies if c.get("domain") in [".google.com", "google.com"] and "1PSID" in c.get("name", "")}
                        if "__Secure-1PSID" in cdict and "__Secure-1PSIDTS" in cdict:
                            fallback_client = GeminiClientWrapper(
                                client_id=f"live-{b_name}",
                                secure_1psid=cdict["__Secure-1PSID"],
                                secure_1psidts=cdict["__Secure-1PSIDTS"],
                                secure_1psidcc=cdict.get("__Secure-1PSIDCC"),
                                proxy=None,
                                curl_options={CurlOpt.DOH_URL: doh_url},
                            )
                            await fallback_client.init(
                                timeout=g_config.gemini.timeout,
                                watchdog_timeout=g_config.gemini.watchdog_timeout,
                                auto_refresh=g_config.gemini.auto_refresh,
                                verbose=g_config.gemini.verbose,
                                refresh_interval=g_config.gemini.refresh_interval,
                            )
                            if fallback_client.running():
                                self._clients.append(fallback_client)
                                self._id_map[fallback_client.id] = fallback_client
                                self._round_robin.append(fallback_client)
                                self._restart_locks[fallback_client.id] = asyncio.Lock()
                                success_count += 1
                                logger.info(f"Activated live browser client {fallback_client.id}")
                                break
                    except Exception:
                        continue
            except Exception as e:
                logger.warning(f"Browser re-extraction failed: {e}")

        if success_count == 0:
            raise RuntimeError("Failed to initialize any Gemini clients")

    async def acquire(self, client_id: str | None = None) -> GeminiClientWrapper:
        \"\"\"Return a healthy client by id or using round-robin.\"\"\"
        if not self._round_robin:
            raise RuntimeError("No Gemini clients configured")

        if client_id:
            client = self._id_map.get(client_id)
            if not client:
                raise ValueError(f"Client id {client_id} not found")
            if await self._ensure_client_ready(client):
                return client
            raise RuntimeError(
                f"Gemini client {client_id} is not running and could not be restarted"
            )

        for _ in range(len(self._round_robin)):
            client = self._round_robin[0]
            self._round_robin.rotate(-1)
            if await self._ensure_client_ready(client):
                return client

        await self.init()
        for _ in range(len(self._round_robin)):
            client = self._round_robin[0]
            self._round_robin.rotate(-1)
            if await self._ensure_client_ready(client):
                return client

        raise RuntimeError("No Gemini clients are currently available")
"""
    import re
    if "class GeminiClientPool" in ptxt:
        ptxt = re.sub(r'class GeminiClientPool\(metaclass=Singleton\):.*?async def _ensure_client_ready', new_pool_code.strip() + "\n\n    async def _ensure_client_ready", ptxt, flags=re.DOTALL)
    pool_file.write_text(ptxt)

# 5. Ensure config/config.yaml exists and does not hold expired dummy credentials
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
    if "YOUR_SECURE" in c_txt or "g.a000" in c_txt or not c_txt.strip():
        import re
        c_txt = re.sub(r'secure_1psid:\s*".*?"', 'secure_1psid: ""', c_txt)
        c_txt = re.sub(r'secure_1psidts:\s*".*?"', 'secure_1psidts: ""', c_txt)
        cfg_file.write_text(c_txt)

# 6. Ensure FastAPI binds to localhost only (127.0.0.1)
cfg_py = fastapi_dir / "app" / "utils" / "config.py"
if cfg_py.exists():
    ctxt = cfg_py.read_text()
    if "host: str = Field(default=\"0.0.0.0\"" in ctxt:
        ctxt = ctxt.replace("host: str = Field(default=\"0.0.0.0\"", "host: str = Field(default=\"127.0.0.1\"")
    if "secure_1psidcc: str | None = Field" not in ctxt:
        ctxt = ctxt.replace(
            "secure_1psidts: str = Field(..., description=\"Gemini Secure 1PSIDTS\")",
            "secure_1psidts: str = Field(..., description=\"Gemini Secure 1PSIDTS\")\n    secure_1psidcc: str | None = Field(default=None, description=\"Gemini Secure 1PSIDCC\")"
        )
    cfg_py.write_text(ctxt)
' 2>/dev/null || true
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
    \"\"\"Return a clean list of available models based on configuration strategy.\"\"\"
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

    return models_data"""

if old_fn in txt:
    txt = txt.replace(old_fn, new_fn)
    p.write_text(txt)
' 2>/dev/null || true
    fi
fi
# Ensure StrEnum compatibility & DNS / SNI Proxy (xbox-dns.ru) support in gemini_webapi
"$PYTHON_EXEC" -c '
import glob
from pathlib import Path

for sp in glob.glob("'"$SMOL_DIR"'/.venv/lib/python*/site-packages"):
    # 0. Patch gemini_webapi/__init__.py for global BaseSession DoH
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
                "try:\n        from curl_cffi import CurlOpt\n        if curl_options is None:\n            curl_options = {CurlOpt.DOH_URL: b\"https://xbox-dns.ru/dns-query\"}\n    except Exception:\n        pass\n    client = AsyncSession(\n        impersonate=\"chrome\", proxy=proxy, allow_redirects=True, verify=verify, curl_options=curl_options\n    )"
            )
            gat_file.write_text(txt)

    # 3. Patch client.py to store and pass curl_options
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
        if "secure_1psidcc" not in txt:
            txt = txt.replace(
                "self._cookies.set(\n                    \"__Secure-1PSIDTS\", secure_1psidts, domain=\".google.com\"\n                )",
                "self._cookies.set(\n                    \"__Secure-1PSIDTS\", secure_1psidts, domain=\".google.com\"\n                )\n        if secure_1psidcc := kwargs.get(\"secure_1psidcc\"):\n            self._cookies.set(\"__Secure-1PSIDCC\", secure_1psidcc, domain=\".google.com\")"
            )
        if "Ignoring non-fatal post-generation code" not in txt:
            old_err = """                                    case _:
                                        raise APIError(
                                            f"Failed to generate contents (stream). Unknown API error code: {error_code}. "
                                            "This might be a temporary Google service issue."
                                        )"""
            new_err = """                                    case _:
                                        if has_generated_text or error_code in [1096]:
                                            logger.warning(f"Ignoring non-fatal post-generation code {error_code}")
                                            break
                                        raise APIError(
                                            f"Failed to generate contents (stream). Unknown API error code: {error_code}. "
                                            "This might be a temporary Google service issue."
                                        )"""
            if old_err in txt:
                txt = txt.replace("nonlocal is_thinking, is_queueing, has_candidates, is_completed, is_final_chunk, cid, rid", "nonlocal is_thinking, is_queueing, has_candidates, is_completed, is_final_chunk, cid, rid, has_generated_text")
                txt = txt.replace("has_candidates = False", "has_candidates = False\n                    has_generated_text = False")
                txt = txt.replace(old_err, new_err)
        client_file.write_text(txt)

    # 4. Patch image.py and video.py for file uploads
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

    # 4.5. Patch rotate_1psidts.py to preserve 1PSIDCC, 3PSIDCC and SIDCC in cookie cache
    rot_file = Path(f"{sp}/gemini_webapi/utils/rotate_1psidts.py")
    if rot_file.exists():
        rtxt = rot_file.read_text()
        if "__Secure-1PSIDCC" not in rtxt:
            rtxt = rtxt.replace(
                'is_auth_cookie = cookie.name in ["__Secure-1PSID", "__Secure-1PSIDTS"]',
                'is_auth_cookie = cookie.name in ["__Secure-1PSID", "__Secure-1PSIDTS", "__Secure-1PSIDCC", "__Secure-3PSID", "__Secure-3PSIDTS", "__Secure-3PSIDCC", "SIDCC"]'
            )
            rot_file.write_text(rtxt)

    # 5. Patch curl_cffi/requests/utils.py to guarantee DoH on ALL curl requests
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

# Check/Install agentic-browser and quizmaster skill dependencies
mkdir -p "$SKILL_DIR"
if [ -d "$SCRIPT_DIR/agentic-browser" ]; then
    cp -r "$SCRIPT_DIR/agentic-browser/"* "$SKILL_DIR/"
fi
QUIZ_DIR="$HOME/.agents/skills/quizmaster"
mkdir -p "$QUIZ_DIR"
if [ -d "$SCRIPT_DIR/quizmaster" ]; then
    cp -r "$SCRIPT_DIR/quizmaster/"* "$QUIZ_DIR/"
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

@tool
def quizmaster(max_questions: int = 0) -> str:
    """
    Runs the QuizMaster interactive assistant on the connected browser session (port 9222) in an indefinite loop.
    Monitors the active browser tab for quiz questions (both multiple-choice options/checkboxes and open-ended text inputs),
    uses the AI model to determine the best answer, non-intrusively selects the option or types the answer (~200ms/char),
    and waits for the user to proceed to the next question.
    Runs indefinitely until the quiz ends or until interrupted (Ctrl+C).

    Args:
        max_questions: Maximum number of questions to process (default is 0, which means run indefinitely in a loop until stopped or finished). Pass 1 to answer only the current question.
    """
    import subprocess
    import os
    import json
    import time
    import urllib.request

    script_path = os.path.expanduser("~/.agents/skills/agentic-browser/scripts/agent.js")
    prev_q = ""
    answered_count = 0
    results_summary = []

    print("\n[QuizMaster] Activated. Connecting to active browser on port 9222...", flush=True)
    print("[QuizMaster] Running in live loop. Non-intrusive: answers are selected/typed without submitting.", flush=True)
    print("[QuizMaster] Press Ctrl+C at any time to stop.\n", flush=True)

    try:
        while True:
            if max_questions > 0 and answered_count >= max_questions:
                print(f"[QuizMaster] Reached limit of {max_questions} questions.", flush=True)
                break

            cmd = ["node", script_path, "wait-quiz"]
            if prev_q:
                cmd.append(prev_q)

            try:
                res = subprocess.run(cmd, capture_output=True, text=True)
            except Exception as e:
                print(f"[QuizMaster] Execution error: {e}", flush=True)
                break

            out_text = res.stdout.strip()
            if not out_text:
                err_text = res.stderr.strip()
                if "Failed to connect to browser" in err_text:
                    msg = "Failed to connect to browser on port 9222. Please start Yandex Browser with:\nyandex-browser --remote-debugging-port=9222 --user-data-dir=$HOME/.config/yandex-browser-debug --remote-allow-origins=\"*\""
                    print(f"[QuizMaster] {msg}", flush=True)
                    return msg
                print(f"[QuizMaster] No question received. Exiting.", flush=True)
                break

            try:
                state = json.loads(out_text)
            except Exception:
                print(f"[QuizMaster] Output was not valid JSON: {out_text[:200]}", flush=True)
                break

            if state.get("status") != "ready":
                print(f"[QuizMaster] Quiz state: {state}", flush=True)
                break

            q_text = state.get("question", "")
            q_type = state.get("type", "choice")
            options = state.get("options", [])
            is_multi = state.get("isMulti", False)
            url = state.get("url", "")

            print(f"\n==================================================", flush=True)
            print(f"[QuizMaster] Question {answered_count + 1}:", flush=True)
            print(f"{q_text}", flush=True)
            print(f"Type: {q_type} | URL: {url}", flush=True)
            if options:
                print("Options:", flush=True)
                for opt in options:
                    print(f"  - {opt.get('text')}", flush=True)

            # Query local Gemini-FastAPI model endpoint for best answer
            prompt_content = f"You are an expert quiz solver. Question:\n{q_text}\n\n"
            if q_type == "choice":
                opts_str = "\n".join([f"- {opt.get('text')}" for opt in options])
                prompt_content += (
                    f"Options:\n{opts_str}\n\n"
                    "Select the best/most appropriate option from the list above. "
                    "Return ONLY the exact text of the single selected option, verbatim. Do not explain."
                )
            else:
                prompt_content += (
                    "This is an open-ended question. "
                    "Provide a short, direct, appropriate answer to type into the text box. "
                    "Return ONLY the answer text, verbatim. Do not explain."
                )

            answer_text = ""
            try:
                req = urllib.request.Request(
                    "http://127.0.0.1:8000/v1/chat/completions",
                    headers={"Content-Type": "application/json"},
                    data=json.dumps({
                        "model": "gemini-3.8-flash",
                        "messages": [{"role": "user", "content": prompt_content}]
                    }).encode("utf-8")
                )
                opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
                with opener.open(req, timeout=30) as resp:
                    resp_data = json.loads(resp.read().decode("utf-8"))
                    answer_text = resp_data["choices"][0]["message"]["content"].strip()
            except Exception as e:
                print(f"[QuizMaster] Error querying model: {e}", flush=True)
                answer_text = options[0]["text"] if options else "Answer"

            clean_answer = answer_text.strip('"`*')
            print(f"[QuizMaster] Suggested answer: '{clean_answer}'", flush=True)

            if q_type == "choice":
                sel_res = subprocess.run(["node", script_path, "select", clean_answer], capture_output=True, text=True, timeout=30)
                print(f"[QuizMaster] Option selected: {sel_res.stdout.strip() or clean_answer}", flush=True)
                results_summary.append(f"Q: {q_text.splitlines()[0]} -> Selected: {clean_answer}")
            else:
                type_res = subprocess.run(["node", script_path, "type", clean_answer, "200"], capture_output=True, text=True, timeout=90)
                print(f"[QuizMaster] Typed answer at ~200ms/char: {clean_answer}", flush=True)
                results_summary.append(f"Q: {q_text.splitlines()[0]} -> Typed: {clean_answer}")

            answered_count += 1
            prev_q = q_text

            if max_questions > 0 and answered_count >= max_questions:
                break

            print(f"\n[QuizMaster] Answer applied! Proceed to next question in browser (Ctrl+C to stop)...", flush=True)
            time.sleep(1)

    except KeyboardInterrupt:
        print("\n[QuizMaster] Loop interrupted by user (Ctrl+C).", flush=True)

    return f"QuizMaster completed. Processed {answered_count} question(s):\n" + "\n".join(results_summary)

@tool
def wait_for_quiz_question(previous_question: str = "") -> str:
    """
    Waits in blocking mode for an active quiz question to appear or update in the connected Yandex/Chromium browser session on port 9222.
    Returns JSON containing the detected question text, question type ('choice' or 'open_ended'), options, and page url.

    Args:
        previous_question: Optional text or number of the previously answered question (e.g. 'Question 1 of 7') to avoid duplicate triggers.
    """
    import subprocess
    import os
    script_path = os.path.expanduser("~/.agents/skills/agentic-browser/scripts/agent.js")
    cmd = ["node", script_path, "wait-quiz"]
    if previous_question:
        cmd.append(previous_question)
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
        return res.stdout.strip() or res.stderr.strip() or "No quiz question detected."
    except subprocess.TimeoutExpired:
        return "Timeout waiting for quiz question."
    except Exception as e:
        return f"Error executing wait-quiz: {str(e)}"

@tool
def select_quiz_option(option_text_or_index: str) -> str:
    """
    Non-intrusively selects a multiple-choice radio button, checkbox, or option button on the active quiz page in the browser without submitting.

    Args:
        option_text_or_index: The exact or partial label text of the option, or its 0-based index.
    """
    import subprocess
    import os
    script_path = os.path.expanduser("~/.agents/skills/agentic-browser/scripts/agent.js")
    cmd = ["node", script_path, "select", option_text_or_index]
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        return res.stdout.strip() or res.stderr.strip() or "Option selected."
    except Exception as e:
        return f"Error executing select: {str(e)}"

@tool
def type_quiz_answer(answer_text: str, delay_ms: int = 200) -> str:
    """
    Simulates realistic human typing into an open-ended quiz input field or textarea at the specified keystroke speed (~200ms per character).

    Args:
        answer_text: The answer string to type into the open-ended question text field.
        delay_ms: Delay in milliseconds between each typed character (default is 200ms).
    """
    import subprocess
    import os
    script_path = os.path.expanduser("~/.agents/skills/agentic-browser/scripts/agent.js")
    cmd = ["node", script_path, "type", answer_text, str(delay_ms)]
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=90)
        return res.stdout.strip() or res.stderr.strip() or "Answer typed."
    except Exception as e:
        return f"Error executing type: {str(e)}"

@tool
def type_quiz_file(file_path: str, delay_ms: int = 200) -> str:
    """
    Types code or text from a file into the active Monaco editor or open-ended text input at ~200ms/char with tab indentation.

    Args:
        file_path: Absolute or relative path to the file whose contents should be typed.
        delay_ms: Delay in milliseconds between keystrokes (default 200ms).
    """
    import subprocess
    import os
    script_path = os.path.expanduser("~/.agents/skills/agentic-browser/scripts/agent.js")
    resolved_path = os.path.abspath(os.path.expanduser(file_path))
    if not os.path.exists(resolved_path):
        return f"Error: File {resolved_path} does not exist."
    cmd = ["node", script_path, "type-file", resolved_path, str(delay_ms)]
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
        return res.stdout.strip() or res.stderr.strip() or "File typed successfully."
    except Exception as e:
        return f"Error executing type-file: {str(e)}"

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
        tools=[quizmaster, execute_bash, wait_for_quiz_question, select_quiz_option, type_quiz_answer, type_quiz_file],
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

if [ -f "$HOME/.bashrc" ]; then
    . "$HOME/.bashrc" 2>/dev/null || true
fi

unset all_proxy ALL_PROXY http_proxy HTTP_PROXY https_proxy HTTPS_PROXY

if ! curl --noproxy "*" --max-time 3 -s -f http://127.0.0.1:$FASTAPI_PORT/v1/models >/dev/null 2>&1; then
    echo "Starting Gemini-FastAPI server on port $FASTAPI_PORT..."
    (cd "$FASTAPI_DIR" && nohup env -u all_proxy -u ALL_PROXY -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY "$PYTHON_EXEC" run.py > "$STACK_DIR/proxy_access.log" 2>&1 &)
    
    PROXY_READY=0
    i=1
    while [ $i -le 60 ]; do
        if curl --noproxy "*" --max-time 3 -s -f http://127.0.0.1:$FASTAPI_PORT/v1/models >/dev/null 2>&1; then
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


