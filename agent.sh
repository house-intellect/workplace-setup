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
    echo "Starting Gemini-FastAPI server on port $FASTAPI_PORT..."
    (cd "$FASTAPI_DIR" && nohup env -u all_proxy -u ALL_PROXY -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY "$PYTHON_EXEC" run.py > "$HOME/local-ai-stack/proxy_access.log" 2>&1 &)
    
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

