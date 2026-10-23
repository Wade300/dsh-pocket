import {
  AcpContent, AiChoice, AiConfigOption, ChatMessage, HistoryMessage, RawConfigChoice, RawConfigOption, UsageInfo
} from './Models';

export interface ContentBlock {
  code: boolean;
  text: string;
}

export function contentText(content: AcpContent | AcpContent[] | undefined): string {
  if (content === undefined) {
    return '';
  }
  if (Array.isArray(content)) {
    let out: string = '';
    for (let i = 0; i < content.length; i++) {
      out += contentText(content[i]);
    }
    return out;
  }
  if (content.type === 'text' && content.text !== undefined) {
    return content.text;
  }
  if (content.content !== undefined) {
    return contentText(content.content);
  }
  return '';
}

export function splitCodeBlocks(text: string): ContentBlock[] {
  const blocks: ContentBlock[] = [];
  const lines: string[] = text.split('\n');
  let buffer: string = '';
  let inCode: boolean = false;

  const flush = (): void => {
    if (buffer.length > 0) {
      blocks.push({ code: inCode, text: buffer });
      buffer = '';
    }
  };

  for (let i = 0; i < lines.length; i++) {
    const line: string = lines[i];
    if (line.trim().startsWith('```')) {
      flush();
      inCode = !inCode;
      continue;
    }
    buffer += line;
    buffer += '\n';
  }
  flush();
  if (blocks.length === 0 && text.length > 0) {
    blocks.push({ code: false, text: text });
  }
  return blocks;
}

export function flattenChoices(raw: RawConfigChoice[], group: string): AiChoice[] {
  const out: AiChoice[] = [];
  for (let i = 0; i < raw.length; i++) {
    const item: RawConfigChoice = raw[i];
    if (item.options !== undefined && item.options.length > 0) {
      const name: string = item.group !== undefined ? item.group : (item.name !== undefined ? item.name : group);
      const nested: AiChoice[] = flattenChoices(item.options, name);
      for (let j = 0; j < nested.length; j++) {
        out.push(nested[j]);
      }
      continue;
    }
    const value: string = item.value !== undefined ? item.value : '';
    if (value.length === 0) {
      continue;
    }
    const choice: AiChoice = {
      value: value,
      name: item.name !== undefined ? item.name : value,
      description: item.description !== undefined ? item.description : '',
      group: group
    };
    out.push(choice);
  }
  return out;
}

export function parseConfigOptions(raw: RawConfigOption[]): AiConfigOption[] {
  const out: AiConfigOption[] = [];
  for (let i = 0; i < raw.length; i++) {
    const r: RawConfigOption = raw[i];
    const option: AiConfigOption = {
      id: r.id,
      name: r.name,
      category: r.category,
      currentValue: r.currentValue,
      choices: flattenChoices(r.options !== undefined ? r.options : [], '')
    };
    out.push(option);
  }
  return out;
}

export function findPreferredModel(options: AiConfigOption[]): string {
  for (let i = 0; i < options.length; i++) {
    if (options[i].id !== 'model') {
      continue;
    }
    const choices: AiChoice[] = options[i].choices;
    let account: string = '';
    for (let j = 0; j < choices.length; j++) {
      const value: string = choices[j].value;
      if (value.indexOf('deepseek-account') >= 0) {
        if (value.indexOf('flash') >= 0) {
          return value;
        }
        if (account.length === 0) {
          account = value;
        }
      }
    }
    if (account.length > 0) {
      return account;
    }
  }
  return '';
}

export function currentModelName(options: AiConfigOption[]): string {
  for (let i = 0; i < options.length; i++) {
    if (options[i].id !== 'model') {
      continue;
    }
    const option: AiConfigOption = options[i];
    for (let j = 0; j < option.choices.length; j++) {
      if (option.choices[j].value === option.currentValue) {
        return option.choices[j].name;
      }
    }
    return option.currentValue.length > 0 ? option.currentValue : '模型';
  }
  return '模型';
}

export function usageLabel(usage: UsageInfo): string {
  const total: number = usage.totalTokens !== undefined ? usage.totalTokens : 0;
  if (total <= 0) {
    return '';
  }
  if (total >= 1000) {
    return `${Math.round(total / 100) / 10}k tokens`;
  }
  return `${total} tokens`;
}

export function shortCwd(cwd: string): string {
  if (cwd.length === 0) {
    return '未设置目录';
  }
  const normalized: string = cwd.replace(/\\/g, '/');
  const parts: string[] = normalized.split('/');
  for (let i = parts.length - 1; i >= 0; i--) {
    if (parts[i].length > 0) {
      return parts[i];
    }
  }
  return cwd;
}

export function shortSessionId(id: string): string {
  if (id.length <= 10) {
    return id;
  }
  return id.substring(id.length - 8);
}

export function newMessage(role: string): ChatMessage {
  const msg: ChatMessage = {
    id: `${role}-${Date.now()}-${Math.floor(Math.random() * 100000)}`,
    role: role,
    text: '',
    reasoning: '',
    toolName: '',
    toolArgs: '',
    toolText: '',
    callId: '',
    status: '',
    at: Date.now(),
    expanded: false,
    streaming: false,
    usage: '',
    rev: 0
  };
  return msg;
}

export function copyMessage(m: ChatMessage): ChatMessage {
  const c: ChatMessage = {
    id: m.id,
    role: m.role,
    text: m.text,
    reasoning: m.reasoning,
    toolName: m.toolName,
    toolArgs: m.toolArgs,
    toolText: m.toolText,
    callId: m.callId,
    status: m.status,
    at: m.at,
    expanded: m.expanded,
    streaming: m.streaming,
    usage: m.usage,
    rev: m.rev + 1
  };
  return c;
}

export function fromHistory(h: HistoryMessage): ChatMessage {
  const msg: ChatMessage = newMessage(h.role);
  msg.text = h.text !== undefined ? h.text : '';
  msg.reasoning = h.reasoning !== undefined ? h.reasoning : '';
  msg.toolName = h.toolName !== undefined ? h.toolName : '';
  msg.toolArgs = h.args !== undefined ? h.args : '';
  msg.toolText = h.text !== undefined && h.role === 'tool' ? h.text : '';
  msg.callId = h.callId !== undefined ? h.callId : '';
  msg.status = h.status !== undefined ? h.status : '';
  msg.at = h.at !== undefined ? h.at : Date.now();
  if (h.usage !== undefined) {
    msg.usage = usageLabel(h.usage);
  }
  return msg;
}

export function clampText(text: string, limit: number): string {
  if (text.length <= limit) {
    return text;
  }
  return text.substring(0, limit) + '\n…（已截断）';
}

export function timeLabel(at: number): string {
  if (at <= 0) {
    return '';
  }
  const d: Date = new Date(at);
  const h: number = d.getHours();
  const m: number = d.getMinutes();
  const hh: string = h < 10 ? '0' + h : '' + h;
  const mm: string = m < 10 ? '0' + m : '' + m;
  return hh + ':' + mm;
}
