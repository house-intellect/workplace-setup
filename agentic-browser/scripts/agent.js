const puppeteer = require('puppeteer');
const { execSync } = require('child_process');

async function ensureBrowserRunning() {
  try {
    const res = await fetch('http://127.0.0.1:9222/json/version');
    if (res.ok) return;
  } catch (e) {
    // Not running
  }

  let browserCmd = 'yandex-browser';
  try {
    execSync('which yandex-browser', { stdio: 'ignore' });
  } catch (e) {
    try {
      execSync('which yandex-browser-stable', { stdio: 'ignore' });
      browserCmd = 'yandex-browser-stable';
    } catch (err) {
      browserCmd = 'google-chrome';
    }
  }

  execSync(`nohup ${browserCmd} --remote-debugging-port=9222 > /dev/null 2>&1 &`);

  for (let i = 0; i < 20; i++) {
    try {
      const res = await fetch('http://127.0.0.1:9222/json/version');
      if (res.ok) return;
    } catch (e) {}
    await new Promise((r) => setTimeout(r, 500));
  }
}

class BrowserAgent {
  constructor() {
    this.browser = null;
  }

  async init() {
    await ensureBrowserRunning();
    const versionResp = await fetch('http://127.0.0.1:9222/json/version');
    const versionData = await versionResp.json();
    this.browser = await puppeteer.connect({
      browserWSEndpoint:
        'ws://127.0.0.1:9222/devtools/browser/' +
        versionData.webSocketDebuggerUrl.split('/').pop(),
      defaultViewport: null,
    });
  }

  async getPage() {
    const pages = await this.browser.pages();
    return pages[0] || (await this.browser.newPage());
  }

  async getSemanticMap() {
    const page = await this.getPage();
    return await page.evaluate(() => {
      const selector = 'a, button, input, textarea, label, [role="button"], [role="radio"], [role="tab"], [data-marker], div[class*="category"], div[class*="item"], div[class*="card"]';
      const actionable = Array.from(document.querySelectorAll(selector))
        .filter((el) => {
          const style = window.getComputedStyle(el);
          return (
            el.offsetWidth > 0 &&
            el.offsetHeight > 0 &&
            style.display !== 'none' &&
            style.visibility !== 'hidden'
          );
        })
        .map((el) => ({
          text: (
            el.innerText ||
            el.value ||
            el.placeholder ||
            el.getAttribute('aria-label') ||
            el.getAttribute('title') ||
            ''
          ).trim(),
          tagName: el.tagName,
          dataMarker: el.getAttribute('data-marker'),
          type: el.type || el.getAttribute('role') || null,
        }))
        .filter(
          (el) =>
            (el.text.length > 0 && el.text.length < 150) ||
            el.tagName === 'INPUT' ||
            el.tagName === 'TEXTAREA'
        );
      return {
        url: window.location.href,
        title: document.title,
        actionable: actionable.slice(0, 150),
      };
    });
  }

