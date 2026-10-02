const puppeteer = require('puppeteer');
const path = require('path');
const fs = require('fs');

class BrowserAgent {
  constructor(options = {}) {
    this.browser = null;
    this.targetUrlPattern = options.url || null;
    this.targetTabIndex = options.tab !== undefined && options.tab !== null ? parseInt(options.tab, 10) : null;
  }

  async init() {
    try {
      const versionResp = await fetch('http://127.0.0.1:9222/json/version');
      if (!versionResp.ok) {
        throw new Error(`HTTP ${versionResp.status} from 127.0.0.1:9222`);
      }
      const versionData = await versionResp.json();
      const wsUrl =
        versionData.webSocketDebuggerUrl ||
        ('ws://127.0.0.1:9222/devtools/browser/' + versionData.webSocketDebuggerUrl?.split('/').pop());
      this.browser = await puppeteer.connect({
        browserWSEndpoint: wsUrl,
        defaultViewport: null,
      });

      // Automatically reset any CDP emulation or viewport overrides on all open pages
      try {
        const pages = await this.browser.pages();
        for (const p of pages) {
          await this.ensureFullViewport(p);
        }
      } catch (e) {}

      // Keep viewport full and natural whenever new tabs/pages are created
      this.browser.on('targetcreated', async (target) => {
        if (target.type() === 'page') {
          try {
            const newPage = await target.page();
            if (newPage) await this.ensureFullViewport(newPage);
          } catch (e) {}
        }
      });
    } catch (err) {
      throw new Error(
        `Failed to connect to browser on 127.0.0.1:9222 (${err.message}). Ensure Chromium/Yandex Browser is running with: yandex-browser --remote-debugging-port=9222 --user-data-dir=$HOME/.config/yandex-browser-debug --remote-allow-origins="*"`
      );
    }
  }

  async ensureFullViewport(page) {
    if (!page) return;
    try {
      const u = typeof page.url === 'function' ? page.url() : '';
      if (
        u.startsWith('devtools://') ||
        u.startsWith('chrome://') ||
        u.startsWith('chrome-extension://')
      ) {
        return;
      }
      const client = await page.target().createCDPSession();
      await client.send('Emulation.setDeviceMetricsOverride', {
        width: 0,
        height: 0,
        deviceScaleFactor: 0,
        mobile: false,
      });
      await client.send('Emulation.clearDeviceMetricsOverride');
      await page.setViewport(null);
      await client.detach();
    } catch (e) {}
  }

  async listTabs() {
    const pages = await this.browser.pages();
    const list = [];
    for (let i = 0; i < pages.length; i++) {
      const p = pages[i];
      try {
        list.push({
          index: i,
          title: await p.title(),
          url: p.url(),
        });
      } catch (e) {
        list.push({ index: i, title: '<error>', url: '<error>' });
      }
    }
    return list;
  }

  async getPage() {
    const pages = await this.browser.pages();
    if (!pages || pages.length === 0) {
      throw new Error('No open pages/tabs found in browser. Please open a tab.');
    }

    let selected = null;
    if (this.targetTabIndex !== null && pages[this.targetTabIndex]) {
      selected = pages[this.targetTabIndex];
    } else if (this.targetUrlPattern) {
      selected = pages.find((p) => p.url().toLowerCase().includes(this.targetUrlPattern.toLowerCase()));
    }

    if (!selected) {
      // 1. Prioritize actively visible/focused tab in browser window
      for (const p of pages) {
        try {
          const u = p.url().toLowerCase();
          if (
            u.startsWith('devtools://') ||
            u.startsWith('chrome://') ||
            u.startsWith('chrome-extension://') ||
            u.includes('search?') ||
            u.includes('/search')
          ) {
            continue;
          }
          const isVisible = await p.evaluate(() => document.visibilityState === 'visible');
          if (isVisible) {
            selected = p;
            break;
          }
        } catch (e) {}
      }
    }

    if (!selected) {
      // 2. Normal pages fallback
      const normalPages = pages.filter((p) => {
        const u = p.url().toLowerCase();
        return (
          !u.startsWith('devtools://') &&
          !u.startsWith('chrome://') &&
          !u.startsWith('chrome-extension://') &&
          !u.includes('search?') &&
          !u.includes('/search') &&
          u !== 'about:blank'
        );
      });
      selected = normalPages[normalPages.length - 1] || pages[0];
    }

    if (selected) {
      await this.ensureFullViewport(selected);
    }
    return selected;
  }

  async getActivePage() {
    return await this.getPage();
  }

