// Private JavaScript/TypeScript lexical analysis for discovery risk analysis and static
// candidate screening. This is a tokenizer plus bracket/symbol heuristics, NOT a parser and NOT a
// sandbox. It never evaluates its input. On any lexical doubt (unterminated string, comment,
// template or regex) it reports ok=false and callers must stay conservative.

const KEYWORDS_BEFORE_REGEX = new Set([
  'return', 'typeof', 'instanceof', 'in', 'of', 'new', 'delete', 'void', 'throw', 'case', 'do', 'else', 'yield', 'await',
]);

const PUNCTUATORS = [
  '>>>=', '...', '===', '!==', '**=', '<<=', '>>=', '>>>', '&&=', '||=', '??=',
  '=>', '==', '!=', '<=', '>=', '&&', '||', '??', '?.', '++', '--', '+=', '-=', '*=', '/=', '%=', '&=', '|=', '^=', '<<', '>>', '**',
];
const PUNCT_BY_LEN = { 4: new Set(), 3: new Set(), 2: new Set() };
for (const p of PUNCTUATORS) PUNCT_BY_LEN[p.length].add(p);

const ID_RE = /[\p{ID_Start}$_][\p{ID_Continue}$\u200c\u200d]*/uy;
const NUM_RE = /(?:0[xX][0-9a-fA-F_]+n?|0[bB][01_]+n?|0[oO][0-7_]+n?|(?:\d[\d_]*\.?[\d_]*|\.\d[\d_]*)(?:[eE][+-]?\d+)?n?)/y;

const isNewline = (c) => c === '\n' || c === '\r' || c === '\u2028' || c === '\u2029';

function decodeString(inner) {
  return inner.replace(/\\(?:u\{([0-9a-fA-F]+)\}|u([0-9a-fA-F]{4})|x([0-9a-fA-F]{2})|(\r\n|[\n\r\u2028\u2029])|([0-7]{1,3})|([\s\S]))/g,
    (whole, cp, u4, x2, cont, oct, other) => {
      if (cp !== undefined) {
        const n = parseInt(cp, 16);
        return n <= 0x10ffff ? String.fromCodePoint(n) : whole;
      }
      if (u4 !== undefined) return String.fromCharCode(parseInt(u4, 16));
      if (x2 !== undefined) return String.fromCharCode(parseInt(x2, 16));
      if (cont !== undefined) return '';
      if (oct !== undefined) return String.fromCharCode(parseInt(oct, 8));
      switch (other) {
        case 'n': return '\n';
        case 't': return '\t';
        case 'r': return '\r';
        case 'b': return '\b';
        case 'f': return '\f';
        case 'v': return '\v';
        default: return other;
      }
    });
}

function buildLineIndex(src) {
  const starts = [0];
  for (let i = 0; i < src.length; i++) {
    const c = src[i];
    if (c === '\n') starts.push(i + 1);
    else if (c === '\r') {
      if (src[i + 1] === '\n') i++;
      starts.push(i + 1);
    } else if (c === '\u2028' || c === '\u2029') starts.push(i + 1);
  }
  return starts;
}
function lineOf(starts, offset) {
  let lo = 0;
  let hi = starts.length - 1;
  while (lo < hi) {
    const mid = (lo + hi + 1) >> 1;
    if (starts[mid] <= offset) lo = mid;
    else hi = mid - 1;
  }
  return lo + 1;
}

function canStartRegex(prev) {
  if (!prev) return true;
  if (prev.t === 'p') return !(prev.v === ')' || prev.v === ']' || prev.v === '}' || prev.v === '++' || prev.v === '--');
  if (prev.t === 'id') return KEYWORDS_BEFORE_REGEX.has(prev.v);
  return false;
}