  async performAction(type, target, value = '') {
    const page = await this.getPage();
    if (type === 'goto') {
      await page.goto(target, { waitUntil: 'domcontentloaded', timeout: 60000 });
      return { success: true, url: page.url(), title: await page.title() };
    }
    if (type === 'screenshot') {
      let path = 'browser_screenshot.png';
      if (target && !target.startsWith('http://') && !target.startsWith('https://') && target !== 'page') {
        path = target;
      }
      await page.screenshot({ path });
      return { success: true, screenshot_path: path };
    }

    const el = await page.evaluateHandle((type, target) => {
      // 1. Check if target is a CSS selector (e.g. input[data-marker="..."] or button[...])
      if (target.includes('[') || target.includes('.') || target.includes('#')) {
        try {
          const matchBySelector = document.querySelector(target);
          if (matchBySelector) return matchBySelector;
        } catch (e) {}
      }

      const selector = 'a, button, input, textarea, label, [role="button"], [role="radio"], [role="tab"], [data-marker], div, span';
      const elements = Array.from(document.querySelectorAll(selector));
      const targetLower = target.trim().toLowerCase();

      // 2. Combined Exact Match (Matches both text AND data-marker if available)
      let match = elements.find(
        (el) =>
          el.innerText &&
          el.innerText.trim() === target &&
          (!el.getAttribute('data-marker') || el.getAttribute('data-marker') === target)
      );

      // 3. Exact match by text, value, placeholder, or aria-label
      if (!match) {
        match = elements.find(
          (el) =>
            (el.innerText && el.innerText.trim() === target) ||
            (el.value && el.value.trim() === target) ||
            (el.placeholder && el.placeholder === target) ||
            (el.getAttribute('aria-label') === target)
        );
      }

      // 4. Match data-marker if target equals exact data-marker value
      if (!match) {
        match = elements.find(
          (el) => el.getAttribute('data-marker') && el.getAttribute('data-marker') === target
        );
      }

      // 5. Partial text match fallback (case-insensitive)
      if (!match) {
        match = elements.find(
          (el) =>
            el.innerText &&
            el.innerText.trim().toLowerCase().includes(targetLower) &&
            el.innerText.trim().length < 150
        );
      }

      return match;
    }, type, target);

    if (!el) throw new Error(`Element matching '${target}' not found on page`);

    if (type === 'click') {
      try {
        await page.evaluate((el) => el.scrollIntoView({ block: 'center', inline: 'center' }), el);
        await new Promise(r => setTimeout(r, 300));
        await el.click();
      } catch (err) {
        // Fallback: click bounding box center physically via page.mouse
        const box = await el.boundingBox();
        if (box) {
          await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);
        } else {
          await page.evaluate((el) => {
            const opts = { bubbles: true, cancelable: true, view: window };
            try { el.dispatchEvent(new PointerEvent('pointerdown', opts)); } catch(e) {}
            try { el.dispatchEvent(new MouseEvent('mousedown', opts)); } catch(e) {}
            try { el.dispatchEvent(new PointerEvent('pointerup', opts)); } catch(e) {}
            try { el.dispatchEvent(new MouseEvent('mouseup', opts)); } catch(e) {}
            try { el.dispatchEvent(new MouseEvent('click', opts)); } catch(e) {}
            if (typeof el.click === 'function') el.click();
          }, el);
        }
      }
      await new Promise(r => setTimeout(r, 1000));
    }

    if (type === 'input') {
      const isInput = await page.evaluate((el) => {
        if (!el) return false;
        let inputEl = el;
        if (el.tagName !== 'INPUT' && el.tagName !== 'TEXTAREA') {
          inputEl = el.querySelector('input, textarea') ||
                    (el.htmlFor ? document.getElementById(el.htmlFor) : null) ||
                    el.closest('label, div, section, fieldset')?.querySelector('input, textarea');
        }
        if (!inputEl) return false;
        try {
          inputEl.focus();
          inputEl.value = '';
        } catch(e) {}
        return true;
      }, el);

      if (!isInput) {
        // Fallback: try finding any active or visible input on the page
        const inputs = await page.$$('input[type="text"], input:not([type]), textarea');
        if (inputs.length > 0) {
          await inputs[0].focus();
          await inputs[0].type(value, { delay: 50 });
          return { success: true, url: page.url() };
        }
        throw new Error(`Could not find an input field matching '${target}'`);
      }

      // Type text cleanly into target element handle
      try {
        await el.type(value, { delay: 50 });
      } catch (err) {
        await page.evaluate((el, val) => {
          let inputEl = (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') ? el : el.querySelector('input, textarea');
          if (inputEl) {
            inputEl.value = val;
            inputEl.dispatchEvent(new Event('input', { bubbles: true }));
            inputEl.dispatchEvent(new Event('change', { bubbles: true }));
          }
        }, el, value);
      }
    }
    return { success: true, url: page.url() };
  }

  async close() {
    if (this.browser) await this.browser.disconnect();
  }
}

(async () => {
  const [command, target, value] = process.argv.slice(2);
  const agent = new BrowserAgent();
  await agent.init();
  try {
    if (command === 'map')
      console.log(JSON.stringify(await agent.getSemanticMap(), null, 2));
    else if (command === 'goto')
      console.log(JSON.stringify(await agent.performAction('goto', target)));
    else if (command === 'screenshot')
      console.log(
        JSON.stringify(await agent.performAction('screenshot', target))
      );
    else if (command === 'click')
      console.log(JSON.stringify(await agent.performAction('click', target)));
    else if (command === 'input')
      console.log(
        JSON.stringify(await agent.performAction('input', target, value))
      );
  } catch (err) {
    console.error(JSON.stringify({ error: err.message }));
  } finally {
    await agent.close();
  }
})();
