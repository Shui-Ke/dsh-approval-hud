import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { request } from 'node:http'
import { join } from 'node:path'
import { test } from 'node:test'

import {
  ApprovalHud,
  cleanText,
  apply,
  name,
  normalizeConfig,
} from '../lib/index.mjs'

/** Minimal Cordis context double. */
function fakeContext() {
  const handlers = new Map()
  return {
    handlers,
    logger: { warn() {} },
    on(event, listener, options) {
      handlers.set(event, { listener, options })
    },
    effect(factory) {
      this.disposeEffect = factory()
    },
  }
}

/** Fake PowerShell child process. */
function fakeChild() {
  const callbacks = new Map()
  const stdin = {
    writes: [],
    ended: false,
    write(chunk) { this.writes.push(String(chunk)) },
    end() { this.ended = true },
  }
  return {
    pid: 4242,
    killed: false,
    stdin,
    stdout: { on() {} },
    stderr: { on() {} },
    on(event, callback) {
      callbacks.set(event, callback)
    },
    emit(event, ...args) {
      callbacks.get(event)?.(...args)
    },
    kill() {
      this.killed = true
    },
  }
}

/** One JSON request to the HUD server. */
function call(port, path, { method = 'GET', token, body, origin } = {}) {
  return new Promise((resolve, reject) => {
    const data = body === undefined ? undefined : Buffer.from(JSON.stringify(body), 'utf8')
    const headers = {}
    if (token !== undefined) headers['x-dsh-approval-token'] = token
    if (origin !== undefined) headers.origin = origin
    if (data !== undefined) {
      headers['content-type'] = 'application/json'
      headers['content-length'] = data.length
    }
    const req = request({ host: '127.0.0.1', port, path, method, headers }, (res) => {
      let text = ''
      res.setEncoding('utf8')
      res.on('data', (chunk) => { text += chunk })
      res.on('end', () => {
        let json
        try { json = text === '' ? null : JSON.parse(text) } catch { json = text }
        resolve({ status: res.statusCode, body: json })
      })
    })
    req.on('error', reject)
    if (data !== undefined) req.write(data)
    req.end()
  })
}

/** Build one approval request. */
function approval(overrides = {}) {
  const controller = new AbortController()
  return {
    controller,
    request: {
      toolName: 'pwsh',
      reason: 'Need to run a command with elevated permissions.',
      agent: {
        session: {
          id: 'session-abcdef123456',
          header: { cwd: 'C:\\work\\demo', origin: 'subagent' },
        },
      },
      signal: controller.signal,
      ...overrides,
    },
  }
}

/** Build a root (non-subagent) approval request. */
function rootApproval(overrides = {}) {
  return approval({
    agent: {
      session: {
        id: 'session-root123456',
        header: { cwd: 'C:\\work\\demo' },
      },
    },
    ...overrides,
  })
}

/** Start a HUD with a fake UI and mark it ready. */
async function startHud(options = {}) {
  const ctx = fakeContext()
  const child = fakeChild()
  const spawnCalls = []
  const config = normalizeConfig({ debug: false, ...options })
  const hud = new ApprovalHud(ctx, config, {
    platform: 'win32',
    spawnUi: (command, args, options_) => {
      spawnCalls.push({ command, args, options: options_ })
      return child
    },
    auditDir: join(process.cwd(), 'tests', '.tmp-audit'),
  })
  await hud.serverPromise
  hud.markReady()
  return { ctx, child, hud, spawnCalls }
}

test('normalizeConfig clamps invalid values', () => {
  const config = normalizeConfig({
    position: 'somewhere',
    idleMode: 'always',
    language: 'fr',
    maxReasonChars: 1,
    startupTimeoutMs: 1,
    sound: 0,
    autoApproveMinutes: 0,
    autoApproveOptions: [10, 10, 0, 500, 'x', 30],
    keepAwakeDuringAutoApprove: 0,
    autoApproveSubagents: 0,
    autoApproveDenyPatterns: ['x', 3, 'y'],
  })
  assert.equal(config.position, 'bottom-right')
  assert.equal(config.idleMode, 'hide')
  assert.equal(config.language, 'zh')
  assert.equal(config.maxReasonChars, 120)
  assert.equal(config.startupTimeoutMs, 3000)
  assert.equal(config.sound, false)
  assert.equal(config.followVirtualDesktop, true)
  assert.equal(config.keepTopmost, true)
  assert.equal(config.autoApproveMinutes, 1)
  assert.deepEqual(config.autoApproveOptions, [10, 30])
  assert.equal(config.keepAwakeDuringAutoApprove, false)
  assert.equal(config.autoApproveSubagents, false)
  assert.deepEqual(config.autoApproveDenyPatterns, ['x', 'y'])
})

