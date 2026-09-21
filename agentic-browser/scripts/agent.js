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
    } catch (err) {
      throw new Error(
        `Failed to connect to browser on 127.0.0.1:9222 (${err.message}). Ensure Chromium/Yandex Browser is running with: yandex-browser --remote-debugging-port=9222 --user-data-dir=$HOME/.config/yandex-browser-debug --remote-allow-origins="*"`
      );
    }
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

    if (this.targetTabIndex !== null && pages[this.targetTabIndex]) {
      return pages[this.targetTabIndex];
    }

    if (this.targetUrlPattern) {
      const match = pages.find((p) => p.url().toLowerCase().includes(this.targetUrlPattern.toLowerCase()));
      if (match) return match;
    }

    // 1. Prioritize actively visible/focused tab in browser window
    for (const p of pages) {
      try {
        const u = p.url().toLowerCase();
        if (u.startsWith('devtools://') || u.startsWith('chrome://') || u.startsWith('chrome-extension://') || u.includes('search?') || u.includes('/search')) {
          continue;
        }
        const isVisible = await p.evaluate(() => document.visibilityState === 'visible');
        if (isVisible) {
          return p;
        }
      } catch (e) {}
    }

    // 2. Normal pages fallback
    const normalPages = pages.filter((p) => {
      const u = p.url().toLowerCase();
      return !u.startsWith('devtools://') && !u.startsWith('chrome://') && !u.startsWith('chrome-extension://') && !u.includes('search?') && !u.includes('/search') && u !== 'about:blank';
    });
    return normalPages[normalPages.length - 1] || pages[0];
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
        results.push({ url: page.url(), status: 'restored_full_window' });
      } catch (err) {
        results.push({ url: page.url(), status: 'error', message: err.message });
      }
    }
    return results;
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
      const elements = Array.from(
        document.querySelectorAll(
          'button, a, input[type=submit], input[type=button], [role="button"], [role="tab"], [role="option"], [data-marker], [debug-id], vertical-form-field label'
        )
      );

      function matches(el) {
        const text = (el.innerText || el.textContent || '').trim().toLowerCase();
        const aria = (el.getAttribute('aria-label') || '').trim().toLowerCase();
        const debugId = (el.getAttribute('debug-id') || '').trim().toLowerCase();
        const marker = (el.getAttribute('data-marker') || '').trim().toLowerCase();
        const placeholder = (el.placeholder || '').trim().toLowerCase();

        return (
          text === targetLower ||
          aria === targetLower ||
          debugId === targetLower ||
          marker === targetLower ||
          placeholder === targetLower ||
          text.includes(targetLower) ||
          aria.includes(targetLower) ||
          debugId.includes(targetLower)
        );
      }

      const match = elements.find(matches);
      if (!match) return { success: false, error: `Element matching "${target}" not found` };

      const clickable = match.closest('button, a, [role="button"]') || match;
      clickable.click();
      return { success: true, matchedTag: clickable.tagName, text: (clickable.innerText || '').slice(0, 50) };
    }, target);

    if (!result.success) throw new Error(result.error);
    return result;
  }

  async input(target, value) {
    const page = await this.getPage();
    const result = await page.evaluate((target, value) => {
      const targetLower = target.toLowerCase().trim();

      function findInput() {
        // 1. Direct input by debugId, placeholder, name, id
        const direct = Array.from(document.querySelectorAll('input, textarea')).find((el) => {
          return (
            (el.getAttribute('debug-id') || '').toLowerCase() === targetLower ||
            (el.placeholder || '').toLowerCase().includes(targetLower) ||
            (el.name || '').toLowerCase() === targetLower ||
            (el.id || '').toLowerCase() === targetLower
          );
        });
        if (direct) return direct;

        // 2. By associated label or container
        const labels = Array.from(document.querySelectorAll('label, .label, vertical-form-field, [role=heading]'));
        for (const l of labels) {
          if ((l.innerText || '').toLowerCase().includes(targetLower)) {
            const container = l.closest('vertical-form-field, form, div');
            if (container) {
              const inp = container.querySelector('input:not([type=file]):not([type=submit]), textarea');
              if (inp) return inp;
            }
          }
        }
        return null;
      }

      const inputEl = findInput();
      if (!inputEl) return { success: false, error: `Input for "${target}" not found` };

      // Set value with native property setter for Angular/React/Vue compatibility
      const valueSetter = Object.getOwnPropertyDescriptor(inputEl, 'value')
        ? Object.getOwnPropertyDescriptor(inputEl, 'value').set
        : Object.getOwnPropertyDescriptor(Object.getPrototypeOf(inputEl), 'value').set;

      if (valueSetter) {
        valueSetter.call(inputEl, value);
      } else {
        inputEl.value = value;
      }

      inputEl.dispatchEvent(new Event('input', { bubbles: true }));
      inputEl.dispatchEvent(new Event('change', { bubbles: true }));
      return { success: true, targetTag: inputEl.tagName };
    }, target, value);

    if (!result.success) throw new Error(result.error);
    return result;
  }

  async upload(filePaths, targetContainer = null) {
    const page = await this.getPage();
    const resolvedPaths = filePaths.map((p) => path.resolve(p));
    for (const p of resolvedPaths) {
      if (!fs.existsSync(p)) throw new Error(`File not found: ${p}`);
    }

    const inputs = await page.$$('input[type=file]');
    if (inputs.length === 0) throw new Error('No input[type=file] found on the active page');

    let chosenInput = inputs[inputs.length - 1];

    if (targetContainer) {
      const containerInput = await page.evaluateHandle((containerTarget) => {
        const containers = Array.from(
          document.querySelectorAll('vertical-form-field, material-drawer, [role=dialog], .modal')
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

          const headings = Array.from(
            document.querySelectorAll(
              '[class*="markdown"], [class*="markup"], .question_text, [data-qa*="question"], h1, h2, h3, [class*="question"], [class*="title"], legend'
            )
          )
            .map((h) => (h.innerText || '').trim())
            .filter(
              (t) =>
                t.length > 5 &&
                !t.includes('Take later') &&
                !t.includes('Завершить') &&
                !t.includes('Всего осталось') &&
                t.length < 1500
            );

          const questionText = headings[0] || document.title || 'Quiz Question';

          if (prevQ) {
            const qNumMatch = questionText.match(/question\s+(\d+)/i);
            const prevNumMatch = prevQ.match(/question\s+(\d+)/i);
            if (qNumMatch && prevNumMatch && qNumMatch[1] === prevNumMatch[1]) {
              return null;
            }
            if (
              questionText === prevQ ||
              questionText.includes(prevQ) ||
              prevQ.includes(questionText) ||
              window.location.href === prevQ ||
              window.location.href.endsWith(prevQ)
            ) {
              return null;
            }
          }

          if (isOpenEnded) {
            return {
              status: 'ready',
              type: 'open_ended',
              question: questionText,
              url: window.location.href,
            };
          }

          const seen = new Set();
          const uniqueCandidates = [];
          for (let i = 0; i < candidates.length; i++) {
            const c = candidates[i];
            const t = getDesc(c, i);
            if (t && !seen.has(t)) {
              seen.add(t);
              uniqueCandidates.push(c);
            }
          }

          if (uniqueCandidates.length < 2) {
            return null;
          }

          const isMulti = uniqueCandidates.some(
            (c) => c.getAttribute('role') === 'checkbox' || c.type === 'checkbox'
          );

          const options = uniqueCandidates.map((el, idx) => {
            const radio = el.querySelector('input[type="radio"], input[type="checkbox"]');
            return {
              id: idx,
              text: getDesc(el, idx),
              isSelected: el.classList.contains('selected') || (radio && radio.checked) || el.checked === true,
            };
          });

          return {
            status: 'ready',
            type: 'choice',
            question: questionText,
            isMulti,
            options,
            url: window.location.href,
          };
        }

        const initial = extractQuizState();
        if (initial) return resolve(initial);

        const observer = new MutationObserver(() => {
          const state = extractQuizState();
          if (state) {
            cleanup();
            resolve(state);
          }
        });

        observer.observe(document.body, {
          childList: true,
          subtree: true,
          attributes: true,
          characterData: true,
        });

        const timer = setInterval(() => {
          const state = extractQuizState();
          if (state) {
            cleanup();
            resolve(state);
          }
        }, 400);

        const clickHandler = () => {
          setTimeout(() => {
            const state = extractQuizState();
            if (state) {
              cleanup();
              resolve(state);
            }
          }, 300);
        };
        document.addEventListener('click', clickHandler, { capture: true });

        function cleanup() {
          observer.disconnect();
          clearInterval(timer);
          document.removeEventListener('click', clickHandler, { capture: true });
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

      // 3. Numeric / "image X" index match (e.g. "image 1" -> 0, or "2" -> 1)
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

  const [command, arg1, ...rest] = cleanArgs;
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
      case 'click':
        console.log(JSON.stringify(await agent.click(arg1)));
        break;
      case 'input':
        console.log(JSON.stringify(await agent.input(arg1, rest.join(' '))));
        break;
      case 'upload':
        console.log(JSON.stringify(await agent.upload([arg1, ...rest])));
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
        console.log(JSON.stringify(await agent.eval(arg1), null, 2));
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
            error: `Unknown command: ${command}`,
            commands: [
              'tabs',
              'map',
              'click <target>',
              'input <target> <value>',
              'upload <files...>',
              'reset-viewport',
              'wait <query>',
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
