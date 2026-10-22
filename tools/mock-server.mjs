/**
 * Persistent mock host for manual UI debugging. Writes its port/token to
 * tools/mock.json and appends every request to tools/mock.log.
 */
import { createServer } from 'node:http'
import { randomBytes } from 'node:crypto'
import { appendFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const token = randomBytes(16).toString('hex')
const log = (line) => appendFileSync(join(here, 'mock.log'), `${new Date().toISOString()} ${line}\n`)
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
  let body = ''
  req.on('data', (chunk) => { body += chunk })
  req.on('end', () => {
    log(`${req.method} ${url.pathname} ${body}`)
    if (url.pathname === '/state') {
      return send(200, {
        ok: true, version: '0.1.0', now: Date.now(), hostPid: process.pid, uiReady: true,
        config: { position: 'bottom-right', idleMode: 'hide', sound: false, showProject: true, language: 'zh' },
        pending: [item],
      })
    }
    if (url.pathname === '/ready') return send(200, { ok: true })
    if (url.pathname === '/answer') return send(200, { ok: true, got: body })
    if (url.pathname === '/bye') return send(200, { ok: true })
    send(404, { ok: false })
  })
})

server.listen(0, '127.0.0.1', () => {
  const port = server.address().port
  writeFileSync(join(here, 'mock.json'), JSON.stringify({ port, token }))
  log(`listening ${port}`)
  console.log(`listening ${port}`)
})
