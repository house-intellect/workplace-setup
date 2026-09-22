#!/bin/bash
# Self-reexec with bash if invoked with sh/dash
if [ -z "$BASH_VERSION" ]; then
    exec /usr/bin/env bash "$0" "$@"
fi
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${1:-$SCRIPT_DIR/open-webui}"

echo "=== Open WebUI Auto-Installer & Tool Sync ==="

# 1. Deploy agentic-browser and quizmaster skills to home directory
echo "[1/4] Deploying agentic-browser and quizmaster skills..."
rm -f /tmp/gemini_webapi/.cached_cookies_*.json 2>/dev/null || true
mkdir -p "$HOME/.agents/skills/agentic-browser"
if [ -d "$SCRIPT_DIR/agentic-browser" ]; then
    cp -r "$SCRIPT_DIR/agentic-browser/"* "$HOME/.agents/skills/agentic-browser/"
fi
mkdir -p "$HOME/.agents/skills/quizmaster"
if [ -d "$SCRIPT_DIR/quizmaster" ]; then
    cp -r "$SCRIPT_DIR/quizmaster/"* "$HOME/.agents/skills/quizmaster/"
fi

if [ -f "$HOME/.agents/skills/agentic-browser/package.json" ]; then
    if [ ! -d "$HOME/.agents/skills/agentic-browser/node_modules" ]; then
        if command -v npm >/dev/null 2>&1; then
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
    elif command -v git >/dev/null 2>&1; then
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
    if command -v "$p" >/dev/null 2>&1 && check_python_version "$(command -v "$p")"; then
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

    # 1.2 Patch app/services/client.py (GeminiClientWrapper curl_options & AccountStatus check)
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

    # 1.3 Patch app/utils/helper.py (save_url_to_tempfile DoH)
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

    # 1.4 Patch app/services/pool.py (Rookiepy multi-browser extraction, prioritize Firefox, DoH)
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
                # Prioritize Firefox first
                for b_name in ["firefox", "chrome", "chromium", "brave"]:
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
                            fallback_client = GeminiClientWrapper(
                                client_id=f"live-{b_name}",
                                secure_1psid=psid,
                                secure_1psidts=psidts,
                                secure_1psidcc=psidcc,
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
        if "YOUR_SECURE" in c_txt or "g.a000" in c_txt or not c_txt.strip():
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
        if "secure_1psidcc: str | None = Field" not in ctxt:
            ctxt = ctxt.replace(
                "secure_1psidts: str = Field(..., description=\"Gemini Secure 1PSIDTS\")",
                "secure_1psidts: str = Field(..., description=\"Gemini Secure 1PSIDTS\")\n    secure_1psidcc: str | None = Field(default=None, description=\"Gemini Secure 1PSIDCC\")"
            )
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
        # Patch open_webui to bind strictly to localhost (127.0.0.1) instead of 0.0.0.0
        for webui_init in [Path(sp) / "open_webui" / "__init__.py"]:
            if webui_init.exists():
                wtxt = webui_init.read_text()
                if "host: str = '0.0.0.0'" in wtxt:
                    wtxt = wtxt.replace("host: str = '0.0.0.0'", "host: str = '127.0.0.1'")
                    webui_init.write_text(wtxt)

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

        # Patch rotate_1psidts.py to preserve 1PSIDCC, 3PSIDCC and SIDCC in cookie cache
        rot_file = Path(f"{sp}/gemini_webapi/utils/rotate_1psidts.py")
        if rot_file.exists():
            rtxt = rot_file.read_text()
            if "__Secure-1PSIDCC" not in rtxt:
                rtxt = rtxt.replace(
                    'is_auth_cookie = cookie.name in ["__Secure-1PSID", "__Secure-1PSIDTS"]',
                    'is_auth_cookie = cookie.name in ["__Secure-1PSID", "__Secure-1PSIDTS", "__Secure-1PSIDCC", "__Secure-3PSID", "__Secure-3PSIDTS", "__Secure-3PSIDCC", "SIDCC"]'
                )
                rot_file.write_text(rtxt)

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
if command -v ollama >/dev/null 2>&1; then
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

# 5. Ensure start-ai-stack.sh in local-ai-stack is synchronized with localhost binding
if [ -f "$SCRIPT_DIR/start-ai-stack.sh" ] && [ -d "$HOME/local-ai-stack" ]; then
    cp "$SCRIPT_DIR/start-ai-stack.sh" "$HOME/local-ai-stack/start-ai-stack.sh"
    chmod +x "$HOME/local-ai-stack/start-ai-stack.sh"
fi

echo "Open WebUI installation and tool sync complete!"
