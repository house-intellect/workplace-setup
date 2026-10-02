#!/bin/bash
# Self-reexec with bash if invoked with sh/dash
if [ -z "$BASH_VERSION" ]; then
    exec /usr/bin/env bash "$0" "$@"
fi
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${1:-$SCRIPT_DIR/open-webui}"

check_trash_execution() {
    local cwd_phys
    cwd_phys="$(pwd -P 2>/dev/null || pwd)"
    case "$SCRIPT_DIR|$cwd_phys" in
        *Trash*|*/.local/share/Trash/*|*/.Trash/*)
            echo "❌ ERROR: Cannot run installation from inside Trash directory:"
            echo "   SCRIPT_DIR: $SCRIPT_DIR"
            echo "   CWD:        $cwd_phys"
            echo ""
            echo "   This happens if previous project directories were deleted via a file manager or trash"
            echo "   while your terminal was still navigated inside them."
            echo "   Please navigate to a clean folder outside of Trash, for example:"
            echo "       cd ~"
            echo "       tar -xzf workplace-ai-bundle.tar.gz"
            echo "       cd workplace-setup && ./install-bundle.sh"
            exit 1
            ;;
    esac
}
check_trash_execution

# Detect user's private Firefox DoH resolver (e.g. network.trr.uri / custom_uri)
detect_firefox_doh() {
    local dirs=(
        "$HOME/.mozilla/firefox"
        "$HOME/.var/app/org.mozilla.firefox/.mozilla/firefox"
        "$HOME/snap/firefox/common/.mozilla/firefox"
    )
    for d in "${dirs[@]}"; do
        [ -d "$d" ] || continue
        for pref in "$d"/*/prefs.js; do
            [ -f "$pref" ] || continue
            local uri
            uri=$(grep -E 'network\.trr\.(custom_)?uri' "$pref" 2>/dev/null | grep -o 'https://[^"]*' | head -n1 || true)
            if [ -n "$uri" ]; then
                case "$uri" in
                    *xbox-dns*|*1.1.1.1*|*cloudflare*)
                        continue
                        ;;
                    *)
                        echo "$uri"
                        return 0
                        ;;
                esac
            fi
        done
    done
    return 1
}

# Configurable DNS-over-HTTPS (DoH) resolver for SNI routing around geoblocks
if [ -z "$CUSTOM_DOH_URL" ] && [ -z "$GEMINI_DOH_URL" ]; then
    DETECTED_DOH=$(detect_firefox_doh || true)
    if [ -n "$DETECTED_DOH" ]; then
        CUSTOM_DOH_URL="$DETECTED_DOH"
    else
        CUSTOM_DOH_URL="https://dns.bezmezhau.com/dns-query"
    fi
fi
CUSTOM_DOH_URL="${CUSTOM_DOH_URL:-${GEMINI_DOH_URL:-https://dns.bezmezhau.com/dns-query}}"
export CUSTOM_DOH_URL
export GEMINI_DOH_URL="$CUSTOM_DOH_URL"

echo "=== Open WebUI Auto-Installer & Tool Sync ==="

