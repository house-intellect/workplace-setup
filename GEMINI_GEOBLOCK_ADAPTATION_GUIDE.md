# Gemini Third-Party Agent Geoblock Bypass & Adaptation Handover Manual
*A comprehensive guide and recipe for adapting AI agents (e.g., Smolagents, Open WebUI, Oh My Pi, CrewAI, LangChain) to operate in geoblocked regions using Gemini WebAPI and DoH SNI Proxying without Keyring/KWallet blocks.*

---

## 1. Executive Summary & Problem Landscape

In many regions, Google restricts direct access to the Gemini web application (`gemini.google.com`) and Gemini API endpoints based on geolocation (IP-based geo-fencing). Additionally, building agentic stacks that interface with Gemini Web encounters three major hurdles:

1. **Geoblocking & Proxy Detection**: Conventional datacenter proxies or VPNs are frequently detected, throttled, or flagged with CAPTCHAs by Google Cloud Armor.
2. **KDE Wallet / OS Keyring Locking**: Extracting stored cookies from Chromium-based browsers (Chrome, Chromium, Brave, Edge) on Linux queries D-Bus Secret Service / KWallet. In headless, remote SSH, or automated CLI environments, this triggers interactive GUI modals or hard-locks the process indefinitely.
3. **Session Integrity & Protocol Drift**: Google Gemini Web requires multi-token authentication (`__Secure-1PSID`, `__Secure-1PSIDTS`, and session integrity token `__Secure-1PSIDCC` / `__Secure-3PSIDCC`). Furthermore, Google's internal Batchexecute RPCs (`otAQ7b`, `StreamGenerate`) evolve, changing response formats and returning undocumented codes (such as `1096` or `1097`) that cause naive scrapers to fail on multi-turn conversations.

### The Solution Architecture
```
┌────────────────────────────────────────────────────────┐
│ Target Machine (e.g. Remote Host / VPS / Local System) │
│                                                        │
│  Firefox Browser (Logged into gemini.google.com)       │
│    └─ Plain SQLite Storage: cookies.sqlite             │
│         (NO KWallet / NO Keyring / Zero GUI Dialogs)   │
│                                                        │
│  Agent Installer / Runner (e.g. agent.sh, oh-my-pi)   │
│    ├─ rookiepy.firefox([".google.com"])                │
│    │    └─ Extracts 1PSID, 1PSIDTS, 1PSIDCC/3PSIDCC    │
│    │                                                   │
│    ├─ Gemini-FastAPI (Local Server :8000)              │
│    │    ├─ OpenAI-Compatible /v1/chat/completions      │
│    │    ├─ Built-in Tool Calling & Function Execution  │
│    │    └─ curl_cffi with DoH SNI Proxy                │
│    │                                                   │
│    └─ Outbound HTTPS Request via curl_cffi             │
└──────────────────────────┬─────────────────────────────┘
                           │
                           │ DoH: https://xbox-dns.ru/dns-query
                           ▼
┌────────────────────────────────────────────────────────┐
│ SNI Reverse-Proxy / DoH Gateway (xbox-dns.ru)          │
│   Reroutes gemini.google.com to unblocked edge nodes   │
└──────────────────────────┬─────────────────────────────┘
                           │
                           ▼
┌────────────────────────────────────────────────────────┐
│ Google Gemini Infrastructure (gemini.google.com)       │
│   Full 2.5/3.0/3.7 Flash & Pro access, search, tools   │
└────────────────────────────────────────────────────────┘
```

---

## 2. The Three Architectural Pillars

### Pillar 1: DoH SNI Proxy Routing via `curl_cffi`

Rather than tunneling all system traffic through a slow or detectable SOCKS/HTTP proxy, we route only Google hostnames through an SNI-resolving DNS-over-HTTPS (DoH) resolver. 

* **Primary DoH Resolver**: `https://xbox-dns.ru/dns-query` (Fallback: `https://dns.comss.one/dns-query`)
* **How it works**: The DoH server resolves `gemini.google.com` to edge reverse proxies that forward TLS ClientHello SNI headers transparently, bypassing regional IP filtering while maintaining end-to-end TLS security.
* **Implementation**: We inject `CurlOpt.DOH_URL` into `curl_cffi.requests.AsyncSession` or `BaseSession`:

```python
from curl_cffi import CurlOpt
from curl_cffi.requests import AsyncSession

# Explicit DoH option in curl_cffi
session = AsyncSession(
    impersonate="chrome",
    curl_options={CurlOpt.DOH_URL: b"https://xbox-dns.ru/dns-query"}
)
```

