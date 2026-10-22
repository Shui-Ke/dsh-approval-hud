/**
 * dsh-approval-hud — DeepSeek Harness host half.
 *
 * Intercepts `approval/request` and asks a small always-on-top Windows window
 * instead of the main DSH panel. The window is a plain PowerShell/WPF process
 * that polls a loopback-only HTTP endpoint owned by this plugin. If the window
 * is unavailable, every request is handed to the next answerer unchanged, so
 * DSH's own approval card remains the fallback.
 *
 * @module dsh-approval-hud
 */

import { createServer } from 'node:http'
import { spawn } from 'node:child_process'
import { randomBytes, randomUUID } from 'node:crypto'
import { appendFileSync, existsSync, mkdirSync, statSync, renameSync } from 'node:fs'
import { homedir } from 'node:os'
import { basename, dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

/** Plugin name used by the loader, logs and diagnostics. */
export const name = 'dsh-approval-hud'

/** This plugin only uses Cordis events, so it injects no service. */
export const inject = []

const VERSION = '0.1.0'
const PACKAGE_DIR = dirname(dirname(fileURLToPath(import.meta.url)))
const UI_SCRIPT = join(PACKAGE_DIR, 'ui', 'hud.ps1')

/** Defaults overridable from the profile patch. */
export const DEFAULT_CONFIG = Object.freeze({
  /** Master switch. When false, approvals stay in the DSH window. */
  enabled: true,
  /** Corner used for the first placement: top-left|top-right|bottom-left|bottom-right|remember. */
  position: 'bottom-right',
  /** What to show while nothing is pending: hide|compact. */
  idleMode: 'hide',
  /** Play the Windows asterisk sound when a new request appears. */
  sound: true,
  /** Show the session's working-directory name on the card. */
  showProject: true,
  /** Upper bound on the reason text shown in the window. */
  maxReasonChars: 600,
  /** UI language: zh|en. */
  language: 'zh',
  /** How long PowerShell may take to report ready before requests fall back. */
  startupTimeoutMs: 15000,
  /** Append diagnostics to %LOCALAPPDATA%\dsh-approval-hud\plugin.log. */
  debug: false,
})

const POSITIONS = new Set(['top-left', 'top-right', 'bottom-left', 'bottom-right', 'remember'])
const IDLE_MODES = new Set(['hide', 'compact'])
const LANGUAGES = new Set(['zh', 'en'])

/**
 * Merge user config over defaults and clamp invalid values.
 * @param {unknown} raw Config object from the profile patch.
 * @returns {typeof DEFAULT_CONFIG} Effective config.
 */
export function normalizeConfig(raw) {
  const input = raw !== null && typeof raw === 'object' ? raw : {}
  const config = { ...DEFAULT_CONFIG, ...input }
  if (!POSITIONS.has(config.position)) config.position = DEFAULT_CONFIG.position
  if (!IDLE_MODES.has(config.idleMode)) config.idleMode = DEFAULT_CONFIG.idleMode
  if (!LANGUAGES.has(config.language)) config.language = DEFAULT_CONFIG.language
  for (const key of ['enabled', 'sound', 'showProject', 'debug']) {
    config[key] = Boolean(config[key])
  }
  const max = Number(config.maxReasonChars)
  config.maxReasonChars = Number.isFinite(max) ? Math.min(4000, Math.max(120, Math.trunc(max))) : DEFAULT_CONFIG.maxReasonChars
  const timeout = Number(config.startupTimeoutMs)
  config.startupTimeoutMs = Number.isFinite(timeout) ? Math.min(60000, Math.max(3000, Math.trunc(timeout))) : DEFAULT_CONFIG.startupTimeoutMs
  return config
}

/**
 * Collapse and bound arbitrary request text for one-line-safe display.
 * @param {unknown} value Raw reason.
 * @param {number} max Maximum characters.
 * @returns {{ text: string, truncated: boolean }} Cleaned text.
 */
export function cleanText(value, max) {
  if (typeof value !== 'string') return { text: '', truncated: false }
  let text = value.replace(/\r\n?/g, '\n').replace(/[ \t]+\n/g, '\n').replace(/\n{3,}/g, '\n\n').trim()
  if (text.length <= max) return { text, truncated: false }
  return { text: `${text.slice(0, max).trimEnd()}…`, truncated: true }
}

/** Resolve the Windows PowerShell 5.1 executable, falling back to PATH. */
function powershellPath() {
  const root = process.env.SystemRoot ?? 'C:\\Windows'
  const candidate = join(root, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe')
  return existsSync(candidate) ? candidate : 'powershell.exe'
}

/** Write one JSON response and close the connection. */
function sendJson(res, status, value) {
  let body
  try {
    body = Buffer.from(JSON.stringify(value), 'utf8')
  } catch {
    body = Buffer.from('{"ok":false}', 'utf8')
    status = 500
  }
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': body.length,
    'Cache-Control': 'no-store',
    Connection: 'close',
  })
  res.end(body)
}