  async resetViewport() {
    const pages = await this.browser.pages();
    const results = [];
    for (const page of pages) {
      if (page.url().startsWith('chrome://') || page.url().startsWith('chrome-extension://')) continue;
      try {
        await this.ensureFullViewport(page);
        const dims = await page.evaluate(() => ({
          width: window.innerWidth,
          height: window.innerHeight,
          devicePixelRatio: window.devicePixelRatio,
        }));
        results.push({ url: page.url(), status: 'restored_full_window', dimensions: dims });
      } catch (err) {
        results.push({ url: page.url(), status: 'error', message: err.message });
      }
    }
    return results;
  }

  async goto(url) {
    const page = await this.getPage();
    let targetUrl = (url || '').trim();
    if (!targetUrl.startsWith('http://') && !targetUrl.startsWith('https://')) {
      targetUrl = 'https://' + targetUrl;
    }
    await page.goto(targetUrl, { waitUntil: 'networkidle2', timeout: 45000 });
    return {
      success: true,
      url: page.url(),
      title: await page.title(),
    };
  }

  async screenshot(targetPath = null) {
    const page = await this.getPage();
    let filePath = targetPath ? targetPath.trim() : null;
    if (!filePath) {
      const ts = new Date().toISOString().replace(/[:.]/g, '-');
      const picDir = path.join(process.env.HOME || '/tmp', 'Pictures');
      if (fs.existsSync(picDir)) {
        filePath = path.join(picDir, `screenshot_${ts}.png`);
      } else {
        filePath = `/tmp/screenshot_${ts}.png`;
      }
    }
    filePath = path.resolve(filePath);
    const parentDir = path.dirname(filePath);
    if (!fs.existsSync(parentDir)) {
      fs.mkdirSync(parentDir, { recursive: true });
    }
    await page.screenshot({ path: filePath, fullPage: false, captureBeyondViewport: false });
    await this.ensureFullViewport(page);
    return {
      success: true,
      path: filePath,
      title: await page.title(),
      url: page.url(),
    };
  }

  async scroll(targetOrDirection = 'down') {
    const page = await this.getPage();
    const result = await page.evaluate((target) => {
      const t = (target || 'down').toLowerCase().trim();
      if (t === 'down') {
        window.scrollBy({ top: 600, behavior: 'smooth' });
        return { success: true, scrolled: 'down', scrollY: window.scrollY };
      }
      if (t === 'up') {
        window.scrollBy({ top: -600, behavior: 'smooth' });
        return { success: true, scrolled: 'up', scrollY: window.scrollY };
      }
      if (t === 'top') {
        window.scrollTo({ top: 0, behavior: 'smooth' });
        return { success: true, scrolled: 'top', scrollY: 0 };
      }
      if (t === 'bottom') {
        window.scrollTo({ top: document.body.scrollHeight, behavior: 'smooth' });
        return { success: true, scrolled: 'bottom', scrollY: window.scrollY };
      }

      // Find element to scroll into view
      let el = null;
      try {
        el = document.querySelector(target);
      } catch (e) {}

      if (!el) {
        el = Array.from(
          document.querySelectorAll('button, a, input, textarea, select, [data-marker], [role="button"], h1, h2, h3, div')
        ).find((e) => {
          const txt = (e.innerText || '').toLowerCase().trim();
          const marker = (e.getAttribute('data-marker') || '').toLowerCase().trim();
          return txt === t || marker === t || txt.includes(t) || marker.includes(t);
        });
      }

      if (el) {
        el.scrollIntoView({ behavior: 'smooth', block: 'center', inline: 'center' });
        return { success: true, scrolled: 'element', target };
      }
      return { success: false, error: `Element matching "${target}" not found to scroll to` };
    }, targetOrDirection);

    if (!result.success) throw new Error(result.error);
    await new Promise((r) => setTimeout(r, 600));
    return result;
  }

  async checkErrors() {
    const page = await this.getPage();
    return await page.evaluate(() => {
      const errorElements = Array.from(
        document.querySelectorAll(
          '[data-marker*="error"], .error, [class*="error-"], [class*="Error"], [role="alert"], .alert-danger, .has-error'
        )
      )
        .filter((el) => {
          const text = (el.innerText || '').trim();
          const style = window.getComputedStyle(el);
          return (
            text.length > 0 &&
            style.display !== 'none' &&
            style.visibility !== 'hidden' &&
            el.offsetHeight > 0
          );
        })
        .map((el) => el.innerText.trim());

      const uniqueErrors = Array.from(new Set(errorElements));
      return {
        count: uniqueErrors.length,
        errors: uniqueErrors,
      };
    });
  }

