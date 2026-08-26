# Workplace Setup & AI Stack Automation

Comprehensive zero-touch installation scripts, tools, and agentic skills for deploying an autonomous AI stack on Linux systems. Supports both **Open WebUI** (web interface with native tools) and **Smolagents** (standalone Python agent CLI with Gemini OpenAI Proxy).

---

## 🛠️ Included Software Suites & Capabilities

### 1. Open WebUI Local Stack (`install_openwebui_tools.sh`)
An all-in-one bash installer and SQLite database tool syncer for [Open WebUI](https://github.com/open-webui/open-webui).

**Key Features:**
- **Auto-Installation**: Automatically clones Open WebUI if not present in the target directory.
- **Smart Virtualenv Reuse**: Scans directory tree up to `$HOME` to locate and reuse existing Python virtual environments (`.venv`).
- **Database Tool Injection**: Registers `native_bash_tool` and `agentic_browser_tool` directly into `webui.db` with complete JSON schemas.
- **Multi-Turn Fixes Included**: Pre-configured with fallback handling for Jinja prompt templates during tool calling loops.

---

### 2. Smolagent & Proxy CLI Suite (`setup_and_run_smolagent.sh` & `agent.sh`)
An autonomous tool-calling CLI agent powered by Hugging Face `smolagents` and a local Gemini OpenAI proxy.

**Key Features:**
- **One-Click Bootstrap**: Checks system dependencies (`node`, `npm`, `python3`, `git`, `nc`) and auto-builds missing stack components.
- **Gemini OpenAI Proxy Integration**: Starts a local Node.js proxy on port `8085` to convert Gemini API calls into OpenAI-compatible endpoint responses.
- **Multimodal & File Support**:
  - `-f /path/to/file.txt`: Attach text context or code snippets.
  - `-i /path/to/image.png`: Attach images for multimodal vision reasoning.
- **Autonomous Tool Loops**: Runs code agents capable of local shell command execution, file editing, and web search.

---

### 3. Agentic Browser Skill (`agentic-browser/`)
A Puppeteer-based browser automation engine operating on local Chrome / Yandex Browser instance debugging ports (`9222`).

**Key Features:**
- **Auto-Launch Headless/Headed Browser**: Spawns Yandex Browser / Chrome via `nohup` on port `9222` if inactive.
- **Physical Mouse & Keyboard Emulation**: Uses Puppeteer CDP physical mouse clicks (`isTrusted = true`) and physical keyboard typing (`page.type()`) to bypass React/Next.js SPA interaction defenses.
- **Semantic DOM Mapping**: Evaluates visual interactive elements (`map`) into clean JSON trees for LLM reasoning.
- **Sanitized Screenshots**: Automatically captures rendered DOM page states to `browser_screenshot.png` without filesystem path errors.

---

## 🚀 Installation & Quick Start

### Prerequisites
- Linux OS (Debian/Ubuntu, Fedora, Arch, etc.)
- Python 3.10+
- Node.js 18+ & npm
- Git

---

### Option A: Setup Open WebUI with Tools

Run the Open WebUI auto-installer script:

```bash
./install_openwebui_tools.sh [/path/to/open-webui]
```

- If `/path/to/open-webui` is omitted, defaults to `./open-webui`.
- Deploys `agentic-browser` skill to `~/.agents/skills/agentic-browser`.
- Registers `native_bash_tool` and `agentic_browser_tool` into `webui.db`.

---

### Option B: Setup & Run Smolagent CLI

Run the all-in-one Smolagent launcher script:

```bash
./setup_and_run_smolagent.sh "Your prompt here"
```

#### Examples:

**1. Run a bash execution query:**
```bash
./setup_and_run_smolagent.sh "Check disk space and list top 5 memory consuming processes"
```

**2. Attach a text file:**
```bash
./setup_and_run_smolagent.sh -f main.py "Refactor this code to use async/await"
```

**3. Multimodal vision analysis:**
```bash
./setup_and_run_smolagent.sh -i UI_mockup.png "Generate Jetpack Compose layout code for this design"
```

---

## 📁 Repository Structure

```
workplace-setup/
├── install_openwebui_tools.sh   # Open WebUI installation & SQLite tool injection script
├── setup_and_run_smolagent.sh   # Smolagent dependency checker, proxy runner & launcher
├── agent.sh                     # Smolagent CLI wrapper script (supports -f and -i)
├── agentic-browser/             # Autonomous Puppeteer agent skill folder
│   ├── SKILL.md                 # Agent skill instructions & tool contract
│   ├── package.json             # Puppeteer dependency manifest
│   └── scripts/
│       └── agent.js             # Core Puppeteer browser automation logic (port 9222)
├── README.md                    # Workplace setup documentation
└── .gitignore                   # Excludes .venv, node_modules, logs
```