stop_running_stack() {
    local ports=(8000 8080)
    local found_occupying=0
    local announced_pids=""

    echo "Checking required stack ports (8000, 8080) and running instances..."

    # 1. Check processes holding required ports
    for port in "${ports[@]}"; do
        local pids=""
        if command -v lsof >/dev/null 2>&1; then
            pids=$(lsof -ti:"${port}" 2>/dev/null || true)
        fi
        if [ -z "$pids" ] && command -v fuser >/dev/null 2>&1; then
            pids=$(fuser "${port}/tcp" 2>/dev/null | tr -s ' ' '\n' | grep -v '^$' || true)
        fi

        if [ -n "$pids" ]; then
            for pid in $pids; do
                if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                    local cmd=""
                    if [ -r "/proc/$pid/cmdline" ]; then
                        cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | head -c 80 || true)
                    fi
                    [ -z "$cmd" ] && cmd=$(ps -p "$pid" -o comm= 2>/dev/null || echo "process")
                    echo "⚠️  Found process occupying required port $port: PID $pid ($cmd)"
                    echo "   -> Terminating PID $pid to allow bundle services to bind to port $port..."
                    found_occupying=1
                    announced_pids="$announced_pids $pid"
                fi
            done
        fi
    done

    # 2. Check known stack processes by pattern
    local pattern_pids
    pattern_pids=$(pgrep -f "gemini-fastapi.*run\.py|open-webui serve" 2>/dev/null || true)
    if [ -n "$pattern_pids" ]; then
        for pid in $pattern_pids; do
            case " $announced_pids " in
                *" $pid "*) ;; # already announced
                *)
                    if kill -0 "$pid" 2>/dev/null; then
                        local cmd=""
                        if [ -r "/proc/$pid/cmdline" ]; then
                            cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | head -c 80 || true)
                        fi
                        [ -z "$cmd" ] && cmd=$(ps -p "$pid" -o comm= 2>/dev/null || echo "process")
                        echo "⚠️  Found active previous stack instance: PID $pid ($cmd)"
                        echo "   -> Terminating PID $pid to prevent version collisions..."
                        found_occupying=1
                        announced_pids="$announced_pids $pid"
                    fi
                    ;;
            esac
        done
    fi

    # 3. Stop systemd services if present
    if command -v systemctl >/dev/null 2>&1; then
        for srv in open-webui.service gemini-fastapi.service; do
            if systemctl --user is-active "$srv" >/dev/null 2>&1; then
                echo "⚠️  Found active systemd user service: $srv"
                echo "   -> Stopping $srv so bundle services can manage ports 8000 and 8080..."
                systemctl --user stop "$srv" 2>/dev/null || true
                found_occupying=1
            fi
        done
        # Disable and remove standalone unshielded gemini-fastapi.service if present
        if systemctl --user list-unit-files gemini-fastapi.service 2>/dev/null | grep -q "gemini-fastapi.service" || [ -f "$HOME/.config/systemd/user/gemini-fastapi.service" ]; then
            systemctl --user disable --now gemini-fastapi.service 2>/dev/null || true
            rm -f "$HOME/.config/systemd/user/gemini-fastapi.service" "$HOME/.config/systemd/user/default.target.wants/gemini-fastapi.service" 2>/dev/null || true
            systemctl --user daemon-reload 2>/dev/null || true
        fi
    fi

    if [ "$found_occupying" -eq 0 ]; then
        echo "✓ Required ports (8000, 8080) are free. No conflicting processes detected."
        return 0
    fi

    # 4. Terminate with SIGTERM
    pkill -TERM -f "gemini-fastapi.*run\.py" 2>/dev/null || true
    pkill -TERM -f "open-webui serve" 2>/dev/null || true
    pkill -TERM -f "open_webui" 2>/dev/null || true

    for port in "${ports[@]}"; do
        if command -v fuser >/dev/null 2>&1; then
            fuser -k -TERM "${port}/tcp" >/dev/null 2>&1 || true
        fi
        if command -v lsof >/dev/null 2>&1; then
            local pids
            pids=$(lsof -ti:"${port}" 2>/dev/null || true)
            if [ -n "$pids" ]; then
                kill -TERM $pids >/dev/null 2>&1 || true
            fi
        fi
    done

    local wait_count=0
    while [ $wait_count -lt 5 ]; do
        if pgrep -f "gemini-fastapi.*run\.py" >/dev/null 2>&1 || pgrep -f "open-webui serve" >/dev/null 2>&1; then
            sleep 1
            wait_count=$((wait_count + 1))
        else
            break
        fi
    done

    # 5. Force kill fallback with SIGKILL if still holding ports or running
    for port in "${ports[@]}"; do
        if command -v fuser >/dev/null 2>&1; then
            fuser -k -KILL "${port}/tcp" >/dev/null 2>&1 || true
        fi
        if command -v lsof >/dev/null 2>&1; then
            local pids
            pids=$(lsof -ti:"${port}" 2>/dev/null || true)
            if [ -n "$pids" ]; then
                kill -9 $pids >/dev/null 2>&1 || true
            fi
        fi
    done
    pkill -9 -f "gemini-fastapi.*run\.py" 2>/dev/null || true
    pkill -9 -f "open-webui serve" 2>/dev/null || true
    pkill -9 -f "open_webui" 2>/dev/null || true
    rm -f /tmp/gemini_webapi/.cached_cookies_*.json 2>/dev/null || true
    echo "✓ Conflicting processes terminated. Ports 8000 and 8080 are now free."
}

# Stop any previous versions before proceeding with setup/update
stop_running_stack

# 1. Deploy agentic-browser and quizmaster skills to home directory
echo "[1/4] Deploying agentic-browser and quizmaster skills..."
rm -f /tmp/gemini_webapi/.cached_cookies_*.json 2>/dev/null || true
if [ -d "$SCRIPT_DIR/agentic-browser" ]; then
    echo "Cleanly overwriting previous agentic-browser skill..."
    rm -rf "$HOME/.agents/skills/agentic-browser"
    mkdir -p "$HOME/.agents/skills/agentic-browser"
    cp -r "$SCRIPT_DIR/agentic-browser/"* "$HOME/.agents/skills/agentic-browser/"
fi
if [ -d "$SCRIPT_DIR/quizmaster" ]; then
    echo "Cleanly overwriting previous quizmaster skill..."
    rm -rf "$HOME/.agents/skills/quizmaster"
    mkdir -p "$HOME/.agents/skills/quizmaster"
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
if [ -d "$SCRIPT_DIR/open-webui" ] && [ -f "$SCRIPT_DIR/open-webui/package.json" ]; then
    if [ "$TARGET_DIR" != "$SCRIPT_DIR/open-webui" ]; then
        echo "Found pre-downloaded open-webui in $SCRIPT_DIR/open-webui. Cleanly updating $TARGET_DIR..."
        mkdir -p "$TARGET_DIR"
        if command -v rsync >/dev/null 2>&1; then
            rsync -a --delete --exclude='.venv' --exclude='backend/data' --exclude='data' "$SCRIPT_DIR/open-webui/" "$TARGET_DIR/"
        else
            cp -r "$SCRIPT_DIR/open-webui/"* "$TARGET_DIR/"
        fi
    fi
elif [ -d "$SCRIPT_DIR/open-webui-fork" ] && [ -f "$SCRIPT_DIR/open-webui-fork/package.json" ]; then
    if [ "$TARGET_DIR" != "$SCRIPT_DIR/open-webui-fork" ]; then
        echo "Found pre-downloaded open-webui-fork in $SCRIPT_DIR/open-webui-fork. Cleanly updating $TARGET_DIR..."
        mkdir -p "$TARGET_DIR"
        if command -v rsync >/dev/null 2>&1; then
            rsync -a --delete --exclude='.venv' --exclude='backend/data' --exclude='data' "$SCRIPT_DIR/open-webui-fork/" "$TARGET_DIR/"
        else
            cp -r "$SCRIPT_DIR/open-webui-fork/"* "$TARGET_DIR/"
        fi
    fi