> [!IMPORTANT]
> **Proxy Environment Isolation**: Local proxy environment variables (`http_proxy`, `https_proxy`, `all_proxy`) must be unset when running local agents so requests to `http://127.0.0.1:8000` do not get routed into external proxies. Outbound requests to Google will exclusively use the DoH resolver configured in `curl_cffi`.

---

### Pillar 2: Zero-Keyring Firefox Cookie Extraction

Chromium-based browsers store cookies with encrypted values where the encryption key resides in the system keyring (`gnome-keyring`, `kwallet`, or D-Bus SecretService). Reading them programmatically prompts for a password unlock dialog.

**Firefox stores cookies in plain SQLite format**:
* File location: `~/.mozilla/firefox/*.default-release/cookies.sqlite`
* Can be read directly from Python using `rookiepy.firefox([".google.com"])` without invoking D-Bus or GUI prompts.

#### The Cookie Triple and Fallbacks
Google Gemini Web requires three security tokens:
1. `__Secure-1PSID`: Account session token.
2. `__Secure-1PSIDTS`: Session timestamp token (rotated periodically).
3. `__Secure-1PSIDCC`: Session integrity cookie.

> [!TIP]
> **The 3PSIDCC / SIDCC Fallback**: On Firefox (specifically under Total Cookie Protection / Multi-Account Containers), Google often saves the integrity token under `__Secure-3PSIDCC` or `SIDCC` instead of `__Secure-1PSIDCC`.
> **Always resolve with fallback**:
> `psidcc = cdict.get("__Secure-1PSIDCC") or cdict.get("__Secure-3PSIDCC") or cdict.get("SIDCC")`

#### Preserving Cookies in the Rotation Cache
In `gemini_webapi/utils/rotate_1psidts.py`, ensure that when `save_cookies` writes to `/tmp/gemini_webapi/.cached_cookies_*.json`, it does not discard session integrity tokens:
```python
is_auth_cookie = cookie.name in [
    "__Secure-1PSID",
    "__Secure-1PSIDTS",
    "__Secure-1PSIDCC",
    "__Secure-3PSID",
    "__Secure-3PSIDTS",
    "__Secure-3PSIDCC",
    "SIDCC",
]
```

---

### Pillar 3: Google RPC & Status Code Patches

Google's internal APIs change without warning. The following patches are essential for modern Google accounts:

#### 1. Numeric Session ID in `GET_USER_STATUS` (`otAQ7b`)
* **Google's Change**: Google now returns a 64-bit integer session ID (e.g. `5491852811706632035`) in `part_body` instead of a list with status code at index 14.
* **Fix**: In `gemini_webapi/client.py`:
  ```python
  status_code = get_nested_value(part_body, [14])
  if isinstance(status_code, int):
      # A valid 64-bit session ID indicates an authenticated available session
      self.account_status = AccountStatus.AVAILABLE
  else:
      self.account_status = AccountStatus.from_status_code(status_code)
  ```

#### 2. Non-Fatal Stream Codes (`1096` / `1097`)
* **Google's Change**: Google frequently sends completion frames containing status `1096` or `1097` (`BardErrorInfo`) after successfully streaming answer text.
* **Fix**: Treat these codes as non-fatal post-generation delimiters if text has already been emitted:
  ```python
  case _:
      if has_generated_text or error_code in [1096, 1097]:
          logger.warning(f"Ignoring non-fatal post-generation code {error_code}")
          is_completed = True
          break
      raise APIError(f"Failed to generate contents. Error code: {error_code}")
  ```

#### 3. Streamlined Startup RPCs
* Default `gemini_webapi` attempts `_send_bard_settings`, `_send_bard_activity`, and `_fetch_recent_chats` during `client.init()`. Google frequently throttles or drops these auxiliary RPCs on non-US IP addresses, causing 30–60 second startup delays.
* **Fix**: Bypassing these during `_init_rpc` drops client startup time from ~35 seconds to **under 2 seconds**.

---

## 3. The Reusable Adaptation Recipe (Step-by-Step)

When adapting a new third-party agent (such as **"Oh My Pi"**, Smolagents, AutoGPT, or custom CLI scripts) to use this bypass, follow this standardized pattern.

### Step 1: Deploy `Gemini-FastAPI` as Local OpenAI Proxy

The cleanest architecture is running `gemini-fastapi` on `http://127.0.0.1:8000/v1`. This provides standard OpenAI endpoints:
* `POST /v1/chat/completions` (supports streaming, tools/function calling, system prompts)
* `GET /v1/models` (exposes `gemini-3.8-flash`, `gemini-3.7-pro`, etc.)