/**
 * Read a bounded JSON request body.
 * @param {import('node:http').IncomingMessage} req Request.
 * @param {number} [limit] Maximum bytes.
 * @returns {Promise<Record<string, unknown>>} Parsed body.
 */
function readJsonBody(req, limit = 64 * 1024) {
  return new Promise((resolve, reject) => {
    let size = 0
    const chunks = []
    req.on('data', (chunk) => {
      size += chunk.length
      if (size > limit) {
        reject(new Error('body too large'))
        req.destroy()
        return
      }
      chunks.push(chunk)
    })
    req.on('end', () => {
      if (chunks.length === 0) {
        resolve({})
        return
      }
      try {
        const value = JSON.parse(Buffer.concat(chunks).toString('utf8'))
        if (value === null || typeof value !== 'object' || Array.isArray(value)) {
          reject(new Error('body must be an object'))
          return
        }
        resolve(value)
      } catch (error) {
        reject(error)
      }
    })
    req.on('error', reject)
  })
}

/**
 * One pending approval and the promise handed back to the host waterfall.
 */
class PendingApproval {
  /**
   * @param {object} fields Item fields.
   */
  constructor(fields) {
    this.id = fields.id
    this.toolName = fields.toolName
    this.reason = fields.reason
    this.reasonTruncated = fields.reasonTruncated
    this.project = fields.project
    this.sessionId = fields.sessionId
    this.subagent = fields.subagent
    this.createdAt = fields.createdAt
    this.settled = false
    this.promise = new Promise((resolve) => {
      this.resolve = resolve
    })
    this.signal = fields.signal
    this.onAbort = undefined
    this.next = fields.next
  }

  /**
   * Finish once with the closed approval outcome.
   * @param {string} outcome allowed-once|rejected|cancelled|unavailable.
   */
  finish(outcome) {
    if (this.settled) return
    this.settled = true
    if (this.signal !== undefined && this.onAbort !== undefined) {
      this.signal.removeEventListener('abort', this.onAbort)
    }
    this.resolve(outcome)
  }

  /**
   * Hand this request back to the DSH answerer chain.
   * @param {string} why Diagnostic reason.
   * @returns {Promise<void>} Resolves after the delegate outcome settles.
   */
  async delegate(why) {
    if (this.settled) return
    this.settled = true
    if (this.signal !== undefined && this.onAbort !== undefined) {
      this.signal.removeEventListener('abort', this.onAbort)
    }
    let outcome = 'unavailable'
    try {
      outcome = await this.next()
    } catch {
      outcome = 'unavailable'
    }
    this.resolve(outcome)
    // Keep the field for diagnostics without holding the promise open twice.
    this.delegateReason = why
  }
}

/**
 * The host-side service: loopback state server, UI process lifecycle and the
 * approval waterfall listener.
 */
export class ApprovalHud {
  /**
   * @param {any} ctx Cordis context.
   * @param {typeof DEFAULT_CONFIG} config Effective config.
   * @param {{ spawnUi?: Function, platform?: string }} [deps] Test seams.
   */
  constructor(ctx, config, deps = {}) {
    this.ctx = ctx
    this.config = config
    this.spawnUi = deps.spawnUi ?? spawn
    this.platform = deps.platform ?? process.platform
    this.pending = new Map()
    this.disposed = false
    this.ui = undefined
    this.uiReady = false
    this.uiState = 'idle'
    this.uiAttempts = 0
    this.uiDisabled = false
    this.uiOutput = ''
    this.uiTimer = undefined
    this.restartTimer = undefined
    this.server = undefined
    this.serverReady = false
    this.port = 0
    this.token = randomBytes(24).toString('hex')
    this.traceReady = false
    this.lastPollAt = 0
    this.serverPromise = this.startServer().then((ready) => {
      if (ready) this.startUi()
      return ready
    })
    // A WPF process can hang without exiting. Its 350ms state poll is the
    // heartbeat; after 30 quiet seconds, recycle it and delegate its queue.
    this.watchdog = setInterval(() => {
      if (this.disposed || !this.uiReady) return
      if (this.lastPollAt === 0 || Date.now() - this.lastPollAt < 30000) return
      this.warn('UI stopped polling; restarting it')
      this.uiReady = false
      try {
        this.ui?.kill?.()
      } catch {
        // The exit handler still runs if the process was already gone.
      }
    }, 5000)
    this.watchdog.unref?.()
  }

