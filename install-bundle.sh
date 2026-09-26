#!/bin/bash
# ==============================================================================
# Workplace Unified Bundle Installer
# Factors in Smolagent CLI Suite and Open WebUI with Gemini-FastAPI & Native Tools
# ==============================================================================

if [ -z "$BASH_VERSION" ]; then
    exec /usr/bin/env bash "$0" "$@"
fi
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_DIR="${LOCAL_AI_STACK_DIR:-$HOME/local-ai-stack}"
FASTAPI_DIR="$STACK_DIR/gemini-fastapi"
OPENWEBUI_DIR="$STACK_DIR/open-webui"
FASTAPI_PORT=8000
WEBUI_PORT=8080

# Clean proxy environment variables
unset all_proxy ALL_PROXY http_proxy HTTP_PROXY https_proxy HTTPS_PROXY
export HF_HUB_OFFLINE=1

stop_running_stack() {
    echo "Stopping any currently running AI stack processes (gemini-fastapi, open-webui)..."
    if command -v systemctl >/dev/null 2>&1; then
        systemctl --user stop open-webui.service 2>/dev/null || true
    fi
    pkill -TERM -f "gemini-fastapi.*run\.py" 2>/dev/null || true
    pkill -TERM -f "open-webui serve" 2>/dev/null || true
    pkill -TERM -f "open_webui" 2>/dev/null || true

    for port in $FASTAPI_PORT $WEBUI_PORT; do
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

    for port in $FASTAPI_PORT $WEBUI_PORT; do
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
    echo "Stale processes stopped and ports $FASTAPI_PORT & $WEBUI_PORT cleared."
}

deploy_skills() {
    echo "Deploying skills to ~/.agents/skills/..."
    local skills_base="$HOME/.agents/skills"
    mkdir -p "$skills_base"

    if [ -d "$SCRIPT_DIR/agentic-browser" ]; then
        mkdir -p "$skills_base/agentic-browser"
        cp -ru "$SCRIPT_DIR/agentic-browser/"* "$skills_base/agentic-browser/" 2>/dev/null || cp -r "$SCRIPT_DIR/agentic-browser/"* "$skills_base/agentic-browser/"
        echo "   -> agentic-browser skill deployed."
    fi

    if [ -d "$SCRIPT_DIR/quizmaster" ]; then
        mkdir -p "$skills_base/quizmaster"
        cp -ru "$SCRIPT_DIR/quizmaster/"* "$skills_base/quizmaster/" 2>/dev/null || cp -r "$SCRIPT_DIR/quizmaster/"* "$skills_base/quizmaster/"
        echo "   -> quizmaster skill deployed."
    fi
}

show_status() {
    echo "=================================================="
    echo "              AI Stack Service Status             "
    echo "=================================================="
    
    # 1. Gemini-FastAPI Status
    local fastapi_pid
    fastapi_pid=$(pgrep -f "gemini-fastapi.*run\.py" || true)
    if [ -n "$fastapi_pid" ]; then
        echo "● Gemini-FastAPI: RUNNING (PID: $fastapi_pid)"
        if curl --noproxy "*" --max-time 3 -s -f "http://127.0.0.1:$FASTAPI_PORT/v1/models" >/dev/null 2>&1; then
            echo "  Health: OK (http://127.0.0.1:$FASTAPI_PORT/v1/models reachable)"
        else
            echo "  Health: UNRESPONSIVE (Port $FASTAPI_PORT open but /v1/models failed)"
        fi
    else
        echo "○ Gemini-FastAPI: STOPPED"
    fi

    # 2. Open WebUI Status
    local webui_pid
    webui_pid=$(pgrep -f "open-webui serve" || true)
    if [ -n "$webui_pid" ]; then
        echo "● Open WebUI:    RUNNING (PID: $webui_pid)"
        if curl --noproxy "*" --max-time 3 -s -f "http://127.0.0.1:$WEBUI_PORT/health" >/dev/null 2>&1; then
            echo "  Health: OK (http://127.0.0.1:$WEBUI_PORT/health reachable)"
        else
            echo "  Health: INITIALIZING or UNRESPONSIVE"
        fi
    else
        echo "○ Open WebUI:    STOPPED"
    fi
    echo "=================================================="
}

show_help() {
    cat << EOF
Workplace Unified Bundle Installer

Usage:
  ./install-bundle.sh [command] [options]
  ./bundle-installer.sh [command] [options]

Commands:
  all (default)          Stop running processes, install/sync both Smolagent and
                         Open WebUI suites, inject tools, and apply rate limits.
  smolagent [prompt]     Setup Smolagent & Gemini-FastAPI; optionally run a prompt.
  openwebui [target_dir] Setup Open WebUI, install dependencies, and inject SQLite tools.
  start                  Start the full local AI stack (Gemini-FastAPI + Open WebUI).
  stop                   Stop all running AI stack processes and free ports 8000 & 8080.
  restart                Stop running processes and restart the local AI stack.
  status                 Check health and process status of Gemini-FastAPI and Open WebUI.
  help, -h, --help       Show this help message.

Examples:
  ./install-bundle.sh                                    # Install everything
  ./install-bundle.sh smolagent "What is today's date?"   # Test Smolagent CLI
  ./install-bundle.sh start                              # Launch full stack
  ./install-bundle.sh stop                               # Stop running stack
EOF
}

