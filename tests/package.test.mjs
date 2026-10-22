import assert from 'node:assert/strict'
import { existsSync, readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { test } from 'node:test'
import { fileURLToPath } from 'node:url'

const root = dirname(dirname(fileURLToPath(import.meta.url)))
const read = (path) => readFileSync(join(root, path), 'utf8')

test('manifest points at real runtime files', () => {
  const pkg = JSON.parse(read('package.json'))
  assert.equal(pkg.name, 'dsh-approval-hud')
  assert.equal(pkg.type, 'module')
  assert.equal(pkg.exports['.'], './lib/index.mjs')
  assert.equal(pkg.dsh.bundle.patch, './cordis.patch.yml')
  for (const path of [
    pkg.main,
    pkg.dsh.bundle.patch,
    'ui/hud.ps1',
    'ui/hud.xaml',
    'ui/strings.zh.json',
    'ui/strings.en.json',
    'locale/zh.json',
    'locale/en.json',
    'icon.svg',
  ]) {
    assert.ok(existsSync(join(root, path)), `missing ${path}`)
  }
})

test('the bundle patch inserts the packaged plugin', () => {
  const patch = read('cordis.patch.yml')
  assert.match(patch, /- insert:/)
  assert.match(patch, /id:\s*approval-hud/)
  assert.match(patch, /name:\s*dsh-approval-hud/)
})

test('the published file list keeps the runtime and docs', () => {
  const pkg = JSON.parse(read('package.json'))
  const files = new Set(pkg.files)
  for (const required of ['lib', 'ui', 'cordis.patch.yml', 'README.md', 'LICENSE']) {
    assert.ok(files.has(required), `files is missing ${required}`)
  }
  assert.ok(pkg.files.some((entry) => entry.startsWith('docs/')))
  assert.ok(pkg.files.some((entry) => entry.startsWith('locale/')))
})

test('plugin version matches the host module constant', () => {
  const pkg = JSON.parse(read('package.json'))
  const source = read('lib/index.mjs')
  assert.match(source, new RegExp(`const VERSION = '${pkg.version.replaceAll('.', '\\.')}'`))
})

test('the package contains no absolute personal paths', () => {
  for (const path of ['package.json', 'cordis.patch.yml', 'lib/index.mjs', 'ui/hud.ps1', 'README.md', 'README.zh.md']) {
    const text = read(path)
    assert.ok(!/[A-Za-z]:\\Users\\/i.test(text), `absolute path in ${path}`)
  }
})