elif [ -d "$(dirname "$SCRIPT_DIR")/open-webui-fork" ] && [ -f "$(dirname "$SCRIPT_DIR")/open-webui-fork/package.json" ]; then
    PARENT_FORK="$(dirname "$SCRIPT_DIR")/open-webui-fork"
    if [ "$TARGET_DIR" != "$PARENT_FORK" ]; then
        echo "Found local open-webui-fork in $PARENT_FORK. Cleanly updating $TARGET_DIR..."
        mkdir -p "$TARGET_DIR"
        if command -v rsync >/dev/null 2>&1; then
            rsync -a --delete --exclude='.venv' --exclude='backend/data' --exclude='data' "$PARENT_FORK/" "$TARGET_DIR/"
        else
            cp -r "$PARENT_FORK/"* "$TARGET_DIR/"
        fi
    fi
elif [ -d "$SCRIPT_DIR/backend" ] && [ -f "$SCRIPT_DIR/package.json" ]; then
    echo "Running directly inside Open WebUI codebase ($SCRIPT_DIR)."
    TARGET_DIR="$SCRIPT_DIR"
elif [ -d "$TARGET_DIR" ] && [ -f "$TARGET_DIR/.venv/bin/open-webui" ]; then
    echo "Found existing Open WebUI installation with virtualenv at $TARGET_DIR."
elif [ -d "$HOME/local-ai-stack/open-webui" ] && ([ -f "$HOME/local-ai-stack/open-webui/package.json" ] || [ -f "$HOME/local-ai-stack/open-webui/.venv/bin/open-webui" ]); then
    echo "Using existing Open WebUI installation at $HOME/local-ai-stack/open-webui..."
    TARGET_DIR="$HOME/local-ai-stack/open-webui"
