/**
 * 原生 Markdown 解析。只覆盖 DSH 输出里常见的块：
 * 标题、段落、无序/有序列表、引用、代码块、表格、分隔线；
 * 行内支持 **粗体**、*斜体*、`代码`、~~删除线~~、[链接](url)。
 *
 * 不追求 CommonMark 完整语义；解析失败时退化成纯文本，不丢内容。
 */

export interface MdSpan {
  text: string;
  bold: boolean;
  italic: boolean;
  code: boolean;
  strike: boolean;
  link: boolean;
}

export interface MdItem {
  text: string;
  spans: MdSpan[];
  ordered: boolean;
  marker: string;
  indent: number;
}

export interface MdRow {
  cells: string[];
  header: boolean;
}

export interface MdBlock {
  kind: string;
  level: number;
  text: string;
  spans: MdSpan[];
  lang: string;
  items: MdItem[];
  rows: MdRow[];
}

interface ListLine {
  indent: number;
  ordered: boolean;
  marker: string;
  text: string;
}

function makeSpan(text: string, bold: boolean, italic: boolean, code: boolean, strike: boolean, link: boolean): MdSpan {
  const span: MdSpan = { text: text, bold: bold, italic: italic, code: code, strike: strike, link: link };
  return span;
}

function pushSpan(out: MdSpan[], text: string, bold: boolean, italic: boolean, code: boolean, strike: boolean, link: boolean): void {
  if (text.length === 0) {
    return;
  }
  if (out.length > 0) {
    const last: MdSpan = out[out.length - 1];
    if (last.bold === bold && last.italic === italic && last.code === code && last.strike === strike && last.link === link) {
      last.text += text;
      return;
    }
  }
  out.push(makeSpan(text, bold, italic, code, strike, link));
}

export function parseInline(text: string): MdSpan[] {
  const out: MdSpan[] = [];
  let plain: string = '';
  let i: number = 0;
  const n: number = text.length;

  while (i < n) {
    if (text.startsWith('**', i)) {
      const end: number = text.indexOf('**', i + 2);
      if (end > i + 2) {
        pushSpan(out, plain, false, false, false, false, false);
        plain = '';
        pushSpan(out, text.substring(i + 2, end), true, false, false, false, false);
        i = end + 2;
        continue;
      }
    }
    if (text.startsWith('~~', i)) {
      const end: number = text.indexOf('~~', i + 2);
      if (end > i + 2) {
        pushSpan(out, plain, false, false, false, false, false);
        plain = '';
        pushSpan(out, text.substring(i + 2, end), false, false, false, true, false);
        i = end + 2;
        continue;
      }
    }
    if (text.startsWith('`', i)) {
      const end: number = text.indexOf('`', i + 1);
      if (end > i + 1) {
        pushSpan(out, plain, false, false, false, false, false);
        plain = '';
        pushSpan(out, text.substring(i + 1, end), false, false, true, false, false);
        i = end + 1;
        continue;
      }
    }
    if (text[i] === '[') {
      const closeBracket: number = text.indexOf('](', i + 1);
      if (closeBracket > i + 1) {
        const closeParen: number = text.indexOf(')', closeBracket + 2);
        if (closeParen > closeBracket + 2) {
          pushSpan(out, plain, false, false, false, false, false);
          plain = '';
          pushSpan(out, text.substring(i + 1, closeBracket), false, false, false, false, true);
          i = closeParen + 1;
          continue;
        }
      }
    }
    if (text[i] === '*') {
      const end: number = text.indexOf('*', i + 1);
      if (end > i + 1) {
        pushSpan(out, plain, false, false, false, false, false);
        plain = '';
        pushSpan(out, text.substring(i + 1, end), false, true, false, false, false);
        i = end + 1;
        continue;
      }
    }
    plain += text[i];
    i++;
  }
  pushSpan(out, plain, false, false, false, false, false);
  if (out.length === 0) {
    out.push(makeSpan(text, false, false, false, false, false));
  }
  return out;
}