# Subcommand dispatch
MODE="${1:-all}"

case "$MODE" in
    help|-h|--help)
        show_help
        exit 0
        ;;
    stop|--stop)
        stop_running_stack
        exit 0
        ;;
    status|--status)
        show_status
        exit 0
        ;;
    restart|--restart)
        stop_running_stack
        if [ -f "$SCRIPT_DIR/start-ai-stack.sh" ]; then
            exec "$SCRIPT_DIR/start-ai-stack.sh"
        elif [ -f "$STACK_DIR/start-ai-stack.sh" ]; then
            exec "$STACK_DIR/start-ai-stack.sh"
        else
            echo "Error: start-ai-stack.sh not found."
            exit 1
        fi
        ;;
    start|--start)
        if [ -f "$SCRIPT_DIR/start-ai-stack.sh" ]; then
            exec "$SCRIPT_DIR/start-ai-stack.sh"
        elif [ -f "$STACK_DIR/start-ai-stack.sh" ]; then
            exec "$STACK_DIR/start-ai-stack.sh"
        else
            echo "Error: start-ai-stack.sh not found."
            exit 1
        fi
        ;;
    smolagent)
        shift
        echo "Running Smolagent installer / runner..."
        exec "$SCRIPT_DIR/setup_and_run_smolagent.sh" "$@"
        ;;
    openwebui)
        shift
        echo "Running Open WebUI installer..."
        TARGET="${1:-$OPENWEBUI_DIR}"
        exec "$SCRIPT_DIR/install_openwebui_tools.sh" "$TARGET"
        ;;
    all|--all)
        echo "=================================================================="
        echo "       Workplace Unified AI Stack Bundle Installer"
        echo "=================================================================="
        echo ""

        # Step 1: Cleanly stop any existing processes
        stop_running_stack
        echo ""

        # Step 2: Deploy Skills
        deploy_skills
        echo ""

        # Step 3: Run Smolagent & Gemini-FastAPI Setup
        echo "--- [1/2] Installing / Syncing Smolagent CLI & Gemini-FastAPI ---"
        bash "$SCRIPT_DIR/setup_and_run_smolagent.sh"
        echo ""

        # Step 4: Run Open WebUI Setup & SQLite Tool Injection
        echo "--- [2/2] Installing / Syncing Open WebUI & SQLite Tools ---"
        bash "$SCRIPT_DIR/install_openwebui_tools.sh" "$OPENWEBUI_DIR"
        echo ""

        # Step 5: Ensure start-ai-stack.sh and agent.sh are synced to stack directory
        mkdir -p "$STACK_DIR"
        if [ -f "$SCRIPT_DIR/start-ai-stack.sh" ]; then
            cp -f "$SCRIPT_DIR/start-ai-stack.sh" "$STACK_DIR/start-ai-stack.sh"
            chmod +x "$STACK_DIR/start-ai-stack.sh"
        fi
        if [ -f "$SCRIPT_DIR/agent.sh" ]; then
            cp -f "$SCRIPT_DIR/agent.sh" "$STACK_DIR/agent.sh"
            chmod +x "$STACK_DIR/agent.sh"
            cp -f "$SCRIPT_DIR/agent.sh" "$HOME/agent.sh" 2>/dev/null || true
            chmod +x "$HOME/agent.sh" 2>/dev/null || true
        fi

        echo "=================================================================="
        echo "🎉 Unified Installation Complete!"
        echo "=================================================================="
        echo "✓ Gemini-FastAPI: Throttled to 1 req / 2s to protect quotas."
        echo "✓ Smolagent CLI:   Installed with thinking display & rate limits."
        echo "✓ Open WebUI:      Tools registered & 4x parallel tasks disabled."
        echo "✓ Agentic Skills:  agentic-browser & quizmaster deployed."
        echo ""
        echo "Quick Commands:"
        echo "  • Start the full stack:   ./install-bundle.sh start"
        echo "                            (or: ~/local-ai-stack/start-ai-stack.sh)"
        echo "  • Smolagent query:        ~/agent.sh \"Your prompt here\""
        echo "  • Open WebUI access:      http://127.0.0.1:8080"
        echo "  • Check service health:   ./install-bundle.sh status"
        echo "  • Stop services:          ./install-bundle.sh stop"
        echo "=================================================================="
        ;;
    *)
        echo "Unknown command: $MODE"
        show_help
        exit 1
        ;;
esac
