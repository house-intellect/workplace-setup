#!/bin/sh

INSTALL_DIR="$HOME/local-ai-stack"
FASTAPI_DIR="$INSTALL_DIR/gemini-fastapi"
FASTAPI_PORT=8000
PYTHON_EXEC="$INSTALL_DIR/tool-calling-test/.venv/bin/python"

echo "=================================================="
echo "             Starting Local AI Stack              "
echo "=================================================="

# 1. Clear conflicting proxy environment variables
unset all_proxy ALL_PROXY http_proxy HTTP_PROXY https_proxy HTTPS_PROXY
export HF_HUB_OFFLINE=1

# 2. Start Gemini-FastAPI server in the background if not already running
if ! nc -z localhost $FASTAPI_PORT 2>/dev/null; then
    echo "1. Starting Gemini-FastAPI proxy on http://localhost:$FASTAPI_PORT..."
    (cd "$FASTAPI_DIR" && nohup "$PYTHON_EXEC" run.py > "$INSTALL_DIR/proxy_access.log" 2>&1 &)
    FASTAPI_PID=$!
    echo "   -> Gemini-FastAPI started (PID: $FASTAPI_PID). Logging to $INSTALL_DIR/proxy_access.log"
    
    i=1
    while [ $i -le 20 ]; do
        if nc -z localhost $FASTAPI_PORT 2>/dev/null; then
            echo "   -> Gemini-FastAPI is ready on port $FASTAPI_PORT!"
            break
        fi
        sleep 1
        i=$((i + 1))
    done
else
    echo "1. Gemini-FastAPI is already running on http://localhost:$FASTAPI_PORT."
fi

echo ""

# 3. Start Open WebUI on localhost only (127.0.0.1)
if nc -z 127.0.0.1 8080 2>/dev/null; then
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