export function plainInline(text: string): string {
  const spans: MdSpan[] = parseInline(text);
  let out: string = '';
  for (let i = 0; i < spans.length; i++) {
    out += spans[i].text;
  }
  return out;
}

function makeBlock(kind: string): MdBlock {
  const block: MdBlock = {
    kind: kind,
    level: 0,
    text: '',
    spans: [],
    lang: '',
    items: [],
    rows: []
  };
  return block;
}

function isBlank(line: string): boolean {
  return line.trim().length === 0;
}

function isHr(line: string): boolean {
  const t: string = line.trim();
  if (t.length < 3) {
    return false;
  }
  const ch: string = t[0];
  if (ch !== '-' && ch !== '*' && ch !== '_') {
    return false;
  }
  for (let i = 0; i < t.length; i++) {
    if (t[i] !== ch) {
      return false;
    }
  }
  return true;
}

function headingLevel(line: string): number {
  const t: string = line.trim();
  let level: number = 0;
  while (level < t.length && t[level] === '#') {
    level++;
  }
  if (level === 0 || level > 6) {
    return 0;
  }
  if (level < t.length && t[level] !== ' ') {
    return 0;
  }
  return level;
}

function listLine(line: string): ListLine | null {
  const n: number = line.length;
  let i: number = 0;
  while (i < n && line[i] === ' ') {
    i++;
  }
  const indent: number = Math.floor(i / 2);
  if (i >= n) {
    return null;
  }
  const ch: string = line[i];
  if (ch === '-' || ch === '*' || ch === '+') {
    if (i + 1 < n && line[i + 1] === ' ') {
      const text: string = line.substring(i + 2).trim();
      if (text.length > 0) {
        const item: ListLine = { indent: indent, ordered: false, marker: '•', text: text };
        return item;
      }
    }
    return null;
  }
  let j: number = i;
  while (j < n && line[j] >= '0' && line[j] <= '9') {
    j++;
  }
  if (j > i && j < n && (line[j] === '.' || line[j] === ')') && j + 1 < n && line[j + 1] === ' ') {
    const text: string = line.substring(j + 2).trim();
    if (text.length > 0) {
      const item: ListLine = {
        indent: indent,
        ordered: true,
        marker: line.substring(i, j + 1),
        text: text
      };
      return item;
    }
  }
  return null;
}

function isTableSeparator(line: string): boolean {
  const t: string = line.trim();
  if (t.indexOf('|') < 0 || t.indexOf('-') < 0) {
    return false;
  }
  let body: string = t;
  if (body.startsWith('|')) {
    body = body.substring(1);
  }
  if (body.endsWith('|')) {
    body = body.substring(0, body.length - 1);
  }
  const cells: string[] = body.split('|');
  if (cells.length === 0) {
    return false;
  }
  for (let i = 0; i < cells.length; i++) {
    let c: string = cells[i].trim();
    if (c.startsWith(':')) {
      c = c.substring(1);
    }
    if (c.endsWith(':')) {
      c = c.substring(0, c.length - 1);
    }
    if (c.length < 3) {
      return false;
    }
    for (let k = 0; k < c.length; k++) {
      if (c[k] !== '-') {
        return false;
      }
    }
  }
  return true;
}

function splitRow(line: string): string[] {
  let t: string = line.trim();
  if (t.startsWith('|')) {
    t = t.substring(1);
  }
  if (t.endsWith('|')) {
    t = t.substring(0, t.length - 1);
  }
  const parts: string[] = t.split('|');
  const cells: string[] = [];
  for (let i = 0; i < parts.length; i++) {
    cells.push(parts[i].trim());
  }
  return cells;
}

function isBlockStart(lines: string[], i: number): boolean {
  const line: string = lines[i];
  const t: string = line.trim();
  if (t.startsWith('```')) {
    return true;
  }
  if (headingLevel(t) > 0) {
    return true;
  }
  if (isHr(t)) {
    return true;
  }
  if (t.startsWith('>')) {
    return true;
  }
  if (listLine(line) !== null) {
    return true;
  }
  if (t.indexOf('|') >= 0 && i + 1 < lines.length && isTableSeparator(lines[i + 1])) {
    return true;
  }
  return false;
}