  async getSemanticMap() {
    const page = await this.getPage();
    return await page.evaluate(() => {
      const actionable = Array.from(
        document.querySelectorAll(
          'a, button, input, textarea, select, [role="button"], [role="tab"], [role="option"], [role="radio"], [role="checkbox"], [data-marker], [debug-id], vertical-form-field label'
        )
      )
        .filter((el) => {
          const rect = el.getBoundingClientRect();
          return rect.width > 0 && rect.height > 0;
        })
        .map((el) => {
          const text = (el.innerText || el.textContent || '').trim().split('\n')[0];
          return {
            tagName: el.tagName.toLowerCase(),
            text: text.slice(0, 100),
            placeholder: el.placeholder || null,
            ariaLabel: el.getAttribute('aria-label') || null,
            debugId: el.getAttribute('debug-id') || null,
            dataMarker: el.getAttribute('data-marker') || null,
            type: el.type || null,
            disabled: !!el.disabled,
          };
        })
        .filter((el) => el.text || el.placeholder || el.ariaLabel || el.debugId || el.type === 'file');

      return {
        url: window.location.href,
        title: document.title,
        actionableCount: actionable.length,
        actionable: actionable.slice(0, 150),
      };
    });
  }

  async click(target) {
    const page = await this.getPage();
    const result = await page.evaluate((target) => {
      const targetLower = target.toLowerCase().trim();

      let match = null;
      try {
        match = document.querySelector(target);
      } catch (e) {}

      if (!match) {
        const elements = Array.from(
          document.querySelectorAll(
            'button, a, input[type=submit], input[type=button], input[type=radio], input[type=checkbox], [role="button"], [role="tab"], [role="option"], [role="radio"], [role="checkbox"], [data-marker], [debug-id], vertical-form-field label, label, li'
          )
        );

        function matches(el) {
          const text = (el.innerText || el.textContent || '').trim().toLowerCase();
          const aria = (el.getAttribute('aria-label') || '').trim().toLowerCase();
          const debugId = (el.getAttribute('debug-id') || '').trim().toLowerCase();
          const marker = (el.getAttribute('data-marker') || '').trim().toLowerCase();
          const placeholder = (el.placeholder || '').trim().toLowerCase();
          const val = (el.value || '').trim().toLowerCase();

          return (
            text === targetLower ||
            marker === targetLower ||
            aria === targetLower ||
            debugId === targetLower ||
            val === targetLower ||
            placeholder === targetLower ||
            marker.includes(targetLower) ||
            text.includes(targetLower) ||
            aria.includes(targetLower) ||
            debugId.includes(targetLower)
          );
        }

        match = elements.find(matches);
      }

      if (!match) return { success: false, error: `Element matching "${target}" not found` };

      match.scrollIntoView({ behavior: 'smooth', block: 'center', inline: 'center' });

      if (match.tagName === 'INPUT' && (match.type === 'radio' || match.type === 'checkbox')) {
        match.checked = true;
        match.dispatchEvent(new Event('change', { bubbles: true }));
        match.click();
        return { success: true, matchedTag: match.tagName, type: match.type, text: match.value || target };
      }

      const clickable = match.closest('button, a, [role="button"], label, li') || match;
      clickable.click();

      const innerInput = clickable.querySelector('input[type=radio], input[type=checkbox]');
      if (innerInput) {
        innerInput.checked = true;
        innerInput.dispatchEvent(new Event('change', { bubbles: true }));
      }

      return {
        success: true,
        matchedTag: clickable.tagName,
        text: (clickable.innerText || clickable.textContent || '').trim().slice(0, 50),
        dataMarker: clickable.getAttribute('data-marker'),
      };
    }, target);

    if (!result.success) throw new Error(result.error);
    await new Promise((r) => setTimeout(r, 400));
    return result;
  }

