#!/bin/sh

INSTALL_DIR="$HOME/local-ai-stack"
FASTAPI_DIR="$INSTALL_DIR/gemini-fastapi"
FASTAPI_PORT=8000
PYTHON_EXEC="$INSTALL_DIR/tool-calling-test/.venv/bin/python"

stop_running_stack() {
    echo "Stopping any currently running AI stack processes (gemini-fastapi, open-webui)..."
    if command -v systemctl >/dev/null 2>&1; then
        systemctl --user stop open-webui.service 2>/dev/null || true
    fi
    pkill -TERM -f "gemini-fastapi.*run\.py" 2>/dev/null || true
    pkill -TERM -f "open-webui serve" 2>/dev/null || true
    pkill -TERM -f "open_webui" 2>/dev/null || true

    for port in 8000 8080; do
        if command -v fuser >/dev/null 2>&1; then
            fuser -k -TERM "${port}/tcp" 2>/dev/null || true
        fi
        if command -v lsof >/dev/null 2>&1; then
            pids=$(lsof -ti:"${port}" 2>/dev/null || true)
            if [ -n "$pids" ]; then
                kill -TERM $pids >/dev/null 2>&1 || true
            fi
        fi
    done

    sleep 1

    for port in 8000 8080; do
        if command -v fuser >/dev/null 2>&1; then
            fuser -k -KILL "${port}/tcp" 2>/dev/null || true
        fi
        if command -v lsof >/dev/null 2>&1; then
            pids=$(lsof -ti:"${port}" 2>/dev/null || true)
            if [ -n "$pids" ]; then
                kill -9 $pids >/dev/null 2>&1 || true
            fi
        fi
    done
    pkill -9 -f "gemini-fastapi.*run\.py" 2>/dev/null || true
    pkill -9 -f "open-webui serve" 2>/dev/null || true
    rm -f /tmp/gemini_webapi/.cached_cookies_*.json 2>/dev/null || true
    echo "Stack stopped."
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
if curl --noproxy "*" --max-time 3 -s -f "http://127.0.0.1:8080/health" >/dev/null 2>&1; then
    echo "2. Open WebUI is already running on http://127.0.0.1:8080."
    exit 0
fi

echo "2. Starting Open WebUI on http://127.0.0.1:8080 (localhost only)..."
export HOST="127.0.0.1"
export PORT="8080"
export WEBUI_HOST="127.0.0.1"
export WEBUI_PORT="8080"
cd "$INSTALL_DIR/open-webui"
if [ -f ".venv/bin/open-webui" ]; then
    exec .venv/bin/open-webui serve --host 127.0.0.1 --port 8080
elif [ -f "$INSTALL_DIR/open-webui/.venv/bin/open-webui" ]; then
    exec "$INSTALL_DIR/open-webui/.venv/bin/open-webui" serve --host 127.0.0.1 --port 8080
else
    if [ -f ".venv/bin/activate" ]; then
        . .venv/bin/activate
    fi
    exec open-webui serve --host 127.0.0.1 --port 8080
fi

