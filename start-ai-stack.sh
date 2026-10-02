#!/bin/bash
if [ -z "$BASH_VERSION" ]; then
    exec /usr/bin/env bash "$0" "$@"
fi
set -e

INSTALL_DIR="$HOME/local-ai-stack"
FASTAPI_DIR="$INSTALL_DIR/gemini-fastapi"
FASTAPI_PORT=8000
WEBUI_PORT=8080
PYTHON_EXEC="$INSTALL_DIR/tool-calling-test/.venv/bin/python"

check_trash_execution() {
    local cwd_phys
    cwd_phys="$(pwd -P 2>/dev/null || pwd)"
    case "$INSTALL_DIR|$cwd_phys" in
        *Trash*|*/.local/share/Trash/*|*/.Trash/*)
            echo "❌ ERROR: Cannot run AI stack from inside Trash directory: $cwd_phys"
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

stop_running_stack() {
    local ports=($FASTAPI_PORT $WEBUI_PORT)
    local found_occupying=0
    local announced_pids=""

    echo "Checking required stack ports ($FASTAPI_PORT, $WEBUI_PORT) and running instances..."

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
    pattern_pids=$(pgrep -f "gemini-fastapi.*run\.py|open-webui.*serve|open_webui" 2>/dev/null || true)
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
                echo "   -> Stopping $srv so bundle services can manage ports $FASTAPI_PORT and $WEBUI_PORT..."
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
        echo "✓ Required ports ($FASTAPI_PORT, $WEBUI_PORT) are free. No conflicting processes detected."
        return 0
    fi

    # 4. Terminate with SIGTERM
    pkill -TERM -f "gemini-fastapi.*run\.py" 2>/dev/null || true
    pkill -TERM -f "open-webui.*serve" 2>/dev/null || true
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
        if pgrep -f "gemini-fastapi.*run\.py" >/dev/null 2>&1 || pgrep -f "open-webui.*serve" >/dev/null 2>&1 || pgrep -f "open_webui" >/dev/null 2>&1; then
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
    pkill -9 -f "open-webui.*serve" 2>/dev/null || true
    pkill -9 -f "open_webui" 2>/dev/null || true
    rm -f /tmp/gemini_webapi/.cached_cookies_*.json 2>/dev/null || true
    echo "✓ Conflicting processes terminated. Ports $FASTAPI_PORT and $WEBUI_PORT are now free."
}

if [ "$1" = "--restart" ] || [ "$1" = "-r" ] || [ "$1" = "restart" ]; then
    stop_running_stack
elif [ "$1" = "--stop" ] || [ "$1" = "stop" ]; then
    stop_running_stack
    exit 0
fi

echo "=================================================="
echo "             Starting Local AI Stack              "
echo "=================================================="

# 1. Clear conflicting proxy environment variables
unset all_proxy ALL_PROXY http_proxy HTTP_PROXY https_proxy HTTPS_PROXY
export HF_HUB_OFFLINE=1

# 2. Check and start Gemini-FastAPI server
FASTAPI_HEALTHY=0
if curl --noproxy "*" --max-time 3 -s -f "http://127.0.0.1:$FASTAPI_PORT/v1/models" >/dev/null 2>&1; then
    FASTAPI_HEALTHY=1
fi

if [ $FASTAPI_HEALTHY -eq 0 ]; then
    if command -v fuser >/dev/null 2>&1; then
        fuser -k -TERM "${FASTAPI_PORT}/tcp" 2>/dev/null || true
    fi
    pkill -f "gemini-fastapi.*run\.py" 2>/dev/null || true

    SPOOF_DIR="$HOME/.local/share/gemini-spoof"
    HOSTS_FILE="$SPOOF_DIR/hosts"
    if [ ! -f "$HOSTS_FILE" ] || ! grep -q "91.108.243.78" "$HOSTS_FILE" 2>/dev/null; then
        mkdir -p "$SPOOF_DIR"
        cat << 'EOF_SPOOF' > "$HOSTS_FILE"
127.0.0.1 localhost

# Google AI Services (unblocked SNI proxies)
91.108.243.78 gemini.google.com
45.88.174.254 gemini.google.com
91.108.243.78 aistudio.google.com
45.88.174.254 aistudio.google.com
91.108.243.78 generativelanguage.googleapis.com
45.88.174.254 generativelanguage.googleapis.com
91.108.243.78 aitestkitchen.withgoogle.com
45.88.174.254 aitestkitchen.withgoogle.com
91.108.243.78 aisandbox-pa.googleapis.com
45.88.174.254 aisandbox-pa.googleapis.com
91.108.243.78 webchannel-alkalimakersuite-pa.clients6.google.com
45.88.174.254 webchannel-alkalimakersuite-pa.clients6.google.com
91.108.243.78 alkalimakersuite-pa.clients6.google.com
45.88.174.254 alkalimakersuite-pa.clients6.google.com
91.108.243.78 assistant-s3-pa.googleapis.com
45.88.174.254 assistant-s3-pa.googleapis.com
91.108.243.78 proactivebackend-pa.googleapis.com
45.88.174.254 proactivebackend-pa.googleapis.com
91.108.243.78 robinfrontend-pa.googleapis.com
45.88.174.254 robinfrontend-pa.googleapis.com
64.233.163.94 o.pki.goog
91.108.243.78 labs.google
45.88.174.254 labs.google
91.108.243.78 notebooklm.google.com
45.88.174.254 notebooklm.google.com
91.108.243.78 jules.google.com
45.88.174.254 jules.google.com
91.108.243.78 stitch.withgoogle.com
45.88.174.254 stitch.withgoogle.com

# Google Core & Auth
142.251.1.84 accounts.google.com
91.108.243.78 content-push.googleapis.com
45.88.174.254 content-push.googleapis.com
142.251.157.119 www.google.com
142.251.1.139 google.com

# OpenAI
45.155.204.190 chatgpt.com
45.155.204.190 ab.chatgpt.com
45.155.204.190 auth.openai.com
45.155.204.190 auth0.openai.com
45.155.204.190 platform.openai.com
45.155.204.190 cdn.oaistatic.com
45.155.204.190 files.oaiusercontent.com
45.155.204.190 cdn.auth0.com
45.155.204.190 tcr9i.chat.openai.com
45.155.204.190 webrtc.chatgpt.com
45.155.204.190 android.chat.openai.com
45.155.204.190 api.openai.com
45.155.204.190 operator.chatgpt.com
45.155.204.190 sora.chatgpt.com
45.155.204.190 sora.com
45.155.204.190 videos.openai.com
45.155.204.190 ios.chat.openai.com

# Microsoft
45.155.204.190 copilot.microsoft.com
45.155.204.190 sydney.bing.com
45.155.204.190 edgeservices.bing.com
45.155.204.190 rewards.bing.com

# GitHub Copilot
144.31.14.104 api.github.com
144.31.14.104 api.individual.githubcopilot.com
144.31.14.104 proxy.individual.githubcopilot.com

# Grok
45.155.204.190 grok.com
45.155.204.190 accounts.x.ai
45.155.204.190 assets.grok.com

# Claude
45.155.204.190 claude.ai
45.155.204.190 console.anthropic.com
45.155.204.190 api.anthropic.com
EOF_SPOOF
    fi
    BWRAP_CMD=""
    if [ -f "$HOSTS_FILE" ] && command -v bwrap >/dev/null 2>&1; then
        BWRAP_CMD="bwrap --dev-bind / / --ro-bind $HOSTS_FILE /etc/hosts"
    fi

    echo "1. Starting Gemini-FastAPI proxy on http://localhost:$FASTAPI_PORT..."
    (cd "$FASTAPI_DIR" && nohup env -u all_proxy -u ALL_PROXY -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY $BWRAP_CMD "$PYTHON_EXEC" run.py > "$INSTALL_DIR/proxy_access.log" 2>&1 &)
    FASTAPI_PID=$!
    echo "   -> Gemini-FastAPI started (PID: $FASTAPI_PID). Logging to $INSTALL_DIR/proxy_access.log"
    
    i=1
    while [ $i -le 30 ]; do
        if curl --noproxy "*" --max-time 3 -s -f "http://127.0.0.1:$FASTAPI_PORT/v1/models" >/dev/null 2>&1; then
            echo "   -> Gemini-FastAPI is ready on port $FASTAPI_PORT!"
            FASTAPI_HEALTHY=1
            break
        fi
        sleep 1
        i=$((i + 1))
    done

    if [ $FASTAPI_HEALTHY -eq 0 ]; then
        echo "   -> Warning: Gemini-FastAPI did not respond to /v1/models within 30s. Check $INSTALL_DIR/proxy_access.log"
    fi
else
    echo "1. Gemini-FastAPI is already running and healthy on http://localhost:$FASTAPI_PORT."
fi

echo ""

# 3. Start Open WebUI on localhost only (127.0.0.1)
if curl --noproxy "*" --max-time 3 -s -f "http://127.0.0.1:$WEBUI_PORT/health" >/dev/null 2>&1; then
    echo "2. Open WebUI is already running on http://127.0.0.1:$WEBUI_PORT."
    exit 0
fi

echo "2. Starting Open WebUI on http://127.0.0.1:$WEBUI_PORT (localhost only)..."
export HOST="127.0.0.1"
export PORT="$WEBUI_PORT"
export WEBUI_HOST="127.0.0.1"
export WEBUI_PORT="$WEBUI_PORT"
cd "$INSTALL_DIR/open-webui"
if [ -x ".venv/bin/open-webui" ]; then
    exec .venv/bin/open-webui serve --host 127.0.0.1 --port "$WEBUI_PORT"
elif [ -x "$INSTALL_DIR/open-webui/.venv/bin/open-webui" ]; then
    exec "$INSTALL_DIR/open-webui/.venv/bin/open-webui" serve --host 127.0.0.1 --port "$WEBUI_PORT"
elif command -v open-webui >/dev/null 2>&1; then
    exec "$(command -v open-webui)" serve --host 127.0.0.1 --port "$WEBUI_PORT"
else
    PY=""
    if [ -x ".venv/bin/python" ]; then
        PY=".venv/bin/python"
    elif [ -x "$INSTALL_DIR/open-webui/.venv/bin/python" ]; then
        PY="$INSTALL_DIR/open-webui/.venv/bin/python"
    elif [ -x "$INSTALL_DIR/tool-calling-test/.venv/bin/python" ]; then
        PY="$INSTALL_DIR/tool-calling-test/.venv/bin/python"
    else
        PY="$(command -v python3 || command -v python)"
    fi
    export PYTHONPATH="$INSTALL_DIR/open-webui/backend:$PYTHONPATH"
    if [ -f ".venv/bin/activate" ]; then
        . .venv/bin/activate
    fi
    exec "$PY" -c "import sys; from open_webui import app; sys.argv=['open-webui', 'serve', '--host', '127.0.0.1', '--port', '$WEBUI_PORT']; sys.exit(app())"
fi

