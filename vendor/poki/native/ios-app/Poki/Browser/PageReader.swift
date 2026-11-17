/// The script Poki's browser runs in each page, in its own content world (the page's scripts cannot see
/// or change it). It lists what a person would see and use on the page, in order: links, buttons and
/// fields with a ref each, headings and text blocks without one. Clicks and typing go to an element by
/// its ref. Refs live as long as the page: after a navigation the agent reads again.
///
/// What it leaves out: hidden elements, scripts and styles, the text inside a link or button (it is the
/// element's name), private field values, and the inside of frames from other sites (named as unreadable).
enum PageReader {
    static let source = #"""
(() => {
  if (window.__pokiReader) return;
  const refs = new Map();
  const ids = new WeakMap();
  let nextRef = 1;
  const SKIP = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'HEAD', 'META', 'LINK', 'TITLE']);
  const ROLES = new Set(['button', 'link', 'checkbox', 'radio', 'switch', 'tab', 'menuitem', 'menuitemcheckbox',
    'menuitemradio', 'option', 'combobox', 'textbox', 'searchbox', 'slider', 'spinbutton', 'treeitem']);
  const HUMAN_CHECK = /challenges\.cloudflare\.com|recaptcha|hcaptcha|turnstile|arkoselabs|captcha/i;
  const squash = (text) => (text || '').replace(/\s+/g, ' ').trim();
  const cut = (text, n) => text.length > n ? text.slice(0, n - 1) + '…' : text;

  const refFor = (el) => {
    let ref = ids.get(el);
    if (!ref) { ref = 'e' + nextRef++; ids.set(el, ref); refs.set(ref, new WeakRef(el)); }
    return ref;
  };
  const element = (ref) => { const el = refs.get(ref)?.deref(); return el && el.isConnected ? el : null; };

  const fieldRole = (el) => {
    const type = (el.getAttribute('type') || 'text').toLowerCase();
    if (type === 'checkbox' || type === 'radio') return type;
    if (['button', 'submit', 'reset', 'image'].includes(type)) return 'button';
    if (type === 'search') return 'searchbox';
    if (type === 'range') return 'slider';
    return 'textbox';
  };
  const role = (el) => {
    const explicit = (el.getAttribute('role') || '').toLowerCase();
    if (ROLES.has(explicit)) return explicit;
    switch (el.tagName) {
      case 'A': return el.hasAttribute('href') ? 'link' : null;
      case 'BUTTON': case 'SUMMARY': return 'button';
      case 'SELECT': return 'combobox';
      case 'TEXTAREA': return 'textbox';
      case 'INPUT': return (el.getAttribute('type') || '').toLowerCase() === 'hidden' ? null : fieldRole(el);
      case 'LABEL': return el.control && el.control.type && ['checkbox', 'radio'].includes(el.control.type) ? el.control.type : null;
    }
    if (el.isContentEditable && el.parentElement && !el.parentElement.isContentEditable) return 'textbox';
    return null;
  };
  const privateField = (el) => {
    const type = (el.getAttribute('type') || '').toLowerCase();
    const editable = el.tagName === 'TEXTAREA' || el.tagName === 'SELECT' || el.isContentEditable ||
      el.tagName === 'INPUT' && !['checkbox', 'radio', 'button', 'submit', 'reset', 'image', 'range', 'color', 'hidden'].includes(type);
    if (!editable) return null;
    const autocomplete = (el.getAttribute('autocomplete') || '').toLowerCase().split(/\s+/);
    const clues = ['name', 'id', 'aria-label', 'placeholder', 'title'].map((attr) => el.getAttribute(attr) || '').join(' ');
    if (type === 'password' || autocomplete.some((token) => /^(current|new)-password$/.test(token)) || /passw(or)?d|passphrase|密码|密碼/i.test(clues)) return 'password';
    if (autocomplete.includes('one-time-code') || /one.?time|otp|verification.?code|security.?token|验证码|驗證碼/i.test(clues)) return 'one-time code';
    if (autocomplete.some((token) => token.startsWith('cc-')) || /card|credit|debit|cvc|cvv|csc|expir|expiry|security.?code|银行卡|銀行卡|有效期|安全码|安全碼/i.test(clues)) return 'payment card';
    if (/passport|identity|national.?id|id.?number|document|social.?security|ssn|tax.?id|证件|證件|身份证|身分證|护照|護照/i.test(clues)) return 'identity document';
    const inputmode = quieted.has(el) ? quieted.get(el) : el.getAttribute('inputmode');
    if (/^(numeric|decimal|tel)$/i.test(inputmode || '') || ['number', 'tel', 'email', 'file'].includes(type)) return 'private field';
    if (type === 'search' || el.getAttribute('role') === 'searchbox' || /\b(search|query|q|keywords?)\b|搜索|搜尋|查询|查詢/i.test(clues)) return null;
    return 'private field';
  };
  const textOf = (id, doc) => squash(doc.getElementById(id)?.innerText || doc.getElementById(id)?.textContent);
  const name = (el, privacy = privateField(el)) => {
    if (privacy) return privacy;
    const doc = el.ownerDocument;
    const labelledby = el.getAttribute('aria-labelledby');
    if (labelledby) { const t = squash(labelledby.split(/\s+/).map((id) => textOf(id, doc)).join(' ')); if (t) return t; }
    const aria = squash(el.getAttribute('aria-label'));
    if (aria) return aria;
    if (el.labels && el.labels.length) { const t = squash([...el.labels].map((l) => l.innerText).join(' ')); if (t) return t; }
    if (el.tagName === 'INPUT' && ['button', 'submit', 'reset'].includes(el.type)) return squash(el.value);
    const inner = squash(el.innerText);
    if (inner) return inner;
    const img = el.querySelector && el.querySelector('img[alt]');
    return squash(el.getAttribute('placeholder') || el.getAttribute('title') || (img && img.alt) || el.getAttribute('name'));
  };
  const href = (el) => {
    try { const url = new URL(el.href, location.href); return url.origin === location.origin ? url.pathname + url.search : url.href; } catch (_) { return ''; }
  };

