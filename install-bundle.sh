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

deploy_skills() {
    echo "Deploying skills to ~/.agents/skills/..."
    local skills_base="$HOME/.agents/skills"
    mkdir -p "$skills_base"

    if [ -d "$SCRIPT_DIR/agentic-browser" ]; then
        echo "   -> Overwriting previous agentic-browser skill..."
        rm -rf "$skills_base/agentic-browser"
        mkdir -p "$skills_base/agentic-browser"
        cp -r "$SCRIPT_DIR/agentic-browser/"* "$skills_base/agentic-browser/"
        echo "   -> agentic-browser skill deployed."
    fi

    if [ -d "$SCRIPT_DIR/quizmaster" ]; then
        echo "   -> Overwriting previous quizmaster skill..."
        rm -rf "$skills_base/quizmaster"
        mkdir -p "$skills_base/quizmaster"
        cp -r "$SCRIPT_DIR/quizmaster/"* "$skills_base/quizmaster/"
        echo "   -> quizmaster skill deployed."
    fi
}

start_openwebui_background() {
    local stack_dir="${LOCAL_AI_STACK_DIR:-$HOME/local-ai-stack}"
    local webui_dir="${OPENWEBUI_DIR:-$stack_dir/open-webui}"
    local webui_port="${WEBUI_PORT:-8080}"

    if curl --noproxy "*" --max-time 3 -s -f "http://127.0.0.1:$webui_port/health" >/dev/null 2>&1; then
        echo "✓ Open WebUI is already running and healthy on http://127.0.0.1:$webui_port"
        return 0
    fi

    echo "Starting Open WebUI service on http://127.0.0.1:$webui_port..."

    local started=0

    # 1. Start via systemd user service if available
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl --user list-unit-files open-webui.service 2>/dev/null | grep -q open-webui.service; then
            echo "   -> Starting via systemd user service (open-webui.service)..."
            systemctl --user start open-webui.service 2>/dev/null || true
            sleep 2
            if systemctl --user is-active open-webui.service >/dev/null 2>&1; then
                started=1
            fi
        fi
    fi

    # 2. If systemd not available or failed to start, launch via background process
    if [ $started -eq 0 ]; then
        local webui_bin=""
        if [ -x "$webui_dir/.venv/bin/open-webui" ]; then
            webui_bin="$webui_dir/.venv/bin/open-webui"
        elif [ -x "$SCRIPT_DIR/open-webui/.venv/bin/open-webui" ]; then
            webui_bin="$SCRIPT_DIR/open-webui/.venv/bin/open-webui"
            webui_dir="$SCRIPT_DIR/open-webui"
        elif command -v open-webui >/dev/null 2>&1; then
            webui_bin="$(command -v open-webui)"
        fi

        if [ -n "$webui_bin" ]; then
            echo "   -> Starting Open WebUI background daemon ($webui_bin)..."
            mkdir -p "$stack_dir"
            (
                cd "$webui_dir" 2>/dev/null || cd "$HOME"
                export HOST="127.0.0.1"
                export PORT="$webui_port"
                export WEBUI_HOST="127.0.0.1"
                export WEBUI_PORT="$webui_port"
                export USE_SLIM=true
                export USE_SLIM_DOCKER=true
                export FRONTEND_BUILD_DIR="$webui_dir/build"
                nohup "$webui_bin" serve --host 127.0.0.1 --port "$webui_port" > "$stack_dir/open-webui.log" 2>&1 &
            )
            started=1
        elif [ -f "$stack_dir/start-ai-stack.sh" ]; then
            echo "   -> Starting via $stack_dir/start-ai-stack.sh in background..."
            nohup bash "$stack_dir/start-ai-stack.sh" > "$stack_dir/open-webui.log" 2>&1 &
            started=1
        fi
    fi

    # 3. Wait for Open WebUI health check (up to 75s)
    echo "   -> Waiting for Open WebUI to become ready on http://127.0.0.1:$webui_port..."
    local ready=0
    for i in $(seq 1 75); do
        if curl --noproxy "*" --max-time 2 -s -f "http://127.0.0.1:$webui_port/health" >/dev/null 2>&1; then
            ready=1
            break
        fi
        sleep 1
    done

    if [ $ready -eq 1 ]; then
        echo "✓ Open WebUI is running and healthy at http://127.0.0.1:$webui_port"
    else
        echo "⚠️  Open WebUI launched in background; still initializing (check $stack_dir/open-webui.log or systemctl --user status open-webui)"
    fi
}