  /** Append a diagnostic line when debug is enabled. */
  trace(message) {
    if (!this.config.debug) return
    try {
      const dir = join(process.env.LOCALAPPDATA ?? homedir(), 'dsh-approval-hud')
      mkdirSync(dir, { recursive: true })
      const file = join(dir, 'plugin.log')
      if (!this.traceReady) {
        this.traceReady = true
        try {
          if (existsSync(file) && statSync(file).size > 512 * 1024) renameSync(file, `${file}.old`)
        } catch {
          // A failed rotation must not disable diagnostics.
        }
      }
      appendFileSync(file, `${new Date().toISOString()} ${message}\n`)
    } catch {
      // Diagnostics are best-effort only.
    }
  }

  /** Log through Cordis when available, otherwise stay silent. */
  warn(message) {
    this.trace(`warn: ${message}`)
    try {
      this.ctx.logger?.warn?.(`${name}: ${message}`)
    } catch {
      // Logging must never break approval handling.
    }
  }

  /** Start the loopback HTTP server and resolve once the port is known. */
  async startServer() {
    const server = createServer((req, res) => {
      this.onRequest(req, res).catch((error) => {
        this.trace(`http failure: ${error?.stack ?? error}`)
        if (!res.headersSent) sendJson(res, 500, { ok: false })
        else res.destroy()
      })
    })
    this.server = server
    await new Promise((resolve) => {
      const fail = (error) => {
        this.warn(`state server failed: ${String(error)}`)
        resolve(false)
      }
      server.once('error', fail)
      server.listen(0, '127.0.0.1', () => {
        server.removeListener('error', fail)
        server.on('error', (error) => this.warn(`state server error: ${String(error)}`))
        const address = server.address()
        this.port = typeof address === 'object' && address !== null ? address.port : 0
        this.serverReady = this.port > 0
        this.trace(`state server listening on 127.0.0.1:${this.port}`)
        resolve(this.serverReady)
      })
    })
    return this.serverReady
  }

  /** Spawn the PowerShell UI once. */
  startUi() {
    if (this.disposed || !this.config.enabled || this.uiDisabled) return
    if (this.platform !== 'win32') {
      this.uiState = 'unsupported'
      this.trace('ui skipped: platform is not Windows')
      return
    }
    if (this.ui !== undefined) return
    if (!existsSync(UI_SCRIPT)) {
      this.uiState = 'failed'
      this.warn(`UI script missing: ${UI_SCRIPT}`)
      return
    }
    const args = [
      '-NoLogo',
      '-NoProfile',
      '-NonInteractive',
      '-STA',
      '-ExecutionPolicy',
      'Bypass',
      '-WindowStyle',
      'Hidden',
      '-File',
      UI_SCRIPT,
      '-Port',
      String(this.port),
      '-Token',
      this.token,
      '-ParentPid',
      String(process.pid),
      '-Language',
      this.config.language,
    ]
    if (this.config.debug) args.push('-DebugLog')
    let child
    try {
      child = this.spawnUi(powershellPath(), args, {
        windowsHide: true,
        stdio: ['ignore', 'pipe', 'pipe'],
      })
    } catch (error) {
      this.uiState = 'failed'
      this.warn(`failed to start UI: ${String(error)}`)
      return
    }
    this.ui = child
    this.uiState = 'starting'
    this.uiAttempts += 1
    this.trace(`ui spawned pid=${String(child.pid)} attempt=${String(this.uiAttempts)}`)
    const capture = (stream) => {
      stream?.on?.('data', (chunk) => {
        const text = chunk.toString()
        this.uiOutput = `${this.uiOutput}${text}`.slice(-4000)
        this.trace(`ui: ${text.trim()}`)
      })
    }
    capture(child.stdout)
    capture(child.stderr)
    child.on?.('error', (error) => {
      this.warn(`UI process error: ${String(error)}`)
      this.handleUiExit(child, 'error')
    })
    child.on?.('exit', (code, signal) => {
      this.trace(`ui exited code=${String(code)} signal=${String(signal)}`)
      this.handleUiExit(child, `exit ${String(code)}`)
    })
    this.uiTimer = setTimeout(() => {
      if (this.disposed || this.uiReady) return
      this.warn(`UI did not report ready within ${String(this.config.startupTimeoutMs)}ms; falling back to the DSH panel`)
      this.uiState = 'failed'
    }, this.config.startupTimeoutMs)
    this.uiTimer.unref?.()
  }

