# dsh-approval-hud

Put DeepSeek Harness permission prompts in an **always-on-top Windows card**. Keep working in your browser or editor, click **Allow once** or **Reject**, and the agent continues without bringing DSH back to the foreground.

![Approval HUD](docs/preview.png)

## What it does

DSH renders approvals above the conversation composer. Once you switch windows, the agent waits where you cannot see it.

This plugin intercepts `approval/request` on the **host** side and renders each request in a small native window:

- Always on top, but **does not steal focus**.
- Shows the tool, project, reason, wait time and queue position.
- **Allow once**, **Reject**, and **Handle in DSH**.
- A tray shield keeps the window reachable.
- Approvals from every session and subagent share one queue.
- If the HUD is unavailable, requests fall back to the normal DSH card. It never auto-approves.

## Requirements

| | |
|---|---|
| OS | Windows 10 / 11 |
| DSH | `0.2.1-rc.1` or newer |
| PowerShell | Windows PowerShell 5.1 (built in) |
| Other | No Node, no build step, no admin rights |

## Install

A restart of the DSH process is required; refreshing the page is not enough.

### A. Plugin manager

1. Keep the `dsh-approval-hud` folder or the packed `dsh-approval-hud-0.2.0.tgz`.
2. Open DSH's **Plugins** page.
3. Add a plugin by absolute spec:
   - folder: `link:C:\path\to\dsh-approval-hud`
   - tarball: `file:C:\path\to\dsh-approval-hud-0.2.0.tgz`
4. Restart DSH. A shield icon appears in the tray.

### B. install.ps1 (most reliable)

1. Quit DSH completely from its tray menu.
2. Run:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\install.ps1
   ```

   It copies the plugin to `%USERPROFILE%\.dsh\plugins\`, adds the dependency and bundle to the `desktop` profile, and installs with DSH's bundled pnpm.
3. Start DSH again.

Options: `-DryRun`, `-Profile web`, `-Uninstall`.

### C. CLI

```powershell
dsh plugin --profile desktop add "link:C:\path\to\dsh-approval-hud"
```

Then restart DSH.

> The Plugins page shows it as **Approval HUD** (package `dsh-approval-hud`, entry id `approval-hud`).
> Refresh the page with `Ctrl+R` if the list is stale; the read-only Settings → Plugins inventory lists only **loaded** rows and needs a DSH restart.
> The manager page only manages the bundle; the HUD itself loads on the next DSH start.

## Usage

| Action | Meaning |
|---|---|
| Allow once | Grants this request only |
| Reject | Fails this request as a user rejection |
| Handle in DSH | Hands this request back to DSH's own approval card |
| Drag the header | Moves the window and remembers the position |
| `Enter` / `Esc` | Allow / reject when the window has focus |
| Tray double-click | Re-show the window |
| Tray → Quit | Disables the HUD until the next DSH restart |

When several requests are pending, the oldest is shown with `1 / N`; answering it reveals the next. Alt+F4 hides the window instead of dropping the request.

## Configuration

Override the plugin row in the profile's `cordis.patch.yml`. A patch replaces the whole `config` value, so list every key you want to keep:

```yaml
- id: approval-hud
  name: dsh-approval-hud
  config:
    position: bottom-right   # top-left | top-right | bottom-left | bottom-right | remember
    idleMode: hide           # hide | compact
    sound: true
    showProject: true
    followVirtualDesktop: true
    keepTopmost: true
    maxReasonChars: 600
    language: en             # zh | en
    startupTimeoutMs: 15000
    debug: false
```

`enabled: false` restores the normal DSH approval card. `followVirtualDesktop` moves the card to the current Windows virtual desktop when you press `Win+Ctrl+←/→`; `keepTopmost` re-asserts HWND_TOPMOST while the card is visible. `debug: true` writes `plugin.log` and `ui.log` under `%LOCALAPPDATA%\dsh-approval-hud\`.

## Fallback and safety

- The listener is prepended, so a ready HUD answers before DSH's browser panel.
- If the HUD is starting, failed, exited, or explicitly quit, the request is delegated to the next answerer unchanged.
- Pending requests delegate back to DSH when the UI process exits; the plugin retries the UI at most three times.
- Unloading the plugin or stopping DSH closes pending requests as `unavailable`; it never blocks forever.
- The loopback server binds a random `127.0.0.1` port, requires a random token, rejects browser `Origin` requests, and never auto-approves.
- Only one-shot grants exist; the plugin does not change DSH's approval policy.

## Limitations

- Windows only; other platforms fall back immediately.
- Only permission approvals (`approval/request`) are intercepted. `ask_user_question` and `exit_plan_mode` still use the DSH UI.
- The card shows the tool and reason, not full tool arguments. Use **Handle in DSH** when you need the command detail.
- One card at a time; the rest queue.
- The resident PowerShell/WPF process costs roughly 50–100 MB of memory.
- Under DSH's `never` approval policy there are no requests to show.

## Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall
```

Or remove `dsh-approval-hud` in the Plugins page and restart DSH.

## Development

```powershell
node tests/host.test.mjs
node tests/ui-smoke.mjs
node tools/ui-preview.mjs
```

`ui/hud.ps1` is intentionally ASCII-only; Chinese copy lives in `ui/hud.xaml` and `ui/strings.*.json`, which are read as UTF-8 by the XML/JSON parsers.

## License

MIT
