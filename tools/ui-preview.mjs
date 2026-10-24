/**
 * Local mock host for previewing and smoke-testing ui/hud.ps1.
 * Not part of the installed plugin.
 */
import { createServer } from 'node:http'
import { spawn } from 'node:child_process'
import { randomBytes } from 'node:crypto'
import { fileURLToPath } from 'node:url'
import { mkdirSync } from 'node:fs'
import { dirname, join } from 'node:path'

const here = dirname(fileURLToPath(import.meta.url))
const root = dirname(here)
const uiScript = join(root, 'ui', 'hud.ps1')
const renderTo = process.argv[2] ?? join(root, 'prototype', 'ui-preview.png')
const mode = process.argv[3] ?? ''
const dataDir = join(root, 'prototype', 'data')
const token = randomBytes(16).toString('hex')
mkdirSync(dirname(renderTo), { recursive: true })
mkdirSync(dataDir, { recursive: true })
const answers = []
let autoActive = mode.startsWith('auto')
let autoUntil = autoActive ? Date.now() + 899000 : 0
let autoCount = autoActive ? 2 : 0
const idleOnly = mode === 'auto-idle' || mode === 'start-auto' || mode === 'custom-dialog'

const item = {
  id: 'mock-1',
  toolName: 'pwsh',
  reason: '需要以更高权限运行 PowerShell 命令：Get-ChildItem C:\\Users\\you\\project -Recurse | Select-Object FullName',
  reasonTruncated: false,
  project: 'demo',
  sessionId: 'a1b2c3d4',
  subagent: false,
  createdAt: Date.now(),
}

const server = createServer((req, res) => {
  const url = new URL(req.url, 'http://127.0.0.1')
  const send = (status, body) => {
    const data = Buffer.from(JSON.stringify(body))
    res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': data.length, Connection: 'close' })
    res.end(data)
  }
  if (req.headers.origin !== undefined) return send(403, { ok: false })
  if (url.pathname === '/state') {
    return send(200, {
      ok: true,
      version: '0.3.0',
      now: Date.now(),
      hostPid: process.pid,
      uiReady: true,
      config: {
        position: 'bottom-right',
        idleMode: 'hide',
        sound: false,
        showProject: true,
        followVirtualDesktop: true,
        keepTopmost: true,
        autoApproveMinutes: 15,
        autoApproveOptions: [15, 30, 60],
        keepAwakeDuringAutoApprove: true,
        autoApproveSubagents: false,
        language: 'zh',
      },
      autoApprove: {
        active: autoActive,
        until: autoUntil,
        remainingMs: autoActive ? Math.max(0, autoUntil - Date.now()) : 0,
        count: autoCount,
        last: null,
      },
      pending: idleOnly ? [] : (answers.length === 0 ? [item] : []),
    })
  }
  if (req.method === 'POST') {
    let body = ''
    req.on('data', (chunk) => { body += chunk })
    req.on('end', () => {
      let parsed = {}
      try { parsed = JSON.parse(body || '{}') } catch {}
      if (url.pathname === '/ready') return send(200, { ok: true })
      if (url.pathname === '/auto-approve') {
        autoActive = true
        autoCount = 0
        autoUntil = Date.now() + 900000
        return send(200, { ok: true, minutes: 15, until: autoUntil })
      }
      if (url.pathname === '/auto-approve/stop') {
        autoActive = false
        autoUntil = 0
        return send(200, { ok: true })
      }
      if (url.pathname === '/answer') {
        answers.push(parsed)
        console.log('ANSWER', JSON.stringify(parsed))
        return send(200, { ok: true })
      }
      if (url.pathname === '/bye') {
        console.log('BYE')
        send(200, { ok: true })
        setTimeout(() => { server.close(); process.exit(0) }, 150)
        return
      }
      return send(404, { ok: false })
    })
    return
  }
  send(404, { ok: false })
})

server.listen(0, '127.0.0.1', () => {
  const port = server.address().port
  console.log('READY', JSON.stringify({ port, token }))
  const args = [
    '-NoLogo', '-NoProfile', '-NonInteractive', '-STA', '-ExecutionPolicy', 'Bypass',
    '-WindowStyle', 'Hidden', '-File', uiScript,
    '-Port', String(port), '-Token', token, '-ParentPid', String(process.pid),
    '-Language', 'zh', '-DataDir', dataDir, '-DebugLog', '-RenderTo', renderTo,
  ]
  if (mode === 'start-auto') args.push('-AutoStartMinutes', '15')
  if (mode === 'custom-dialog') args.push('-TestCustomDialog')
  const child = spawn('powershell.exe', args, { windowsHide: true, stdio: 'inherit' })
  child.on('exit', (code) => {
    console.log('PS_EXIT', code)
    setTimeout(() => { server.close(); process.exit(code ?? 0) }, 300)
  })
})