#### `Gemini-FastAPI` Deployment Code Snippet
Ensure `app/services/pool.py` has Firefox-first extraction with the `3PSIDCC`/`SIDCC` fallback:
```python
import rookiepy

def extract_firefox_gemini_credentials():
    cookies = rookiepy.firefox([".google.com"])
    cdict = {c["name"]: c["value"] for c in cookies if c.get("domain") in [".google.com", "google.com"]}
    psid = cdict.get("__Secure-1PSID")
    psidts = cdict.get("__Secure-1PSIDTS")
    psidcc = cdict.get("__Secure-1PSIDCC") or cdict.get("__Secure-3PSIDCC") or cdict.get("SIDCC")
    
    if not (psid and psidts):
        raise ValueError("Google login cookies not found in Firefox. Please log into gemini.google.com in Firefox.")
        
    return {
        "secure_1psid": psid,
        "secure_1psidts": psidts,
        "secure_1psidcc": psidcc,
    }
```

---

### Step 2: Configure the Target Agent

Most modern agents (including "Oh My Pi", Smolagents, LangChain, LlamaIndex) have native support for custom OpenAI-compatible endpoints.

#### Configuration Environment Variables
Set the target agent to point to local `gemini-fastapi`:
```bash
export OPENAI_BASE_URL="http://127.0.0.1:8000/v1"
export OPENAI_API_BASE="http://127.0.0.1:8000/v1"
export OPENAI_API_KEY="sk-gemini-local"   # Dummy key accepted by local server
export MODEL="gemini-3.8-flash"          # Or gemini-3.7-pro, gemini-3.0-flash
```

#### Example: Python Integration (`smolagents` / `oh-my-pi`)
```python
from smolagents import CodeAgent, OpenAIServerModel, ToolCallingAgent

model = OpenAIServerModel(
    model_id="gemini-3.8-flash",
    api_base="http://127.0.0.1:8000/v1",
    api_key="sk-gemini-local",
)

agent = ToolCallingAgent(
    tools=[...],
    model=model
)

response = agent.run("Perform task...")
```

---

### Step 3: Write the Universal Runner Script (`agent.sh`)

Create a runner shell script that ensures local environment isolation, starts the FastAPI daemon if it is not already active, and executes the agent.

```bash
#!/bin/sh
FASTAPI_PORT=8000
STACK_DIR="$HOME/local-ai-stack"
FASTAPI_DIR="$STACK_DIR/gemini-fastapi"
PYTHON_EXEC="$STACK_DIR/tool-calling-test/.venv/bin/python"

# 1. Unset system proxies for localhost loopback safety
unset all_proxy ALL_PROXY http_proxy HTTP_PROXY https_proxy HTTPS_PROXY

# 2. Check if FastAPI server is responding on localhost
if ! curl --noproxy "*" --max-time 3 -s -f "http://127.0.0.1:$FASTAPI_PORT/v1/models" >/dev/null 2>&1; then
    echo "Starting Gemini-FastAPI server on port $FASTAPI_PORT..."
    (cd "$FASTAPI_DIR" && nohup env -u all_proxy -u ALL_PROXY -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY "$PYTHON_EXEC" run.py > "$STACK_DIR/proxy_access.log" 2>&1 &)
    
    PROXY_READY=0
    i=1
    while [ $i -le 30 ]; do
        if curl --noproxy "*" --max-time 3 -s -f "http://127.0.0.1:$FASTAPI_PORT/v1/models" >/dev/null 2>&1; then
            PROXY_READY=1
            break
        fi
        sleep 1
        i=$((i + 1))
    done

    if [ $PROXY_READY -eq 0 ]; then
        echo "Error: Gemini-FastAPI failed to start on port $FASTAPI_PORT."
        tail -n 25 "$STACK_DIR/proxy_access.log"
        exit 1
    fi
fi

# 3. Execute the agent payload (e.g. Oh My Pi / Smolagent)
exec env -u all_proxy -u ALL_PROXY -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY \
     OPENAI_BASE_URL="http://127.0.0.1:$FASTAPI_PORT/v1" \
     OPENAI_API_KEY="sk-gemini-local" \
     "$PYTHON_EXEC" "$STACK_DIR/agent_runner.py" "$@"
```

---

## 4. One-Script Installer Adaptation Blueprint (e.g. `install_oh_my_pi.sh`)

When adapting an installer like `oh-my-pi`, structure the bash installer into 4 modular stages:

### Stage 1: System Checks & Firefox Verification
* Verify `python3` (>= 3.10), `curl`, and `tar` exist.
* Verify Firefox exists (`command -v firefox`) and check that `~/.mozilla/firefox/*.default-release/cookies.sqlite` is present.
* Inform the user to log into `gemini.google.com` in Firefox if cookies are missing.