// Scans [start, ...). When untilBrace is true the scan stops at the unmatched '}' (template ${ }).
function scan(src, start, untilBrace, starts) {
  const toks = [];
  let i = start;
  const n = src.length;
  let nl = false;
  let depth = 0;
  const push = (t, v, s, e, extra) => {
    toks.push({ t, v, raw: src.slice(s, e), s, e, l: lineOf(starts, s), el: lineOf(starts, e > s ? e - 1 : s), nl, ...extra });
    nl = false;
  };
  if (!untilBrace && src.startsWith('#!')) while (i < n && !isNewline(src[i])) i++;
  while (i < n) {
    const c = src[i];
    if (isNewline(c)) { nl = true; i++; continue; }
    if (/\s/.test(c) || c === '\ufeff') { i++; continue; }
    if (c === '/' && src[i + 1] === '/') {
      while (i < n && !isNewline(src[i])) i++;
      continue;
    }
    if (c === '/' && src[i + 1] === '*') {
      const end = src.indexOf('*/', i + 2);
      if (end === -1) return { tokens: toks, end: n, ok: false };
      if (/[\n\r\u2028\u2029]/.test(src.slice(i, end))) nl = true;
      i = end + 2;
      continue;
    }
    if (c === '"' || c === "'") {
      let j = i + 1;
      for (;;) {
        if (j >= n) return { tokens: toks, end: n, ok: false };
        const d = src[j];
        if (d === '\\') {
          j += src[j + 1] === '\r' && src[j + 2] === '\n' ? 3 : 2;
          continue;
        }
        if (d === '\n' || d === '\r') return { tokens: toks, end: j, ok: false };
        if (d === c) break;
        j++;
      }
      const innerText = src.slice(i + 1, j);
      // Decoded value serves screening; comparison keeps escaped spellings raw because decoding
      // could erase semantics such as a directive prologue ("\x75se strict" is not "use strict").
      push('str', `s:${decodeString(innerText)}`, i, j + 1, innerText.includes('\\') ? { cmp: `r:${src.slice(i, j + 1)}` } : undefined);
      i = j + 1;
      continue;
    }
    if (c === '`') {
      let j = i + 1;
      const inner = [];
      for (;;) {
        if (j >= n) return { tokens: toks, end: n, ok: false };
        const d = src[j];
        if (d === '\\') { j += 2; continue; }
        if (d === '`') break;
        if (d === '$' && src[j + 1] === '{') {
          const sub = scan(src, j + 2, true, starts);
          if (!sub.ok || src[sub.end] !== '}') return { tokens: toks, end: n, ok: false };
          inner.push(...sub.tokens);
          j = sub.end + 1;
          continue;
        }
        j++;
      }
      push('tpl', src.slice(i, j + 1), i, j + 1, { inner });
      i = j + 1;
      continue;
    }
    if (/[0-9]/.test(c) || (c === '.' && /[0-9]/.test(src[i + 1] || ''))) {
      NUM_RE.lastIndex = i;
      const m = NUM_RE.exec(src);
      if (!m) return { tokens: toks, end: i, ok: false };
      push('num', m[0], i, i + m[0].length);
      i += m[0].length;
      continue;
    }
    if (c === '#') {
      ID_RE.lastIndex = i + 1;
      const m = ID_RE.exec(src);
      if (m && m.index === i + 1) {
        push('id', `#${m[0]}`, i, i + 1 + m[0].length);
        i += 1 + m[0].length;
        continue;
      }
    }
    ID_RE.lastIndex = i;
    const idm = ID_RE.exec(src);
    if (idm && idm.index === i) {
      push('id', idm[0], i, i + idm[0].length);
      i += idm[0].length;
      continue;
    }
    if (c === '/' && canStartRegex(toks[toks.length - 1])) {
      let j = i + 1;
      let inClass = false;
      for (;;) {
        if (j >= n || isNewline(src[j])) return { tokens: toks, end: j, ok: false };
        const d = src[j];
        if (d === '\\') { j += 2; continue; }
        if (d === '[') inClass = true;
        else if (d === ']') inClass = false;
        else if (d === '/' && !inClass) break;
        j++;
      }
      j++;
      while (j < n && /[A-Za-z]/.test(src[j])) j++;
      push('re', src.slice(i, j), i, j);
      i = j;
      continue;
    }
    if (c === '}' && untilBrace && depth === 0) return { tokens: toks, end: i, ok: true };
    let p = c;
    for (const len of [4, 3, 2]) {
      const cand = src.slice(i, i + len);
      if (cand.length === len && PUNCT_BY_LEN[len].has(cand)) {
        if (cand === '?.' && /[0-9]/.test(src[i + 2] || '')) continue;
        p = cand;
        break;
      }
    }
    if (p === '{') depth++;
    else if (p === '}') depth--;
    push('p', p, i, i + p.length);
    i += p.length;
  }
  return { tokens: toks, end: i, ok: !untilBrace };
}

