const puppeteer = require('puppeteer');

class BrowserAgent {
  constructor() {
    this.browser = null;
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
        `Failed to connect to browser on 127.0.0.1:9222 (${err.message}). Ensure Yandex Browser is running with: yandex-browser --remote-debugging-port=9222 --user-data-dir=$HOME/.config/yandex-browser-debug --remote-allow-origins="*"`
      );
    }
  }

  async getActivePage() {
    const pages = await this.browser.pages();
    if (!pages || pages.length === 0) {
      throw new Error('No open pages/tabs found in browser. Please open a tab.');
    }

    // 1. Prioritize actively visible/focused tab in browser window
    for (const p of pages) {
      try {
        const u = p.url().toLowerCase();
        if (u.startsWith('devtools://') || u.startsWith('chrome://') || u.includes('search?') || u.includes('/search')) {
          continue;
        }
        const isVisible = await p.evaluate(() => document.visibilityState === 'visible');
        if (isVisible) {
          return p;
        }
      } catch (e) {}
    }

    // 2. Look for test / quiz URLs
    const testPage = pages.find((p) => {
      const u = p.url().toLowerCase();
      if (u.startsWith('devtools://') || u.startsWith('chrome://') || u.includes('search?') || u.includes('/search')) {
        return false;
      }
      return (
        u.includes('hh.ru') ||
        u.includes('uquiz.com') ||
        u.includes('/quiz') ||
        u.includes('/test') ||
        u.includes('assessment') ||
        u.includes('verifications')
      );
    });

    if (testPage) return testPage;

    // 3. Fallback to last non-devtools page
    const normalPages = pages.filter((p) => {
      const u = p.url().toLowerCase();
      return !u.startsWith('devtools://') && !u.startsWith('chrome://') && !u.includes('search?') && !u.includes('/search');
    });
    return normalPages[normalPages.length - 1] || pages[0];
  }

  async getPage() {
    return await this.getActivePage();
  }

  async waitForQuiz(previousQuestion = '') {
    const inPageExtractOrWait = (prevQ) => {
      return new Promise((resolve) => {
        function extractQuizState() {
          const bodyText = document.body ? document.body.innerText : '';
          // Ignore lobby / entry / waiting screens and course catalogs
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

          // 1. Look for choices: check image options first, then standard choice rows
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

          // Candidates must be explicit radios, checkboxes, answer rows, or image options

          // 2. Check for open-ended text input / textarea
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

          // Question prompt
          const headings = Array.from(
            document.querySelectorAll(
              '[class*="markdown"], [class*="markup"], .question_text, [data-qa*="question"], h1, h2, h3, [class*="question"], [class*="title"], legend'
            )
          )
            .map((h) => (h.innerText || '').trim())
            .filter((t) => t.length > 5 && !t.includes('Take later') && !t.includes('Завершить') && !t.includes('Всего осталось') && t.length < 1500);

          const questionText = headings[0] || document.title || 'Quiz Question';

          // Match against previous question
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

          // Deduplicate candidate options
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

      const imgOpts = candidates.filter((el) => el.classList && (el.classList.contains('image_option') || el.className.includes('image_option')));
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

      // Click radio / checkbox / image / label
      const radio = match.querySelector('input[type="radio"], input[type="checkbox"]') || (match.tagName === 'INPUT' ? match : null);
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
    return text.split('\n').map((line) => {
      let spaces = 0;
      while (spaces < line.length && line[spaces] === ' ') {
        spaces++;
      }
      if (spaces === 0) return line;
      const tabs = Math.floor(spaces / 4);
      const remSpaces = spaces % 4;
      return '\t'.repeat(tabs) + (remSpaces >= 2 ? '\t' : '') + line.slice(spaces);
    }).join('\n');
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
          wordBasedSuggestions: 'off'
        });
        ed.focus();
      });

      // Clear existing content cleanly via keyboard
      await page.keyboard.down('Control');
      await page.keyboard.press('KeyA');
      await page.keyboard.up('Control');
      await page.keyboard.press('Backspace');

      // Type character by character with delayMs delay
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
          // slight random jitter around delayMs for human realism (+-15%)
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
    await page.evaluate((elem) => { elem.value = ''; }, el);
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

(async () => {
  const [command, arg1, arg2] = process.argv.slice(2);
  const agent = new BrowserAgent();
  await agent.init();
  try {
    if (command === 'wait-quiz') {
      const res = await agent.waitForQuiz(arg1 || '');
      console.log(JSON.stringify(res, null, 2));
    } else if (command === 'select') {
      const res = await agent.selectOption(arg1);
      console.log(JSON.stringify(res, null, 2));
    } else if (command === 'type') {
      const delay = arg2 ? parseInt(arg2, 10) : 200;
      const res = await agent.typeAnswer(arg1, delay);
      console.log(JSON.stringify(res, null, 2));
    } else if (command === 'type-file') {
      const fs = require('fs');
      const content = fs.readFileSync(arg1, 'utf8');
      const delay = arg2 ? parseInt(arg2, 10) : 200;
      const res = await agent.typeAnswer(content, delay);
      console.log(JSON.stringify(res, null, 2));
    } else {
      console.log(JSON.stringify({ error: `Unknown command: ${command}` }));
    }
  } catch (err) {
    console.error(JSON.stringify({ error: err.message }));
    process.exit(1);
  } finally {
    await agent.close();
  }
})();
