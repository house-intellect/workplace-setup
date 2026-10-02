#!/bin/bash
# ==============================================================================
# Package AI Stack Bundle for Google Drive Deployment (Zero-GitHub Dependency)
# ==============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STACK_DIR="${LOCAL_AI_STACK_DIR:-$HOME/local-ai-stack}"
OUTPUT_ARCHIVE="${1:-$HOME/workplace-ai-bundle.tar.gz}"

echo "=================================================================="
echo "    Packaging AI Stack Bundle for Google Drive (Offline / No GitHub)"
echo "=================================================================="

WORK_DIR=$(mktemp -d /tmp/gdrive_bundle_XXXXXX)
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p "$WORK_DIR/workplace-setup"

echo "[1/3] Copying workplace-setup scripts and skills..."
rsync -a --exclude=".git" --exclude="__pycache__" --exclude="*.pyc" --exclude=".venv" --exclude="*.tar.gz" \
    "$SCRIPT_DIR/" "$WORK_DIR/workplace-setup/"

if [ -d "$STACK_DIR/gemini-fastapi" ]; then
    echo "[2/3] Bundling pre-downloaded Gemini-FastAPI (~9 MB)..."
    mkdir -p "$WORK_DIR/workplace-setup/gemini-fastapi"
    rsync -a --exclude=".git" --exclude=".venv" --exclude="__pycache__" --exclude="*.pyc" --exclude="data/lmdb" \
        "$STACK_DIR/gemini-fastapi/" "$WORK_DIR/workplace-setup/gemini-fastapi/"
fi

if [ ! -d "$WORK_DIR/workplace-setup/open-webui" ] && [ -d "$STACK_DIR/open-webui" ]; then
    echo "[2.5/3] Bundling pre-downloaded Open WebUI..."
    mkdir -p "$WORK_DIR/workplace-setup/open-webui"
    rsync -a --exclude=".git" --exclude=".venv" --exclude="__pycache__" --exclude="*.pyc" \
        "$STACK_DIR/open-webui/" "$WORK_DIR/workplace-setup/open-webui/"
fi

echo "[3/3] Creating compressed tarball: $OUTPUT_ARCHIVE..."
tar -czf "$OUTPUT_ARCHIVE" -C "$WORK_DIR" workplace-setup

ARCHIVE_SIZE=$(du -h "$OUTPUT_ARCHIVE" | cut -f1)

echo "=================================================================="
echo "✓ Archive created successfully: $OUTPUT_ARCHIVE ($ARCHIVE_SIZE)"
echo "=================================================================="
echo ""
echo "How to deploy via Google Drive (Account: quezon):"
echo "1. Upload '$OUTPUT_ARCHIVE' (or just setup_and_run_smolagent.sh) to your Google Drive."
echo "2. Right-click the uploaded file -> 'Share' -> set to 'Anyone with the link can view'."
echo "3. Copy the link: https://drive.google.com/file/d/FILE_ID/view?usp=sharing"
echo "4. On your target machine (where GitHub is blocked), run this terminal one-liner:"
echo ""
echo "   --- For single script (setup_and_run_smolagent.sh) ---"
echo "   curl -sSL \"https://drive.usercontent.google.com/download?id=FILE_ID&export=download\" -o setup.sh && bash setup.sh"
echo ""
echo "   --- For full bundled archive ($ARCHIVE_SIZE) ---"
echo "   curl -sSL \"https://drive.usercontent.google.com/download?id=FILE_ID&export=download\" -o bundle.tar.gz && tar -xzf bundle.tar.gz && cd workplace-setup && bash setup_and_run_smolagent.sh"
echo "=================================================================="