  // STEP-FILL IS THE DEFAULT INPUT WAY
  async input(target, value, options = {}) {
    const page = await this.getPage();
    const delay = options.delay !== undefined ? parseInt(options.delay, 10) : 30; // default typing delay in ms
    const stringValue = String(value ?? '');

    // Step 1: Find target input/textarea handle
    const inputHandle = await page.evaluateHandle((targetStr) => {
      const targetLower = targetStr.toLowerCase().trim();

      // 1. Direct input by debugId, data-marker, placeholder, name, id
      const direct = Array.from(document.querySelectorAll('input, textarea')).find((el) => {
        return (
          (el.getAttribute('debug-id') || '').toLowerCase() === targetLower ||
          (el.getAttribute('data-marker') || '').toLowerCase() === targetLower ||
          (el.getAttribute('data-marker') || '').toLowerCase().includes(targetLower) ||
          (el.placeholder || '').toLowerCase().includes(targetLower) ||
          (el.name || '').toLowerCase() === targetLower ||
          (el.id || '').toLowerCase() === targetLower
        );
      });
      if (direct) return direct;

      // 2. By associated label or container
      const labels = Array.from(document.querySelectorAll('label, .label, vertical-form-field, [role=heading], div'));
      for (const l of labels) {
        const txt = (l.innerText || '').toLowerCase();
        if (txt.includes(targetLower)) {
          const container = l.closest('vertical-form-field, form, div, fieldset');
          if (container) {
            const inp = container.querySelector('input:not([type=file]):not([type=submit]):not([type=button]), textarea');
            if (inp) return inp;
          }
        }
      }

      // 3. Fallback: try selector directly
      try {
        const bySel = document.querySelector(targetStr);
        if (bySel && (bySel.tagName === 'INPUT' || bySel.tagName === 'TEXTAREA' || bySel.isContentEditable)) {
          return bySel;
        }
      } catch (e) {}

      return null;
    }, target);

    const el = inputHandle.asElement();
    if (!el) {
      throw new Error(`Input for "${target}" not found`);
    }

    // Scroll into view & focus
    await page.evaluate((elem) => {
      elem.scrollIntoView({ behavior: 'smooth', block: 'center', inline: 'center' });
    }, el);
    await new Promise((r) => setTimeout(r, 200));

    await el.focus();

    // Clear existing text
    await page.evaluate((elem) => {
      if (elem.value) {
        elem.value = '';
        elem.dispatchEvent(new Event('input', { bubbles: true }));
      }
    }, el);

    // Select all & backspace for clean synthetic state
    await page.keyboard.down('Control');
    await page.keyboard.press('KeyA');
    await page.keyboard.up('Control');
    await page.keyboard.press('Backspace');

    // Step-fill: symbol by symbol with delay
    for (let i = 0; i < stringValue.length; i++) {
      const char = stringValue[i];
      if (char === '\n') {
        await page.keyboard.press('Enter');
      } else if (char === '\t') {
        await page.keyboard.press('Tab');
      } else {
        await page.keyboard.type(char, { delay });
      }
    }

    // Dispatch final synthetic events
    const info = await page.evaluate((elem, expectedVal) => {
      elem.dispatchEvent(new Event('input', { bubbles: true }));
      elem.dispatchEvent(new Event('change', { bubbles: true }));
      elem.dispatchEvent(new Event('blur', { bubbles: true }));

      // Fallback: If value is still empty (e.g. strict controlled input ignoring synthetic typing), set via descriptor
      if (!elem.value && expectedVal) {
        const valueSetter = Object.getOwnPropertyDescriptor(elem, 'value')
          ? Object.getOwnPropertyDescriptor(elem, 'value').set
          : Object.getOwnPropertyDescriptor(Object.getPrototypeOf(elem), 'value').set;
        if (valueSetter) {
          valueSetter.call(elem, expectedVal);
          elem.dispatchEvent(new Event('input', { bubbles: true }));
          elem.dispatchEvent(new Event('change', { bubbles: true }));
        }
      }

      return {
        tagName: elem.tagName,
        value: elem.value,
        name: elem.name || elem.id || elem.getAttribute('data-marker'),
      };
    }, el, stringValue);

    return {
      success: true,
      stepFilled: true,
      targetTag: info.tagName,
      name: info.name,
      value: info.value,
    };
  }

  async stepFill(target, value, options = {}) {
    return await this.input(target, value, options);
  }

  async selectDropdownOption(target, optionTextOrValue) {
    const page = await this.getPage();
    const result = await page.evaluate((targetStr, optStr) => {
      const targetLower = targetStr.toLowerCase().trim();
      const optLower = (optStr || '').toLowerCase().trim();

      // 1. Check if target is a <select> element
      let selectEl = null;
      try {
        selectEl = document.querySelector(targetStr);
      } catch (e) {}

      if (!selectEl) {
        selectEl = Array.from(document.querySelectorAll('select')).find((s) => {
          return (
            (s.name || '').toLowerCase() === targetLower ||
            (s.id || '').toLowerCase() === targetLower ||
            (s.getAttribute('data-marker') || '').toLowerCase().includes(targetLower)
          );
        });
      }

      if (selectEl && selectEl.tagName === 'SELECT') {
        const options = Array.from(selectEl.options);
        const match = options.find(
          (o) => (o.value || '').toLowerCase() === optLower || (o.text || '').toLowerCase().includes(optLower)
        );
        if (match) {
          selectEl.value = match.value;
          selectEl.dispatchEvent(new Event('change', { bubbles: true }));
          return { success: true, type: 'select', selected: match.text, value: match.value };
        }
      }

      // 2. Custom dropdown: click trigger to open
      const trigger =
        document.querySelector(targetStr) ||
        Array.from(document.querySelectorAll('[role="combobox"], [data-marker], div, button')).find(
          (el) =>
            (el.innerText || '').toLowerCase().includes(targetLower) ||
            (el.getAttribute('data-marker') || '').toLowerCase().includes(targetLower)
        );

      if (trigger) {
        trigger.click();
        return { success: true, type: 'opened_dropdown', waitingForOption: optStr };
      }

      return { success: false, error: `Could not find select or dropdown for "${targetStr}"` };
    }, target, optionTextOrValue);

    if (!result.success) throw new Error(result.error);

    if (result.waitingForOption) {
      await new Promise((r) => setTimeout(r, 600));
      const clicked = await page.evaluate((optStr) => {
        const optLower = optStr.toLowerCase().trim();
        const options = Array.from(
          document.querySelectorAll('li, [role="option"], [data-marker*="option"], div, span')
        ).filter((el) => {
          const t = (el.innerText || '').toLowerCase().trim();
          return t === optLower || t.includes(optLower);
        });
        if (options.length > 0) {
          const target = options[options.length - 1];
          target.click();
          return { success: true, text: target.innerText.trim() };
        }
        return { success: false, error: `Option "${optStr}" not found in dropdown` };
      }, optionTextOrValue);

      if (!clicked.success) throw new Error(clicked.error);
      return clicked;
    }

    return result;
  }