  /**
   * Handle a UI process ending.
   * @param {any} child The process that ended.
   * @param {string} why Diagnostic reason.
   */
  handleUiExit(child, why) {
    if (this.ui !== child) return
    this.ui = undefined
    this.uiReady = false
    if (this.uiTimer !== undefined) {
      clearTimeout(this.uiTimer)
      this.uiTimer = undefined
    }
    if (this.disposed) return
    if (this.uiDisabled) {
      this.uiState = 'disabled'
      return
    }
    this.trace(`ui unavailable: ${why}`)
    this.delegateAll('ui-exit')
    if (this.uiAttempts < 3) {
      this.uiState = 'exited'
      this.restartTimer = setTimeout(() => {
        this.restartTimer = undefined
        if (!this.disposed && !this.uiDisabled) this.startUi()
      }, 2000)
      this.restartTimer.unref?.()
    } else {
      this.uiState = 'failed'
      this.warn('UI exited repeatedly; approvals will use the DSH panel')
    }
  }

  /** Mark the UI as connected and cancel the startup timeout. */
  markReady() {
    if (this.disposed) return
    this.uiReady = true
    this.uiState = 'ready'
    this.lastPollAt = Date.now()
    if (this.uiTimer !== undefined) {
      clearTimeout(this.uiTimer)
      this.uiTimer = undefined
    }
    this.trace('ui ready')
  }

  /** Snapshot sent to the UI on every poll. */
  snapshot() {
    return {
      ok: true,
      version: VERSION,
      now: Date.now(),
      hostPid: process.pid,
      uiReady: this.uiReady,
      config: {
        position: this.config.position,
        idleMode: this.config.idleMode,
        sound: this.config.sound,
        showProject: this.config.showProject,
        language: this.config.language,
      },
      pending: [...this.pending.values()]
        .filter((item) => !item.settled)
        .map((item) => ({
          id: item.id,
          toolName: item.toolName,
          reason: item.reason,
          reasonTruncated: item.reasonTruncated,
          project: item.project,
          sessionId: item.sessionId,
          subagent: item.subagent,
          createdAt: item.createdAt,
        })),
    }
  }

  /**
   * Route one loopback request. The token plus the absence of an Origin header
   * keeps other local pages and processes from answering approvals.
   * @param {import('node:http').IncomingMessage} req Request.
   * @param {import('node:http').ServerResponse} res Response.
   */
  async onRequest(req, res) {
    const remote = req.socket.remoteAddress
    if (remote !== '127.0.0.1' && remote !== '::1' && remote !== '::ffff:127.0.0.1') {
      sendJson(res, 403, { ok: false })
      return
    }
    if (req.headers.origin !== undefined) {
      sendJson(res, 403, { ok: false })
      return
    }
    let url
    try {
      url = new URL(req.url ?? '/', `http://127.0.0.1:${this.port}`)
    } catch {
      sendJson(res, 400, { ok: false })
      return
    }
    const headerToken = req.headers['x-dsh-approval-token']
    const queryToken = url.searchParams.get('token')
    const method = req.method ?? 'GET'
    const isPost = method === 'POST'
    if (isPost) {
      if (typeof headerToken !== 'string' || headerToken !== this.token) {
        sendJson(res, 403, { ok: false })
        return
      }
    } else if ((typeof headerToken === 'string' ? headerToken : queryToken) !== this.token) {
      sendJson(res, 403, { ok: false })
      return
    }

    if (method === 'GET' && url.pathname === '/health') {
      sendJson(res, 200, {
        ok: true,
        version: VERSION,
        ready: this.uiReady,
        pending: this.pending.size,
      })
      return
    }
    if (method === 'GET' && url.pathname === '/state') {
      this.lastPollAt = Date.now()
      sendJson(res, 200, this.snapshot())
      return
    }
    if (isPost && url.pathname === '/ready') {
      this.markReady()
      sendJson(res, 200, { ok: true })
      return
    }
    if (isPost && url.pathname === '/answer') {
      let body
      try {
        body = await readJsonBody(req)
      } catch {
        sendJson(res, 400, { ok: false, code: 'bad-body' })
        return
      }
      const id = typeof body.id === 'string' ? body.id : ''
      const decision = typeof body.decision === 'string' ? body.decision : ''
      const result = this.answer(id, decision)
      sendJson(res, result.ok ? 200 : 409, result)
      return
    }
    if (isPost && url.pathname === '/bye') {
      this.uiDisabled = true
      this.uiReady = false
      this.delegateAll('ui-quit')
      sendJson(res, 200, { ok: true })
      return
    }
    sendJson(res, 404, { ok: false })
  }

