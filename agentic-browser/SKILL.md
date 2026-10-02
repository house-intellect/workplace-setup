---
name: agentic-browser
description: Autonomous, semantic browser navigation capabilities for dynamic DOM analysis, element interaction, file uploads, quiz solving, and data extraction via CDP.
---
# Skill: agentic-browser

Autonomous, semantic browser navigation capabilities for dynamic DOM analysis, element interaction, file uploads, quiz solving, and data extraction using an existing browser session via Chrome DevTools Protocol (CDP).

## Triggers
"browse", "navigate", "extract from web", "interact with browser", "upload file to browser", "fix browser viewport", "step-fill", "goto", "screenshot", "scroll", "wait-quiz", "select option", "type answer"

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
- `--url=<substring>`: Target tab matching URL substring (e.g. `--url=publishing`, `--url=avito`).
- `--tab=<index>`: Target tab by zero-based index (e.g. `--tab=1`, `--tab=2`).

---

## Commands

### 1. Tab & Viewport Management
- `tabs`
  List all open browser tabs with their index, title, and current URL.
- `goto <url>` (or `navigate <url>`)
  Navigates the active tab to the specified URL (auto-prefixes `https://` if protocol omitted) and waits for network idle.
- `screenshot [filePath]`
  Captures a screenshot of the active tab. Defaults to `~/Pictures/screenshot_<timestamp>.png` (or `/tmp/`).
- `reset-viewport` (or `fix-viewport`)
  Clears CDP device metrics and viewport emulation (`Emulation.clearDeviceMetricsOverride`), restoring the browser's native full-window desktop resolution (fixes 800×600 shrinking).

### 2. Inspection & Mapping
- `map`
  Generates a semantic map of actionable elements (`button`, `a`, `input`, `textarea`, `select`, `role="button"`, `debug-id`, `data-marker`, etc.) on the target page.
- `text [selector]`
  Extracts `innerText` from the entire page or a specific CSS selector.
- `wait <textOrSelector> [timeoutMs]`
  Waits for specific text or a DOM selector to become available (default 30s timeout).
- `errors` (or `check-errors`)
  Scans the page for active validation errors, error banners, and alert dialogs (e.g. `[data-marker*="error"]`, `.error`, `[role="alert"]`), returning counts and error messages.

### 3. User Interactions & Form Filling
- `input <target> <value>` *(Step-fill by default)*
  Finds the target input, textarea, or form field, scrolls into view, focuses, clears existing text, and types the value **symbol by symbol** with realistic keystroke delays (25-35ms) and event dispatching (`input`, `change`, `blur`). Fully compatible with React controlled components, Vue, Angular, autocomplete suggestions, and masked inputs.
- `step-fill <target> <value>` (or `step_fill`)
  Explicit alias for `input` with symbol-by-symbol entry.
- `click <target>`
  Robust click matching by visible text, `data-marker` (e.g. `item-edit/button-next`, `geo/undefined/custom-option(0)`), `aria-label`, `debug-id`, or placeholder. Automatically scrolls into view, activates radio/checkbox states, and clicks associated labels or buttons.
- `select-option <target> <option>` (or `select-dropdown`)
  Selects an option by value or text from standard HTML `<select>` elements or clicks custom dropdown triggers and selects matching options from popup listboxes/menus.
- `scroll [down|up|top|bottom|<selector>]`
  Smoothly scrolls the page up/down, to the top/bottom, or scrolls a specific element into view.
- `upload <file1> [file2... | directory]`
  Uploads one or more files to `<input type="file">`. Supports individual files, comma-separated lists, and directories (automatically finds all image/document files in the folder).

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