elif [ ! -d "$TARGET_DIR" ] || [ ! -f "$TARGET_DIR/package.json" -a ! -d "$TARGET_DIR/backend" -a ! -f "$TARGET_DIR/.venv/bin/open-webui" ]; then
    if command -v git >/dev/null 2>&1; then
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
    case "$SEARCH_CURR" in
        *Trash*|*/.local/share/Trash/*|*/.Trash/*)
            break
            ;;
    esac
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
for p in python3.12 python3.11 python3.10 python3; do
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

# 2.4 Verify & install lightweight Open WebUI dependencies without PyPI backtracking
CHECK_WEBUI_DEPS="import typer, aiohttp, sqlalchemy, aiosqlite, alembic, starlette_compress, starsessions, redis, mcp, google_re2, asgiref, ldap3"
if ! "$VENV_DIR/bin/python" -c "$CHECK_WEBUI_DEPS" 2>/dev/null; then
    echo "Installing required lightweight Open WebUI dependencies into $VENV_DIR..."
    "$VENV_DIR/bin/pip" install --no-cache-dir \
        typer==0.25.1 aiohttp==3.13.5 sqlalchemy==2.0.50 aiosqlite==0.22.1 alembic==1.18.4 \
        argon2-cffi==25.1.0 authlib==1.7.2 bcrypt==5.0.0 brotli==1.2.0 itsdangerous==2.2.0 \
        joserfc==1.7.4 "pyjwt[crypto]==2.13.0" python-socketio==5.16.2 starlette-compress==1.7.1 \
        "starsessions[redis]==2.2.1" aiocache==0.12.3 aiofiles==25.1.0 greenlet redis==8.0.1 \
        async-timeout==5.0.1 pycrdt python-dateutil pytz fake-useragent ftfy chardet \
        Markdown beautifulsoup4 lxml validators psutil rank-bm25 python-mimeparse python-multipart \
        aiodns==3.6.1 hiredis==3.4.0 langchain-core langchain-text-splitters langchain-classic \
        black tiktoken pillow "mcp==1.27.2" google-re2 asgiref azure-identity ldap3==2.9.1 2>/dev/null || true
fi

# 2.5 Ensure executable launcher exists at $VENV_DIR/bin/open-webui
mkdir -p "$VENV_DIR/bin"
cat << 'EOF_LAUNCHER' > "$VENV_DIR/bin/open-webui"
#!/bin/sh
'''exec' "$(dirname "$0")/python" "$0" "$@"
' '''
import sys
import os

os.environ.setdefault("USE_SLIM", "true")
os.environ.setdefault("USE_SLIM_DOCKER", "true")

bin_dir = os.path.dirname(os.path.abspath(__file__))
venv_dir = os.path.dirname(bin_dir)
webui_dir = os.path.dirname(venv_dir)

candidates = [
    os.path.join(webui_dir, "backend"),
    os.path.expanduser("~/local-ai-stack/open-webui/backend"),
]
for c in candidates:
    if os.path.isdir(c) and c not in sys.path:
        sys.path.insert(0, c)

for sp in [
    os.path.expanduser("~/local-ai-stack/tool-calling-test/.venv/lib/python3.11/site-packages"),
    os.path.expanduser("~/local-ai-stack/tool-calling-test/.venv/lib/python3.10/site-packages"),
    os.path.expanduser("~/local-ai-stack/tool-calling-test/.venv/lib/python3.12/site-packages"),
]:
    if os.path.isdir(sp) and sp not in sys.path:
        sys.path.append(sp)

if "FRONTEND_BUILD_DIR" not in os.environ:
    build_dir = os.path.join(webui_dir, "build")
    if os.path.isdir(build_dir):
        os.environ["FRONTEND_BUILD_DIR"] = build_dir

from open_webui import app

if __name__ == '__main__':
    sys.argv[0] = sys.argv[0].removesuffix('.exe')
    sys.exit(app())
EOF_LAUNCHER
chmod +x "$VENV_DIR/bin/open-webui"
echo "✓ Configured Open WebUI launcher: $VENV_DIR/bin/open-webui"

# 3. Ensure Gemini-FastAPI Bridge, Cookie Fallbacks & Custom DNS (dns.bezmezhau.com) are Present
FASTAPI_DIR="$(dirname "$TARGET_DIR")/gemini-fastapi"
if [ -d "$SCRIPT_DIR/Gemini-FastAPI" ] && [ -f "$SCRIPT_DIR/Gemini-FastAPI/run.py" ]; then
    echo "Found pre-downloaded Gemini-FastAPI in $SCRIPT_DIR/Gemini-FastAPI. Cleanly overwriting previous version at $FASTAPI_DIR..."
    rm -rf "$FASTAPI_DIR"
    mkdir -p "$FASTAPI_DIR"
    cp -r "$SCRIPT_DIR/Gemini-FastAPI/"* "$FASTAPI_DIR/"
elif [ -d "$SCRIPT_DIR/gemini-fastapi" ] && [ -f "$SCRIPT_DIR/gemini-fastapi/run.py" ]; then
    echo "Found pre-downloaded gemini-fastapi in $SCRIPT_DIR/gemini-fastapi. Cleanly overwriting previous version at $FASTAPI_DIR..."
    rm -rf "$FASTAPI_DIR"
    mkdir -p "$FASTAPI_DIR"
    cp -r "$SCRIPT_DIR/gemini-fastapi/"* "$FASTAPI_DIR/"
elif [ ! -d "$FASTAPI_DIR" ]; then
    if [ -d "$HOME/local-ai-stack/gemini-fastapi" ]; then
        FASTAPI_DIR="$HOME/local-ai-stack/gemini-fastapi"
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
    import os

    _orig_base_init = BaseSession.__init__

    def _doh_base_init(self, *args, **kwargs):
        curl_opts = kwargs.get("curl_options")
        if curl_opts is None:
            curl_opts = {}
            kwargs["curl_options"] = curl_opts
        if isinstance(curl_opts, dict) and CurlOpt.DOH_URL not in curl_opts:
            doh_endpoint = os.environ.get("CUSTOM_DOH_URL", os.environ.get("GEMINI_DOH_URL", "https://dns.bezmezhau.com/dns-query"))
            if isinstance(doh_endpoint, str):
                doh_endpoint = doh_endpoint.encode()
            curl_opts[CurlOpt.DOH_URL] = doh_endpoint
        _orig_base_init(self, *args, **kwargs)

    BaseSession.__init__ = _doh_base_init
except Exception:
    pass

"""
            app_init.write_text(doh_code + atxt)
        elif "xbox-dns.ru" in atxt or "dns.comss.one" in atxt:
            atxt = atxt.replace("https://xbox-dns.ru/dns-query", "https://dns.bezmezhau.com/dns-query").replace("https://dns.comss.one/dns-query", "https://dns.bezmezhau.com/dns-query")
            app_init.write_text(atxt)

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
        doh_endpoint = os.environ.get("CUSTOM_DOH_URL", os.environ.get("GEMINI_DOH_URL", "https://dns.bezmezhau.com/dns-query"))
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
            _doh = os.environ.get("CUSTOM_DOH_URL", os.environ.get("GEMINI_DOH_URL", "https://dns.bezmezhau.com/dns-query"))
            if isinstance(_doh, str):
                _doh = _doh.encode()
            h_opts = {CurlOpt.DOH_URL: _doh}
        except Exception:
            h_opts = {}
        async with AsyncSession(impersonate="chrome", curl_options=h_opts) as client:"""
            )
            helper_file.write_text(htxt)
        elif "xbox-dns.ru" in htxt or "dns.comss.one" in htxt:
            htxt = htxt.replace("https://xbox-dns.ru/dns-query", "https://dns.bezmezhau.com/dns-query").replace("https://dns.comss.one/dns-query", "https://dns.bezmezhau.com/dns-query")
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
        doh_url = os.environ.get("CUSTOM_DOH_URL", os.environ.get("GEMINI_DOH_URL", "https://dns.bezmezhau.com/dns-query"))
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
                doh_url = os.environ.get("CUSTOM_DOH_URL", os.environ.get("GEMINI_DOH_URL", "https://dns.bezmezhau.com/dns-query"))
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

    # 1.7 Ensure Gemini models and 1 req / 2s max frequency rate limiting in chat.py
    chat_file = fastapi_dir / "app" / "server" / "chat.py"
    if chat_file.exists():
        ch_txt = chat_file.read_text()
        if "import asyncio" not in ch_txt:
            ch_txt = "import asyncio\nimport time\n" + ch_txt
        elif "import time" not in ch_txt:
            ch_txt = "import time\n" + ch_txt

        if "gemini-3.7-flash" not in ch_txt and "MODEL_ALIASES" not in ch_txt:
            old_m = """def _get_model_by_name(name: str) -> Model:
    \"\"\"Retrieve a Model instance by name.\"\"\"
    strategy = g_config.gemini.model_strategy
    custom_models = {m.model_name: m for m in g_config.gemini.models if m.model_name}

    if name in custom_models:
        return Model.from_dict(custom_models[name].model_dump())

    if strategy == "overwrite":
        raise ValueError(f"Model \x27{name}\x27 not found in custom models (strategy=\x27overwrite\x27).")

    return Model.from_name(name)"""

            new_m = """MODEL_ALIASES = {
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
            if old_m in ch_txt:
                ch_txt = ch_txt.replace(old_m, new_m)

        if "MIN_REQUEST_INTERVAL" not in ch_txt:
            rl_code = """
_rate_limit_lock = asyncio.Lock()
_last_request_time = 0.0
_last_response_time = 0.0
MIN_REQUEST_INTERVAL = 2.0  # Impose max request frequency: at most 1 request per 2 seconds

async def _throttle_request():
    global _last_request_time, _last_response_time
    async with _rate_limit_lock:
        now = time.monotonic()
        target_time = max(_last_request_time, _last_response_time) + MIN_REQUEST_INTERVAL
        if now < target_time:
            wait_sec = target_time - now
            logger.info(f"Rate limiting active: waiting {wait_sec:.2f}s before sending to Gemini...")
            await asyncio.sleep(wait_sec)
        _last_request_time = time.monotonic()

def _mark_response_completed():
    global _last_response_time
    _last_response_time = time.monotonic()

"""
            ch_txt = ch_txt.replace("async def _send_with_split(", rl_code + "async def _send_with_split(")

        if "await _throttle_request()" not in ch_txt:
            ch_txt = ch_txt.replace(
                "async def _send_with_split(\n    session: ChatSession,\n    text: str,\n    files: list[Path | str | io.BytesIO] | None = None,\n    stream: bool = False,\n    temporary: bool = False,\n) -> AsyncGenerator[ModelOutput] | ModelOutput:\n    \"\"\"Send text to Gemini, splitting or converting to attachment if too long.\"\"\"\n",
                "async def _send_with_split(\n    session: ChatSession,\n    text: str,\n    files: list[Path | str | io.BytesIO] | None = None,\n    stream: bool = False,\n    temporary: bool = False,\n) -> AsyncGenerator[ModelOutput] | ModelOutput:\n    \"\"\"Send text to Gemini, splitting or converting to attachment if too long.\"\"\"\n    await _throttle_request()\n"
            )

        if "should_fallback = reused_session" not in ch_txt:
            old_fallback = """        should_fallback = (
            reused_session
            and not stream
            and _is_missing_chat_error(exc)
        )"""
            new_fallback = "        should_fallback = reused_session"
            if old_fallback in ch_txt:
                ch_txt = ch_txt.replace(old_fallback, new_fallback)
                ch_txt = ch_txt.replace("stream=False,\n            temporary=temporary,\n        )\n        return output, fallback_session, fallback_client", "stream=stream,\n            temporary=temporary,\n        )\n        return output, fallback_session, fallback_client")

        if "_mark_response_completed()" in ch_txt and "yield \"data: [DONE]\\n\\n\"\\n        _mark_response_completed()" not in ch_txt:
            ch_txt = ch_txt.replace("yield \"data: [DONE]\\n\\n\"", "yield \"data: [DONE]\\n\\n\"\n        _mark_response_completed()")

        chat_file.write_text(ch_txt)

# 2. Patch gemini_webapi in all site-packages across stack and target venv
search_roots = [
    "'"$VENV_DIR"'",
    "'"$TARGET_DIR"'/.venv",
    "'"$HOME"'/local-ai-stack/tool-calling-test/.venv",
    "'"$HOME"'/local-ai-stack/open-webui/.venv"
]
sp_dirs = set()
for root in search_roots:
    for sp in glob.glob(f"{root}/lib/python*/site-packages"):
        if os.path.isdir(sp):
            sp_dirs.add(sp)