/** Tokenise JS/TS text. Returns {tokens, ok}. ok=false means do not trust the token stream. */
export function lex(text) {
  const starts = buildLineIndex(text);
  const r = scan(text, 0, false, starts);
  return { tokens: r.tokens, ok: r.ok, lineCount: starts.length };
}

// ---------------------------------------------------------------------------
// Formatting-insensitive comparison keys
// ---------------------------------------------------------------------------
const isPunct = (t, v) => !!t && t.t === 'p' && t.v === v;

function continuesLine(t) {
  return (t.t === 'p' && CONTINUES.has(t.v)) || t.t === 'tpl' || (t.t === 'id' && (t.v === 'instanceof' || t.v === 'in'));
}

function hasTopLevelComma(tokens, match, open, close) {
  for (let j = open + 1; j < close; j++) {
    if (tokens[j].t === 'p' && OPEN[tokens[j].v] && match.has(j)) { j = match.get(j); continue; }
    if (isPunct(tokens[j], ',')) return true;
  }
  return false;
}

/** Indices of redundant parentheses a formatter may add or remove without changing semantics. */
function cosmeticParens(tokens) {
  const { match } = matchBrackets(tokens);
  const drop = new Set();
  for (let i = 0; i < tokens.length; i++) {
    if (!isPunct(tokens[i], '(') || !match.has(i)) continue;
    const c = match.get(i);
    if (c === i + 1) continue;
    const prev = tokens[i - 1];
    const inner = tokens[i + 1];
    const after = tokens[c + 1];
    // (x) => ...   <->   x => ...
    if (c === i + 2 && inner.t === 'id' && isPunct(after, '=>')) { drop.add(i); drop.add(c); continue; }
    // `return\n(x)` returns undefined; only same-line parentheses after return are cosmetic
    const isReturn = !!prev && prev.t === 'id' && prev.v === 'return' && !tokens[i].nl && !(isPunct(tokens[i - 2], '.') || isPunct(tokens[i - 2], '?.'));
    const isArrowBody = isPunct(prev, '=>');
    if (!isReturn && !isArrowBody) continue;
    if (isPunct(inner, '{')) continue; // ({...}) is an object literal, braces alone would be a block
    if (isArrowBody && hasTopLevelComma(tokens, match, i, c)) continue; // `=> (a, b)` is not `=> a, b`
    const endsExpression = !after
      || (after.t === 'p' && (after.v === ';' || after.v === '}' || (isArrowBody && (after.v === ',' || after.v === ')' || after.v === ']'))))
      || (after.nl && !continuesLine(after));
    if (endsExpression) { drop.add(i); drop.add(c); }
  }
  return drop;
}

// A line terminator is semantically significant (automatic semicolon insertion) right after these
// words (restricted productions) and before ++/--; the TypeScript contextual keywords are included
// conservatively. Everywhere else newlines are formatting.
const NEWLINE_RESTRICTED_AFTER = new Set(['return', 'throw', 'break', 'continue', 'yield', 'async', 'type', 'interface', 'declare', 'abstract', 'namespace', 'module']);

