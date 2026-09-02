# Offline Installation Guide for AltLinux (Non-Root)

This bundle contains two completely self-sufficient offline archives for running the Local AI Stack without GitHub access:

## 📦 Included Archives

1. **`smolagent-suite-offline.tar.gz`**
   - Self-contained package for Smolagents CLI + Gemini-FastAPI server + agentic-browser skill.
   - Includes pre-downloaded `gemini-fastapi` repository, `agentic-browser` with pre-installed `node_modules`, and auto-patching scripts.

2. **`openwebui-suite-offline.tar.gz`**
   - Self-contained package for Open WebUI + Gemini-FastAPI + native bash tool & agentic-browser skill.
   - Includes full pre-downloaded `open-webui` repository, `gemini-fastapi`, and SQLite tool injection scripts.

---

## 🚀 Quick Start Instructions

### Option 1: Install & Run Smolagent CLI (Standalone Agent)
```bash
# 1. Extract the smolagent archive
tar -xzf smolagent-suite-offline.tar.gz
cd smolagent-setup

# 2. Run the installer / agent runner (works 100% offline from local repo folders)
./setup-and-run.sh "Echo 'Pipeline Test: OK' | tr a-z A-Z"
# or
./setup_and_run_smolagent.sh "Your prompt here"

# 3. Use ~/agent.sh anytime afterwards:
~/agent.sh "Your prompt here"
```

### Option 2: Install & Sync Open WebUI with Tools
```bash
# 1. Extract the openwebui archive
tar -xzf openwebui-suite-offline.tar.gz
cd openwebui-setup

# 2. Run the Open WebUI installer
./install-openwebui.sh
# or
./install_openwebui_tools.sh

# 3. Start the entire stack (Gemini-FastAPI + Open WebUI):
./start-ai-stack.sh
```
