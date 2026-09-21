---
name: agentic-browser
description: Autonomous, semantic browser navigation capabilities for dynamic DOM analysis, element interaction, file uploads, quiz solving, and data extraction via CDP.
---
# Skill: agentic-browser

Autonomous, semantic browser navigation capabilities for dynamic DOM analysis, element interaction, file uploads, quiz solving, and data extraction using an existing browser session via Chrome DevTools Protocol (CDP).

## Triggers
"browse", "navigate", "extract from web", "interact with browser", "upload file to browser", "fix browser viewport", "wait-quiz", "select option", "type answer"

## Prerequisites: Running the Debugged Browser
The browser automation connects strictly to an existing browser instance on port `9222`. It does not launch standalone browsers.

Run the debugged browser with:
```bash
yandex-browser --remote-debugging-port=9222 --user-data-dir=$HOME/.config/yandex-browser-debug --remote-allow-origins="*"
```

> **Note**: Remote debugging requires a non-default `--user-data-dir` and `--remote-allow-origins="*"` for the CDP endpoint (`127.0.0.1:9222`) to bind properly.

### Verification
Verify connectivity before issuing automation commands:
```bash
curl -s http://127.0.0.1:9222/json/version
```

---

## Execution
Run commands via:
```bash
node ~/.agents/skills/agentic-browser/scripts/agent.js [options] <command> [arguments...]
```

### Global Target Options
Filter the target tab before executing commands:
- `--url=<substring>`: Target tab matching URL substring (e.g. `--url=publishing`, `--url=store-listings`).
- `--tab=<index>`: Target tab by zero-based index (e.g. `--tab=1`).

---

## Commands

### 1. Tab & Viewport Management
- `tabs`
  List all open browser tabs with their index, title, and current URL.
- `reset-viewport` (or `fix-viewport`)
  Clears CDP device metrics and viewport emulation (`Emulation.clearDeviceMetricsOverride`), restoring the browser's native full-window desktop resolution (fixes the 800×600 shrinking issue).

### 2. Inspection & Mapping
- `map`
  Generates a semantic map of actionable elements (`button`, `a`, `input`, `textarea`, `select`, `role="button"`, `debug-id`, etc.) on the target page.
- `text [selector]`
  Extracts `innerText` from the entire page or a specific CSS selector.
- `wait <textOrSelector> [timeoutMs]`
  Waits for specific text or a DOM selector to become available (default 30s timeout).

### 3. User Interactions
- `click <target>`
  Robust click matching by visible text (ignoring material icon prefixes/newlines), `aria-label`, `debug-id`, `placeholder`, or `data-marker`.
- `input <target> <value>`
  Sets input or textarea values using framework-compatible native property setters (compatible with Angular, React, Vue, Material Web Components) and dispatches `input` + `change` events.
- `upload <file1> [file2...]`
  Uploads one or more files to `<input type="file">`. Automatically handles multiple file attributes and dynamically injected file uploaders (like Google Play Console asset drawers and AI import modals).

### 4. Quiz & Assessment Automation (QuizMaster)
- `wait-quiz [previous_question]`
  Waits in blocking mode for a quiz question to render or update, returning structured JSON with question text, type (`choice` or `open_ended`), options, and URL.
- `select <target>`
  Non-intrusively selects a radio button, checkbox, or option button without submitting.
- `type <text> [delay_ms]`
  Types into open input fields or Monaco code editors with simulated human keystroke delay (~200ms/char default) and tab-based indentation.
- `type-file <file_path> [delay_ms]`
  Reads code/text from a file and types it with natural typing delay into the active code editor or textarea.

### 5. Advanced Automation
- `eval "<code>"`
  Executes arbitrary JavaScript within the target tab context and outputs the evaluated result as JSON.
