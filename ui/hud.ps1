# dsh-approval-hud Windows UI.
#
# A tiny always-on-top WPF card that polls the host plugin over loopback HTTP.
# This file is intentionally ASCII-only: all Chinese copy lives in hud.xaml or
# strings.<lang>.json, both read as UTF-8 by the XML/JSON parsers.

param(
  [Parameter(Mandatory = $true)][int]$Port,
  [Parameter(Mandatory = $true)][string]$Token,
  [int]$ParentPid = 0,
  [string]$Language = 'zh',
  [string]$DataDir = '',
  [switch]$DebugLog,
  [string]$RenderTo = '',
  [ValidateSet('', 'allow', 'reject', 'delegate')][string]$AutoAnswer = '',
  [int]$AutoAnswerAfterMs = 1200
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:DebugEnabled = [bool]$DebugLog
$script:DataDir = if (-not [string]::IsNullOrWhiteSpace($DataDir)) {
  $DataDir
} else {
  Join-Path $env:LOCALAPPDATA 'dsh-approval-hud'
}
$script:LogPath = Join-Path $script:DataDir 'ui.log'

function Write-UiLog {
  param([string]$Message)
  if (-not $script:DebugEnabled) { return }
  try {
    $dir = Split-Path -Parent $script:LogPath
    if (-not (Test-Path -LiteralPath $dir)) {
      New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $line = '{0} {1}' -f (Get-Date).ToString('o'), $Message
    Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
  } catch {
    # Diagnostics must never break the approval channel.
  }
}

# Per-monitor DPI awareness must be set before WPF creates its first window.
$nativeSource = @'
using System;
using System.Runtime.InteropServices;

namespace DshApprovalHud {
  public static class Native {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetProcessDpiAwarenessContext(IntPtr value);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetProcessDPIAware();

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr insertAfter, int x, int y, int cx, int cy, uint flags);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern int GetWindowLong(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr GetShellWindow();

    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr GetDesktopWindow();

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr FindWindow(string className, string windowName);

    [ComImport, Guid("AA509086-5CA9-4C25-8F95-589D3C07B48A")]
    private class VirtualDesktopManagerClass {
    }

    [ComImport, Guid("A5CD92FF-29BE-454C-8D04-D82879FB3F1B"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IVirtualDesktopManager {
      [PreserveSig]
      int IsWindowOnCurrentVirtualDesktop(IntPtr topLevelWindow, [MarshalAs(UnmanagedType.Bool)] out bool onCurrentDesktop);

      [PreserveSig]
      int GetWindowDesktopId(IntPtr topLevelWindow, out Guid desktopId);

      [PreserveSig]
      int MoveWindowToDesktop(IntPtr topLevelWindow, [In] ref Guid desktopId);
    }

    private static IVirtualDesktopManager virtualDesktopManager;
    private static bool virtualDesktopManagerLoaded;

    private static IVirtualDesktopManager VirtualDesktopManager {
      get {
        if (!virtualDesktopManagerLoaded) {
          virtualDesktopManagerLoaded = true;
          try {
            virtualDesktopManager = (IVirtualDesktopManager)new VirtualDesktopManagerClass();
          } catch {
            virtualDesktopManager = null;
          }
        }
        return virtualDesktopManager;
      }
    }

    public static bool VirtualDesktopSupported() {
      return VirtualDesktopManager != null;
    }

    public static bool IsOnCurrentVirtualDesktop(IntPtr hWnd) {
      IVirtualDesktopManager manager = VirtualDesktopManager;
      if (manager == null || hWnd == IntPtr.Zero) return true;
      try {
        bool onCurrent;
        return manager.IsWindowOnCurrentVirtualDesktop(hWnd, out onCurrent) == 0 ? onCurrent : true;
      } catch {
        return true;
      }
    }

    public static Guid CurrentVirtualDesktopId() {
      IVirtualDesktopManager manager = VirtualDesktopManager;
      if (manager == null) return Guid.Empty;
      IntPtr source = GetForegroundWindow();
      if (source == IntPtr.Zero) source = GetShellWindow();
      if (source == IntPtr.Zero) source = FindWindow("Shell_TrayWnd", null);
      if (source == IntPtr.Zero) source = GetDesktopWindow();
      if (source == IntPtr.Zero) return Guid.Empty;
      try {
        Guid id;
        return manager.GetWindowDesktopId(source, out id) == 0 ? id : Guid.Empty;
      } catch {
        return Guid.Empty;
      }
    }

    public static bool MoveToCurrentVirtualDesktop(IntPtr hWnd) {
      IVirtualDesktopManager manager = VirtualDesktopManager;
      if (manager == null || hWnd == IntPtr.Zero) return false;
      Guid id = CurrentVirtualDesktopId();
      if (id == Guid.Empty) return false;
      try {
        return manager.MoveWindowToDesktop(hWnd, ref id) == 0;
      } catch {
        return false;
      }
    }
  }
}
'@

try {
  Add-Type -TypeDefinition $nativeSource -ErrorAction Stop
} catch {
  # A reused runspace may already contain the type; calling it below is enough.
}
try {
  [void][DshApprovalHud.Native]::SetProcessDpiAwarenessContext([IntPtr](-4))
} catch {
  try { [void][DshApprovalHud.Native]::SetProcessDPIAware() } catch { }
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Loopback only: never let a system proxy intercept the token-bearing calls.
[System.Net.WebRequest]::DefaultWebProxy = $null

# Create the WPF application before any Window so the dispatcher and shutdown
# semantics are owned by this process rather than a default application.
$script:App = New-Object System.Windows.Application
$script:App.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown

function Load-Strings {
  param([string]$Lang)
  $path = Join-Path $PSScriptRoot ('strings.{0}.json' -f $Lang)
  if (-not (Test-Path -LiteralPath $path)) {
    $path = Join-Path $PSScriptRoot 'strings.zh.json'
  }
  $text = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
  return ($text | ConvertFrom-Json)
}

$script:Language = if ($Language -in @('zh', 'en')) { $Language } else { 'zh' }
$script:Strings = Load-Strings $script:Language

function T {
  param([string]$Key, [string]$Fallback = '')
  if ($null -eq $script:Strings) { return $Fallback }
  $value = $script:Strings.$Key
  if ($null -eq $value) { return $Fallback }
  return [string]$value
}

$stream = [IO.File]::OpenRead((Join-Path $PSScriptRoot 'hud.xaml'))
try {
  $window = [Windows.Markup.XamlReader]::Load($stream)
} finally {
  $stream.Dispose()
}

$window.ShowActivated = $false
$window.Topmost = $true
$window.WindowStartupLocation = [System.Windows.WindowStartupLocation]::Manual

function Get-Control {
  param([string]$ControlName)
  $control = $window.FindName($ControlName)
  if ($null -eq $control) {
    throw "hud.xaml is missing the named control '$ControlName'"
  }
  return $control
}

$card = Get-Control 'Card'
$idleBar = Get-Control 'IdleBar'
$header = Get-Control 'Header'
$idleHeader = Get-Control 'IdleHeader'
$statusText = Get-Control 'StatusText'
$elapsedText = Get-Control 'ElapsedText'
$counterText = Get-Control 'CounterText'
$toolText = Get-Control 'ToolText'
$projectChip = Get-Control 'ProjectChip'
$projectText = Get-Control 'ProjectText'
$subagentChip = Get-Control 'SubagentChip'
$subagentText = Get-Control 'SubagentText'
$reasonScroll = Get-Control 'ReasonScroll'
$reasonText = Get-Control 'ReasonText'
$delegateButton = Get-Control 'DelegateButton'
$rejectButton = Get-Control 'RejectButton'
$allowButton = Get-Control 'AllowButton'
$footerText = Get-Control 'FooterText'
$idleText = Get-Control 'IdleText'
$idleCountText = Get-Control 'IdleCountText'

$script:CurrentConfig = $null
$script:CurrentItem = $null
$script:Pending = @()
$script:ActiveId = ''
$script:LastSoundId = ''
$script:Busy = $false
$script:Quitting = $false
$script:Shown = $false
$script:Positioned = $false
$script:AnchorBottom = $true
$script:Tick = 0
$script:FailCount = 0
$script:LastSuccess = [DateTime]::UtcNow
$script:AutoAnswered = $false
$script:AutoTargetId = ''
$script:AutoSeenAt = $null
$script:Rendered = $false
$script:SavedPosition = $null
$script:RenderTo = $RenderTo
$script:LastDesktopAttempt = [DateTime]::MinValue
$script:LastDesktopFailureLog = [DateTime]::MinValue

function Set-Labels {
  $allowButton.Content = T 'allow' 'Allow once'
  $rejectButton.Content = T 'reject' 'Reject'
  $delegateButton.Content = T 'delegate' 'Handle in DSH'
  $statusText.Text = T 'waiting' 'Waiting for your approval'
  $footerText.Text = T 'footer' 'Enter allow - Esc reject'
  $idleText.Text = T 'idle' 'DSH Approval HUD - nothing pending'
  $subagentText.Text = T 'subagent' 'subagent'
  if ($null -ne $script:NotifyIcon) {
    $script:NotifyIcon.Text = T 'trayTip' 'DSH Approval HUD'
  }
  if ($null -ne $script:ShowMenuItem) {
    $script:ShowMenuItem.Text = T 'trayShow' 'Show approval window'
  }
  if ($null -ne $script:QuitMenuItem) {
    $script:QuitMenuItem.Text = T 'trayQuit' 'Quit approval window'
  }
}

function Invoke-HudApi {
  param(
    [string]$Method,
    [string]$Path,
    [string]$Body = $null
  )

  $uri = 'http://127.0.0.1:{0}{1}' -f $Port, $Path
  $params = @{
    Uri = $uri
    Method = $Method
    TimeoutSec = 2
    Headers = @{ 'X-DSH-Approval-Token' = $Token }
  }
  if (-not [string]::IsNullOrEmpty($Body)) {
    $params.Body = $Body
    $params.ContentType = 'application/json; charset=utf-8'
  }

  try {
    $data = Invoke-RestMethod @params
    return [pscustomobject]@{ Ok = $true; Status = 200; Data = $data; Error = '' }
  } catch {
    $status = 0
    try {
      if ($null -ne $_.Exception.Response) {
        $status = [int]$_.Exception.Response.StatusCode
      }
    } catch {
      $status = 0
    }
    return [pscustomobject]@{ Ok = $false; Status = $status; Data = $null; Error = $_.Exception.Message }
  }
}

function Test-OnScreen {
  param([double]$Left, [double]$Top)
  $vsLeft = [Windows.SystemParameters]::VirtualScreenLeft
  $vsTop = [Windows.SystemParameters]::VirtualScreenTop
  $vsRight = $vsLeft + [Windows.SystemParameters]::VirtualScreenWidth
  $vsBottom = $vsTop + [Windows.SystemParameters]::VirtualScreenHeight
  return ($Left -ge ($vsLeft - 120) -and $Top -ge ($vsTop - 80) -and $Left -lt $vsRight -and $Top -lt $vsBottom)
}

function Load-SavedPosition {
  try {
    $path = Join-Path $script:DataDir 'window.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $raw = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
    $saved = $raw | ConvertFrom-Json
    if ($null -eq $saved.left -or $null -eq $saved.top) { return $null }
    $left = [double]$saved.left
    $top = [double]$saved.top
    if (-not (Test-OnScreen -Left $left -Top $top)) { return $null }
    return [pscustomobject]@{ Left = $left; Top = $top }
  } catch {
    return $null
  }
}

function Save-Position {
  try {
    $dir = $script:DataDir
    if (-not (Test-Path -LiteralPath $dir)) {
      New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $value = @{
      left = [Math]::Round($window.Left, 1)
      top = [Math]::Round($window.Top, 1)
    } | ConvertTo-Json -Compress
    [IO.File]::WriteAllText((Join-Path $dir 'window.json'), $value, (New-Object Text.UTF8Encoding($false)))
  } catch {
    # Position memory is a convenience, not a requirement.
  }
}

function Place-Window {
  $area = [Windows.SystemParameters]::WorkArea
  $width = $window.Width
  $height = if ($window.ActualHeight -gt 0) { $window.ActualHeight } else { 260 }
  $margin = 16
  $position = 'bottom-right'
  if ($null -ne $script:CurrentConfig -and -not [string]::IsNullOrEmpty([string]$script:CurrentConfig.position)) {
    $position = [string]$script:CurrentConfig.position
  }

  if ($null -ne $script:SavedPosition) {
    $window.Left = $script:SavedPosition.Left
    $window.Top = $script:SavedPosition.Top
    # Keep growing upward when the user parked the window in the lower half.
    $script:AnchorBottom = ($script:SavedPosition.Top -gt ($area.Top + $area.Height / 2))
    return
  }

  $left = $area.Right - $width - $margin
  $top = $area.Bottom - $height - $margin
  $script:AnchorBottom = $true
  switch ($position) {
    'top-left' {
      $left = $area.Left + $margin
      $top = $area.Top + $margin
      $script:AnchorBottom = $false
    }
    'top-right' {
      $left = $area.Right - $width - $margin
      $top = $area.Top + $margin
      $script:AnchorBottom = $false
    }
    'bottom-left' {
      $left = $area.Left + $margin
      $top = $area.Bottom - $height - $margin
      $script:AnchorBottom = $true
    }
    default {
      $left = $area.Right - $width - $margin
      $top = $area.Bottom - $height - $margin
      $script:AnchorBottom = $true
    }
  }
  $window.Left = $left
  $window.Top = $top
}

function Keep-Topmost {
  if ($script:Quitting -or $null -eq $window -or -not $window.IsVisible) { return }
  $keep = $true
  if ($null -ne $script:CurrentConfig -and $null -ne $script:CurrentConfig.keepTopmost) {
    $keep = [bool]$script:CurrentConfig.keepTopmost
  }
  if (-not $keep) { return }
  try {
    $helper = New-Object System.Windows.Interop.WindowInteropHelper($window)
    if ($helper.Handle -ne [IntPtr]::Zero) {
      # HWND_TOPMOST, SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE
      [void][DshApprovalHud.Native]::SetWindowPos($helper.Handle, [IntPtr](-1), 0, 0, 0, 0, 0x0013)
    }
  } catch {
    # WPF's Topmost property remains the fallback.
  }
}

function Sync-VirtualDesktop {
  param([switch]$Force)
  if ($script:Quitting -or $null -eq $window -or -not $window.IsVisible) { return }
  $follow = $true
  if ($null -ne $script:CurrentConfig -and $null -ne $script:CurrentConfig.followVirtualDesktop) {
    $follow = [bool]$script:CurrentConfig.followVirtualDesktop
  }
  if (-not $follow) { return }
  # Do not yank the window while the user is dragging it between monitors.
  if ([System.Windows.Input.Mouse]::LeftButton -eq [System.Windows.Input.MouseButtonState]::Pressed) { return }
  if (-not $Force -and ([DateTime]::UtcNow - $script:LastDesktopAttempt).TotalMilliseconds -lt 500) { return }
  $script:LastDesktopAttempt = [DateTime]::UtcNow
  try {
    if (-not [DshApprovalHud.Native]::VirtualDesktopSupported()) {
      if (([DateTime]::UtcNow - $script:LastDesktopFailureLog).TotalSeconds -gt 60) {
        $script:LastDesktopFailureLog = [DateTime]::UtcNow
        Write-UiLog 'virtual desktop: IVirtualDesktopManager unavailable'
      }
      return
    }
    $helper = New-Object System.Windows.Interop.WindowInteropHelper($window)
    $hwnd = $helper.Handle
    if ($hwnd -eq [IntPtr]::Zero) { return }
    if ([DshApprovalHud.Native]::IsOnCurrentVirtualDesktop($hwnd)) { return }
    if ([DshApprovalHud.Native]::MoveToCurrentVirtualDesktop($hwnd)) {
      Write-UiLog 'virtual desktop: moved to current'
      Keep-Topmost
    } elseif (([DateTime]::UtcNow - $script:LastDesktopFailureLog).TotalSeconds -gt 60) {
      $script:LastDesktopFailureLog = [DateTime]::UtcNow
      Write-UiLog 'virtual desktop: move failed'
    }
  } catch {
    if (([DateTime]::UtcNow - $script:LastDesktopFailureLog).TotalSeconds -gt 60) {
      $script:LastDesktopFailureLog = [DateTime]::UtcNow
      Write-UiLog ('virtual desktop error: ' + $_.Exception.Message)
    }
  }
}

function Show-HudWindow {
  Write-UiLog ('show-window visible=' + $window.IsVisible + ' positioned=' + $script:Positioned)
  if (-not $window.IsVisible) {
    if (-not $script:Positioned) {
      $window.Left = -20000
      $window.Top = -20000
    }
    $window.Show()
  }
  $window.UpdateLayout()
  if (-not $script:Positioned) {
    Place-Window
    $script:Positioned = $true
  } elseif ($script:AnchorBottom) {
    $area = [Windows.SystemParameters]::WorkArea
    $window.Top = $area.Bottom - $window.ActualHeight - 16
  }
  $window.Topmost = $true
  Write-UiLog ('after-show visible=' + $window.IsVisible + ' actual=' + $window.ActualWidth + 'x' + $window.ActualHeight + ' left=' + $window.Left + ' top=' + $window.Top + ' title=' + $window.Title)
  try {
    $helper = New-Object System.Windows.Interop.WindowInteropHelper($window)
    Write-UiLog ('hwnd=' + $helper.Handle)
    # HWND_TOPMOST, SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE
    [void][DshApprovalHud.Native]::SetWindowPos($helper.Handle, [IntPtr](-1), 0, 0, 0, 0, 0x0013)
    $exStyle = [DshApprovalHud.Native]::GetWindowLong($helper.Handle, -20)
    $foreground = [DshApprovalHud.Native]::GetForegroundWindow()
    Write-UiLog ('exstyle=0x{0:X} topmost={1} focused={2}' -f $exStyle, [bool]($exStyle -band 0x8), ($foreground -eq $helper.Handle))
  } catch {
    # Topmost from WPF is enough if the native call is unavailable.
  }
  try {
    $helper = New-Object System.Windows.Interop.WindowInteropHelper($window)
    $onCurrent = [DshApprovalHud.Native]::IsOnCurrentVirtualDesktop($helper.Handle)
    $currentId = [DshApprovalHud.Native]::CurrentVirtualDesktopId()
    Write-UiLog ('desktop supported=' + [DshApprovalHud.Native]::VirtualDesktopSupported() + ' onCurrent=' + $onCurrent + ' current=' + $currentId)
  } catch { }
  Sync-VirtualDesktop -Force
  $script:Shown = $true
}

function Hide-HudWindow {
  if ($window.IsVisible) { $window.Hide() }
  $script:Shown = $false
}

function Show-Idle {
  $mode = 'hide'
  if ($null -ne $script:CurrentConfig -and -not [string]::IsNullOrEmpty([string]$script:CurrentConfig.idleMode)) {
    $mode = [string]$script:CurrentConfig.idleMode
  }
  if ($mode -eq 'compact') {
    $card.Visibility = [System.Windows.Visibility]::Collapsed
    $idleBar.Visibility = [System.Windows.Visibility]::Visible
    $idleText.Text = T 'idle' 'DSH Approval HUD - nothing pending'
    Show-HudWindow
  } else {
    Hide-HudWindow
  }
}

function Update-Elapsed {
  if ($null -eq $script:CurrentItem) {
    $elapsedText.Text = ''
    return
  }
  $created = [int64]$script:CurrentItem.createdAt
  $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $seconds = [Math]::Max(0, [int](($now - $created) / 1000))
  if ($seconds -lt 2) {
    $elapsedText.Text = T 'justNow' 'just now'
  } else {
    $elapsedText.Text = (T 'waited' 'waiting {0}s') -f $seconds
  }
}

function Set-ButtonsEnabled {
  param([bool]$Enabled)
  $allowButton.IsEnabled = $Enabled
  $rejectButton.IsEnabled = $Enabled
  $delegateButton.IsEnabled = $Enabled
}

function Show-Item {
  param($Item, [int]$Index, [int]$Total, [bool]$IsNew)
  $card.Visibility = [System.Windows.Visibility]::Visible
  $idleBar.Visibility = [System.Windows.Visibility]::Collapsed
  $statusText.Text = T 'waiting' 'Waiting for your approval'

  $tool = if ($null -ne $Item.toolName -and -not [string]::IsNullOrWhiteSpace([string]$Item.toolName)) {
    [string]$Item.toolName
  } else {
    'tool'
  }
  $toolText.Text = $tool
  Write-UiLog ('show-item tool=' + $tool + ' total=' + $Total + ' new=' + $IsNew)
  $toolText.ToolTip = $tool

  $project = if ($null -ne $Item.project) { [string]$Item.project } else { '' }
  $projectText.Text = $project
  $projectText.ToolTip = $project
  if ([string]::IsNullOrWhiteSpace($project)) {
    $projectChip.Visibility = [System.Windows.Visibility]::Collapsed
  } else {
    $projectChip.Visibility = [System.Windows.Visibility]::Visible
  }

  if ($null -ne $Item.subagent -and [bool]$Item.subagent) {
    $subagentChip.Visibility = [System.Windows.Visibility]::Visible
  } else {
    $subagentChip.Visibility = [System.Windows.Visibility]::Collapsed
  }

  $reason = if ($null -ne $Item.reason) { [string]$Item.reason } else { '' }
  if ([string]::IsNullOrWhiteSpace($reason)) {
    $reason = (T 'defaultReason' 'Tool {0} requests a sensitive operation.') -f $tool
  }
  if ($null -ne $Item.reasonTruncated -and [bool]$Item.reasonTruncated) {
    $reason = $reason + (T 'truncated' '')
  }
  $reasonText.Text = $reason
  $reasonText.ToolTip = $reason
  if ($IsNew) {
    $reasonScroll.ScrollToHome()
  }

  $counterText.Text = (T 'counter' '{0} / {1}') -f ($Index + 1), $Total
  Update-Elapsed

  if (-not $script:Shown) {
    Show-HudWindow
  }

  if ($IsNew -and $script:CurrentConfig -and [bool]$script:CurrentConfig.sound -and $script:LastSoundId -ne [string]$Item.id) {
    $script:LastSoundId = [string]$Item.id
    try { [System.Media.SystemSounds]::Asterisk.Play() } catch { }
  }
}

function Update-Tray {
  param([int]$Count)
  if ($null -eq $script:NotifyIcon) { return }
  try {
    if ($Count -gt 0) {
      $script:NotifyIcon.Text = (T 'trayTipPending' '{0} pending') -f $Count
    } else {
      $script:NotifyIcon.Text = T 'trayTip' 'DSH Approval HUD'
    }
  } catch {
    # NotifyIcon.Text is length-limited on some Windows versions.
  }
}

function Send-Ready {
  for ($attempt = 0; $attempt -lt 6; $attempt++) {
    $result = Invoke-HudApi -Method POST -Path '/ready' -Body '{}'
    if ($result.Ok) { return $true }
    Start-Sleep -Milliseconds 250
  }
  return $false
}

function Send-Decision {
  param([string]$Decision)
  if ($script:Busy -or $null -eq $script:CurrentItem) { return }
  $id = [string]$script:CurrentItem.id
  if ([string]::IsNullOrEmpty($id)) { return }

  $script:Busy = $true
  Set-ButtonsEnabled $false
  if ($Decision -eq 'allow') {
    $statusText.Text = T 'approved' 'Allowed. Waiting for the next step...'
  } elseif ($Decision -eq 'reject') {
    $statusText.Text = T 'rejected' 'Rejected. Waiting for the next step...'
  }

  $body = @{ id = $id; decision = $Decision } | ConvertTo-Json -Compress
  $result = Invoke-HudApi -Method POST -Path '/answer' -Body $body
  Write-UiLog ('answer {0} {1}: ok={2} status={3}' -f $id, $Decision, $result.Ok, $result.Status)

  if ($result.Ok) {
    if ($Decision -eq 'delegate') { Hide-HudWindow }
    $script:ActiveId = ''
    $script:CurrentItem = $null
    $script:Pending = @()
    $script:Busy = $false
    Set-ButtonsEnabled $true
    Poll
    return
  }

  if ($result.Status -eq 409) {
    $statusText.Text = T 'gone' 'This request was already handled'
    $script:ActiveId = ''
    $script:CurrentItem = $null
    $script:Busy = $false
    Set-ButtonsEnabled $true
    Poll
    return
  }

  $statusText.Text = T 'error' 'Cannot reach DSH, retrying'
  $script:Busy = $false
  Set-ButtonsEnabled $true
}

function Poll {
  if ($script:Quitting) { return }

  $path = '/state?token=' + [Uri]::EscapeDataString($Token)
  $result = Invoke-HudApi -Method GET -Path $path
  if (-not $result.Ok) {
    $script:FailCount += 1
    if ($script:FailCount -eq 8) {
      Write-UiLog ('state polling failed: {0}' -f $result.Error)
    }
    $silentFor = ([DateTime]::UtcNow - $script:LastSuccess).TotalSeconds
    if ($silentFor -gt 45) {
      Write-UiLog 'host has been unreachable for 45s; exiting UI'
      Quit
    }
    return
  }

  $script:FailCount = 0
  $script:LastSuccess = [DateTime]::UtcNow

  $state = $result.Data
  if ($null -eq $state) { return }

  $config = $state.config
  if ($null -ne $config) {
    $stateLanguage = [string]$config.language
    if ($stateLanguage -in @('zh', 'en') -and $stateLanguage -ne $script:Language) {
      $script:Language = $stateLanguage
      $script:Strings = Load-Strings $stateLanguage
      Set-Labels
    }
    $script:CurrentConfig = $config
  }

  # Assigning an if-expression would unroll a one-element array into a scalar;
  # build the array explicitly so Count and indexing stay reliable.
  $items = @()
  if ($null -ne $state.pending) { $items = @($state.pending) }
  $script:Pending = $items
  $total = $items.Count
  if ($null -eq $total -or $total -lt 1) { $total = 1 }
  Write-UiLog ('state pending count={0}' -f $items.Count)

  if ($items.Count -eq 0) {
    $script:CurrentItem = $null
    $script:ActiveId = ''
    $script:AutoSeenAt = $null
    $script:AutoTargetId = ''
    if ($script:Busy) { $script:Busy = $false }
    Set-ButtonsEnabled $true
    Update-Tray 0
    Show-Idle
    return
  }

  $item = $items[0]
  $itemId = [string]$item.id
  $isNew = ($itemId -ne $script:ActiveId)
  if ($isNew) {
    $script:ActiveId = $itemId
    $script:ActiveItemSeenAt = [DateTime]::UtcNow
    if ($script:Busy) { $script:Busy = $false }
    Set-ButtonsEnabled $true
  }
  $script:CurrentItem = $item
  Show-Item -Item $item -Index 0 -Total $total -IsNew $isNew
  Update-Tray $total

  if ($script:RenderTo -ne '' -and -not $script:Rendered) {
    $script:Rendered = $true
    Render-Current -Path $script:RenderTo
    Write-UiLog ('rendered preview to {0}' -f $script:RenderTo)
    Quit
    return
  }

  if ($AutoAnswer -ne '' -and -not $script:AutoAnswered) {
    if ($script:AutoTargetId -ne $itemId) {
      $script:AutoTargetId = $itemId
      $script:AutoSeenAt = [DateTime]::UtcNow
    }
    if ($null -ne $script:AutoSeenAt -and ([DateTime]::UtcNow - $script:AutoSeenAt).TotalMilliseconds -ge $AutoAnswerAfterMs) {
      $script:AutoAnswered = $true
      Send-Decision $AutoAnswer
    }
  }
}

function Render-Current {
  param([string]$Path)
  $window.UpdateLayout()
  $width = [int][Math]::Ceiling($window.ActualWidth)
  $height = [int][Math]::Ceiling($window.ActualHeight)
  if ($width -le 0 -or $height -le 0) {
    throw 'window has no layout size'
  }
  $bitmap = New-Object Windows.Media.Imaging.RenderTargetBitmap($width, $height, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
  $bitmap.Render($window.Content)
  $encoder = New-Object Windows.Media.Imaging.PngBitmapEncoder
  $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
  $stream = [IO.File]::Open($Path, [IO.FileMode]::Create)
  try { $encoder.Save($stream) } finally { $stream.Dispose() }
}

function Show-Current {
  if ($null -ne $script:CurrentItem) {
    Show-HudWindow
    return
  }
  try {
    $script:NotifyIcon.ShowBalloonTip(2500, (T 'trayTip' 'DSH Approval HUD'), (T 'idle' 'Nothing pending'), [System.Windows.Forms.ToolTipIcon]::Info)
  } catch {
    # Balloons can be disabled by the system.
  }
}

function Quit {
  if ($script:Quitting) { return }
  $script:Quitting = $true
  try { $script:Timer.Stop() } catch { }
  try { [void](Invoke-HudApi -Method POST -Path '/bye' -Body '{}') } catch { }
  try { if ($null -ne $script:NotifyIcon) { $script:NotifyIcon.Visible = $false; $script:NotifyIcon.Dispose() } } catch { }
  try { $window.Hide() } catch { }
  try { $script:App.Shutdown() } catch { }
}

# --- Tray presence -----------------------------------------------------------
# A missing tray must not take the approval card down with it.
$script:NotifyIcon = $null
$script:ShowMenuItem = $null
$script:QuitMenuItem = $null
try {
  $script:NotifyIcon = New-Object System.Windows.Forms.NotifyIcon
  $icon = $null
  try { $icon = [System.Drawing.SystemIcons]::Shield } catch { $icon = $null }
  if ($null -eq $icon) {
    try { $icon = [System.Drawing.SystemIcons]::Application } catch { $icon = $null }
  }
  if ($null -ne $icon) { $script:NotifyIcon.Icon = $icon }
  $script:NotifyIcon.Text = T 'trayTip' 'DSH Approval HUD'

  $menu = New-Object System.Windows.Forms.ContextMenuStrip
  $script:ShowMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem
  $script:QuitMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem
  [void]$menu.Items.Add($script:ShowMenuItem)
  [void]$menu.Items.Add($script:QuitMenuItem)
  $script:NotifyIcon.ContextMenuStrip = $menu
  $script:NotifyIcon.add_DoubleClick({ Show-Current })
  $script:ShowMenuItem.add_Click({ Show-Current })
  $script:QuitMenuItem.add_Click({ Quit })
  $script:NotifyIcon.Visible = $true
} catch {
  Write-UiLog ('tray unavailable: ' + $_.Exception.Message)
  $script:NotifyIcon = $null
  $script:ShowMenuItem = $null
  $script:QuitMenuItem = $null
}

Set-Labels

# --- Window events -----------------------------------------------------------
$dragHandler = {
  try {
    $window.DragMove()
  } catch {
    return
  }
  $script:SavedPosition = [pscustomobject]@{ Left = $window.Left; Top = $window.Top }
  $script:AnchorBottom = $false
  Save-Position
}
$header.Add_MouseLeftButtonDown($dragHandler)
$idleHeader.Add_MouseLeftButtonDown($dragHandler)

$window.Add_Closing({
  param($sender, $eventArgs)
  if (-not $script:Quitting) {
    $eventArgs.Cancel = $true
    Hide-HudWindow
  }
})

$window.Add_SizeChanged({
  if ($script:Shown -and $script:AnchorBottom -and -not $script:Quitting) {
    try {
      $area = [Windows.SystemParameters]::WorkArea
      $window.Top = $area.Bottom - $window.ActualHeight - 16
    } catch { }
  }
})

$window.Add_PreviewKeyDown({
  param($sender, $eventArgs)
  if ($script:Quitting -or $script:Busy -or $null -eq $script:CurrentItem) { return }
  if ($eventArgs.Key -eq [System.Windows.Input.Key]::Enter) {
    Send-Decision 'allow'
    $eventArgs.Handled = $true
  } elseif ($eventArgs.Key -eq [System.Windows.Input.Key]::Escape) {
    Send-Decision 'reject'
    $eventArgs.Handled = $true
  }
})

$allowButton.Add_Click({ Send-Decision 'allow' })
$rejectButton.Add_Click({ Send-Decision 'reject' })
$delegateButton.Add_Click({ Send-Decision 'delegate' })

# --- Bootstrap ---------------------------------------------------------------
$script:SavedPosition = Load-SavedPosition

$script:Timer = New-Object System.Windows.Threading.DispatcherTimer
$script:Timer.Interval = [TimeSpan]::FromMilliseconds(350)
$script:Timer.Add_Tick({
  $script:Tick += 1
  Poll
  Update-Elapsed
  if (($script:Tick % 2) -eq 0) { Sync-VirtualDesktop }
  if (($script:Tick % 5) -eq 0) { Keep-Topmost }
  if ($ParentPid -gt 0 -and ($script:Tick % 20) -eq 0) {
    try {
      $parent = Get-Process -Id $ParentPid -ErrorAction SilentlyContinue
      if ($null -eq $parent) { Quit }
    } catch { }
  }
})

Write-UiLog ('ui starting pid={0} parent={1} port={2}' -f $PID, $ParentPid, $Port)
[void](Send-Ready)
$script:LastSuccess = [DateTime]::UtcNow
$script:Timer.Start()
$script:App.Run()
Write-UiLog 'ui event loop ended'