function comparisonKey(tokens, i) {
  const tk = tokens[i];
  const prev = tokens[i - 1];
  let key = `${tk.t}|${tk.cmp !== undefined ? tk.cmp : tk.v}`;
  if (tk.nl) {
    const afterRestricted = !!prev && prev.t === 'id' && NEWLINE_RESTRICTED_AFTER.has(prev.v) && !(isPunct(tokens[i - 2], '.') || isPunct(tokens[i - 2], '?.'));
    const incDec = tk.t === 'p' && (tk.v === '++' || tk.v === '--');
    if (afterRestricted || incDec) key += '|nl';
  }
  return key;
}

/**
 * Returns kept tokens (comments/whitespace are never tokens) with cosmetic punctuation removed:
 * trailing commas, a final semicolon, quote style of escape-free strings (escaped spellings compare
 * raw), redundant return/arrow-body/single-parameter parentheses, and newlines outside restricted
 * (ASI-sensitive) positions.
 */
export function comparableTokens(tokens) {
  const drop = cosmeticParens(tokens);
  const kept = [];
  for (let i = 0; i < tokens.length; i++) {
    if (drop.has(i)) continue;
    const tk = tokens[i];
    const next = tokens[i + 1];
    if (tk.t === 'p' && tk.v === ',' && next && next.t === 'p' && (next.v === ')' || next.v === ']' || next.v === '}')) {
      const prev = tokens[i - 1];
      if (!(prev && prev.t === 'p' && (prev.v === ',' || prev.v === '['))) continue; // cosmetic trailing comma
    }
    if (tk.t === 'p' && tk.v === ';' && (!next || (next.t === 'p' && next.v === '}'))) continue; // optional final semicolon
    kept.push({ key: comparisonKey(tokens, i), tok: tk, index: i });
  }
  return kept;
}

// ---------------------------------------------------------------------------
// Token diff (Myers with a hard bound; beyond the bound the whole middle is one change)
// ---------------------------------------------------------------------------
const MAX_EDIT_DISTANCE = 1200;

function myersMatches(a, b) {
  const N = a.length;
  const M = b.length;
  const MAX = Math.min(N + M, MAX_EDIT_DISTANCE);
  const off = MAX + 1;
  const v = new Int32Array(2 * MAX + 3);
  const trace = [];
  let D = -1;
  outer:
  for (let d = 0; d <= MAX; d++) {
    trace.push(v.slice());
    for (let k = -d; k <= d; k += 2) {
      let x;
      if (k === -d || (k !== d && v[off + k - 1] < v[off + k + 1])) x = v[off + k + 1];
      else x = v[off + k - 1] + 1;
      let y = x - k;
      while (x < N && y < M && a[x] === b[y]) { x++; y++; }
      v[off + k] = x;
      if (x >= N && y >= M) { D = d; break outer; }
    }
  }
  if (D < 0) return null;
  const matches = [];
  let x = N;
  let y = M;
  for (let d = D; d > 0; d--) {
    const vp = trace[d];
    const k = x - y;
    const pk = (k === -d || (k !== d && vp[off + k - 1] < vp[off + k + 1])) ? k + 1 : k - 1;
    const px = vp[off + pk];
    const py = px - pk;
    while (x > px && y > py) { x--; y--; matches.push([x, y]); }
    x = px;
    y = py;
  }
  while (x > 0 && y > 0) { x--; y--; matches.push([x, y]); }
  return matches.reverse();
}

/**
 * Diff two key arrays. Returns groups {a0,a1,b0,b1} (half-open index ranges of unmatched keys).
 */