test('cleanText collapses and truncates long reasons', () => {
  const short = cleanText('  a\r\n\r\n\r\nb  ', 100)
  assert.equal(short.text, 'a\n\nb')
  assert.equal(short.truncated, false)
  const long = cleanText('x'.repeat(200), 120)
  assert.equal(long.truncated, true)
  assert.equal(long.text.length, 121)
  assert.ok(long.text.endsWith('…'))
  assert.deepEqual(cleanText(undefined, 10), { text: '', truncated: false })
})

test('apply prepends the approval listener', () => {
  const ctx = fakeContext()
  const child = fakeChild()
  apply(ctx, { debug: false }, { platform: 'win32', spawnUi: () => child })
  const entry = ctx.handlers.get('approval/request')
  assert.equal(entry.options.prepend, true)
  assert.equal(typeof entry.listener, 'function')
  ctx.disposeEffect()
})

test('allow once answers the approval and clears pending state', async () => {
  const { hud } = await startHud()
  try {
    const { request: req } = approval()
    const outcome = hud.handle(req, async () => 'unavailable')
    const state = await call(hud.port, `/state?token=${hud.token}`, { token: hud.token })
    assert.equal(state.status, 200)
    assert.equal(state.body.pending.length, 1)
    assert.equal(state.body.pending[0].toolName, 'pwsh')
    assert.equal(state.body.pending[0].project, 'demo')
    assert.equal(state.body.pending[0].subagent, true)
    assert.equal(state.body.pending[0].sessionId, 'ef123456')
    const answer = await call(hud.port, '/answer', {
      method: 'POST',
      token: hud.token,
      body: { id: state.body.pending[0].id, decision: 'allow' },
    })
    assert.deepEqual(answer.body, { ok: true })
    assert.equal(await outcome, 'allowed-once')
    const after = await call(hud.port, `/state?token=${hud.token}`, { token: hud.token })
    assert.equal(after.body.pending.length, 0)
  } finally {
    hud.dispose()
  }
})

test('reject answers the approval with rejected', async () => {
  const { hud } = await startHud()
  try {
    const { request: req } = approval()
    const outcome = hud.handle(req, async () => 'unavailable')
    const state = await call(hud.port, `/state?token=${hud.token}`, { token: hud.token })
    await call(hud.port, '/answer', {
      method: 'POST',
      token: hud.token,
      body: { id: state.body.pending[0].id, decision: 'reject' },
    })
    assert.equal(await outcome, 'rejected')
  } finally {
    hud.dispose()
  }
})

test('delegate hands the request to the next answerer', async () => {
  const { hud } = await startHud()
  try {
    const { request: req } = approval({ toolName: 'write', reason: undefined })
    let nextCalls = 0
    const outcome = hud.handle(req, async () => {
      nextCalls += 1
      return 'rejected'
    })
    const state = await call(hud.port, `/state?token=${hud.token}`, { token: hud.token })
    assert.equal(state.body.pending[0].reason, '')
    await call(hud.port, '/answer', {
      method: 'POST',
      token: hud.token,
      body: { id: state.body.pending[0].id, decision: 'delegate' },
    })
    assert.equal(await outcome, 'rejected')
    assert.equal(nextCalls, 1)
  } finally {
    hud.dispose()
  }
})

test('aborting the request settles as cancelled and removes it', async () => {
  const { hud } = await startHud()
  try {
    const { controller, request: req } = approval()
    const outcome = hud.handle(req, async () => 'unavailable')
    const state = await call(hud.port, `/state?token=${hud.token}`, { token: hud.token })
    assert.equal(state.body.pending.length, 1)
    controller.abort()
    assert.equal(await outcome, 'cancelled')
    const after = await call(hud.port, `/state?token=${hud.token}`, { token: hud.token })
    assert.equal(after.body.pending.length, 0)
  } finally {
    hud.dispose()
  }
})

test('requests delegate immediately while the UI is not ready', async () => {
  const ctx = fakeContext()
  const child = fakeChild()
  const hud = new ApprovalHud(ctx, normalizeConfig({ debug: false }), {
    platform: 'win32',
    spawnUi: () => child,
  })
  await hud.serverPromise
  try {
    const { request: req } = approval()
    let nextCalls = 0
    const outcome = await hud.handle(req, async () => {
      nextCalls += 1
      return 'unavailable'
    })
    assert.equal(outcome, 'unavailable')
    assert.equal(nextCalls, 1)
  } finally {
    hud.dispose()
  }
})

