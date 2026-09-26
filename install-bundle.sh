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