import sys, site
for p in sys.path + site.getsitepackages():
    if "site-packages" in p and os.path.isdir(p):
        sp_dirs.add(p)
for p in Path(sys.prefix).glob("lib/python*/site-packages"):
    if p.is_dir():
        sp_dirs.add(str(p))
for p in [
    os.path.expanduser("~/local-ai-stack/tool-calling-test/.venv/lib/python3.10/site-packages"),
    os.path.expanduser("~/local-ai-stack/tool-calling-test/.venv/lib/python3.11/site-packages"),
    os.path.expanduser("~/local-ai-stack/tool-calling-test/.venv/lib/python3.12/site-packages"),
    os.path.expanduser("~/local-ai-stack/open-webui/.venv/lib/python3.10/site-packages"),
    os.path.expanduser("~/local-ai-stack/open-webui/.venv/lib/python3.11/site-packages"),
    os.path.expanduser("~/local-ai-stack/open-webui/.venv/lib/python3.12/site-packages"),
]:
    if os.path.isdir(p):
        sp_dirs.add(p)

doh_url_str = os.environ.get("CUSTOM_DOH_URL", os.environ.get("GEMINI_DOH_URL", "https://dns.bezmezhau.com/dns-query"))

for sp in sorted(sp_dirs):
    # StrEnum compatibility
    for f in glob.glob(f"{sp}/gemini_webapi/**/*.py", recursive=True):
        p = Path(f)
        if p.exists():
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

    # Patch open_webui env.py for USE_SLIM and version metadata fallback
    for env_file in [
        Path(sp) / "open_webui" / "env.py",
        Path("'"$TARGET_DIR"'") / "backend" / "open_webui" / "env.py",
        Path("'"$TARGET_DIR"'") / "open_webui" / "env.py",
    ]:
        if env_file.exists():
            etxt = env_file.read_text()
            if "USE_SLIM = os.getenv('USE_SLIM_DOCKER', 'False')" in etxt:
                etxt = etxt.replace(
                    "USE_SLIM = os.getenv('USE_SLIM_DOCKER', 'False').lower() == 'true'",
                    "USE_SLIM = os.getenv('USE_SLIM_DOCKER', os.getenv('USE_SLIM', 'True')).lower() == 'true'"
                )
            if "PACKAGE_DATA = {'version': importlib.metadata.version('open-webui')}" in etxt and "except Exception:" not in etxt:
                old_pkg = "PACKAGE_DATA = {'version': importlib.metadata.version('open-webui')}"
                new_pkg = """try:
        PACKAGE_DATA = {'version': importlib.metadata.version('open-webui')}
    except Exception:
        try:
            PACKAGE_DATA = json.loads((BASE_DIR / 'package.json').read_text())
        except Exception:
            PACKAGE_DATA = {'version': '0.11.0'}"""
                etxt = etxt.replace(old_pkg, new_pkg)
            if "DATA_DIR = Path(os.getenv('DATA_DIR', BACKEND_DIR / 'data')).resolve()" in etxt:
                if "DATA_DIR.mkdir(parents=True, exist_ok=True)" not in etxt:
                    etxt = etxt.replace(
                        "DATA_DIR = Path(os.getenv('DATA_DIR', BACKEND_DIR / 'data')).resolve()",
                        "DATA_DIR = Path(os.getenv('DATA_DIR', BACKEND_DIR / 'data')).resolve()\nDATA_DIR.mkdir(parents=True, exist_ok=True)"
                    )
            env_file.write_text(etxt)

    # Patch open_webui routers/auths.py to make ldap3 optional
    for auths_file in [
        Path(sp) / "open_webui" / "routers" / "auths.py",
        Path("'"$TARGET_DIR"'") / "backend" / "open_webui" / "routers" / "auths.py",
        Path("'"$TARGET_DIR"'") / "open_webui" / "routers" / "auths.py",
    ]:
        if auths_file.exists():
            atxt = auths_file.read_text()
            if "from ldap3 import NONE" in atxt and "except ImportError:" not in atxt:
                old_ldap = """from ldap3 import NONE, Connection, Server, Tls
from ldap3.utils.conv import escape_filter_chars
from ldap3.utils.dn import parse_dn"""
                new_ldap = """try:
    from ldap3 import NONE, Connection, Server, Tls
    from ldap3.utils.conv import escape_filter_chars
    from ldap3.utils.dn import parse_dn
except ImportError:
    NONE = Connection = Server = Tls = None
    escape_filter_chars = lambda x: x
    parse_dn = lambda x: []"""
                atxt = atxt.replace(old_ldap, new_ldap)
                auths_file.write_text(atxt)

    # Patch gemini_webapi/__init__.py for global BaseSession DoH
    init_file = Path(f"{sp}/gemini_webapi/__init__.py")
    if init_file.exists():
        txt = init_file.read_text()
        if "CurlOpt.DOH_URL" not in txt:
            doh_code = f"""try:
    from curl_cffi import CurlOpt
    from curl_cffi.requests.session import BaseSession
    import os

    _orig_base_init = BaseSession.__init__

    def _doh_base_init(self, *args, **kwargs):
        curl_opts = kwargs.get("curl_options")
        if curl_opts is None:
            curl_opts = {{}}
            kwargs["curl_options"] = curl_opts
        if isinstance(curl_opts, dict) and CurlOpt.DOH_URL not in curl_opts:
            doh_url = os.environ.get("CUSTOM_DOH_URL", os.environ.get("GEMINI_DOH_URL", "{doh_url_str}"))
            if isinstance(doh_url, str):
                doh_url = doh_url.encode()
            curl_opts[CurlOpt.DOH_URL] = doh_url
        _orig_base_init(self, *args, **kwargs)

    BaseSession.__init__ = _doh_base_init
except Exception:
    pass

"""
            init_file.write_text(doh_code + txt)
        elif "xbox-dns.ru" in txt:
            txt = txt.replace("https://xbox-dns.ru/dns-query", doh_url_str)
            init_file.write_text(txt)

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
                f"try:\n        from curl_cffi import CurlOpt\n        if curl_options is None:\n            curl_options = {{CurlOpt.DOH_URL: b\"{doh_url_str}\"}}\n    except Exception:\n        pass\n    client = AsyncSession(\n        impersonate=\"chrome\", proxy=proxy, allow_redirects=True, verify=verify, curl_options=curl_options\n    )"
            )
            gat_file.write_text(txt)
        elif "xbox-dns.ru" in txt:
            txt = txt.replace("https://xbox-dns.ru/dns-query", doh_url_str)
            gat_file.write_text(txt)

    # Patch client.py
    client_file = Path(f"{sp}/gemini_webapi/client.py")
    if client_file.exists():
        txt = client_file.read_text()
        if "self.curl_options" not in txt:
            txt = txt.replace(
                "self.kwargs = kwargs",
                f"self.kwargs = kwargs\n        self.curl_options = kwargs.get(\"curl_options\")\n        if self.curl_options is None:\n            try:\n                from curl_cffi import CurlOpt\n                self.curl_options = {{CurlOpt.DOH_URL: b\"{doh_url_str}\"}}\n            except Exception:\n                pass"
            )
            txt = txt.replace(
                "verify=self.kwargs.get(\"verify\", True),",
                "verify=self.kwargs.get(\"verify\", True),\n                    curl_options=self.curl_options,"
            )
        elif "xbox-dns.ru" in txt:
            txt = txt.replace("https://xbox-dns.ru/dns-query", doh_url_str)
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
                    f"req_curl_opts = getattr(self.client, \"curl_options\", None)\n        if req_curl_opts is None:\n            try:\n                from curl_cffi import CurlOpt\n                req_curl_opts = {{CurlOpt.DOH_URL: b\"{doh_url_str}\"}}\n            except Exception:\n                pass\n        req_client = AsyncSession(\n            impersonate=\"chrome\", proxy=proxy, allow_redirects=True, verify=verify, curl_options=req_curl_opts\n        )"
                )
                type_file.write_text(txt)
            elif "xbox-dns.ru" in txt:
                txt = txt.replace("https://xbox-dns.ru/dns-query", doh_url_str)
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
        if doh_url_str not in utxt and "if curl_options:" in utxt:
            utxt = utxt.replace(
                "    if curl_options:\n        for option, setting in curl_options.items():\n            c.setopt(option, setting)",
                f"""    if curl_options is None:
        curl_options = {{}}
    else:
        curl_options = dict(curl_options)
    if CurlOpt.DOH_URL not in curl_options:
        curl_options[CurlOpt.DOH_URL] = b"{doh_url_str}"
    for option, setting in curl_options.items():
        c.setopt(option, setting)"""
            )
            utils_file.write_text(utxt)
        elif "xbox-dns.ru" in utxt:
            utxt = utxt.replace("https://xbox-dns.ru/dns-query", doh_url_str)
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

    async def execute_bash(self, command: str) -> str:
        """
        Execute any command or script in a full Bash terminal environment.

        :param command: The bash command line or multiline script to execute in /bin/bash.
        :return: Terminal stdout and stderr output.
        """
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

    async def bash_tool(self, command: str) -> str:
        """
        Execute any command or script in a full Bash terminal environment (alias for execute_bash).

        :param command: The bash command line or multiline script to execute in /bin/bash.
        :return: Terminal stdout and stderr output.
        """
        return await self.execute_bash(command)
