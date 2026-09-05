#!/bin/bash
FASTAPI_PORT=8000
FASTAPI_DIR="$HOME/local-ai-stack/gemini-fastapi"
SCRIPT_PATH="$HOME/local-ai-stack/tool-calling-test/smolagent.py"

# 1. Capture prompt, text files, image, and model arguments (POSIX compatible)
PROMPT_TEXT=""
FILE_ARG=""
IMAGE_ARG=""
MODEL_ARG=""

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

if [ -z "$PROMPT_TEXT" ] && [ ! -t 0 ]; then
    PROMPT_TEXT=$(cat)
fi

if [ -z "$PROMPT_TEXT" ] && [ -z "$FILE_ARG" ] && [ -z "$IMAGE_ARG" ]; then
    echo "Error: No prompt, text file, or image provided."
    echo "Usage: $0 [-m model] [-f file] [-i image_or_folder] \"Your prompt here\""
    echo "Available models: gemini-3.7-flash (default), gemini-3.7-flash-thinking, gemini-3.1-pro, gemini-3.5-flash-lite"
    exit 1
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

unset all_proxy ALL_PROXY http_proxy HTTP_PROXY https_proxy HTTPS_PROXY

if ! nc -z localhost $FASTAPI_PORT 2>/dev/null; then
    echo "Starting Gemini-FastAPI server on port $FASTAPI_PORT..."
    (cd "$FASTAPI_DIR" && nohup "$PYTHON_EXEC" run.py > "$HOME/local-ai-stack/proxy_access.log" 2>&1 &)
    
    i=1
    while [ $i -le 20 ]; do
        if nc -z localhost $FASTAPI_PORT 2>/dev/null; then
            break
        fi
        sleep 1
        i=$((i + 1))
    done
fi

# 3. Run Python agent
CMD_ARGS=()
if [ -n "$MODEL_ARG" ]; then
    CMD_ARGS+=("-m" "$MODEL_ARG")
fi
if [ -n "$IMAGE_ARG" ]; then
    CMD_ARGS+=("-i" "$IMAGE_ARG")
fi
CMD_ARGS+=("$TASK_PROMPT")

exec env -u all_proxy -u ALL_PROXY -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY "$PYTHON_EXEC" "$SCRIPT_PATH" "${CMD_ARGS[@]}"

