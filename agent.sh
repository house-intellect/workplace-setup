#!/bin/sh
FASTAPI_PORT=8000
FASTAPI_DIR="$HOME/local-ai-stack/gemini-fastapi"
SCRIPT_PATH="$HOME/local-ai-stack/tool-calling-test/smolagent.py"

# 1. Capture prompt, text files, image, and model arguments (POSIX compatible)
PROMPT_TEXT=""
FILE_ARG=""
IMAGE_ARG=""
MODEL_ARG=""
THINKING_ARG=0
LIST_MODELS=0

while [ $# -gt 0 ]; do
    case "$1" in
        -f|--file)
            FILE_ARG="$2"
            shift 2
            ;;
        -i|--image)
            IMAGE_ARG="$2"
            shift 2
            ;;
        -m|--model)
            MODEL_ARG="$2"
            shift 2
            ;;
        -t|--thinking)
            THINKING_ARG=1
            shift
            ;;
        -l|--list-models)
            LIST_MODELS=1
            shift
            ;;
        *)
            if [ -z "$PROMPT_TEXT" ]; then
                PROMPT_TEXT="$1"
            else
                PROMPT_TEXT="$PROMPT_TEXT $1"
            fi
            shift
            ;;
    esac
done

if [ $THINKING_ARG -eq 1 ] && [ -z "$MODEL_ARG" ]; then
    MODEL_ARG="thinking"
fi

if [ $LIST_MODELS -eq 0 ]; then
    if [ -z "$PROMPT_TEXT" ] && [ ! -t 0 ]; then
        PROMPT_TEXT=$(cat)
    fi

    if [ -z "$PROMPT_TEXT" ] && [ -z "$FILE_ARG" ] && [ -z "$IMAGE_ARG" ]; then
        echo "Error: No prompt, text file, or image provided."
        echo "Usage: $0 [-m model] [-t] [-f file] [-i image_or_folder] [-l] \"Your prompt here\""
        echo "Use '$0 -t' to run with a thinking model and display the thought process."
        echo "Use '$0 -l' to list available models dynamically from the FastAPI server."
        exit 1
    fi
fi

TASK_PROMPT="$PROMPT_TEXT"

if [ -n "$FILE_ARG" ]; then
    if [ -f "$FILE_ARG" ]; then
        FILE_CONTENT=$(cat "$FILE_ARG")
        TASK_PROMPT="$TASK_PROMPT

--- File: $FILE_ARG ---
$FILE_CONTENT"
    else
        echo "Warning: File '$FILE_ARG' not found."
    fi
fi

# 2. Start Gemini-FastAPI if needed
PYTHON_EXEC="$HOME/local-ai-stack/tool-calling-test/.venv/bin/python"

if [ -f "$HOME/.bashrc" ]; then
    . "$HOME/.bashrc" 2>/dev/null || true
fi

unset all_proxy ALL_PROXY http_proxy HTTP_PROXY https_proxy HTTPS_PROXY

if ! curl --noproxy "*" --max-time 3 -s -f http://127.0.0.1:$FASTAPI_PORT/v1/models >/dev/null 2>&1; then
    if command -v fuser >/dev/null 2>&1; then
        fuser -k -TERM "$FASTAPI_PORT/tcp" 2>/dev/null || true
    fi
    SPOOF_DIR="$HOME/.local/share/gemini-spoof"
    HOSTS_FILE="$SPOOF_DIR/hosts"
    if [ ! -f "$HOSTS_FILE" ] || ! grep -q "89.150.59.128" "$HOSTS_FILE" 2>/dev/null; then
        mkdir -p "$SPOOF_DIR"
        cat << 'EOF_SPOOF' > "$HOSTS_FILE"
127.0.0.1 localhost

# Google AI Services (resolved by dns.comss.one)
89.150.59.128 gemini.google.com
45.88.174.254 gemini.google.com
89.150.59.128 aistudio.google.com
45.88.174.254 aistudio.google.com
89.150.59.128 generativelanguage.googleapis.com
45.88.174.254 generativelanguage.googleapis.com
89.150.59.128 aitestkitchen.withgoogle.com
45.88.174.254 aitestkitchen.withgoogle.com
89.150.59.128 aisandbox-pa.googleapis.com
45.88.174.254 aisandbox-pa.googleapis.com
89.150.59.128 webchannel-alkalimakersuite-pa.clients6.google.com
45.88.174.254 webchannel-alkalimakersuite-pa.clients6.google.com
89.150.59.128 alkalimakersuite-pa.clients6.google.com
45.88.174.254 alkalimakersuite-pa.clients6.google.com
89.150.59.128 assistant-s3-pa.googleapis.com
45.88.174.254 assistant-s3-pa.googleapis.com
89.150.59.128 proactivebackend-pa.googleapis.com
45.88.174.254 proactivebackend-pa.googleapis.com
89.150.59.128 robinfrontend-pa.googleapis.com
45.88.174.254 robinfrontend-pa.googleapis.com
64.233.163.94 o.pki.goog
89.150.59.128 labs.google
45.88.174.254 labs.google
89.150.59.128 notebooklm.google.com
45.88.174.254 notebooklm.google.com
89.150.59.128 jules.google.com
45.88.174.254 jules.google.com
89.150.59.128 stitch.withgoogle.com
45.88.174.254 stitch.withgoogle.com

# Google Core & Auth
142.251.1.84 accounts.google.com
89.150.59.128 content-push.googleapis.com
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
    (cd "$FASTAPI_DIR" && nohup env -u all_proxy -u ALL_PROXY -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY $BWRAP_CMD "$PYTHON_EXEC" run.py > "$HOME/local-ai-stack/proxy_access.log" 2>&1 &)
    
    PROXY_READY=0
    i=1
    while [ $i -le 60 ]; do
        if curl --noproxy "*" --max-time 3 -s -f http://127.0.0.1:$FASTAPI_PORT/v1/models >/dev/null 2>&1; then
            PROXY_READY=1
            break
        fi
        sleep 1
        i=$((i + 1))
    done

    if [ $PROXY_READY -eq 0 ]; then
        echo "Error: Gemini-FastAPI server failed to start on port $FASTAPI_PORT."
        if [ -f "$HOME/local-ai-stack/proxy_access.log" ]; then
            echo "--- Server Log (last 20 lines) ---"
            tail -n 20 "$HOME/local-ai-stack/proxy_access.log"
        fi
        exit 1
    fi
fi

# 3. Run Python agent (POSIX compatible argument passing)
if [ $LIST_MODELS -eq 1 ]; then
    exec env -u all_proxy -u ALL_PROXY -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY "$PYTHON_EXEC" "$SCRIPT_PATH" -l
elif [ -n "$MODEL_ARG" ] && [ -n "$IMAGE_ARG" ]; then
    exec env -u all_proxy -u ALL_PROXY -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY "$PYTHON_EXEC" "$SCRIPT_PATH" -m "$MODEL_ARG" -i "$IMAGE_ARG" "$TASK_PROMPT"
elif [ -n "$MODEL_ARG" ]; then
    exec env -u all_proxy -u ALL_PROXY -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY "$PYTHON_EXEC" "$SCRIPT_PATH" -m "$MODEL_ARG" "$TASK_PROMPT"
elif [ -n "$IMAGE_ARG" ]; then
    exec env -u all_proxy -u ALL_PROXY -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY "$PYTHON_EXEC" "$SCRIPT_PATH" -i "$IMAGE_ARG" "$TASK_PROMPT"
else
    exec env -u all_proxy -u ALL_PROXY -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY "$PYTHON_EXEC" "$SCRIPT_PATH" "$TASK_PROMPT"
fi