export function diffKeys(a, b) {
  let pre = 0;
  while (pre < a.length && pre < b.length && a[pre] === b[pre]) pre++;
  let suf = 0;
  while (suf < a.length - pre && suf < b.length - pre && a[a.length - 1 - suf] === b[b.length - 1 - suf]) suf++;
  const am = a.slice(pre, a.length - suf);
  const bm = b.slice(pre, b.length - suf);
  if (am.length === 0 && bm.length === 0) return [];
  if (am.length === 0 || bm.length === 0) return [{ a0: pre, a1: pre + am.length, b0: pre, b1: pre + bm.length }];
  const matches = myersMatches(am, bm);
  if (!matches) return [{ a0: pre, a1: pre + am.length, b0: pre, b1: pre + bm.length }];
  const groups = [];
  let ai = 0;
  let bi = 0;
  for (const [mx, my] of matches) {
    if (mx > ai || my > bi) groups.push({ a0: pre + ai, a1: pre + mx, b0: pre + bi, b1: pre + my });
    ai = mx + 1;
    bi = my + 1;
  }
  if (ai < am.length || bi < bm.length) groups.push({ a0: pre + ai, a1: pre + am.length, b0: pre + bi, b1: pre + bm.length });
  return groups;
}

// ---------------------------------------------------------------------------
// Bracket matching and symbol extraction
// ---------------------------------------------------------------------------
const OPEN = { '(': ')', '[': ']', '{': '}' };
const CLOSE = new Set([')', ']', '}']);

export function matchBrackets(tokens) {
  const match = new Map();
  const openOf = new Map();
  const stack = [];
  for (let i = 0; i < tokens.length; i++) {
    const tk = tokens[i];
    if (tk.t !== 'p') continue;
    if (OPEN[tk.v]) stack.push(i);
    else if (CLOSE.has(tk.v)) {
      const o = stack.pop();
      if (o !== undefined && OPEN[tokens[o].v] === tk.v) { match.set(o, i); openOf.set(i, o); }
    }
  }
  return { match, openOf };
}

const NOT_METHOD_NAMES = new Set(['if', 'for', 'while', 'switch', 'catch', 'with', 'function', 'return', 'typeof', 'new', 'await', 'super', 'import', 'delete', 'void', 'throw', 'do', 'else', 'in', 'of', 'instanceof']);
const METHOD_MODIFIERS = new Set(['static', 'async', 'get', 'set', 'public', 'private', 'protected', 'readonly', 'override', 'abstract', 'declare', 'accessor']);
const OBJECT_PRECEDERS = new Set(['=', '(', ',', ':', 'return', '[', '?', '||', '&&', '??', '=>', 'default']);
const CONTINUES = new Set(['.', '?.', '?', '(', '[', '+', '-', '*', '/', '%', '**', '&&', '||', '??', '==', '===', '!=', '!==', '<', '>', '<=', '>=', '&', '|', '^', '<<', '>>', '>>>', ',', ':', '=', '+=', '-=', '*=', '/=', 'instanceof', 'in']);

function exprEnd(tokens, match, b) {
  const first = tokens[b];
  if (!first) return b - 1;
  let j = b;
  while (j < tokens.length) {
    const tk = tokens[j];
    if (tk.t === 'p' && OPEN[tk.v]) {
      const m = match.get(j);
      if (m === undefined) return tokens.length - 1;
      j = m + 1;
      continue;
    }
    if (tk.t === 'p' && (tk.v === ';' || tk.v === ',' || CLOSE.has(tk.v))) return j - 1;
    if (j > b && tk.nl) {
      const prev = tokens[j - 1];
      const prevContinues = prev.t === 'p' && !(prev.v === ')' || prev.v === ']' || prev.v === '}' || prev.v === '++' || prev.v === '--') && prev.v !== ';';
      const nextContinues = (tk.t === 'p' && CONTINUES.has(tk.v)) || tk.t === 'tpl' || (tk.t === 'id' && (tk.v === 'instanceof' || tk.v === 'in'));
      if (!prevContinues && !nextContinues) return j - 1;
    }
    j++;
  }
  return tokens.length - 1;
}

function skipToBody(tokens, match, from) {
  // from: index right after ')' of a parameter list; skip an optional return type to '{'.
  let j = from;
  for (let guard = 0; j < tokens.length && guard < 80; guard++, j++) {
    const tk = tokens[j];
    if (tk.t === 'p' && tk.v === '{') return j;
    if (tk.t === 'p' && (tk.v === ';' || tk.v === '=>' || tk.v === '}')) return -1;
    if (tk.t === 'p' && (tk.v === '(' || tk.v === '[') && match.has(j)) j = match.get(j);
  }
  return -1;
}