'''

bash_specs = [
    {
        "name": "execute_bash",
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
    },
    {
        "name": "bash_tool",
        "description": "Execute any command or script in a full Bash terminal environment (alias for execute_bash).",
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
    }
]

browser_content = '''"""
title: Agentic Browser Tool
author: Local AI Stack
version: 1.2.0
description: Autonomous semantic browser navigation tool using Puppeteer on port 9222
"""

import subprocess
import os

class Tools:
    def __init__(self):
        pass

    async def agentic_browser(
        self,
        action: str,
        target: str = "",
        value: str = "",
        tab: int = -1
    ) -> str:
        """
        Interact with the browser autonomously using semantic mapping, step-fill input, and navigation.

        :param action: Action to perform: 'map', 'click', 'input' (step-fill by default), 'step_fill', 'goto', 'screenshot', 'scroll', 'select_option', 'upload', 'errors', 'eval', 'tabs', 'wait', 'text', 'reset_viewport'.
        :param target: Target element text, placeholder, selector, URL, direction ('down'/'up'/'bottom'/'top'), or code.
        :param value: Value to type/input, option to select, or additional arguments.
        :param tab: Target browser tab index (e.g. 0, 1, 2) or -1 for active tab.
        :return: Result of the browser action.
        """
        try:
            script_path = os.path.expanduser("~/.agents/skills/agentic-browser/scripts/agent.js")
            if not os.path.exists(script_path):
                alt_path = os.path.expanduser("~/PythonProjects/workplace-setup/agentic-browser/scripts/agent.js")
                if os.path.exists(alt_path):
                    script_path = alt_path

            cmd = ["node", script_path]
            if tab is not None and int(tab) >= 0:
                cmd.append(f"--tab={int(tab)}")

            act = action.strip().lower().replace("_", "-")
            cmd.append(act)

            if target:
                cmd.append(str(target))
            if value:
                cmd.append(str(value))

            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=60
            )
            output = result.stdout
            if result.stderr:
                output = output + (chr(10) if output else "") + result.stderr
            if output and output.strip():
                return output.strip()
            return "Browser action completed with no output."
        except Exception as e:
            return f"Error executing browser action: {str(e)}"
