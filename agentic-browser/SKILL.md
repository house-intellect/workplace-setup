---
name: agentic-browser
description: Autonomous, semantic browser navigation capabilities for dynamic DOM analysis, element interaction, and data extraction.
---
# Skill: agentic-browser

Autonomous, semantic browser navigation capabilities for dynamic DOM analysis, element interaction, and data extraction using an existing browser session via Chrome DevTools Protocol (CDP).

## Triggers
"browse", "navigate", "extract from web", "interact with browser"

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

## Usage
Use `node ~/.agents/skills/agentic-browser/scripts/agent.js [command] [target] [value]` to interact with the browser.

### Commands:
- `map`: Returns the semantic JSON map of actionable elements on the active page.
- `click <target>`: Clicks an element by text, placeholder, or data-marker.
- `input <target> <value>`: Types value into an input element.
- `wait-quiz [previous_question]`: Waits in blocking mode for a quiz question to render or update.
- `select <target>`: Non-intrusively selects a radio button, checkbox, or option button without submitting.
- `type <text> [delay_ms]`: Types into open input fields with simulated human keystroke delay (~300ms/char default).
