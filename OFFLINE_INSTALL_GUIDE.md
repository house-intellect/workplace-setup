# Offline Installation Guide for AltLinux / Linux (Non-Root)

This bundle contains a single, completely self-sufficient offline archive for running the Local AI Stack without internet or GitHub access:

## 📦 Single Unified Bundle Archive: `workplace-ai-bundle.tar.gz`

The archive contains one unified bundle installer file cache—no nested archives:
- **`install-bundle.sh` & `bundle-installer.sh`**: Unified installer script that stops running processes, factors in both Smolagent and Open WebUI, and sets up everything in one pass.
- **`gemini-fastapi/`**: Pre-downloaded Gemini-FastAPI proxy with resilient session fallback and **1 request per 2 seconds (0.5 Hz) rate limiting** to prevent Google quota violations.
- **`open-webui/`**: Pre-downloaded Open WebUI source code ready for offline installation.
- **`agentic-browser/`**: Puppeteer browser automation engine with pre-installed `node_modules`.
- **`quizmaster/`**: Multi-agent orchestration and quiz generation skill.
- **`setup_and_run_smolagent.sh`**: Smolagent CLI dependency checker and standalone runner.
- **`install_openwebui_tools.sh`**: Open WebUI dependency builder and SQLite native tool syncer (disables 4x concurrent tasks to protect API quotas).
- **`start-ai-stack.sh`**: Service manager for starting, stopping, or restarting the entire stack.
- **`agent.sh`**: Command-line wrapper for running autonomous Smolagent tasks.

---

## 🚀 Quick Start Instructions

### 1. Extract the Single Bundle Archive
```bash
tar -xzf workplace-ai-bundle.tar.gz
cd workplace-bundle
```

### 2. Run the Unified Bundle Installer
Run the bundle installer (automatically terminates any running stale processes, configures Python virtualenvs, syncs codebases, patches rate limits, and registers tools):
```bash
./install-bundle.sh
# or
./bundle-installer.sh
```

---

## 🎯 Modular Usage Options

You can also run specific components using the bundle installer:

### Option A: Install & Run Smolagent CLI (Standalone Agent)
```bash
# Setup or run a prompt through Smolagent CLI
./install-bundle.sh smolagent "Echo 'Pipeline Test: OK' | tr a-z A-Z"

# Use ~/agent.sh anytime afterwards:
~/agent.sh "Your prompt here"
```

### Option B: Install & Sync Open WebUI with Tools Only
```bash
./install-bundle.sh openwebui
```

### Option C: Manage the Running AI Stack
```bash
# Start full stack (Gemini-FastAPI on port 8000 + Open WebUI on port 8080):
./install-bundle.sh start

# Check service health and running PIDs:
./install-bundle.sh status

# Stop all stack services and free ports:
./install-bundle.sh stop

# Restart all services:
./install-bundle.sh restart
```

---

## 🛡️ Stability & Quota Protections Included

1. **Automatic Process Termination**: Installers automatically detect and terminate old instances of `gemini-fastapi` (port 8000) and `open-webui` (port 8080) before updating, eliminating stale cache bugs and port collisions.
2. **1 Request per 2 Seconds Rate Limiting**: Both Smolagent and Gemini-FastAPI enforce a minimum 2.0s gap between requests, preventing quota rejections from Google's web endpoint.
3. **Resilient Session Fallback**: Multi-turn chat desyncs automatically trigger fresh session replay instead of hanging or crashing streaming requests.
4. **Single-Request WebUI Tuning**: Disabled automatic background generation tasks (`title`, `tags`, `follow_up`, `autocomplete`) in Open WebUI to prevent 4 concurrent requests per prompt.