  // One line per thing on the page, in document order. Blocks collect the text of their inline content.
  function collect() {
    const lines = [];
    const frames = [];
    let interactive = 0;
    const styleOf = (el) => el.ownerDocument.defaultView.getComputedStyle(el);
    // Inside a link or button: its text is already its name, so nothing there becomes a text line.
    const inItem = { parts: [] };
    const visit = (node, block) => {
      for (let child = node.firstChild; child; child = child.nextSibling) {
        if (child.nodeType === 3) { if (block && block !== inItem) block.parts.push(child.data); continue; }
        if (child.nodeType !== 1) continue;
        element1(child, block);
      }
    };
    const element1 = (el, block) => {
      if (SKIP.has(el.tagName.toUpperCase())) return;
      const s = styleOf(el);
      if (s.display === 'none' || s.visibility === 'hidden' || s.visibility === 'collapse') return;
      const r = el.getBoundingClientRect();
      if (r.width * r.height === 0 && (s.overflow === 'hidden' || s.clipPath !== 'none')) return;
      if (Number(s.opacity) === 0 && !role(el)) return;
      if (el.tagName === 'IFRAME' || el.tagName === 'FRAME') {
        let doc = null;
        try { doc = el.contentDocument; } catch (_) { doc = null; }
        const src = el.src || '';
        if (HUMAN_CHECK.test(src)) frames.push(src);
        if (doc && doc.body) visit(doc.body, { parts: [] });
        else if (src && r.width * r.height > 400) lines.push({ kind: 'frame', node: el, text: 'frame (another site, cannot be read) ' + cut(src, 80) });
        return;
      }
      const elRole = role(el);
      if (elRole) {
        interactive++;
        const privacy = privateField(el);
        const item = { kind: 'item', node: el, ref: refFor(el), role: elRole, name: cut(name(el, privacy), 120) };
        if (privacy) {
          item.value = (el.isContentEditable ? el.textContent : el.value) ? '(filled)' : '(empty)';
          lines.push(item);
          return;
        }
        if (el.tagName === 'A' && el.hasAttribute('href')) item.href = cut(href(el), 100);
        if (el.tagName === 'SELECT') {
          item.value = squash(el.selectedOptions[0]?.text);
          item.options = [...el.options].slice(0, 12).map((o) => squash(o.text)).filter(Boolean);
        } else if ('value' in el && elRole !== 'button' && el.type !== 'checkbox' && el.type !== 'radio') {
          item.value = cut(String(el.value || ''), 80);
        }
        const control = el.tagName === 'LABEL' ? el.control : el;
        if (control && typeof control.checked === 'boolean' && (control.type === 'checkbox' || control.type === 'radio')) item.checked = control.checked;
        if (el.getAttribute('aria-selected') === 'true') item.selected = true;
        if (el.getAttribute('aria-expanded')) item.expanded = el.getAttribute('aria-expanded') === 'true';
        if (el.disabled || el.getAttribute('aria-disabled') === 'true') item.disabled = true;
        if (el === el.ownerDocument.activeElement && elRole !== 'link' && elRole !== 'button') item.focused = true;
        lines.push(item);
        // A link or button's own text is its name; a field's text is its value. Items inside still count.
        visit(el.shadowRoot || el, inItem);
        if (el.shadowRoot) visit(el, inItem);
        return;
      }
      if (s.display === 'contents') { visit(el.shadowRoot || el, block); return; }
      const inline = block === inItem || s.display.startsWith('inline') && !/^H[1-6]$/.test(el.tagName);
      if (inline && block) {
        visit(el.shadowRoot || el, block);
        if (el.shadowRoot) visit(el, block);
        return;
      }
      const heading = /^H([1-6])$/.exec(el.tagName) || (el.getAttribute('role') === 'heading' ? [0, el.getAttribute('aria-level') || '2'] : null);
      const own = { kind: heading ? 'heading' : 'text', node: el, level: heading ? Number(heading[1]) : 0, parts: [] };
      lines.push(own);
      visit(el.shadowRoot || el, own);
      if (el.shadowRoot) visit(el, own);
      own.text = cut(squash(own.parts.join('')), 300);
      delete own.parts;
    };
    const root = { parts: [] };
    lines.push(Object.assign(root, { kind: 'text' }));
    visit(document.body || document.documentElement, root);
    root.text = cut(squash(root.parts.join('')), 300);
    delete root.parts;
    return { lines: lines.filter((l) => l.kind !== 'text' && l.kind !== 'heading' || l.text), interactive, frames };
  }