  async upload(filePaths, targetContainer = null) {
    const page = await this.getPage();
    const resolvedPaths = [];

    // Flatten in case paths contain comma-separated lists or directories
    const rawPaths = [];
    for (const p of filePaths) {
      if (typeof p === 'string' && p.includes(',')) {
        rawPaths.push(...p.split(',').map((s) => s.trim()).filter(Boolean));
      } else {
        rawPaths.push(p);
      }
    }

    for (const p of rawPaths) {
      const resolved = path.resolve(p);
      if (!fs.existsSync(resolved)) {
        throw new Error(`File or directory not found: ${p}`);
      }
      const stat = fs.statSync(resolved);
      if (stat.isDirectory()) {
        const files = fs
          .readdirSync(resolved)
          .filter((f) => /\.(jpe?g|png|webp|gif|svg|pdf|mp4|mov)$/i.test(f))
          .map((f) => path.join(resolved, f));
        resolvedPaths.push(...files);
      } else {
        resolvedPaths.push(resolved);
      }
    }

    if (resolvedPaths.length === 0) {
      throw new Error(`No files found to upload in: ${filePaths.join(', ')}`);
    }

    const inputs = await page.$$('input[type=file]');
    if (inputs.length === 0) throw new Error('No input[type=file] found on the active page');

    let chosenInput = inputs[inputs.length - 1];

    if (targetContainer) {
      const containerInput = await page.evaluateHandle((containerTarget) => {
        const containers = Array.from(
          document.querySelectorAll('vertical-form-field, material-drawer, [role=dialog], .modal, [data-marker]')
        );
        const match = containers.find((c) => (c.innerText || '').toLowerCase().includes(containerTarget.toLowerCase()));
        return match ? match.querySelector('input[type=file]') : null;
      }, targetContainer);

      if (containerInput && containerInput.asElement()) {
        chosenInput = containerInput.asElement();
      }
    }

    if (resolvedPaths.length > 1) {
      await page.evaluate((el) => {
        el.multiple = true;
      }, chosenInput);
    }

    await chosenInput.uploadFile(...resolvedPaths);
    await page.evaluate((el) => {
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
    }, chosenInput);

    return { success: true, count: resolvedPaths.length, files: resolvedPaths };
  }

  async waitFor(selectorOrText, timeoutMs = 30000) {
    const page = await this.getPage();
    await page.waitForFunction(
      (query) => {
        const el = document.querySelector(query);
        if (el) return true;
        return document.body && document.body.innerText.includes(query);
      },
      { timeout: timeoutMs },
      selectorOrText
    );
    return { success: true, matched: selectorOrText };
  }

  async getText(selector = null) {
    const page = await this.getPage();
    return await page.evaluate((sel) => {
      if (!sel) return document.body.innerText;
      const el = document.querySelector(sel);
      return el ? el.innerText : null;
    }, selector);
  }

  async eval(code) {
    const page = await this.getPage();
    return await page.evaluate((codeString) => {
      return new Function(codeString)();
    }, code);
  }

