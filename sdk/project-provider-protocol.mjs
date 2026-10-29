// Bounded native protocol admitted for a user-selected project. This module
// validates data forwarded to the provider; the guest owns tool permissions.
export const PROJECT_EXECUTION_CONTRACT = 'selected-directory-rw/v1';
export const PROJECT_MOUNT = '/home/claude/project';
export const PROJECT_TOOLS = Object.freeze(['Read', 'Write', 'Edit', 'Bash', 'Glob', 'Grep']);
export const PROJECT_SYSTEM_PROMPT = 'You are an assistant working in the user-selected project directory /home/claude/project. Use only the enabled project tools. All commands run inside the isolated VM.';

const TOOL_NAMES = new Set(PROJECT_TOOLS);
const TOOL_ID = /^[A-Za-z0-9_-]{1,128}$/;
// The guest's native request boundary remains 512 KiB, including embedded media.
const MAX_BYTES = 524_288;
const MAX_BLOCKS = 512;
const own = (value, key) => Object.hasOwn(value, key);
const record = value => value !== null && typeof value === 'object' && !Array.isArray(value) &&
  [Object.prototype, null].includes(Object.getPrototypeOf(value));
const fail = () => { const error = new Error('PROJECT_PROTOCOL_REJECTED'); error.code = error.message; throw error; };

function keys(value, allowed, required = []) {
  if (!record(value) || Object.keys(value).some(key => !allowed.includes(key)) ||
      required.some(key => !own(value, key))) fail();
}

function json(value, maximumBytes = MAX_BYTES) {
  let nodes = 0;
  const seen = new Set();
  function visit(item, depth) {
    if (++nodes > 16_384 || depth > 16) fail();
    if (item === null || typeof item === 'boolean' || typeof item === 'string') return;
    if (typeof item === 'number') { if (!Number.isFinite(item)) fail(); return; }
    if (!Array.isArray(item) && !record(item) || seen.has(item)) fail();
    seen.add(item);
    for (const child of Object.values(item)) visit(child, depth + 1);
    seen.delete(item);
  }
  visit(value, 0);
  const serialized = JSON.stringify(value);
  if (Buffer.byteLength(serialized, 'utf8') > maximumBytes) fail();
  return JSON.parse(serialized);
}

function cacheControl(value) {
  if (value === undefined || value === null) return;
  keys(value, ['type', 'ttl', 'scope'], ['type']);
  if (value.type !== 'ephemeral' || value.ttl !== undefined && !['5m', '1h'].includes(value.ttl) ||
      value.scope !== undefined && value.scope !== 'global') fail();
}

function textBlock(block, budget) {
  keys(block, ['type', 'text', 'cache_control'], ['type', 'text']);
  if (block.type !== 'text' || typeof block.text !== 'string' || ++budget.blocks > MAX_BLOCKS) fail();
  cacheControl(block.cache_control);
  return { type: 'text', text: block.text };
}

function mediaBlock(block, budget) {
  keys(block, ['type', 'source', 'cache_control'], ['type', 'source']);
  if (!['image', 'document'].includes(block.type) || ++budget.blocks > MAX_BLOCKS) fail();
  const source = block.source;
  keys(source, ['type', 'media_type', 'data'], ['type', 'media_type', 'data']);
  const mediaTypes = block.type === 'image' ? ['image/png', 'image/jpeg', 'image/gif', 'image/webp'] : ['application/pdf'];
  if (source.type !== 'base64' || !mediaTypes.includes(source.media_type) ||
      typeof source.data !== 'string' || !source.data.length || source.data.length > MAX_BYTES ||
      !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(source.data) ||
      Buffer.from(source.data, 'base64').toString('base64') !== source.data) fail();
  cacheControl(block.cache_control);
  // Only inline data is forwarded. URL sources would introduce a separate
  // network fetch outside the selected-directory and broker contracts.
  return { type: block.type, source: { type: 'base64', media_type: source.media_type, data: source.data } };
}

// The input remains opaque JSON here so official optional input fields are not
// guessed. The guest applies the tool-specific path and process restrictions.
export function validateProjectToolInput(name, input) {
  if (!TOOL_NAMES.has(name) || !record(input)) fail();
  return json(input, 262_144);
}

function toolDefinitions(value) {
  if (!Array.isArray(value) || value.length !== PROJECT_TOOLS.length) fail();
  const names = new Set();
  return value.map(tool => {
    keys(tool, ['name', 'description', 'input_schema', 'cache_control'], ['name', 'input_schema']);
    if (!TOOL_NAMES.has(tool.name) || names.has(tool.name) ||
        tool.description !== undefined && (typeof tool.description !== 'string' ||
          Buffer.byteLength(tool.description, 'utf8') > 65_536)) fail();
    names.add(tool.name);
    const schema = tool.input_schema;
    keys(schema, ['type', 'properties', 'required', 'additionalProperties', '$schema'], ['type']);
    if (schema.type !== 'object' || schema.properties !== undefined && !record(schema.properties) ||
        schema.required !== undefined && (!Array.isArray(schema.required) ||
          schema.required.some(key => typeof key !== 'string' || !own(schema.properties ?? {}, key)) ||
          new Set(schema.required).size !== schema.required.length) ||
        schema.additionalProperties !== undefined && typeof schema.additionalProperties !== 'boolean' &&
          !record(schema.additionalProperties) ||
        schema.$schema !== undefined && typeof schema.$schema !== 'string') fail();
    cacheControl(tool.cache_control);
    return { name: tool.name, ...(tool.description === undefined ? {} : { description: tool.description }),
      input_schema: json(schema, 65_536) };
  });
}