  const format = (l) => {
    if (l.kind === 'heading') return 'heading ' + JSON.stringify(l.text);
    if (l.kind !== 'item') return l.kind === 'frame' ? l.text : 'text ' + JSON.stringify(l.text);
    let s = '[' + l.ref + '] ' + l.role + ' ' + JSON.stringify(l.name || '');
    if (l.value !== undefined && l.value !== '') s += ' value=' + JSON.stringify(l.value);
    if (l.options) s += ' options: ' + l.options.join(' | ');
    if (l.checked !== undefined) s += l.checked ? ' (checked)' : ' (not checked)';
    if (l.selected) s += ' (selected)';
    if (l.expanded !== undefined) s += l.expanded ? ' (expanded)' : ' (collapsed)';
    if (l.disabled) s += ' (disabled)';
    if (l.focused) s += ' (focused)';
    if (l.href) s += ' -> ' + l.href;
    return s;
  };

  function humanCheck(page) {
    const title = document.title || '';
    if (/just a moment|attention required|are you a robot|access denied/i.test(title)) return true;
    if (page.frames.length) return true;
    const text = squash(document.body && document.body.innerText).slice(0, 3000);
    return /verify you are human|confirm you are human|are you a robot|press and hold|security check to access/i.test(text);
  }

  // What a found line belongs to: the first line of each of the closest boxes around it (such as the
  // theater a showtime is listed under), up to 3, at most 40 lines back.
  function context(lines, i) {
    const node = lines[i].node, out = [];
    if (!node) return out;
    let start = i;
    for (let box = node.parentElement; box && box !== document.body && out.length < 3; box = box.parentElement) {
      while (start > 0 && i - start < 40 && lines[start - 1].node && box.contains(lines[start - 1].node)) start--;
      if (i - start >= 40) break;
      if (start < i && !out.includes(start)) out.push(start);
    }
    return out;
  }