'''

browser_specs = [{
    "name": "agentic_browser",
    "description": "Interact with the browser autonomously using semantic mapping, step-fill input, and navigation.",
    "parameters": {
        "type": "object",
        "properties": {
            "action": {
                "type": "string",
                "description": "Action to perform: 'map', 'click', 'input' (step-fill by default), 'step_fill', 'goto', 'screenshot', 'scroll', 'select_option', 'upload', 'errors', 'eval', 'tabs', 'wait', 'text', 'reset_viewport'."
            },
            "target": {
                "type": "string",
                "description": "Target element text, placeholder, selector, URL, direction ('down'/'up'/'bottom'/'top'), or code."
            },
            "value": {
                "type": "string",
                "description": "Value to type/input, option to select, or additional arguments."
            },
            "tab": {
                "type": "integer",
                "description": "Target browser tab index (e.g. 0, 1, 2) or -1 for active tab."
            }
        },
        "required": ["action"]
    }
}]

# Resolve tool owner: assign to existing admin user if present, otherwise 'system'
owner_id = 'system'
try:
    cursor.execute("SELECT id FROM user WHERE role='admin' ORDER BY created_at ASC LIMIT 1")
    admin_row = cursor.fetchone()
    if admin_row:
        owner_id = admin_row[0]
except Exception:
    pass

bash_meta = {
    "description": "Real Bash terminal execution tool supporting piping, sequencing, redirects, and multiline scripts",
    "manifest": {
        "title": "Native Bash Tool",
        "author": "Local AI Stack",
        "version": "1.1.0"
    },
    "has_user_valves": False
}
bash_valves = {}

browser_meta = {
    "description": "Autonomous semantic browser navigation tool using Puppeteer on port 9222",
    "manifest": {
        "title": "Agentic Browser Tool",
        "author": "Local AI Stack",
        "version": "1.0.0"
    },
    "has_user_valves": False
}
browser_valves = {}

cursor.execute("""
    INSERT INTO tool (id, user_id, name, content, specs, meta, valves, updated_at, created_at)
    VALUES ('native_bash_tool', ?, 'Native Bash Tool', ?, ?, ?, ?, strftime('%s', 'now'), strftime('%s', 'now'))
    ON CONFLICT(id) DO UPDATE SET
        content=excluded.content,
        specs=excluded.specs,
        meta=excluded.meta,
        valves=excluded.valves,
        updated_at=strftime('%s', 'now')
""", (owner_id, bash_content, json.dumps(bash_specs), json.dumps(bash_meta), json.dumps(bash_valves)))

cursor.execute("""
    INSERT INTO tool (id, user_id, name, content, specs, meta, valves, updated_at, created_at)
    VALUES ('agentic_browser_tool', ?, 'Agentic Browser Tool', ?, ?, ?, ?, strftime('%s', 'now'), strftime('%s', 'now'))
    ON CONFLICT(id) DO UPDATE SET
        content=excluded.content,
        specs=excluded.specs,
        meta=excluded.meta,
        valves=excluded.valves,
        updated_at=strftime('%s', 'now')
""", (owner_id, browser_content, json.dumps(browser_specs), json.dumps(browser_meta), json.dumps(browser_valves)))

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

    # Impose max request frequency: disable concurrent auto-tasks in Open WebUI
    # (title, tags, follow_up, autocomplete) that flood the Gemini Web proxy with parallel requests
    cursor.execute("""
        INSERT INTO config (key, value, updated_at)
        VALUES ('task.title.enable', 'false', strftime('%s', 'now'))
        ON CONFLICT(key) DO UPDATE SET value='false', updated_at=strftime('%s', 'now')
    """)
    cursor.execute("""
        INSERT INTO config (key, value, updated_at)
        VALUES ('task.tags.enable', 'false', strftime('%s', 'now'))
        ON CONFLICT(key) DO UPDATE SET value='false', updated_at=strftime('%s', 'now')
    """)
    cursor.execute("""
        INSERT INTO config (key, value, updated_at)
        VALUES ('task.follow_up.enable', 'false', strftime('%s', 'now'))
        ON CONFLICT(key) DO UPDATE SET value='false', updated_at=strftime('%s', 'now')
    """)
    cursor.execute("""
        INSERT INTO config (key, value, updated_at)
        VALUES ('task.autocomplete.enable', 'false', strftime('%s', 'now'))
        ON CONFLICT(key) DO UPDATE SET value='false', updated_at=strftime('%s', 'now')
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

    meta_37_flash = json.dumps({
        "profile_image_url": "/static/favicon.png",
        "description": "Gemini 3.7 Flash - Fast multimodal all-around model",
        "capabilities": {
            "vision": True, "file_upload": True, "web_search": True,
            "code_interpreter": True, "terminal": True, "builtin_tools": True
        }
    })
    meta_37_pro = json.dumps({
        "profile_image_url": "/static/favicon.png",
        "description": "Gemini 3.7 Pro - Advanced reasoning and coding model",
        "capabilities": {
            "vision": True, "file_upload": True, "web_search": True,
            "code_interpreter": True, "terminal": True, "builtin_tools": True
        }
    })

    models_to_register = [
        ("gemini-3.7-flash", "Gemini 3.7 Flash", meta_37_flash),
        ("gemini-3.7-pro", "Gemini 3.7 Pro", meta_37_pro),
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
            VALUES (?, ?, ?, ?, '{}', ?, strftime('%s', 'now'), strftime('%s', 'now'), 1)
            ON CONFLICT(id) DO UPDATE SET
                name=excluded.name,
                meta=excluded.meta,
                is_active=1,
                updated_at=strftime('%s', 'now')
        """, (m_id, owner_id, m_id, m_name, m_meta))

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

# 6. Ensure systemd user service exists if systemctl is available
if command -v systemctl >/dev/null 2>&1; then
    SERVICE_DIR="$HOME/.config/systemd/user"
    mkdir -p "$SERVICE_DIR"
    # Remove obsolete standalone gemini-fastapi service if present
    systemctl --user disable --now gemini-fastapi.service 2>/dev/null || true
    rm -f "$SERVICE_DIR/gemini-fastapi.service" "$SERVICE_DIR/default.target.wants/gemini-fastapi.service" 2>/dev/null || true

    cat << EOF_SRV > "$SERVICE_DIR/open-webui.service"
[Unit]
Description=Open WebUI and Local AI Stack
After=network.target

[Service]
Type=simple
WorkingDirectory=$HOME/local-ai-stack
ExecStart=/bin/sh $HOME/local-ai-stack/start-ai-stack.sh
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
EOF_SRV
    systemctl --user daemon-reload 2>/dev/null || true
    echo "✓ Configured systemd user service: $SERVICE_DIR/open-webui.service"
fi

echo "Open WebUI installation and tool sync complete!"
