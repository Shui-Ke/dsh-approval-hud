/**
 * End-to-end UI smoke test: a mock host serves one pending approval, the real
 * PowerShell/WPF window renders it and (via -AutoAnswer) clicks "allow", and
 * the mock verifies the decision arrived over loopback HTTP.
 *
 * Run with: node tests/ui-smoke.mjs
 */
import { createServer } from 'node:http'
import { spawn } from 'node:child_process'
import { randomBytes } from 'node:crypto'
import { mkdirSync, rmSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const root = dirname(here)
const dataDir = join(here, '.tmp-ui-smoke')
const uiScript = join(root, 'ui', 'hud.ps1')
const token = randomBytes(16).toString('hex')
const events = []
let pending = [
  {
    id: 'smoke-1',
    toolName: 'pwsh',
    reason: 'Smoke test: run a PowerShell command with elevated permissions.',
    reasonTruncated: false,
    project: 'smoke',
    sessionId: 'deadbeef',
    subagent: false,
    createdAt: Date.now(),
  },
]
let answerResolve
const answerPromise = new Promise((resolve) => { answerResolve = resolve })

const server = createServer((req, res) => {
  const url = new URL(req.url, 'http://127.0.0.1')
  const send = (status, body) => {
    const data = Buffer.from(JSON.stringify(body), 'utf8')
    res.writeHead(status, {
      'Content-Type': 'application/json; charset=utf-8',
      'Content-Length': data.length,
      Connection: 'close',
    })
    res.end(data)
  }
  let body = ''
  req.on('data', (chunk) => { body += chunk })
  req.on('end', () => {
    events.push(`${req.method} ${url.pathname} ${body}`)
    if (url.pathname === '/state') {
      return send(200, {
        ok: true,
        version: '0.1.0',
        now: Date.now(),
        hostPid: process.pid,
        uiReady: true,
        config: { position: 'bottom-right', idleMode: 'hide', sound: false, showProject: true, language: 'zh' },
        pending,
      })
    }
    if (url.pathname === '/ready') return send(200, { ok: true })
    if (url.pathname === '/answer') {
      let parsed = {}
      try { parsed = JSON.parse(body) } catch {}
      pending = []
      answerResolve(parsed)
      return send(200, { ok: true })
    }
    if (url.pathname === '/bye') return send(200, { ok: true })
    send(404, { ok: false })
  })
})

function fail(message) {
  console.error(message)
  console.error(events.join('\n'))
  cleanup(1)
}

let child
function cleanup(code) {
  try { child?.kill() } catch {}
  try { server.close() } catch {}
  try { rmSync(dataDir, { recursive: true, force: true }) } catch {}
  setTimeout(() => process.exit(code), 100)
}

server.listen(0, '127.0.0.1', () => {
  const port = server.address().port
  mkdirSync(dataDir, { recursive: true })
  const args = [
    '-NoLogo', '-NoProfile', '-NonInteractive', '-STA', '-ExecutionPolicy', 'Bypass',
    '-WindowStyle', 'Hidden', '-File', uiScript,
    '-Port', String(port), '-Token', token, '-ParentPid', String(process.pid),
    '-Language', 'zh', '-DataDir', dataDir, '-DebugLog',
    '-AutoAnswer', 'allow', '-AutoAnswerAfterMs', '800',
  ]
  child = spawn('powershell.exe', args, { windowsHide: true, stdio: 'ignore' })
  child.on('error', (error) => fail(`spawn failed: ${String(error)}`))
})

const timer = setTimeout(() => fail('timed out waiting for the approval decision'), 20000)

answerPromise.then((answer) => {
  clearTimeout(timer)
  if (answer.decision !== 'allow' || answer.id !== 'smoke-1') {
    fail(`unexpected answer: ${JSON.stringify(answer)}`)
    return
  }
  if (!events.some((line) => line.startsWith('POST /ready'))) {
    fail('UI never posted /ready')
    return
  }
  if (!events.some((line) => line.startsWith('GET /state'))) {
    fail('UI never polled /state')
    return
  }
  console.log('UI smoke test passed')
  console.log(events.join('\n'))
  cleanup(0)
})