function skipAnglesForward(tokens, i) {
  if (!(tokens[i] && tokens[i].t === 'p' && tokens[i].v === '<')) return i;
  let depth = 0;
  for (let j = i; j < tokens.length && j < i + 120; j++) {
    const v = tokens[j].t === 'p' ? tokens[j].v : '';
    if (v === '<') depth++;
    else if (v === '>') depth--;
    else if (v === '>>') depth -= 2;
    else if (v === '>>>') depth -= 3;
    else if (v === ';' || v === '{') return i;
    if (depth <= 0) return j + 1;
  }
  return i;
}

/**
 * Extract function/method/class symbols with token and line spans.
 * Heuristic by design: names only label hypotheses; mutation scope uses line ranges.
 */
export function extractSymbols(tokens) {
  const { match, openOf } = matchBrackets(tokens);
  const symbols = [];
  const stack = []; // {open, kind: 'class'|'object'|'block'|'paren'|'bracket', name}
  const classBodies = new Map(); // open index -> class name
  const qualify = (name) => {
    for (let s = stack.length - 1; s >= 0; s--) if (stack[s].kind === 'class') return `${stack[s].name}.${name}`;
    return name;
  };
  const addSymbol = (name, kind, startTok, endTok, params) => {
    if (endTok < startTok) return;
    symbols.push({ name, kind, startTok, endTok, params });
  };
  const back = (i, set) => {
    let s = i;
    while (s > 0 && tokens[s - 1].t === 'id' && set.has(tokens[s - 1].v)) s--;
    return s;
  };
  const prefixSet = new Set(['async', 'export', 'default', 'static', 'public', 'private', 'protected', 'abstract', 'declare', 'readonly', 'override', 'get', 'set']);

  for (let i = 0; i < tokens.length; i++) {
    const tk = tokens[i];
    const prev = tokens[i - 1];
    if (tk.t === 'p') {
      if (tk.v === '{') {
        let kind = 'block';
        if (classBodies.has(i)) kind = 'class';
        else if (prev && ((prev.t === 'p' && OBJECT_PRECEDERS.has(prev.v) && prev.v !== '=>') || (prev.t === 'id' && (prev.v === 'return' || prev.v === 'default')))) kind = 'object';
        stack.push({ open: i, kind, name: classBodies.get(i) });
      } else if (tk.v === '(') stack.push({ open: i, kind: 'paren' });
      else if (tk.v === '[') stack.push({ open: i, kind: 'bracket' });
      else if (CLOSE.has(tk.v)) stack.pop();
      if (tk.v === '=>') {
        // locate parameter list start
        let p = -1;
        if (prev && prev.t === 'p' && prev.v === ')') p = openOf.has(i - 1) ? openOf.get(i - 1) : -1;
        else {
          for (let j = i - 1; j > Math.max(0, i - 40); j--) {
            const t2 = tokens[j];
            if (t2.t === 'p' && (t2.v === ';' || t2.v === '=' || t2.v === '{' || t2.v === '}')) break;
            if (t2.t === 'p' && t2.v === ')' && tokens[j + 1] && tokens[j + 1].t === 'p' && tokens[j + 1].v === ':' && openOf.has(j)) { p = openOf.get(j); break; }
          }
          if (p < 0 && prev && prev.t === 'id') p = i - 1;
        }
        if (p >= 0) {
          let start = p;
          if (tokens[start - 1] && tokens[start - 1].t === 'p' && tokens[start - 1].v === '>') {
            for (let j = start - 1, d = 0; j > Math.max(0, start - 30); j--) {
              const v = tokens[j].t === 'p' ? tokens[j].v : '';
              if (v === '>') d++;
              else if (v === '<') { d--; if (d === 0) { start = j; break; } }
            }
          }
          if (tokens[start - 1] && tokens[start - 1].t === 'id' && tokens[start - 1].v === 'async') start--;
          let name = null;
          let declStart = start;
          const before = tokens[start - 1];
          const before2 = tokens[start - 2];
          if (before && before.t === 'p' && before.v === '=' && before2) {
            if (before2.t === 'id') {
              name = before2.v;
              let j = start - 2;
              while (j >= 2 && tokens[j - 1].t === 'p' && tokens[j - 1].v === '.' && tokens[j - 2].t === 'id') { name = `${tokens[j - 2].v}.${name}`; j -= 2; }
              declStart = back(j, new Set(['export', 'const', 'let', 'var', 'static', 'public', 'private', 'protected', 'readonly', 'override']));
            } else {
              for (let j = start - 2; j > Math.max(0, start - 40); j--) {
                if (tokens[j].t === 'p' && tokens[j].v === ':' && tokens[j - 1] && tokens[j - 1].t === 'id') {
                  name = tokens[j - 1].v;
                  declStart = back(j - 1, new Set(['export', 'const', 'let', 'var', 'static', 'public', 'private', 'protected', 'readonly', 'override']));
                  break;
                }
              }
            }
          } else if (before && before.t === 'p' && before.v === ':' && before2 && (before2.t === 'id' || before2.t === 'str')) {
            name = before2.t === 'id' ? before2.v : before2.v.slice(2);
            declStart = start - 2;
          }
          if (name) {
            const bodyFirst = i + 1;
            const end = tokens[bodyFirst] && tokens[bodyFirst].t === 'p' && tokens[bodyFirst].v === '{' && match.has(bodyFirst)
              ? match.get(bodyFirst)
              : exprEnd(tokens, match, bodyFirst);
            addSymbol(qualify(name), 'arrow', declStart, end, { s: p, e: i - 1 });
          }
        }
      }
      continue;
    }
    if (tk.t !== 'id') continue;
    if (tk.v === 'function' && !(prev && prev.t === 'p' && prev.v === '.')) {
      let j = i + 1;
      if (tokens[j] && tokens[j].t === 'p' && tokens[j].v === '*') j++;
      let name = null;
      if (tokens[j] && tokens[j].t === 'id') {
        name = tokens[j].v;
        j++;
      }
      j = skipAnglesForward(tokens, j);
      if (tokens[j] && tokens[j].t === 'p' && tokens[j].v === '(' && match.has(j)) {
        const pClose = match.get(j);
        const body = skipToBody(tokens, match, pClose + 1);
        if (body >= 0 && match.has(body)) {
          let start = back(i, prefixSet);
          if (!name) {
            const b1 = tokens[start - 1];
            const b2 = tokens[start - 2];
            if (b1 && b1.t === 'p' && b1.v === '=' && b2 && b2.t === 'id') name = b2.v;
            else if (b1 && b1.t === 'p' && b1.v === ':' && b2 && b2.t === 'id') name = b2.v;
            else if (tokens[i - 1] && tokens[i - 1].t === 'id' && tokens[i - 1].v === 'default') name = 'default';
          }
          if (name) addSymbol(qualify(name), 'function', start, match.get(body), { s: j, e: pClose });
        }
      }
      continue;
    }
    if (tk.v === 'class' && !(prev && prev.t === 'p' && prev.v === '.')) {
      let j = i + 1;
      let name = null;
      if (tokens[j] && tokens[j].t === 'id' && tokens[j].v !== 'extends' && tokens[j].v !== 'implements') { name = tokens[j].v; j++; }
      let k = j;
      for (let guard = 0; k < tokens.length && guard < 120; guard++, k++) {
        const t2 = tokens[k];
        if (t2.t === 'p' && t2.v === '{') break;
        if (t2.t === 'p' && (t2.v === '(' || t2.v === '[') && match.has(k)) k = match.get(k);
        if (t2.t === 'p' && (t2.v === ';' || t2.v === '}')) { k = -1; break; }
      }
      if (k > 0 && tokens[k] && tokens[k].v === '{' && match.has(k)) {
        if (!name) {
          const b1 = tokens[i - 1];
          const b2 = tokens[i - 2];
          name = b1 && b1.t === 'p' && b1.v === '=' && b2 && b2.t === 'id' ? b2.v : 'default';
        }
        classBodies.set(k, name);
        addSymbol(qualify(name), 'class', back(i, prefixSet), match.get(k), null);
      }
      continue;
    }
    // method in class body / object literal: name ( ... ) [: type] { ... }
    const top = stack[stack.length - 1];
    if (top && (top.kind === 'class' || top.kind === 'object') && !NOT_METHOD_NAMES.has(tk.v) && !(METHOD_MODIFIERS.has(tk.v) && tokens[i + 1] && !(tokens[i + 1].t === 'p' && tokens[i + 1].v === '('))) {
      let j = i + 1;
      if (tokens[j] && tokens[j].t === 'p' && tokens[j].v === '?') j++;
      j = skipAnglesForward(tokens, j);
      const prevOk = !prev || (prev.t === 'p' && (prev.v === '{' || prev.v === ';' || prev.v === '}' || prev.v === ',' || prev.v === '*')) || (prev.t === 'id' && METHOD_MODIFIERS.has(prev.v));
      if (prevOk && tokens[j] && tokens[j].t === 'p' && tokens[j].v === '(' && match.has(j)) {
        const pClose = match.get(j);
        const body = skipToBody(tokens, match, pClose + 1);
        if (body >= 0 && match.has(body)) {
          let start = back(i, METHOD_MODIFIERS);
          if (tokens[start - 1] && tokens[start - 1].t === 'p' && tokens[start - 1].v === '*') start--;
          addSymbol(top.kind === 'class' ? qualify(tk.v) : tk.v, 'method', start, match.get(body), { s: j, e: pClose });
        }
      }
    }
  }
  const out = symbols.map((s) => ({
    ...s,
    startLine: tokens[s.startTok].l,
    endLine: tokens[s.endTok].el,
  }));
  out.sort((x, y) => x.startTok - y.startTok || y.endTok - x.endTok || (x.name < y.name ? -1 : x.name > y.name ? 1 : 0));
  return out;
}

