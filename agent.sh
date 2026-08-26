#!/bin/bash
PROXY_PORT=8085
PROXY_DIR="$HOME/local-ai-stack/gemini-openai-proxy"
SCRIPT_PATH="/home/grapeonwheels/local-ai-stack/tool-calling-test/smolagent.py"
PATCH_PATH="$HOME/.gemini-proxy-patch.js"

# 1. Capture prompt, text files, and image arguments
PROMPT_TEXT=""
FILES=()
IMAGES=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -f|--file)
            FILES+=("$2")
            shift 2
            ;;
        -i|--image)
            TARGET="$2"
            if [ -d "$TARGET" ]; then
                for img in "$TARGET"/*.{png,jpg,jpeg,webp,gif,PNG,JPG,JPEG,WEBP,GIF}; do
                    [ -e "$img" ] && IMAGES+=("$img")
                done
            elif [ -f "$TARGET" ]; then
                IMAGES+=("$TARGET")
            else
                echo "Warning: Image file/dir '$TARGET' not found."
            fi
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

if [ -z "$PROMPT_TEXT" ] && [ ${#FILES[@]} -eq 0 ] && [ ${#IMAGES[@]} -eq 0 ]; then
    echo "Error: No prompt, text file, or image provided."
    echo "Usage: $0 [-f file] [-i image_or_folder] \"Your prompt here\""
    exit 1
fi

TASK_PROMPT="$PROMPT_TEXT"

for file in "${FILES[@]}"; do
    if [ -f "$file" ]; then
        TASK_PROMPT+=$'\n\n'
        TASK_PROMPT+="--- File: $file ---"$'\n'
        TASK_PROMPT+="$(cat "$file")"
    else
        echo "Warning: File '$file' not found."
    fi
done

# 2. Start proxy if needed
if ! nc -z localhost $PROXY_PORT 2>/dev/null; then
    echo "Starting gemini-openai-proxy with patch..."
    cd "$PROXY_DIR" && nohup env PORT=$PROXY_PORT NODE_OPTIONS="-r $PATCH_PATH" npm start > proxy_access.log 2>&1 &
    
    for i in {1..10}; do
        if nc -z localhost $PROXY_PORT 2>/dev/null; then
            break
        fi
        sleep 1
    done
fi

# 3. Run Python agent passing prompt and image arguments
ARGS=("$TASK_PROMPT")
if [ ${#IMAGES[@]} -gt 0 ]; then
    ARGS+=("--images" "${IMAGES[@]}")
fi

~/local-ai-stack/tool-calling-test/.venv/bin/python "$SCRIPT_PATH" "${ARGS[@]}"
