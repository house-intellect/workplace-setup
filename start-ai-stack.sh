#!/usr/bin/env bash

INSTALL_DIR="$HOME/local-ai-stack"
FASTAPI_DIR="$INSTALL_DIR/gemini-fastapi"
FASTAPI_PORT=8000
PYTHON_EXEC="$INSTALL_DIR/tool-calling-test/.venv/bin/python"

echo "=================================================="
echo "             Starting Local AI Stack              "
echo "=================================================="

# 1. Clear conflicting proxy environment variables
for k in all_proxy ALL_PROXY http_proxy HTTP_PROXY https_proxy HTTPS_PROXY; do
    unset $k
done

# 2. Start Gemini-FastAPI server in the background if not already running
if ! nc -z localhost $FASTAPI_PORT 2>/dev/null; then
    echo "1. Starting Gemini-FastAPI proxy on http://localhost:$FASTAPI_PORT..."
    (cd "$FASTAPI_DIR" && nohup "$PYTHON_EXEC" run.py > "$INSTALL_DIR/proxy_access.log" 2>&1 &)
    FASTAPI_PID=$!
    echo "   -> Gemini-FastAPI started (PID: $FASTAPI_PID). Logging to $INSTALL_DIR/proxy_access.log"
    
    for i in {1..20}; do
        if nc -z localhost $FASTAPI_PORT 2>/dev/null; then
            echo "   -> Gemini-FastAPI is ready on port $FASTAPI_PORT!"
            break
        fi
        sleep 1
    done
else
    echo "1. Gemini-FastAPI is already running on http://localhost:$FASTAPI_PORT."
fi

echo ""

# 3. Start Open WebUI in the foreground
echo "2. Starting Open WebUI on http://localhost:8080..."
cd "$INSTALL_DIR/open-webui"
if [ -f ".venv/bin/open-webui" ]; then
    exec .venv/bin/open-webui serve
elif [ -f "$INSTALL_DIR/open-webui/.venv/bin/open-webui" ]; then
    exec "$INSTALL_DIR/open-webui/.venv/bin/open-webui" serve
else
    if [ -f ".venv/bin/activate" ]; then
        . .venv/bin/activate
    fi
    open-webui serve
fi

# Cleanup if WebUI is closed (Ctrl+C)
if [ -n "$FASTAPI_PID" ]; then
    kill "$FASTAPI_PID" 2>/dev/null || true
fi
echo "Services shut down."