function systemEnvelope(message, budget) {
  keys(message, ['role', 'content', 'output_config'], ['role', 'content']);
  if (!Array.isArray(message.content) || message.content.length !== 1) fail();
  const block = textBlock(message.content[0], budget);
  if (block.text.length < 1 || block.text.length > 2048) fail();
  if (message.output_config !== undefined) {
    keys(message.output_config, ['effort'], ['effort']);
    if (!['low', 'medium', 'high', 'max'].includes(message.output_config.effort)) fail();
  }
}

function toolUse(block, ids, pending, budget) {
  keys(block, ['type', 'id', 'name', 'input', 'caller', 'cache_control'], ['type', 'id', 'name', 'input']);
  if (typeof block.id !== 'string' || !TOOL_ID.test(block.id) || ids.has(block.id) || ++budget.blocks > MAX_BLOCKS) fail();
  const input = validateProjectToolInput(block.name, block.input);
  // Official Anthropic ToolUseBlockParam admits caller; only direct calls belong
  // to this contract, never server-side code execution or additional toolsets.
  if (block.caller !== undefined) {
    keys(block.caller, ['type'], ['type']);
    if (block.caller.type !== 'direct') fail();
  }
  cacheControl(block.cache_control);
  ids.add(block.id);
  pending.add(block.id);
  return { type: 'tool_use', id: block.id, name: block.name, input,
    ...(block.caller === undefined ? {} : { caller: { type: 'direct' } }) };
}

function toolResult(block, pending, budget) {
  keys(block, ['type', 'tool_use_id', 'content', 'is_error', 'cache_control'], ['type', 'tool_use_id', 'content']);
  if (typeof block.tool_use_id !== 'string' || !pending.has(block.tool_use_id) ||
      block.is_error !== undefined && typeof block.is_error !== 'boolean' || ++budget.blocks > MAX_BLOCKS) fail();
  let content;
  if (typeof block.content === 'string') content = block.content;
  else {
    if (!Array.isArray(block.content) || block.content.length > 64) fail();
    content = block.content.map(item => item?.type === 'text' ? textBlock(item, budget) : mediaBlock(item, budget));
  }
  cacheControl(block.cache_control);
  pending.delete(block.tool_use_id);
  return { type: 'tool_result', tool_use_id: block.tool_use_id, content,
    ...(block.is_error === undefined ? {} : { is_error: block.is_error }) };
}

export function projectProviderMessages(localBody, configuration) {
  if (!record(localBody) || !Array.isArray(localBody.messages) ||
      localBody.messages.length < 1 || localBody.messages.length > 100) fail();
  // Bound both native definitions and the entire current-turn chain before
  // retaining any of its content. App history was validated by validateInput.
  json({ tools: localBody.tools, messages: localBody.messages });
  const tools = toolDefinitions(localBody.tools);
  const budget = { blocks: 0 };
  const first = localBody.messages[0];
  keys(first, ['role', 'content'], ['role', 'content']);
  if (first.role !== 'user') fail();
  let prompt;
  if (typeof first.content === 'string') prompt = first.content;
  else {
    if (!Array.isArray(first.content) || first.content.length !== 1) fail();
    prompt = textBlock(first.content[0], budget).text;
  }
  if (typeof configuration.messages?.at(-1)?.text !== 'string' || prompt !== configuration.messages.at(-1).text) fail();
  const current = [{ role: 'user', content: prompt }];
  const ids = new Set(), pending = new Set();
  let expectedRole = 'assistant';
  for (const message of localBody.messages.slice(1)) {
    if (message?.role === 'system') { systemEnvelope(message, budget); continue; }
    keys(message, ['role', 'content'], ['role', 'content']);
    if (message.role !== expectedRole || !Array.isArray(message.content) ||
        message.content.length < 1 || message.content.length > 64) fail();
    if (message.role === 'assistant') {
      const content = message.content.map(block => {
        if (block?.type === 'text') return textBlock(block, budget);
        if (block?.type === 'tool_use') return toolUse(block, ids, pending, budget);
        fail();
      });
      // A new provider request can only follow a completed native tool turn.
      if (pending.size === 0) fail();
      current.push({ role: 'assistant', content });
      expectedRole = 'user';
    } else {
      const content = message.content.map(block => {
        if (block?.type !== 'tool_result') fail();
        return toolResult(block, pending, budget);
      });
      if (pending.size !== 0) fail();
      current.push({ role: 'user', content });
      expectedRole = 'assistant';
    }
  }
  if (pending.size !== 0 || expectedRole !== 'assistant') fail();
  return { tools, messages: [...configuration.messages.slice(0, -1)
    .map(message => ({ role: message.role, content: message.text })), ...current] };
}