  async waitForQuiz(previousQuestion = '') {
    const inPageExtractOrWait = (prevQ) => {
      return new Promise((resolve) => {
        function extractQuizState() {
          const bodyText = document.body ? document.body.innerText : '';
          if (
            window.location.href.includes('/courses') ||
            window.location.pathname.startsWith('/courses') ||
            bodyText.includes('Waiting for players') ||
            bodyText.includes('Join on this device') ||
            bodyText.includes('Join at:')
          ) {
            return null;
          }

          function getDesc(el, idx) {
            const rawVal = el.value && el.value !== 'on' ? el.value : '';
            let t = (el.innerText || rawVal || el.getAttribute('aria-label') || '').trim();
            if (!t && el.parentElement) {
              t = (el.parentElement.innerText || '').trim();
            }
            if (!t) {
              const img = el.querySelector('img');
              if (img) {
                t = img.getAttribute('alt') || img.getAttribute('title') || `Image ${idx + 1}`;
              }
            }
            return t || `Option ${idx + 1}`;
          }

          const imageCards = Array.from(
            document.querySelectorAll('.image_option, [class*="image_option"]')
          ).filter((el) => {
            const style = window.getComputedStyle(el);
            return (
              style.display !== 'none' &&
              style.visibility !== 'hidden' &&
              (el.offsetWidth > 0 || el.querySelector('img') !== null)
            );
          });

          let candidates = [];
          if (imageCards.length >= 2) {
            candidates = imageCards;
          } else {
            candidates = Array.from(
              document.querySelectorAll(
                '.answer_row, label[for*="PossibleAnswer"], input[type="radio"], input[type="checkbox"], [class*="answer_row"], button[role="radio"], [role="radio"], [role="checkbox"]'
              )
            ).filter((el) => {
              const text = (el.innerText || el.value || el.getAttribute('aria-label') || '').trim();
              const style = window.getComputedStyle(el);
              return (
                el.offsetWidth > 0 &&
                el.offsetHeight > 0 &&
                style.display !== 'none' &&
                style.visibility !== 'hidden' &&
                !text.toLowerCase().includes('take later') &&
                !text.toLowerCase().includes('enter your name')
              );
            });
          }

          const textInputs = Array.from(
            document.querySelectorAll('input[type="text"], input:not([type]), textarea')
          ).filter((el) => {
            if (
              el.id === 'TakerName' ||
              el.name === 'TakerName' ||
              (el.placeholder || '').toLowerCase().includes('name')
            ) {
              return false;
            }
            const style = window.getComputedStyle(el);
            return (
              el.offsetWidth > 0 &&
              el.offsetHeight > 0 &&
              style.display !== 'none' &&
              style.visibility !== 'hidden'
            );
          });

          const isChoice = candidates.length >= 2;
          const isOpenEnded = !isChoice && textInputs.length > 0;

          if (!isChoice && !isOpenEnded) {
            return null;
          }

          let qText = '';
          const qEl = document.querySelector('.question_text, [class*="question_text"], .question, [class*="question"]');
          if (qEl) {
            qText = (qEl.innerText || '').trim();
          }
          if (!qText) {
            const headings = Array.from(document.querySelectorAll('h1, h2, h3, h4, .title'));
            for (const h of headings) {
              const ht = (h.innerText || '').trim();
              if (ht && !ht.includes('Quiz') && !ht.includes('Question')) {
                qText = ht;
                break;
              }
            }
          }

          const options = candidates.map((el, idx) => ({
            index: idx,
            text: getDesc(el, idx),
          }));

          return {
            status: 'ready',
            type: isChoice ? 'choice' : 'open_ended',
            question: qText,
            options: options,
            url: window.location.href,
          };
        }

        const initialState = extractQuizState();
        if (initialState && initialState.question !== prevQ) {
          resolve(initialState);
          return;
        }

        const observer = new MutationObserver(() => {
          const state = extractQuizState();
          if (state && state.question !== prevQ) {
            cleanup();
            resolve(state);
          }
        });
        observer.observe(document.body, { childList: true, subtree: true });

        const timer = setInterval(() => {
          const state = extractQuizState();
          if (state && state.question !== prevQ) {
            cleanup();
            resolve(state);
          }
        }, 400);

        function cleanup() {
          observer.disconnect();
          clearInterval(timer);
        }
      });
    };

    while (true) {
      const quizPage = await this.getActivePage();
      if (quizPage) {
        try {
          const state = await Promise.race([
            quizPage.evaluate(inPageExtractOrWait, previousQuestion),
            new Promise((r) => setTimeout(() => r(null), 3000)),
          ]);
          if (state && state.status === 'ready') {
            return state;
          }
        } catch (e) {}
      }
      await new Promise((r) => setTimeout(r, 1000));
    }
  }