test('a UI exit delegates pending requests', async () => {
  const { child, hud } = await startHud()
  try {
    const { request: req } = approval()
    let nextCalls = 0
    const outcome = hud.handle(req, async () => {
      nextCalls += 1
      return 'unavailable'
    })
    child.emit('exit', 1)
    assert.equal(await outcome, 'unavailable')
    assert.equal(nextCalls, 1)
  } finally {
    hud.dispose()
  }
})

test('the UI token arrives over stdin, never on the command line', async () => {
  const { hud, child, spawnCalls } = await startHud()
  try {
    assert.equal(spawnCalls.length, 1)
    assert.equal(spawnCalls[0].args.includes('-Token'), false)
    assert.equal(spawnCalls[0].args.includes(hud.token), false)
    assert.equal(spawnCalls[0].options.stdio[0], 'pipe')
    assert.deepEqual(child.stdin.writes, [`${hud.token}\n`])
    assert.equal(child.stdin.ended, true)
  } finally {
    hud.dispose()
  }
})

test('the loopback API requires the token and rejects browser origins', async () => {
  const { hud } = await startHud()
  try {
    const missing = await call(hud.port, '/state')
    assert.equal(missing.status, 403)
    const wrong = await call(hud.port, '/answer', {
      method: 'POST',
      token: 'wrong',
      body: { id: 'x', decision: 'allow' },
    })
    assert.equal(wrong.status, 403)
    const origin = await call(hud.port, `/state?token=${hud.token}`, {
      token: hud.token,
      origin: 'https://example.com',
    })
    assert.equal(origin.status, 403)
  } finally {
    hud.dispose()
  }
})

test('unknown ids answer gone and bad decisions are refused', async () => {
  const { hud } = await startHud()
  try {
    const gone = await call(hud.port, '/answer', {
      method: 'POST',
      token: hud.token,
      body: { id: 'does-not-exist', decision: 'allow' },
    })
    assert.equal(gone.status, 409)
    assert.equal(gone.body.code, 'gone')

    const { controller, request: req } = approval()
    const outcome = hud.handle(req, async () => 'unavailable')
    const state = await call(hud.port, `/state?token=${hud.token}`, { token: hud.token })
    const bad = await call(hud.port, '/answer', {
      method: 'POST',
      token: hud.token,
      body: { id: state.body.pending[0].id, decision: 'maybe' },
    })
    assert.equal(bad.status, 409)
    assert.equal(bad.body.code, 'bad-decision')
    assert.equal(state.body.pending.length, 1)
    controller.abort()
    assert.equal(await outcome, 'cancelled')
  } finally {
    hud.dispose()
  }
})

test('two pending requests are answered in arrival order', async () => {
  const { hud } = await startHud()
  try {
    const first = approval({ toolName: 'pwsh' })
    const second = approval({ toolName: 'write' })
    const firstOutcome = hud.handle(first.request, async () => 'unavailable')
    const secondOutcome = hud.handle(second.request, async () => 'unavailable')
    const state = await call(hud.port, `/state?token=${hud.token}`, { token: hud.token })
    assert.equal(state.body.pending.length, 2)
    assert.equal(state.body.pending[0].toolName, 'pwsh')
    assert.equal(state.body.pending[1].toolName, 'write')
    await call(hud.port, '/answer', {
      method: 'POST',
      token: hud.token,
      body: { id: state.body.pending[0].id, decision: 'allow' },
    })
    assert.equal(await firstOutcome, 'allowed-once')
    const next = await call(hud.port, `/state?token=${hud.token}`, { token: hud.token })
    assert.equal(next.body.pending.length, 1)
    assert.equal(next.body.pending[0].toolName, 'write')
    await call(hud.port, '/answer', {
      method: 'POST',
      token: hud.token,
      body: { id: next.body.pending[0].id, decision: 'reject' },
    })
    assert.equal(await secondOutcome, 'rejected')
  } finally {
    hud.dispose()
  }
})

test('timed auto-approve answers without showing a card and audits it', async () => {
  const { hud } = await startHud()
  try {
    const start = await call(hud.port, '/auto-approve', {
      method: 'POST',
      token: hud.token,
      body: { minutes: 5 },
    })
    assert.equal(start.status, 200)
    assert.equal(start.body.ok, true)
    const { request: req } = rootApproval()
    const outcome = await hud.handle(req, async () => 'unavailable')
    assert.equal(outcome, 'allowed-once')
    const state = await call(hud.port, `/state?token=${hud.token}`, { token: hud.token })
    assert.equal(state.body.pending.length, 0)
    assert.equal(state.body.autoApprove.active, true)
    assert.equal(state.body.autoApprove.count, 1)
    assert.ok(state.body.autoApprove.remainingMs > 0)
    const log = readFileSync(join(process.cwd(), 'tests', '.tmp-audit', 'auto-approve.log'), 'utf8')
    assert.match(log, /"toolName":"pwsh"/)
  } finally {
    hud.dispose()
  }
})

