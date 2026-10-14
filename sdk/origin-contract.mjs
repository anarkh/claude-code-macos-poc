// App-owned input receipts. A receipt is an authorization correlation value,
// not a CLI-provided author identity and not an account/region claim.
import { createHash, randomBytes, randomUUID } from 'node:crypto';

export function canonical(value) {
  if (value === null || typeof value !== 'object') return JSON.stringify(value) ?? '<undefined>';
  if (Array.isArray(value)) return `[${value.map(canonical).join(',')}]`;
  return `{${Object.keys(value).sort().map(k => `${JSON.stringify(k)}:${canonical(value[k])}`).join(',')}}`;
}
export const inputHash = value => createHash('sha256').update(canonical(value)).digest('hex');
const REQUIRED_HOOKS = ['UserPromptSubmit', 'PreToolUse', 'Stop', 'StopFailure'];
const FORBIDDEN_TOOLS = /^(Agent|Task|Cron|Schedule|SendMessage|TeamCreate|TeamDelete|mcp__)/;
const denyHook = reason => ({ hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: reason } });

export class OriginContract {
  constructor({ requestId = randomUUID(), revision = 1, clientUuid = randomUUID(), epoch = randomUUID(), expectedSession, body, approvedTools = ['Write', 'AskUserQuestion'] }) {
    const nonce = randomBytes(32).toString('base64url');
    if (![requestId, clientUuid, epoch, nonce].every(v => typeof v === 'string' && v.length > 0) || !Number.isInteger(revision) || revision < 1 || typeof body !== 'string') throw new TypeError('Invalid trusted App registration');
    this.registration = Object.freeze({ request_id: requestId, revision, client_uuid: clientUuid, cli_epoch: epoch, nonce, expected_session: expectedSession ?? null, body_sha256: inputHash(body) });
    this.prompt = `<app-input-receipt>${JSON.stringify(this.registration)}</app-input-receipt>\n${body}`;
    this.clientUuid = clientUuid;
    this.epoch = epoch;
    this.approvedTools = new Set(approvedTools);
    this.state = 'issued';
    this.session = expectedSession;
    this.promptId = undefined;
    this.handshake = false;
    this.init = false;
    this.toolTickets = new Map();
    this.permissions = new Map();
    this.usedRequestIds = new Set();
    this.audit = [];
  }
  log(kind, detail) { this.audit.push({ kind, at: Date.now(), ...detail }); }
  seal(reason) {
    if (this.state !== 'sealed') this.log('sealed', { reason, previous_state: this.state });
    this.state = 'sealed';
    this.sealedReason ??= reason;
    this.toolTickets.clear();
    this.permissions.clear();
  }
  reject(reason) { this.log('rejected', { reason }); this.seal(reason); return reason; }
  markHandshake({ hooksApplied, hookEvents, permissionMode, settingSourcesVerified }) {
    if (this.state === 'sealed') return false;
    const valid = hooksApplied === true && REQUIRED_HOOKS.every(k => hookEvents.includes(k)) && permissionMode === 'default' && settingSourcesVerified === true;
    this.log('handshake', { valid, hooksApplied, hookEvents, permissionMode, settingSourcesVerified });
    if (!valid) { this.reject('initialize_or_hook_policy_mismatch'); return false; }
    this.handshake = true;
    return true;
  }
  markInit(input, expectedCwd) {
    if (this.state === 'sealed') return false;
    const valid = typeof input.session_id === 'string' && input.session_id.length > 0 && (!this.session || input.session_id === this.session) && input.permissionMode === 'default' && input.claude_code_version === '2.1.295' && input.apiKeySource === 'ANTHROPIC_API_KEY' && input.cwd === expectedCwd && Array.isArray(input.mcp_servers) && input.mcp_servers.length === 0 && Array.isArray(input.tools) && input.tools.every(t => this.approvedTools.has(t) && !FORBIDDEN_TOOLS.test(t));
    this.log('native_init', { valid, session_id: input.session_id, permissionMode: input.permissionMode, version: input.claude_code_version, cwd: input.cwd });
    if (!valid) { this.reject('native_init_policy_mismatch'); return false; }
    this.session = input.session_id;
    this.init = true;
    return true;
  }
  onUserPrompt(input) {
    const reasons = [];
    if (this.state !== 'issued') reasons.push('receipt_not_issued_or_already_consumed');
    if (input.prompt !== this.prompt) reasons.push('exact_prompt_receipt_mismatch');
    if (typeof input.prompt_id !== 'string' || !input.prompt_id) reasons.push('native_prompt_id_missing');
    if (typeof input.session_id !== 'string' || !input.session_id || (this.session && input.session_id !== this.session)) reasons.push('native_session_mismatch');
    if (Object.hasOwn(input, 'source') && input.source !== 'sdk') reasons.push('native_source_not_sdk');
    if (input.agent_id) reasons.push('subagent_prompt_forbidden');
    this.log('user_prompt', { source_present: Object.hasOwn(input, 'source'), ...(Object.hasOwn(input, 'source') ? { source: input.source } : {}), session_id: input.session_id, prompt_id: input.prompt_id, prompt_sha256: inputHash(input.prompt), decision: reasons.length ? 'block' : 'consume', reasons });
    if (reasons.length) return { decision: 'block', reason: this.reject(reasons.join(',')) };
    this.state = 'consumed';
    this.session = input.session_id;
    this.promptId = input.prompt_id;
    return {};
  }
  bindingValid(input) { return this.state === 'consumed' && this.handshake && this.init && input.session_id === this.session && typeof input.prompt_id === 'string' && input.prompt_id === this.promptId && !input.agent_id; }
  onPreTool(input) {
    const valid = this.bindingValid(input) && typeof input.tool_use_id === 'string' && input.tool_use_id.length > 0 && this.approvedTools.has(input.tool_name) && input.tool_input !== null && typeof input.tool_input === 'object' && !FORBIDDEN_TOOLS.test(input.tool_name) && !this.toolTickets.has(input.tool_use_id);
    const detail = { valid, session_id: input.session_id, prompt_id: input.prompt_id, tool_use_id: input.tool_use_id, tool_name: input.tool_name, input_sha256: inputHash(input.tool_input), epoch: this.epoch };
    this.log('pre_tool', detail);
    if (!valid) { this.reject('pre_tool_prompt_or_policy_binding_mismatch'); return denyHook('App receipt/tool binding mismatch; epoch sealed'); }
    this.toolTickets.set(input.tool_use_id, Object.freeze({ ...detail, original_input: structuredClone(input.tool_input), status: 'pre_registered' }));
    return { hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'ask', permissionDecisionReason: 'Registered App input; explicit per-call decision required' } };
  }
  beginPermission(toolName, input, options) {
    const ticket = this.toolTickets.get(options.toolUseID);
    const valid = this.state === 'consumed' && this.handshake && this.init && typeof options.signal?.aborted === 'boolean' && !options.signal.aborted && !options.agentID && !options.mcpServer && typeof options.requestId === 'string' && options.requestId.length > 0 && !this.usedRequestIds.has(options.requestId) && ticket && ticket.epoch === this.epoch && ticket.session_id === this.session && ticket.prompt_id === this.promptId && ticket.tool_name === toolName && ticket.input_sha256 === inputHash(input);
    this.log('permission_join', { valid: !!valid, request_id: options.requestId, tool_use_id: options.toolUseID, tool_name: toolName, input_sha256: inputHash(input), joined_native_prompt_id: valid ? ticket.prompt_id : null });
    if (!valid) { this.reject('permission_without_exact_current_pre_tool_ticket'); return undefined; }
    this.toolTickets.delete(options.toolUseID);
    this.usedRequestIds.add(options.requestId);
    const pending = Object.freeze({ ...ticket, request_id: options.requestId, tool_use_id: options.toolUseID, signal: options.signal });
    this.permissions.set(options.requestId, pending);
    return pending;
  }
  resolvePermission(requestId, { behavior, updatedInput } = {}) {
    const pending = this.permissions.get(requestId);
    this.permissions.delete(requestId);
    const valid = pending && this.state === 'consumed' && this.handshake && this.init && !pending.signal?.aborted && pending.epoch === this.epoch && pending.session_id === this.session && pending.prompt_id === this.promptId && ['allow', 'deny'].includes(behavior);
    this.log('permission_resolution', { valid: !!valid, request_id: requestId, behavior: valid ? behavior : 'deny', tool_use_id: pending?.tool_use_id });
    if (!valid || behavior === 'deny') return { behavior: 'deny', message: valid ? 'Explicit one-call fixture/UI denial' : 'Stale or invalid App approval', ...(pending ? { toolUseID: pending.tool_use_id } : {}) };
    if (!updatedInput || typeof updatedInput !== 'object') return { behavior: 'deny', message: 'Missing exact approved input', toolUseID: pending.tool_use_id };
    const stripped = { ...updatedInput };
    if (pending.tool_name === 'AskUserQuestion') delete stripped.answers;
    const unchanged = inputHash(pending.tool_name === 'AskUserQuestion' ? stripped : updatedInput) === pending.input_sha256;
    const answersValid = pending.tool_name !== 'AskUserQuestion' || (updatedInput.answers && Object.entries(updatedInput.answers).every(([question, answer]) => pending.original_input.questions.some(q => q.question === question && q.options.some(o => o.label === answer))));
    if (!unchanged || !answersValid) { this.reject('approval_changed_tool_input'); return { behavior: 'deny', message: 'Approval may not change a tool operation', toolUseID: pending.tool_use_id }; }
    return { behavior: 'allow', updatedInput, toolUseID: pending.tool_use_id };
  }
  async onCanUseTool(toolName, input, options, { fixtureDecision, updatedInput = input, beforeDecision } = {}) {
    const pending = this.beginPermission(toolName, input, options);
    if (!pending) return { behavior: 'deny', message: 'No current registered tool ticket', toolUseID: options.toolUseID };
    // This wrapper is only for a declared test fixture. Production UI uses
    // beginPermission/resolvePermission and must supply authenticated approval.
    if (beforeDecision) await beforeDecision(pending);
    this.log('fixture_only_decision', { request_id: options.requestId, behavior: fixtureDecision ?? 'deny', fixture: true });
    return this.resolvePermission(options.requestId, { behavior: fixtureDecision ?? 'deny', updatedInput });
  }
  snapshot() { return { registration_owner: 'trusted_App_controller', receipt_role: 'one-time correlation value; visible to model and not an independent secret credential', security_prerequisites: ['one pinned CLI process per epoch', 'trusted controller owns input and permission control channel', 'native CLI/work processes cannot read controller memory or forge its control FDs', 'kernel scope lifecycle and PID identity enforced outside this module'], registration: this.registration, prompt_sha256: inputHash(this.prompt), state: this.state, sealed_reason: this.sealedReason, session_id: this.session, actual_prompt_id: this.promptId, handshake_verified: this.handshake, init_verified: this.init, pending_tool_count: this.toolTickets.size, pending_permission_count: this.permissions.size, audit: this.audit }; }
}