  async selectOption(target) {
    const page = await this.getPage();
    return await page.evaluate((target) => {
      let candidates = Array.from(
        document.querySelectorAll(
          '.image_option, [class*="image_option"], .answer_row, [class*="answer_row"], label[for*="PossibleAnswer"], input[type="radio"], input[type="checkbox"], button[role="radio"], [role="radio"]'
        )
      );

      const imgOpts = candidates.filter(
        (el) => el.classList && (el.classList.contains('image_option') || el.className.includes('image_option'))
      );
      if (imgOpts.length >= 2) {
        candidates = imgOpts;
      }

      function getDesc(el, idx) {
        let t = (el.innerText || el.value || el.getAttribute('aria-label') || '').trim();
        if (!t) {
          const img = el.querySelector('img');
          if (img) {
            t = img.getAttribute('alt') || img.getAttribute('title') || `Image ${idx + 1}`;
          }
        }
        return (t || `Option ${idx + 1}`).toLowerCase().trim();
      }

      const targetStr = String(target).toLowerCase().trim();
      let match = null;
      let matchedIndex = -1;

      // 1. Direct text / descriptor match
      candidates.forEach((el, idx) => {
        if (match) return;
        const desc = getDesc(el, idx);
        if (desc === targetStr || desc.startsWith(targetStr)) {
          match = el;
          matchedIndex = idx;
        }
      });

      // 2. Substring match
      if (!match) {
        candidates.forEach((el, idx) => {
          if (match) return;
          const desc = getDesc(el, idx);
          if (desc.includes(targetStr) || targetStr.includes(desc)) {
            match = el;
            matchedIndex = idx;
          }
        });
      }

      // 3. Numeric match
      if (!match) {
        const numMatch = targetStr.match(/(?:image|option)?\s*(\d+)/i);
        if (numMatch) {
          const num = parseInt(numMatch[1], 10);
          if (num >= 1 && num <= candidates.length) {
            match = candidates[num - 1];
            matchedIndex = num - 1;
          } else if (num >= 0 && num < candidates.length) {
            match = candidates[num];
            matchedIndex = num;
          }
        }
      }

      if (!match && candidates.length > 0) {
        match = candidates[0];
        matchedIndex = 0;
      }

      if (!match) {
        throw new Error(`Option matching '${target}' not found.`);
      }

      match.scrollIntoView({ block: 'center', inline: 'center' });

      const radio =
        match.querySelector('input[type="radio"], input[type="checkbox"]') || (match.tagName === 'INPUT' ? match : null);
      const clickable = match.querySelector('img, label, .checkbox, .image') || match;

      clickable.click();
      if (radio) {
        radio.checked = true;
        radio.dispatchEvent(new Event('change', { bubbles: true }));
        radio.dispatchEvent(new Event('click', { bubbles: true }));
      }

      const labelText = getDesc(match, matchedIndex);
      return {
        success: true,
        selectedText: labelText,
      };
    }, target);
  }

  formatTabs(text) {
    if (!text) return text;
    return text
      .split('\n')
      .map((line) => {
        let spaces = 0;
        while (spaces < line.length && line[spaces] === ' ') {
          spaces++;
        }
        if (spaces === 0) return line;
        const tabs = Math.floor(spaces / 4);
        const remSpaces = spaces % 4;
        return '\t'.repeat(tabs) + (remSpaces >= 2 ? '\t' : '') + line.slice(spaces);
      })
      .join('\n');
  }

  async typeAnswer(text, delayMs = 200) {
    const page = await this.getPage();
    text = this.formatTabs(text);

    const hasMonaco = await page.evaluate(() => {
      return typeof window.monaco !== 'undefined' && window.monaco?.editor?.getEditors()?.length > 0;
    });

    if (hasMonaco) {
      await page.evaluate(() => {
        const editors = window.monaco.editor.getEditors();
        const ed = editors[0];
        ed.updateOptions({
          autoClosingBrackets: 'never',
          autoClosingQuotes: 'never',
          autoSurround: 'never',
          autoIndent: 'none',
          quickSuggestions: false,
          suggestOnTriggerCharacters: false,
          acceptSuggestionOnEnter: 'off',
          tabCompletion: 'off',
          wordBasedSuggestions: 'off',
        });
        ed.focus();
      });

      await page.keyboard.down('Control');
      await page.keyboard.press('KeyA');
      await page.keyboard.up('Control');
      await page.keyboard.press('Backspace');

      for (let i = 0; i < text.length; i++) {
        const char = text[i];
        if (char === '\n') {
          await page.keyboard.press('Enter');
        } else if (char === '\t') {
          await page.keyboard.press('Tab');
        } else {
          await page.keyboard.type(char);
        }
        if (delayMs > 0) {
          const jitter = Math.floor(delayMs * 0.85 + Math.random() * (delayMs * 0.3));
          await new Promise((r) => setTimeout(r, jitter));
        }
      }

      return {
        success: true,
        target: 'monaco',
        typedLength: text.length,
        speedMs: delayMs,
      };
    }

    const inputHandle = await page.evaluateHandle(() => {
      const inputs = Array.from(
        document.querySelectorAll('input[type="text"], input:not([type]), textarea')
      ).filter((el) => {
        if (
          el.id === 'TakerName' ||
          el.name === 'TakerName' ||
          (el.placeholder || '').toLowerCase().includes('name')
        ) {
          return false;
        }
        const style = window.getComputedStyle(el);
        return el.offsetWidth > 0 && el.offsetHeight > 0 && style.display !== 'none';
      });
      return inputs[0] || null;
    });

    const el = inputHandle.asElement();
    if (!el) {
      throw new Error('No open-ended input or textarea found on current page.');
    }

    await el.focus();
    await page.evaluate((elem) => {
      elem.value = '';
    }, el);
    for (let i = 0; i < text.length; i++) {
      const char = text[i];
      if (char === '\t') {
        await page.keyboard.press('Tab');
      } else {
        await el.type(char);
      }
      if (delayMs > 0) {
        const jitter = Math.floor(delayMs * 0.85 + Math.random() * (delayMs * 0.3));
        await new Promise((r) => setTimeout(r, jitter));
      }
    }
    await page.evaluate((elem) => {
      elem.dispatchEvent(new Event('input', { bubbles: true }));
      elem.dispatchEvent(new Event('change', { bubbles: true }));
    }, el);

    return {
      success: true,
      typedText: text,
      speedMs: delayMs,
    };
  }