test('starting auto-approve resolves the already queued request', async () => {
  const { hud } = await startHud()
  try {
    const { request: req } = rootApproval()
    const outcome = hud.handle(req, async () => 'unavailable')
    const start = await call(hud.port, '/auto-approve', {
      method: 'POST',
      token: hud.token,
      body: { minutes: 5 },
    })
    assert.equal(start.status, 200)
    assert.equal(await outcome, 'allowed-once')
    const state = await call(hud.port, `/state?token=${hud.token}`, { token: hud.token })
    assert.equal(state.body.pending.length, 0)
    assert.equal(state.body.autoApprove.count, 1)
  } finally {
    hud.dispose()
  }
})

test('dangerous commands still require a manual decision during auto-approve', async () => {
  const { hud } = await startHud()
  try {
    await call(hud.port, '/auto-approve', {
      method: 'POST',
      token: hud.token,
      body: { minutes: 5 },
    })
    const { request: req } = rootApproval({ reason: 'Need to run rm -rf / now' })
    const outcome = hud.handle(req, async () => 'unavailable')
    const state = await call(hud.port, `/state?token=${hud.token}`, { token: hud.token })
    assert.equal(state.body.pending.length, 1)
    assert.equal(state.body.pending[0].autoApproveBlocked, 'dangerous')
    await call(hud.port, '/answer', {
      method: 'POST',
      token: hud.token,
      body: { id: state.body.pending[0].id, decision: 'reject' },
    })
    assert.equal(await outcome, 'rejected')
  } finally {
    hud.dispose()
  }
})

test('subagent requests are not auto-approved by default', async () => {
  const { hud } = await startHud()
  try {
    await call(hud.port, '/auto-approve', {
      method: 'POST',
      token: hud.token,
      body: { minutes: 5 },
    })
    const { request: req } = approval()
    const outcome = hud.handle(req, async () => 'unavailable')
    const state = await call(hud.port, `/state?token=${hud.token}`, { token: hud.token })
    assert.equal(state.body.pending.length, 1)
    assert.equal(state.body.pending[0].autoApproveBlocked, 'subagent')
    await call(hud.port, '/answer', {
      method: 'POST',
      token: hud.token,
      body: { id: state.body.pending[0].id, decision: 'allow' },
    })
    assert.equal(await outcome, 'allowed-once')
  } finally {
    hud.dispose()
  }
})

test('stopping auto-approve restores manual decisions', async () => {
  const { hud } = await startHud()
  try {
    await call(hud.port, '/auto-approve', {
      method: 'POST',
      token: hud.token,
      body: { minutes: 5 },
    })
    const stop = await call(hud.port, '/auto-approve/stop', {
      method: 'POST',
      token: hud.token,
      body: {},
    })
    assert.equal(stop.status, 200)
    const { request: req } = rootApproval()
    const outcome = hud.handle(req, async () => 'unavailable')
    const state = await call(hud.port, `/state?token=${hud.token}`, { token: hud.token })
    assert.equal(state.body.autoApprove.active, false)
    assert.equal(state.body.pending.length, 1)
    await call(hud.port, '/answer', {
      method: 'POST',
      token: hud.token,
      body: { id: state.body.pending[0].id, decision: 'reject' },
    })
    assert.equal(await outcome, 'rejected')
  } finally {
    hud.dispose()
  }
})

test('auto-approve stops when the UI exits', async () => {
  const { hud, child } = await startHud()
  try {
    await call(hud.port, '/auto-approve', {
      method: 'POST',
      token: hud.token,
      body: { minutes: 5 },
    })
    child.emit('exit', 0, null)
    const state = await call(hud.port, `/state?token=${hud.token}`, { token: hud.token })
    assert.equal(state.body.autoApprove.active, false)
  } finally {
    hud.dispose()
  }
})

test('dispose fails pending requests closed', async () => {
  const { hud } = await startHud()
  const { request: req } = approval()
  const outcome = hud.handle(req, async () => 'unavailable')
  hud.dispose()
  assert.equal(await outcome, 'unavailable')
  assert.equal(hud.pending.size, 0)
})

test('the exported plugin name is stable', () => {
  assert.equal(name, 'dsh-approval-hud')
})