  // Two kinds of box float over a page. A notice only informs and covers the page: a cookie or privacy
  // banner, or a site's "by continuing to use this site you agree to our terms". Poki dismisses it,
  // with its reject or necessary-only choice when it has one. A prompt that would give the owner an
  // obligation or an identity is the owner's: a sign-in or sign-up, a subscription, payment or free
  // trial, an age or birthday, a human check, a tick for "I agree to the terms", any email or password
  // field. Such a prompt is never taken for a notice, and its go-ahead buttons are not Poki's to tap.
  const ACCEPT = /\b(accept|agree|allow|ok|okay|got it|continue|understood|i understand|close)\b|同意|接受|允许|知道了|好的|关闭/i;
  const REJECT = /\b(reject|decline|deny|refuse|disagree|necessary only|only necessary|essential only|only essential|strictly necessary|necessary cookies|continue without accepting)\b|拒绝|仅必要|仅限必要|只接受必要|不同意/i;
  const GO = /\b(accept|agree|allow|ok|okay|got it|continue|understood|i understand|yes|next|submit|enter|confirm|proceed|start)\b|同意|接受|允许|知道了|好的|继续|确定|下一步|进入|确认|开始/i;
  const CONSENT_TEXT = /cookie|consent|privacy|personal data|tracking|our partners|advertis|terms of (use|service)|\bby (continuing|using|browsing|staying)\b|隐私|个人信息|跟踪|广告|使用条款|服务条款|继续(使用|浏览)/i;
  const CONSENT_MARK = /cookie|consent|gdpr|privacy|onetrust|didomi|truste|usercentrics|cookiebot|quantcast|sp_message/i;
  const OWNER_TEXT = /\b(sign ?in to|log ?in to|sign ?in or|log ?in or|sign ?up|create (an |your |a free )?account|subscribe|subscription|free trial|password|payment|checkout|date of birth|birthday|birth date|years old|years of age|verify (your )?age|(must|you are|you're|i am|i'm) (be )?(over |at least )?(1[3-9]|2[01])|captcha|not a robot|verify (that )?you('re| are) (a )?human)\b|\b(1[3-9]|2[01]) ?(\+|or older|and over)|登录|登入|注册|订阅|密码|付款|支付|试用|年满|出生日期|生日|人机验证|验证码/i;
  const AGREE_TERMS = /\b(agree|accept|consent)\b.*\b(terms|conditions)\b|同意.*(条款|协议)/i;
  const OWNER_FIELDS = 'input[type=password], input[type=email], input[autocomplete~="username"], input[autocomplete~="email"], input[autocomplete~="current-password"]';
  function boxes(el) {
    const out = [];
    for (let box = el && el.parentElement, depth = 0; box && box !== document.body && depth < 12; box = box.parentElement, depth++) {
      const s = box.ownerDocument.defaultView.getComputedStyle(box);
      const floating = s.position === 'fixed' || s.position === 'sticky' || /^(dialog|alertdialog)$/.test(box.getAttribute('role') || '') || box.tagName === 'DIALOG';
      const marked = CONSENT_MARK.test((box.id || '') + ' ' + (typeof box.className === 'string' ? box.className : '') + ' ' + (box.getAttribute('aria-label') || ''));
      if (floating || marked) out.push({ box, floating });
    }
    return out;
  }
  const ownersPrompt = (box) => OWNER_TEXT.test(squash(box.innerText).slice(0, 3000)) || !!box.querySelector(OWNER_FIELDS)
    || [...box.querySelectorAll('input[type=checkbox], [role=checkbox]')].some((c) => AGREE_TERMS.test(name(c)));
  // What a notice is, for the step that dismisses it: read from the boxes around the button up to the
  // notice's own size, since a consent tool often marks just the row of buttons.
  const noticeKind = (el) => {
    const texts = [];
    for (const { box } of boxes(el)) {
      const text = squash(box.innerText);
      if (text.length > 2000 && texts.length) break;
      texts.push(text.slice(0, 2000));
    }
    const text = texts.join(' ');
    if (/\bby (continuing|using|browsing|staying)\b|继续(使用|浏览)/i.test(text) && /\bterms\b|条款/i.test(text)) return 'terms';
    return /cookie/i.test(text) ? 'cookie' : 'privacy';
  };
  // A prompt anywhere around the button that is the owner's wins: when unsure, it is the owner's.
  function consentBox(el) {
    if (ownerBox(el)) return null;
    for (const { box } of boxes(el)) {
      if (ownersPrompt(box)) return null;
      if (CONSENT_TEXT.test(squash(box.innerText).slice(0, 3000))) return box;
    }
    return null;
  }
  const ownerBox = (el) => (boxes(el).find(({ box, floating }) => floating && ownersPrompt(box)) || {}).box || null;
  const rejectIn = (box, except) => [...box.querySelectorAll('button, a[href], [role=button], input[type=button], input[type=submit]')]
    .find((b) => b !== except && b.getClientRects().length && REJECT.test(name(b)));
  // For a tap on `ref`: whether it goes ahead in a prompt that is the owner's (owner); whether it
  // dismisses a notice (dismiss, with the notice's kind); whether it accepts or closes a notice that
  // has a reject choice (accept and reject).
  function consent(ref) {
    const el = element(ref);
    if (!el) return { banner: false, owner: false };
    const label = name(el);
    const owner = GO.test(label) && !REJECT.test(label) && !!ownerBox(el);
    const box = consentBox(el);
    if (!box) return { banner: false, owner };
    const reject = rejectIn(box, el);
    return { banner: true, owner, kind: noticeKind(el), dismiss: ACCEPT.test(label) || REJECT.test(label),
      accept: ACCEPT.test(label) && !REJECT.test(label), reject: reject ? refFor(reject) : null, rejectName: reject ? name(reject) : null };
  }

  // What the last read saw, to tell what a tap or typing changed on the same page.
  let seen = new Set();
  const plain = (line) => line.replace(/^\[e\d+\] /, '');
  const fit = (lines, budget) => { const out = []; let used = 0; for (const l of lines) { if (used + l.length > budget && out.length) break; out.push(l); used += l.length + 1; } return out; };

  // The page as numbered lines, from `offset`, up to `budget` characters; `find` keeps the lines that
  // contain it (with the heading above each, for context). `changes` (after a tap or typing on the same
  // page) puts the lines that were not there before first, such as a search field that just opened.
  function read({ find = '', offset = 0, budget = 9000, changes = false } = {}) {
    const started = performance.now();
    const page = collect();
    // An open consent banner, by the choice that dismisses it: its reject choice, else its accept or close.
    const choice = (test) => page.lines.find((l) => l.kind === 'item' && test.test(l.name) && !(test === ACCEPT && REJECT.test(l.name)) && consentBox(l.node));
    const rejecting = choice(REJECT), dismissing = rejecting || choice(ACCEPT);
    const banners = dismissing ? { choice: '[' + dismissing.ref + '] ' + JSON.stringify(dismissing.name), reject: !!rejecting } : null;
    let lines = page.lines.map(format);
    const before = seen;
    seen = new Set(lines.map(plain));
    if (changes && !find && before.size) {
      const fresh = lines.filter((l) => !before.has(plain(l)));
      if (fresh.length && fresh.length < lines.length * 0.6) {
        const changed = fit(fresh, budget / 2);
        const top = fit(lines, budget - changed.reduce((n, l) => n + l.length + 1, 0));
        return { url: location.href, title: document.title, changed, lines: top, total: lines.length, from: 0, consent: banners,
          next: top.length < lines.length ? top.length : null, interactive: page.interactive, humanCheck: humanCheck(page),
          ms: Math.round(performance.now() - started) };
      }
    }
    if (find) {
      const needle = find.toLowerCase();
      const shown = new Set(), kept = [];
      let heading = -1;
      page.lines.forEach((l, i) => {
        if (l.kind === 'heading') heading = i;
        if (!lines[i].toLowerCase().includes(needle)) return;
        for (const j of [...context(page.lines, i), heading].filter((j) => j >= 0 && j < i).sort((a, b) => a - b)) {
          if (!shown.has(j)) { shown.add(j); kept.push(lines[j]); }
        }
        if (!shown.has(i)) { shown.add(i); kept.push(lines[i]); }
      });
      lines = kept;
    }
    const out = [];
    let used = 0, i = offset;
    for (; i < lines.length; i++) {
      if (used + lines[i].length > budget && out.length) break;
      out.push(lines[i]); used += lines[i].length + 1;
    }
    return { url: location.href, title: document.title, lines: out, total: lines.length, from: offset, consent: banners,
      next: i < lines.length ? i : null, interactive: page.interactive, humanCheck: humanCheck(page),
      ms: Math.round(performance.now() - started) };
  }

  // A short ring where Poki taps, so the person watching sees it.
  function flash(el) {
    const r = el.getBoundingClientRect();
    if (el.ownerDocument !== document) return;
    const ring = document.createElement('div');
    ring.style.cssText = 'position:fixed;z-index:2147483647;pointer-events:none;border-radius:10px;' +
      'border:3px solid #0A84FF;box-shadow:0 0 0 4px rgba(10,132,255,.25);transition:opacity .5s;' +
      `left:${r.left - 4}px;top:${r.top - 4}px;width:${r.width + 8}px;height:${r.height + 8}px`;
    document.documentElement.appendChild(ring);
    setTimeout(() => { ring.style.opacity = '0'; }, 450);
    setTimeout(() => ring.remove(), 1000);
  }

  // While Poki works the page, a field it (or the page) focuses gets inputmode="none", so the phone's
  // keyboard does not come up over the chat. The owner taking over (drive(false)) puts the fields back.
  let driving = true;
  const quieted = new Map();
  const typable = (el) => el && (el.tagName === 'TEXTAREA' || el.isContentEditable ||
    el.tagName === 'INPUT' && !['checkbox', 'radio', 'button', 'submit', 'reset', 'image', 'range', 'color', 'file', 'hidden'].includes((el.type || '').toLowerCase()));
  const quiet = (el) => {
    if (!driving || !typable(el) || quieted.has(el)) return;
    quieted.set(el, el.getAttribute('inputmode'));
    el.setAttribute('inputmode', 'none');
  };
  const unquiet = (el) => {
    if (!quieted.has(el)) return;
    const was = quieted.get(el);
    quieted.delete(el);
    if (was === null) el.removeAttribute('inputmode'); else el.setAttribute('inputmode', was);
  };
  document.addEventListener('focusin', (e) => quiet(e.composedPath()[0]), true);
  document.addEventListener('focusout', (e) => { if (!driving) unquiet(e.composedPath()[0]); }, true);
  function drive(on) {
    driving = on;
    if (!on) [...quieted.keys()].forEach(unquiet);
  }

  const describe = (el) => privateField(el) || squash(el.getAttribute('aria-label') || el.innerText || el.tagName.toLowerCase()).slice(0, 60);

  function click(ref) {
    const el = element(ref);
    if (!el) return { ok: false, error: 'stale' };
    if (el.disabled || el.getAttribute('aria-disabled') === 'true') return { ok: false, error: 'disabled', name: name(el) };
    driving = true;
    quiet(el);
    el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
    const r = el.getBoundingClientRect();
    const x = r.left + r.width / 2, y = r.top + r.height / 2;
    const view = el.ownerDocument.defaultView;
    const top = el.ownerDocument.elementFromPoint(x, y);
    const covered = top && top !== el && !el.contains(top) && !top.contains(el) ? describe(top) : null;
    flash(el);
    const options = { bubbles: true, cancelable: true, composed: true, clientX: x, clientY: y, view, isPrimary: true, pointerType: 'touch', button: 0 };
    el.dispatchEvent(new view.PointerEvent('pointerdown', options));
    el.dispatchEvent(new view.MouseEvent('mousedown', options));
    el.dispatchEvent(new view.PointerEvent('pointerup', options));
    el.dispatchEvent(new view.MouseEvent('mouseup', options));
    if (typeof el.focus === 'function') el.focus({ preventScroll: true });
    el.click();
    return { ok: true, name: name(el), covered };
  }

  function type(ref, text, submit) {
    const el = element(ref);
    if (!el) return { ok: false, error: 'stale' };
    const view = el.ownerDocument.defaultView;
    if (privateField(el)) return { ok: false, error: 'owner', name: name(el) };
    if (el.disabled || el.readOnly) return { ok: false, error: 'disabled', name: name(el) };
    el.scrollIntoView({ block: 'center', behavior: 'instant' });
    flash(el);
    if (el.tagName === 'SELECT') {
      const wanted = text.toLowerCase();
      const option = [...el.options].find((o) => squash(o.text).toLowerCase() === wanted) || [...el.options].find((o) => squash(o.text).toLowerCase().includes(wanted));
      if (!option) return { ok: false, error: 'option', options: [...el.options].map((o) => squash(o.text)).slice(0, 30) };
      el.value = option.value;
      el.dispatchEvent(new view.Event('input', { bubbles: true }));
      el.dispatchEvent(new view.Event('change', { bubbles: true }));
      return { ok: true, name: name(el), value: squash(option.text) };
    }
    driving = true;
    quiet(el);
    el.focus();
    if (el.isContentEditable) {
      el.ownerDocument.execCommand('selectAll');
      el.ownerDocument.execCommand('insertText', false, text);
    } else if ('value' in el) {
      // Through the prototype's setter, so pages that track the field's value (React) see the change.
      const proto = el.tagName === 'TEXTAREA' ? view.HTMLTextAreaElement.prototype : view.HTMLInputElement.prototype;
      const set = Object.getOwnPropertyDescriptor(proto, 'value').set;
      set.call(el, '');
      el.dispatchEvent(new view.InputEvent('input', { bubbles: true, composed: true, inputType: 'deleteContentBackward' }));
      set.call(el, text);
      el.dispatchEvent(new view.InputEvent('input', { bubbles: true, composed: true, inputType: 'insertText', data: text }));
      el.dispatchEvent(new view.Event('change', { bubbles: true }));
    } else {
      return { ok: false, error: 'notfield', name: name(el) };
    }
    // Enter sends the whole form. One that also holds a password, a code, a card or an identity
    // document already filled in is the owner's to send, so the text stays typed and nothing is sent.
    const owners = submit && el.form ? [...el.form.elements].find((other) => other !== el && !['private field', null].includes(privateField(other)) && String(other.value || '').trim() !== '') : null;
    if (owners) return { ok: false, error: 'ownerform', name: name(el) };
    if (submit) {
      for (const type of ['keydown', 'keypress', 'keyup']) {
        el.dispatchEvent(new view.KeyboardEvent(type, { bubbles: true, cancelable: true, key: 'Enter', code: 'Enter', keyCode: 13, which: 13 }));
      }
      if (el.form) { if (el.form.requestSubmit) el.form.requestSubmit(); else el.form.submit(); }
    }
    return { ok: true, name: name(el), value: el.isContentEditable ? squash(el.innerText) : String(el.value) };
  }

  // Resolves once the page has had no changes for `quiet` ms, or after `max` ms.
  function settle(quiet = 400, max = 3000) {
    return new Promise((resolve) => {
      const started = performance.now();
      let timer = null;
      const done = () => { observer.disconnect(); clearTimeout(timer); clearTimeout(cap); resolve(Math.round(performance.now() - started)); };
      const observer = new MutationObserver(() => { clearTimeout(timer); timer = setTimeout(done, quiet); });
      observer.observe(document.documentElement, { subtree: true, childList: true, attributes: true, characterData: true });
      timer = setTimeout(done, quiet);
      const cap = setTimeout(done, max);
    });
  }

  window.__pokiReader = { read, click, type, settle, drive, consent, label: (ref) => { const el = element(ref); return el ? name(el) : null; } };
})();
"""#
}
