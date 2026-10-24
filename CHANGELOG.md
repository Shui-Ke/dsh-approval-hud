# Changelog

## 0.3.2 — 2026-10-24

- Clamp the card inside the work area after every layout pass and on a 350 ms timer, fixing a tall card that could grow below the desktop after the idle strip.
- Add tray `Allow current request` / `Reject current request` as a fallback when the card is off-screen.
- Keep the user's saved position when it is still valid; only move the window when it would overflow.

## 0.3.1 — 2026-10-24

- Auto-approve durations are configurable: `autoApproveMinutes` (card, 1–480) and `autoApproveOptions` (tray, up to three values).
- Choosing another tray duration extends the countdown from the current time.
- Keep the system awake and the display on while auto-approve is active (`keepAwakeDuringAutoApprove`, default `true`), restoring normal power behaviour on stop/expiry/window close/UI exit.
- Document that manual sleep, lid close, or group-policy power settings can still override the request.

## 0.3.0 — 2026-10-24

- Add timed auto-approve: tray 15/30/60 minutes, or "Approve & auto-approve" on the card.
- One click approves the already queued requests and the following ones while the countdown runs.
- Security: the UI token now arrives over a private stdin pipe and no longer appears in the UI process command line.
- Security: README states the HUD is a same-user guardrail, not a boundary against UI automation/memory access.
- Visible countdown on the card/idle strip and in the tray tooltip, with stop from all three.
- Auto-approve stops on timer expiry, window close, UI exit, DSH quit, or DSH restart.
- Best-effort deny list for catastrophic commands; blocked requests still open the card.
- Subagent requests are not auto-approved by default (`autoApproveSubagents: false`).
- Every auto-approval is appended to `%LOCALAPPDATA%\dsh-approval-hud\auto-approve.log`.
- Config: `autoApproveMinutes`, `autoApproveSubagents`, `autoApproveDenyPatterns`.

## 0.2.0 — 2026-10-22

- Follow Windows virtual-desktop switches: the card moves to the current desktop within about one second.
- Re-assert `HWND_TOPMOST` while the card is visible, so ordinary windows cannot cover it.
- Add `followVirtualDesktop` and `keepTopmost` switches (both default `true`).
- Re-assert topmost immediately after a desktop move, without stealing focus.

## 0.1.0 — 2026-10-22

- First release.
- Host half intercepts `approval/request` ahead of the DSH browser answerer.
- Always-on-top WPF card shows tool, project, reason, elapsed time and queue position.
- Allow once, reject, and delegate-back-to-DSH actions; `Enter`/`Esc` shortcuts.
- Tray icon, position memory, sound, and compact idle mode.
- Automatic fallback to the normal DSH approval card when the window is unavailable.
- Windows 10/11, DSH `0.2.1-rc.1` or newer, Windows PowerShell 5.1.
