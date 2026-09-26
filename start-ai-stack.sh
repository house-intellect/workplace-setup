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
                echo "   -> Stopping $srv so bundle services can manage ports $FASTAPI_PORT and $WEBUI_PORT..."
                systemctl --user stop "$srv" 2>/dev/null || true
                found_occupying=1
            fi
        done
    fi

    if [ "$found_occupying" -eq 0 ]; then
        echo "✓ Required ports ($FASTAPI_PORT, $WEBUI_PORT) are free. No conflicting processes detected."
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

    echo "1. Starting Gemini-FastAPI proxy on http://localhost:$FASTAPI_PORT..."
    (cd "$FASTAPI_DIR" && nohup env -u all_proxy -u ALL_PROXY -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY "$PYTHON_EXEC" run.py > "$INSTALL_DIR/proxy_access.log" 2>&1 &)
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
if [ -f ".venv/bin/open-webui" ]; then
    exec .venv/bin/open-webui serve --host 127.0.0.1 --port "$WEBUI_PORT"
elif [ -f "$INSTALL_DIR/open-webui/.venv/bin/open-webui" ]; then
    exec "$INSTALL_DIR/open-webui/.venv/bin/open-webui" serve --host 127.0.0.1 --port "$WEBUI_PORT"
else
    if [ -f ".venv/bin/activate" ]; then
        . .venv/bin/activate
    fi
    exec open-webui serve --host 127.0.0.1 --port "$WEBUI_PORT"
fi