### Stage 2: Isolated Virtual Environment & Dependencies
Install dependencies without polluting global Python:
```bash
python3 -m venv "$TARGET_DIR/.venv"
"$TARGET_DIR/.venv/bin/pip" install --upgrade pip
"$TARGET_DIR/.venv/bin/pip" install \
    rookiepy \
    "curl_cffi>=0.7.4" \
    "gemini-webapi==2.0.0" \
    fastapi uvicorn lmdb pydantic pydantic-settings pyyaml
```

### Stage 3: Auto-Patching `gemini_webapi` & `curl_cffi`
Run an inline Python patcher in the installer to ensure:
1. `gemini_webapi/client.py` includes `self.curl_options` and sets `CurlOpt.DOH_URL = b"https://xbox-dns.ru/dns-query"`.
2. `gemini_webapi/client.py` recognizes numeric session IDs as `AccountStatus.AVAILABLE`.
3. `gemini_webapi/client.py` suppresses non-fatal codes 1096 and 1097.
4. `gemini_webapi/utils/rotate_1psidts.py` retains `__Secure-1PSIDCC`, `__Secure-3PSIDCC`, and `SIDCC` in `is_auth_cookie`.
5. `curl_cffi/requests/utils.py` applies `CurlOpt.DOH_URL` as default if none is provided.

### Stage 4: Service Deployment
Deploy `gemini-fastapi` either as:
* A `systemd --user` service (`~/.config/systemd/user/gemini-fastapi.service`), OR
* An on-demand background daemon launched automatically by the runner script.

---

## 5. Troubleshooting & Verification Checklist

| Symptom | Root Cause | Solution |
| :--- | :--- | :--- |
| **KDE Wallet popup / prompt freezes script** | Cookie extractor is reading Chrome/Brave/Edge and hitting D-Bus SecretService. | Prioritize Firefox SQLite extraction (`rookiepy.firefox([".google.com"])`). Never query Chromium unless Firefox is absent. |
| **"Session is not authenticated or cookies have expired"** | Missing `__Secure-1PSIDCC` or integer session ID in `otAQ7b` RPC. | Use fallback: `1PSIDCC -> 3PSIDCC -> SIDCC`. Apply numeric session ID patch to `_fetch_user_status`. |
| **"Unknown API error code: 1097" on Turn 2** | `rotate_1psidts.py` dropped `__Secure-1PSIDCC` when saving to `/tmp/gemini_webapi/.cached_cookies_*.json`. | Add `__Secure-1PSIDCC`, `__Secure-3PSIDCC`, `SIDCC` to `is_auth_cookie` in `rotate_1psidts.py`. Remove stale cache with `rm -rf /tmp/gemini_webapi`. |
| **502 Bad Gateway / Connection Timed Out** | Google dropped auxiliary RPCs (`_send_bard_activity`, `_send_bard_settings`). | Remove auxiliary blocking RPCs from `_init_rpc` in `gemini_webapi/client.py`. |
| **"User location is not supported"** | Requests are reaching Google via the local direct ISP IP without DoH SNI rerouting. | Verify `curl_options={CurlOpt.DOH_URL: b"https://xbox-dns.ru/dns-query"}` is active on all outbound curl sessions. |
| **`sqlite3.OperationalError: database is locked`** | Firefox is actively running and holding an exclusive SQLite lock on `cookies.sqlite`. | Use `rookiepy.firefox()` (which safely copies SQLite to memory/tmp before reading) rather than opening `cookies.sqlite` directly with raw sqlite3. |

---

## 6. Smoke Test Verification Commands

Run these tests on the target host to verify full functionality:

```bash
# 1. Verify DoH connectivity and Google status
python3 -c "
import asyncio, rookiepy
from curl_cffi import CurlOpt
from gemini_webapi import GeminiClient

async def test():
    cookies = rookiepy.firefox(['.google.com'])
    cd = {c['name']: c['value'] for c in cookies}
    psidcc = cd.get('__Secure-1PSIDCC') or cd.get('__Secure-3PSIDCC') or cd.get('SIDCC')
    client = GeminiClient(
        secure_1psid=cd['__Secure-1PSID'],
        secure_1psidts=cd['__Secure-1PSIDTS'],
        secure_1psidcc=psidcc,
        curl_options={CurlOpt.DOH_URL: b'https://xbox-dns.ru/dns-query'}
    )
    await client.init(timeout=30, auto_refresh=False)
    chat = client.start_chat()
    r1 = await chat.send_message('Say 1')
    r2 = await chat.send_message('Say 2')
    print('Turn 1:', r1.text)
    print('Turn 2:', r2.text)
    await client.close()

asyncio.run(test())
"

# 2. Verify Agent Tool Calling through Local FastAPI Proxy
~/agent.sh "Echo 'Geoblock bypass verified' | tr a-z A-Z"
```
When successful, Step 1 executes `execute_bash` and Step 2 returns `GEOBLOCK BYPASS VERIFIED`.