export function parseMarkdown(text: string): MdBlock[] {
  const blocks: MdBlock[] = [];
  const normalized: string = text.replace(/\r/g, '');
  const lines: string[] = normalized.split('\n');
  let i: number = 0;

  while (i < lines.length) {
    const line: string = lines[i];
    if (isBlank(line)) {
      i++;
      continue;
    }
    const t: string = line.trim();

    if (t.startsWith('```')) {
      const lang: string = t.substring(3).trim();
      const body: string[] = [];
      i++;
      while (i < lines.length && !lines[i].trim().startsWith('```')) {
        body.push(lines[i]);
        i++;
      }
      if (i < lines.length) {
        i++;
      }
      const block: MdBlock = makeBlock('code');
      block.text = body.join('\n');
      block.lang = lang;
      blocks.push(block);
      continue;
    }

    const level: number = headingLevel(t);
    if (level > 0) {
      let title: string = t.substring(level).trim();
      while (title.endsWith('#')) {
        title = title.substring(0, title.length - 1).trim();
      }
      const block: MdBlock = makeBlock('heading');
      block.level = level;
      block.text = title;
      block.spans = parseInline(title);
      blocks.push(block);
      i++;
      continue;
    }

    if (isHr(t)) {
      blocks.push(makeBlock('hr'));
      i++;
      continue;
    }

    if (t.startsWith('>')) {
      const quote: string[] = [];
      while (i < lines.length && lines[i].trim().startsWith('>')) {
        let q: string = lines[i].trim();
        q = q.substring(1);
        if (q.startsWith(' ')) {
          q = q.substring(1);
        }
        quote.push(q);
        i++;
      }
      const block: MdBlock = makeBlock('quote');
      block.text = quote.join('\n');
      block.spans = parseInline(block.text);
      blocks.push(block);
      continue;
    }

    if (t.indexOf('|') >= 0 && i + 1 < lines.length && isTableSeparator(lines[i + 1])) {
      const header: MdRow = { cells: splitRow(line), header: true };
      const rows: MdRow[] = [header];
      i += 2;
      while (i < lines.length && !isBlank(lines[i]) && lines[i].indexOf('|') >= 0) {
        const row: MdRow = { cells: splitRow(lines[i]), header: false };
        rows.push(row);
        i++;
      }
      const block: MdBlock = makeBlock('table');
      block.rows = rows;
      blocks.push(block);
      continue;
    }

    const firstList: ListLine | null = listLine(line);
    if (firstList !== null) {
      const items: MdItem[] = [];
      while (i < lines.length) {
        const itemLine: ListLine | null = listLine(lines[i]);
        if (itemLine !== null) {
          const item: MdItem = {
            text: itemLine.text,
            spans: parseInline(itemLine.text),
            ordered: itemLine.ordered,
            marker: itemLine.marker,
            indent: itemLine.indent
          };
          items.push(item);
          i++;
          continue;
        }
        if (isBlank(lines[i])) {
          break;
        }
        if (lines[i].startsWith('  ') && items.length > 0) {
          const last: MdItem = items[items.length - 1];
          last.text += ' ' + lines[i].trim();
          last.spans = parseInline(last.text);
          i++;
          continue;
        }
        break;
      }
      const block: MdBlock = makeBlock('list');
      block.items = items;
      blocks.push(block);
      continue;
    }

    const para: string[] = [];
    while (i < lines.length && !isBlank(lines[i]) && !isBlockStart(lines, i)) {
      para.push(lines[i].trim());
      i++;
    }
    if (para.length === 0) {
      para.push(t);
      i++;
    }
    const block: MdBlock = makeBlock('paragraph');
    block.text = para.join('\n');
    block.spans = parseInline(block.text);
    blocks.push(block);
  }

  return blocks;
}