/** Innermost symbol (smallest token span) containing token index idx, or null. */
export function innermostSymbol(symbols, idx) {
  let best = null;
  for (const s of symbols) {
    if (s.startTok <= idx && idx <= s.endTok) {
      if (!best || (s.endTok - s.startTok) < (best.endTok - best.startTok)) best = s;
    }
  }
  return best;
}

/** Module specifiers referenced by import/export-from/require/dynamic import with literal args. */
export function moduleSpecifiers(tokens) {
  const specs = [];
  for (let i = 0; i < tokens.length; i++) {
    const tk = tokens[i];
    if (tk.t !== 'id') continue;
    const next = tokens[i + 1];
    const next2 = tokens[i + 2];
    const prev = tokens[i - 1];
    const isMember = prev && prev.t === 'p' && (prev.v === '.' || prev.v === '?.');
    if (tk.v === 'from' && next && next.t === 'str') specs.push({ kind: 'static', specifier: next.v.slice(2), index: i + 1 });
    else if (tk.v === 'import' && next && next.t === 'str') specs.push({ kind: 'static', specifier: next.v.slice(2), index: i + 1 });
    else if ((tk.v === 'require' || tk.v === 'import') && !isMember && next && next.t === 'p' && next.v === '(') {
      const close = tokens[i + 3];
      if (next2 && next2.t === 'str' && close && close.t === 'p' && (close.v === ')' || close.v === ',')) specs.push({ kind: tk.v === 'require' ? 'require' : 'dynamic', specifier: next2.v.slice(2), index: i + 2 });
      else specs.push({ kind: tk.v === 'require' ? 'require' : 'dynamic', specifier: null, index: i });
    }
  }
  return specs;
}