  async close() {
    if (this.browser) await this.browser.disconnect();
  }
}

// CLI Interface
(async () => {
  const args = process.argv.slice(2);
  let urlPattern = null;
  let tabIndex = null;

  const cleanArgs = [];
  for (const a of args) {
    if (a.startsWith('--url=')) urlPattern = a.split('=')[1];
    else if (a.startsWith('--tab=')) tabIndex = a.split('=')[1];
    else cleanArgs.push(a);
  }

  const [rawCommand, arg1, ...rest] = cleanArgs;
  const command = (rawCommand || '').toLowerCase().replace(/_/g, '-');
  const agent = new BrowserAgent({ url: urlPattern, tab: tabIndex });
  await agent.init();

  try {
    switch (command) {
      case 'tabs':
        console.log(JSON.stringify(await agent.listTabs(), null, 2));
        break;
      case 'map':
        console.log(JSON.stringify(await agent.getSemanticMap(), null, 2));
        break;
      case 'goto':
      case 'navigate':
        console.log(JSON.stringify(await agent.goto(arg1), null, 2));
        break;
      case 'screenshot':
        console.log(JSON.stringify(await agent.screenshot(arg1 || null), null, 2));
        break;
      case 'scroll':
        console.log(JSON.stringify(await agent.scroll(arg1 || 'down'), null, 2));
        break;
      case 'click':
        console.log(JSON.stringify(await agent.click(arg1)));
        break;
      case 'input':
      case 'step-fill':
      case 'stepfill': {
        const value = rest.join(' ');
        console.log(JSON.stringify(await agent.input(arg1, value)));
        break;
      }
      case 'select-option':
      case 'select-dropdown': {
        const opt = rest.join(' ');
        console.log(JSON.stringify(await agent.selectDropdownOption(arg1, opt), null, 2));
        break;
      }
      case 'upload':
        console.log(JSON.stringify(await agent.upload([arg1, ...rest])));
        break;
      case 'errors':
      case 'check-errors':
        console.log(JSON.stringify(await agent.checkErrors(), null, 2));
        break;
      case 'reset-viewport':
      case 'fix-viewport':
        console.log(JSON.stringify(await agent.resetViewport(), null, 2));
        break;
      case 'wait':
        console.log(JSON.stringify(await agent.waitFor(arg1, rest[0] ? parseInt(rest[0], 10) : 30000)));
        break;
      case 'text':
        console.log(await agent.getText(arg1 || null));
        break;
      case 'eval':
        console.log(JSON.stringify(await agent.eval(arg1 || rest.join(' ')), null, 2));
        break;
      case 'wait-quiz':
        console.log(JSON.stringify(await agent.waitForQuiz(arg1 || ''), null, 2));
        break;
      case 'select':
        console.log(JSON.stringify(await agent.selectOption(arg1), null, 2));
        break;
      case 'type': {
        const delay = rest[0] ? parseInt(rest[0], 10) : 200;
        console.log(JSON.stringify(await agent.typeAnswer(arg1, delay), null, 2));
        break;
      }
      case 'type-file': {
        const content = fs.readFileSync(arg1, 'utf8');
        const delay = rest[0] ? parseInt(rest[0], 10) : 200;
        console.log(JSON.stringify(await agent.typeAnswer(content, delay), null, 2));
        break;
      }
      default:
        console.log(
          JSON.stringify({
            error: `Unknown command: ${rawCommand}`,
            commands: [
              'tabs',
              'map',
              'goto <url>',
              'click <target>',
              'input <target> <value> (step-fill by default)',
              'step-fill <target> <value>',
              'select-option <target> <option>',
              'upload <files...|folder>',
              'screenshot [path]',
              'scroll [down|up|top|bottom|<target>]',
              'errors',
              'reset-viewport',
              'wait <query> [timeoutMs]',
              'text [selector]',
              'eval <code>',
              'wait-quiz [prev]',
              'select <target>',
              'type <text> [delayMs]',
              'type-file <file> [delayMs]',
            ],
          })
        );
    }
  } catch (err) {
    console.error(JSON.stringify({ error: err.message }));
    process.exit(1);
  } finally {
    await agent.close();
  }
})();
