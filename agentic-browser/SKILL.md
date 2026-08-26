---
name: agentic-browser
description: Autonomous, semantic browser navigation capabilities for dynamic DOM analysis, element interaction, and data extraction.
---
# Skill: agentic-browser
Triggers: "browse", "navigate", "extract from web", "interact with browser"
Usage:
Use `node .agents/skills/agentic-browser/scripts/agent.js [command] [target] [value]` to interact with the browser.
Commands:
- `map`: Returns the semantic JSON map of actionable elements.
- `click <target>`: Clicks an element by text, placeholder, or data-marker.
- `input <target> <value>`: Types value into an input element.