show_status() {
    echo "=================================================="
    echo "              AI Stack Service Status             "
    echo "=================================================="
    
    # 1. Gemini-FastAPI Status
    local fastapi_pid=""
    if command -v lsof >/dev/null 2>&1; then
        fastapi_pid=$(lsof -ti:"$FASTAPI_PORT" 2>/dev/null | head -n1 || true)
    fi
    if [ -z "$fastapi_pid" ] && command -v fuser >/dev/null 2>&1; then
        fastapi_pid=$(fuser "$FASTAPI_PORT/tcp" 2>/dev/null | tr -s ' ' '\n' | grep -v '^$' | head -n1 || true)
    fi
    if [ -z "$fastapi_pid" ]; then
        fastapi_pid=$(pgrep -f "gemini-fastapi.*run\.py|run\.py" | head -n1 || true)
    fi
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
    local webui_pid=""
    if command -v lsof >/dev/null 2>&1; then
        webui_pid=$(lsof -ti:"$WEBUI_PORT" 2>/dev/null | head -n1 || true)
    fi
    if [ -z "$webui_pid" ] && command -v fuser >/dev/null 2>&1; then
        webui_pid=$(fuser "$WEBUI_PORT/tcp" 2>/dev/null | tr -s ' ' '\n' | grep -v '^$' | head -n1 || true)
    fi
    if [ -z "$webui_pid" ]; then
        webui_pid=$(pgrep -f "open-webui.*serve|open_webui" | head -n1 || true)
    fi
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

        # Step 3: Run Open WebUI Setup & SQLite Tool Injection
        echo "--- [1/3] Installing / Syncing Open WebUI & SQLite Tools ---"
        bash "$SCRIPT_DIR/install_openwebui_tools.sh" "$OPENWEBUI_DIR"
        echo ""

        # Step 4: Ensure start-ai-stack.sh and agent.sh are synced to stack directory
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

        # Step 5: Run Smolagent & Gemini-FastAPI Setup
        echo "--- [2/3] Installing / Syncing Smolagent CLI & Gemini-FastAPI ---"
        SKIP_WEBUI_START=1 bash "$SCRIPT_DIR/setup_and_run_smolagent.sh"
        echo ""

        # Step 6: Start/Verify Open WebUI Stack
        echo "--- [3/3] Starting Open WebUI Stack (Port 8080) ---"
        start_openwebui_background
        echo ""

        echo "=================================================================="
        echo "🎉 Unified Installation Complete & Stack Running!"
        echo "=================================================================="
        echo "✓ Gemini-FastAPI: Running on port 8000 (1 req / 2s rate limit)."
        echo "✓ Open WebUI:      Running on http://127.0.0.1:8080 (Tools registered)."
        echo "✓ Smolagent CLI:   Installed with thinking display & rate limits."
        echo "✓ Agentic Skills:  agentic-browser & quizmaster deployed."
        echo ""
        echo "Quick Access & Commands:"
        echo "  • Open WebUI Web Interface: http://127.0.0.1:8080"
        echo "  • Smolagent query:          ~/agent.sh \"Your prompt here\""
        echo "  • Check service health:     ./install-bundle.sh status"
        echo "  • Restart stack:            ./install-bundle.sh restart"
        echo "  • Stop services:            ./install-bundle.sh stop"
        echo "=================================================================="
        ;;
    *)
        echo "Unknown command: $MODE"
        show_help
        exit 1
        ;;
esac