  /**
   * Resolve one pending request from the UI.
   * @param {string} id Pending id.
   * @param {string} decision allow|reject|delegate.
   * @returns {{ ok: boolean, code?: string }} Result.
   */
  answer(id, decision) {
    const item = this.pending.get(id)
    if (item === undefined || item.settled) return { ok: false, code: 'gone' }
    if (decision === 'allow') {
      this.pending.delete(id)
      item.finish('allowed-once')
      return { ok: true }
    }
    if (decision === 'reject') {
      this.pending.delete(id)
      item.finish('rejected')
      return { ok: true }
    }
    if (decision === 'delegate') {
      this.pending.delete(id)
      void item.delegate('user-request')
      return { ok: true }
    }
    return { ok: false, code: 'bad-decision' }
  }

  /** Hand every pending request back to the DSH answerer chain. */
  delegateAll(why) {
    for (const item of [...this.pending.values()]) {
      this.pending.delete(item.id)
      void item.delegate(why)
    }
  }

  /**
   * The `approval/request` waterfall listener.
   * @param {any} request Approval request.
   * @param {() => Promise<string>} next Next answerer.
   * @returns {Promise<string>} Closed outcome.
   */
  async handle(request, next) {
    if (!this.config.enabled || this.disposed) return next()
    if (this.platform !== 'win32') return next()
    if (!this.uiReady || !this.serverReady) {
      this.trace('approval delegated: HUD not ready')
      return next()
    }
    const id = randomUUID()
    const { text, truncated } = cleanText(request?.reason, this.config.maxReasonChars)
    const session = request?.agent?.session
    const header = session?.header
    const cwd = typeof header?.cwd === 'string' ? header.cwd : ''
    const item = new PendingApproval({
      id,
      toolName: typeof request?.toolName === 'string' && request.toolName.length > 0 ? request.toolName : 'tool',
      reason: text,
      reasonTruncated: truncated,
      project: this.config.showProject && cwd.length > 0 ? basename(cwd) : '',
      sessionId: typeof session?.id === 'string' ? session.id.slice(-8) : '',
      subagent: header?.origin === 'subagent' || (typeof header?.delegationDepth === 'number' && header.delegationDepth > 0),
      createdAt: Date.now(),
      signal: request?.signal,
      next,
    })
    if (request?.signal?.aborted === true) {
      item.finish('cancelled')
      return item.promise
    }
    if (request?.signal !== undefined) {
      item.onAbort = () => {
        this.trace(`approval aborted ${id}`)
        this.pending.delete(id)
        item.finish('cancelled')
      }
      request.signal.addEventListener('abort', item.onAbort, { once: true })
    }
    this.pending.set(id, item)
    this.trace(`approval queued ${id} tool=${item.toolName} project=${item.project}`)
    try {
      return await item.promise
    } finally {
      this.pending.delete(id)
      if (item.signal !== undefined && item.onAbort !== undefined) {
        item.signal.removeEventListener('abort', item.onAbort)
      }
    }
  }

  /** Stop the server, the UI and every pending request. */
  dispose() {
    if (this.disposed) return
    this.disposed = true
    this.trace('disposing')
    for (const item of [...this.pending.values()]) item.finish('unavailable')
    this.pending.clear()
    if (this.uiTimer !== undefined) clearTimeout(this.uiTimer)
    if (this.restartTimer !== undefined) clearTimeout(this.restartTimer)
    if (this.watchdog !== undefined) clearInterval(this.watchdog)
    this.uiTimer = undefined
    this.restartTimer = undefined
    this.watchdog = undefined
    try {
      this.ui?.kill?.()
    } catch {
      // The UI may already be gone.
    }
    this.ui = undefined
    try {
      this.server?.close?.()
    } catch {
      // The server may never have bound.
    }
  }
}

/**
 * Install the approval listener. The listener is prepended so it runs before
 * the DSH browser forwarder; calling `next()` restores the normal panel.
 * @param {any} ctx Cordis context.
 * @param {unknown} rawConfig Profile patch config.
 */
export function apply(ctx, rawConfig, deps = {}) {
  const config = normalizeConfig(rawConfig)
  const hud = new ApprovalHud(ctx, config, deps)
  ctx.effect(() => () => hud.dispose())
  ctx.on('approval/request', (request, next) => hud.handle(request, next), { prepend: true })
}
