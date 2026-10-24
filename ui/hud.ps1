# dsh-approval-hud Windows UI.
#
# A tiny always-on-top WPF card that polls the host plugin over loopback HTTP.
# This file is intentionally ASCII-only: all Chinese copy lives in hud.xaml or
# strings.<lang>.json, both read as UTF-8 by the XML/JSON parsers.

param(
  [Parameter(Mandatory = $true)][int]$Port,
  [string]$Token = '',
  [int]$ParentPid = 0,
  [string]$Language = 'zh',
  [string]$DataDir = '',
  [switch]$DebugLog,
  [string]$RenderTo = '',
  [ValidateSet('', 'allow', 'reject', 'delegate')][string]$AutoAnswer = '',
  [int]$AutoAnswerAfterMs = 1200,
  [int]$AutoStartMinutes = 0,
  [switch]$TestCustomDialog
)

# The host passes the token over our stdin pipe, never on the command line.
# A direct -Token argument is still accepted for the preview/smoke tools.
if ([string]::IsNullOrEmpty($Token)) {
  try { $Token = [Console]::In.ReadLine() } catch { $Token = '' }
}
if ([string]::IsNullOrEmpty($Token)) {
  try {
    $errorPath = Join-Path $env:TEMP 'dsh-approval-hud-token-error.log'
    [IO.File]::AppendAllText($errorPath, ('{0} ui started without a token`r`n' -f (Get-Date).ToString('o')))
  } catch { }
  exit 2
}

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

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern uint SetThreadExecutionState(uint esFlags);

    private const uint EsContinuous = 0x80000000u;
    private const uint EsSystemRequired = 0x00000001u;
    private const uint EsDisplayRequired = 0x00000002u;

    public static bool SetKeepAwake(bool enabled) {
      try {
        uint flags = EsContinuous | (enabled ? (EsSystemRequired | EsDisplayRequired) : 0u);
        return SetThreadExecutionState(flags) != 0;
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
$autoApproveButton = Get-Control 'AutoApproveButton'
$idleText = Get-Control 'IdleText'
$idleStopButton = Get-Control 'IdleStopButton'
$idleCountText = Get-Control 'IdleCountText'
$idleDot = Get-Control 'IdleDot'
$statusDot = Get-Control 'StatusDot'

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
$script:AutoApprove = $null
$script:AutoMinutes = 15
$script:AutoOptions = @(15, 30, 60)
$script:KeepAwake = $false
$script:IdleNormalBrush = $idleDot.Fill

function Set-Labels {
  $allowButton.Content = T 'allow' 'Allow once'
  $rejectButton.Content = T 'reject' 'Reject'
  $delegateButton.Content = T 'delegate' 'Handle in DSH'
  $statusText.Text = T 'waiting' 'Waiting for your approval'
  $footerText.Text = T 'footer' 'Enter allow - Esc reject'
  $idleText.Text = T 'idle' 'DSH Approval HUD - nothing pending'
  $subagentText.Text = T 'subagent' 'subagent'
  $autoApproveButton.ToolTip = T 'autoStartTip' 'Automatically approve requests for the selected time'
  $idleStopButton.Content = T 'autoStop' 'Stop auto-approve'
  $autoItems = @($script:Auto15MenuItem, $script:Auto30MenuItem, $script:Auto60MenuItem)
  for ($i = 0; $i -lt $autoItems.Count; $i++) {
    $autoItem = $autoItems[$i]
    if ($null -eq $autoItem) { continue }
    if ($i -lt $script:AutoOptions.Count) {
      $minutes = [int]$script:AutoOptions[$i]
      $autoItem.Text = (T 'trayAutoMinutes' 'Auto-approve for {0} min') -f $minutes
      $autoItem.Tag = $minutes
      $autoItem.Visible = $true
    } else {
      $autoItem.Visible = $false
    }
  }
  if ($null -ne $script:CustomAutoMenuItem) {
    $script:CustomAutoMenuItem.Text = T 'trayAutoCustom' 'Custom auto-approve duration...'
  }
  if ($null -ne $script:StopAutoMenuItem) {
    $script:StopAutoMenuItem.Text = T 'trayStopAuto' 'Stop auto-approve'
  }
  if ($null -ne $script:NotifyIcon) {
    $script:NotifyIcon.Text = T 'trayTip' 'DSH Approval HUD'
  }
  if ($null -ne $script:ShowMenuItem) {
    $script:ShowMenuItem.Text = T 'trayShow' 'Show approval window'
  }
  if ($null -ne $script:AllowCurrentMenuItem) {
    $script:AllowCurrentMenuItem.Text = T 'trayAllow' 'Allow current request'
  }
  if ($null -ne $script:RejectCurrentMenuItem) {
    $script:RejectCurrentMenuItem.Text = T 'trayReject' 'Reject current request'
  }
  if ($null -ne $script:QuitMenuItem) {
    $script:QuitMenuItem.Text = T 'trayQuit' 'Quit approval window'
  }
  Update-AutoApproveUi
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

function Reposition-Hud {
  if ($script:Quitting -or $null -eq $window -or -not $window.IsVisible) { return }
  # Do not fight an in-progress drag; the next tick will clamp it.
  if ([System.Windows.Input.Mouse]::LeftButton -eq [System.Windows.Input.MouseButtonState]::Pressed) { return }
  $area = [Windows.SystemParameters]::WorkArea
  $margin = 16
  $width = if ($window.ActualWidth -gt 0) { $window.ActualWidth } else { $window.Width }
  $height = if ($window.ActualHeight -gt 0) { $window.ActualHeight } else { $window.Height }
  if ($width -le 0 -or $height -le 0) { return }

  $targetLeft = $window.Left
  $targetTop = $window.Top
  if ($script:AnchorBottom) {
    $targetTop = $area.Bottom - $height - $margin
  }
  $maxTop = $area.Bottom - $height - $margin
  $minTop = $area.Top + $margin
  if ($targetTop -gt $maxTop) { $targetTop = $maxTop }
  if ($targetTop -lt $minTop) { $targetTop = $minTop }

  $maxLeft = $area.Right - $width - $margin
  $minLeft = $area.Left + $margin
  if ($targetLeft -gt $maxLeft) { $targetLeft = $maxLeft }
  if ($targetLeft -lt $minLeft) { $targetLeft = $minLeft }

  $changed = $false
  if ([Math]::Abs($window.Left - $targetLeft) -gt 0.5) { $window.Left = $targetLeft; $changed = $true }
  if ([Math]::Abs($window.Top - $targetTop) -gt 0.5) { $window.Top = $targetTop; $changed = $true }
  if ($changed) {
    Write-UiLog ('reposition left={0} top={1} size={2}x{3} workBottom={4}' -f $window.Left, $window.Top, $width, $height, $area.Bottom)
  }
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
  }
  Reposition-Hud
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
  Reposition-Hud
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
  $autoActive = $null -ne $script:AutoApprove -and [bool]$script:AutoApprove.active
  if ($mode -eq 'compact' -or $autoActive) {
    $card.Visibility = [System.Windows.Visibility]::Collapsed
    $idleBar.Visibility = [System.Windows.Visibility]::Visible
    if (-not $autoActive) {
      $idleText.Text = T 'idle' 'DSH Approval HUD - nothing pending'
      $idleStopButton.Visibility = [System.Windows.Visibility]::Collapsed
    }
    Show-HudWindow
    $window.UpdateLayout()
    Reposition-Hud
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
  } else {
    $window.UpdateLayout()
    Reposition-Hud
  }

  if ($IsNew -and $script:CurrentConfig -and [bool]$script:CurrentConfig.sound -and $script:LastSoundId -ne [string]$Item.id) {
    $script:LastSoundId = [string]$Item.id
    try { [System.Media.SystemSounds]::Asterisk.Play() } catch { }
  }
}

function Update-Tray {
  param([int]$Count)
  $autoActive = $null -ne $script:AutoApprove -and [bool]$script:AutoApprove.active
  $hasCurrent = $null -ne $script:CurrentItem -and -not $script:Busy
  if ($null -ne $script:AllowCurrentMenuItem) {
    $script:AllowCurrentMenuItem.Enabled = $hasCurrent
  }
  if ($null -ne $script:RejectCurrentMenuItem) {
    $script:RejectCurrentMenuItem.Enabled = $hasCurrent
  }
  if ($null -ne $script:StopAutoMenuItem) {
    $script:StopAutoMenuItem.Enabled = $autoActive
  }
  if ($null -eq $script:NotifyIcon) { return }
  try {
    if ($autoActive) {
      $clock = Format-Remaining ([int64]$script:AutoApprove.remainingMs)
      $script:NotifyIcon.Text = (T 'trayTipAuto' 'DSH Approval HUD - auto-approving {0}') -f $clock
    } elseif ($Count -gt 0) {
      $script:NotifyIcon.Text = (T 'trayTipPending' '{0} pending') -f $Count
    } else {
      $script:NotifyIcon.Text = T 'trayTip' 'DSH Approval HUD'
    }
  } catch {
    # NotifyIcon.Text is length-limited on some Windows versions.
  }
}

function Format-Remaining {
  param([int64]$Ms)
  if ($Ms -lt 0) { $Ms = 0 }
  $total = [int][Math]::Floor($Ms / 1000)
  $minutes = [int][Math]::Floor($total / 60)
  $seconds = $total % 60
  return ('{0:00}:{1:00}' -f $minutes, $seconds)
}

function Update-AutoApproveUi {
  $active = $false
  $remaining = [int64]0
  $count = 0
  if ($null -ne $script:AutoApprove) {
    $active = [bool]$script:AutoApprove.active
    $remaining = [int64]$script:AutoApprove.remainingMs
    $count = [int]$script:AutoApprove.count
  }
  $clock = Format-Remaining $remaining

  if ($active) {
    $autoApproveButton.Content = (T 'autoStopWithTime' 'Stop - {0}') -f $clock
    try { $autoApproveButton.Foreground = $window.FindResource('Warn') } catch { }
    $idleStopButton.Content = (T 'autoStopWithTime' 'Stop - {0}') -f $clock
    $idleStopButton.Visibility = [System.Windows.Visibility]::Visible
    try { $idleStopButton.Foreground = $window.FindResource('Warn') } catch { }
    try { $idleDot.Fill = $window.FindResource('Warn') } catch { }
    $idleText.Text = (T 'autoIdle' 'Auto-approving - {0} - {1} approved') -f $clock, $count
    $idleCountText.Text = ''
  } else {
    if ($null -ne $script:CurrentItem) {
      $autoApproveButton.Content = (T 'autoStartAndAllow' 'Approve & auto-approve {0} min') -f $script:AutoMinutes
    } else {
      $autoApproveButton.Content = (T 'autoStart' 'Auto-approve {0} min') -f $script:AutoMinutes
    }
    try { $autoApproveButton.ClearValue([System.Windows.Controls.Control]::ForegroundProperty) } catch { }
    $idleStopButton.Visibility = [System.Windows.Visibility]::Collapsed
    try { $idleStopButton.ClearValue([System.Windows.Controls.Control]::ForegroundProperty) } catch { }
    try { $idleDot.Fill = $script:IdleNormalBrush } catch { }
    $idleText.Text = T 'idle' 'DSH Approval HUD - nothing pending'
    $idleCountText.Text = ''
  }

  $keepAwake = $true
  if ($null -ne $script:CurrentConfig -and $null -ne $script:CurrentConfig.keepAwakeDuringAutoApprove) {
    $keepAwake = [bool]$script:CurrentConfig.keepAwakeDuringAutoApprove
  }
  if ($active -and $keepAwake) {
    if (-not $script:KeepAwake) {
      try {
        $keepResult = [DshApprovalHud.Native]::SetKeepAwake($true)
        $script:KeepAwake = $true
        Write-UiLog ('keep-awake on result=' + $keepResult)
      } catch {
        Write-UiLog ('keep-awake on failed: ' + $_.Exception.Message)
      }
    }
  } elseif ($script:KeepAwake) {
    try {
      $keepResult = [DshApprovalHud.Native]::SetKeepAwake($false)
      Write-UiLog ('keep-awake off result=' + $keepResult)
    } catch { }
    $script:KeepAwake = $false
  }

  if ($null -ne $script:CurrentItem -and -not $script:Busy) {
    $blocked = ''
    if ($null -ne $script:CurrentItem.autoApproveBlocked) {
      $blocked = [string]$script:CurrentItem.autoApproveBlocked
    }
    if ($blocked -eq 'dangerous') {
      $statusText.Text = T 'autoBlockedDanger' 'Auto-approve is on, but this sensitive request needs you'
    } elseif ($blocked -eq 'subagent') {
      $statusText.Text = T 'autoBlockedSubagent' 'Auto-approve is on, but this subagent request needs you'
    } elseif ($active) {
      $statusText.Text = (T 'autoActive' 'Auto-approving - {0}') -f $clock
    } else {
      $statusText.Text = T 'waiting' 'Waiting for your approval'
    }
  }

  Update-Tray $script:Pending.Count
}

function Start-AutoApprove {
  param([int]$Minutes)
  if ($script:Quitting) { return }
  if ($Minutes -lt 1 -or $Minutes -gt 480) { $Minutes = $script:AutoMinutes }
  if ($Minutes -lt 1) { $Minutes = 15 }

  $body = @{ minutes = $Minutes } | ConvertTo-Json -Compress
  $result = Invoke-HudApi -Method POST -Path '/auto-approve' -Body $body
  Write-UiLog ('auto-approve start {0}: ok={1} status={2}' -f $Minutes, $result.Ok, $result.Status)
  if (-not $result.Ok) {
    $statusText.Text = T 'error' 'Cannot reach DSH, retrying'
    return
  }

  $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $until = [int64]0
  try { $until = [int64]$result.Data.until } catch { $until = 0 }
  if ($until -le 0) { $until = $now + ($Minutes * 60000) }
  $script:AutoApprove = [pscustomobject]@{
    active = $true
    until = $until
    remainingMs = [Math]::Max(0, $until - $now)
    count = 0
    last = $null
  }
  Update-AutoApproveUi

  # The host resolves the current queue (except blocked entries); the next poll
  # redraws either the idle countdown or the remaining manual request.
  if ($null -eq $script:CurrentItem) {
    Show-Idle
    Update-AutoApproveUi
  }
}

function Stop-AutoApprove {
  if ($script:Quitting) { return }
  $result = Invoke-HudApi -Method POST -Path '/auto-approve/stop' -Body '{}'
  Write-UiLog ('auto-approve stop: ok={0} status={1}' -f $result.Ok, $result.Status)
  if (-not $result.Ok) {
    $statusText.Text = T 'error' 'Cannot reach DSH, retrying'
    return
  }
  $script:AutoApprove = [pscustomobject]@{
    active = $false
    until = 0
    remainingMs = 0
    count = 0
    last = $null
  }
  Update-AutoApproveUi
  if ($null -eq $script:CurrentItem) { Show-Idle }
}

function Show-AutoApproveDialog {
  if ($script:Quitting) { return }
  try {
    $dialog = New-Object System.Windows.Window
    $dialog.Title = T 'autoCustomTitle' 'Custom auto-approve duration'
    $dialog.Width = 360
    $dialog.SizeToContent = [System.Windows.SizeToContent]::Height
    $dialog.ResizeMode = [System.Windows.ResizeMode]::NoResize
    $dialog.WindowStartupLocation = [System.Windows.WindowStartupLocation]::CenterScreen
    $dialog.Topmost = $true
    $dialog.ShowInTaskbar = $false
    $dialog.Background = $window.FindResource('CardFill')
    $dialog.Foreground = $window.FindResource('TextPrimary')
    $dialog.FontFamily = [System.Windows.Media.FontFamily]::new('Segoe UI')

    $panel = New-Object System.Windows.Controls.StackPanel
    $panel.Margin = [System.Windows.Thickness]::new(18)

    $prompt = New-Object System.Windows.Controls.TextBlock
    $prompt.Text = T 'autoCustomPrompt' 'Minutes (1-480):'
    $prompt.Foreground = $window.FindResource('TextSecondary')
    $prompt.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)
    [void]$panel.Children.Add($prompt)

    $input = New-Object System.Windows.Controls.TextBox
    $input.Text = [string]$script:AutoMinutes
    $input.FontSize = 18
    $input.Padding = [System.Windows.Thickness]::new(8, 6, 8, 6)
    $input.Background = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(0x11, 0x15, 0x1C))
    $input.Foreground = $window.FindResource('TextPrimary')
    $input.BorderBrush = $window.FindResource('CardStroke')
    $input.CaretBrush = $window.FindResource('TextPrimary')
    [void]$panel.Children.Add($input)

    $errorText = New-Object System.Windows.Controls.TextBlock
    $errorText.Text = T 'autoCustomInvalid' 'Enter an integer between 1 and 480'
    $errorText.Foreground = $window.FindResource('Warn')
    $errorText.Margin = [System.Windows.Thickness]::new(0, 6, 0, 0)
    $errorText.Visibility = [System.Windows.Visibility]::Collapsed
    [void]$panel.Children.Add($errorText)

    $buttons = New-Object System.Windows.Controls.StackPanel
    $buttons.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $buttons.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
    $buttons.Margin = [System.Windows.Thickness]::new(0, 14, 0, 0)

    $cancel = New-Object System.Windows.Controls.Button
    $cancel.Content = T 'autoCustomCancel' 'Cancel'
    $cancel.Style = $window.FindResource('SecondaryButton')
    $cancel.IsCancel = $true
    $cancel.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
    [void]$buttons.Children.Add($cancel)

    $ok = New-Object System.Windows.Controls.Button
    $ok.Content = T 'autoCustomOk' 'Start'
    $ok.Style = $window.FindResource('PrimaryButton')
    $ok.IsDefault = $true
    [void]$buttons.Children.Add($ok)
    [void]$panel.Children.Add($buttons)

    $dialog.Content = $panel
    $script:DialogMinutes = 0
    $script:DialogWindow = $dialog
    $script:DialogInput = $input
    $script:DialogError = $errorText
    $script:DialogTestTimer = $null

    $ok.Add_Click({
      $parsed = 0
      if ([int]::TryParse($script:DialogInput.Text.Trim(), [ref]$parsed) -and $parsed -ge 1 -and $parsed -le 480) {
        $script:DialogMinutes = $parsed
        $script:DialogWindow.DialogResult = $true
      } else {
        $script:DialogError.Visibility = [System.Windows.Visibility]::Visible
      }
    })
    $cancel.Add_Click({
      $script:DialogWindow.DialogResult = $false
    })
    $dialog.Add_Loaded({
      $script:DialogInput.Focus()
      $script:DialogInput.SelectAll()
    })

    if ($TestCustomDialog) {
      $script:DialogTestTimer = New-Object System.Windows.Threading.DispatcherTimer
      $script:DialogTestTimer.Interval = [TimeSpan]::FromMilliseconds(250)
      $script:DialogTestTimer.Add_Tick({
        $script:DialogTestTimer.Stop()
        $script:DialogMinutes = 42
        $script:DialogWindow.DialogResult = $true
      })
      $script:DialogTestTimer.Start()
    }

    $result = $dialog.ShowDialog()
    $minutes = [int]$script:DialogMinutes
    $script:DialogWindow = $null
    $script:DialogInput = $null
    $script:DialogError = $null
    $script:DialogTestTimer = $null
    if ($result -eq $true -and $minutes -ge 1) {
      Start-AutoApprove $minutes
    }
  } catch {
    Write-UiLog ('custom auto-approve dialog failed: ' + $_.Exception.Message)
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
    if ($null -ne $config.autoApproveMinutes) {
      $minutes = [int]$config.autoApproveMinutes
      if ($minutes -ge 1 -and $minutes -le 480) { $script:AutoMinutes = $minutes }
    }
    $options = @()
    foreach ($value in @($config.autoApproveOptions)) {
      $option = [int]$value
      if ($option -ge 1 -and $option -le 480) { $options += $option }
    }
    if ($options.Count -gt 0) {
      $options = @($options | Select-Object -Unique | Select-Object -First 3)
      if (($options -join ',') -ne ($script:AutoOptions -join ',')) {
        $script:AutoOptions = $options
        Set-Labels
      }
    }
  }

  $auto = $state.autoApprove
  if ($null -ne $auto) {
    $script:AutoApprove = [pscustomobject]@{
      active = [bool]$auto.active
      until = [int64]$auto.until
      remainingMs = [int64]$auto.remainingMs
      count = [int]$auto.count
      last = $auto.last
    }
  } else {
    $script:AutoApprove = $null
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
    Show-Idle
    Update-AutoApproveUi
    if ($script:RenderTo -ne '' -and -not $script:Rendered -and $idleBar.Visibility -eq [System.Windows.Visibility]::Visible) {
      $script:Rendered = $true
      Render-Current -Path $script:RenderTo
      Write-UiLog ('rendered preview to {0}' -f $script:RenderTo)
      Quit
      return
    }
    Update-Tray 0
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
  Update-AutoApproveUi
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
  if ($script:KeepAwake) {
    try { [void][DshApprovalHud.Native]::SetKeepAwake($false) } catch { }
    $script:KeepAwake = $false
  }
  try { [void](Invoke-HudApi -Method POST -Path '/bye' -Body '{}') } catch { }
  try { if ($null -ne $script:NotifyIcon) { $script:NotifyIcon.Visible = $false; $script:NotifyIcon.Dispose() } } catch { }
  try { $window.Hide() } catch { }
  try { $script:App.Shutdown() } catch { }
}

# --- Tray presence -----------------------------------------------------------
# A missing tray must not take the approval card down with it.
$script:NotifyIcon = $null
$script:ShowMenuItem = $null
$script:AllowCurrentMenuItem = $null
$script:RejectCurrentMenuItem = $null
$script:Auto15MenuItem = $null
$script:Auto30MenuItem = $null
$script:Auto60MenuItem = $null
$script:CustomAutoMenuItem = $null
$script:StopAutoMenuItem = $null
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
  $script:AllowCurrentMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem
  $script:RejectCurrentMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem
  $script:Auto15MenuItem = New-Object System.Windows.Forms.ToolStripMenuItem
  $script:Auto30MenuItem = New-Object System.Windows.Forms.ToolStripMenuItem
  $script:Auto60MenuItem = New-Object System.Windows.Forms.ToolStripMenuItem
  $script:CustomAutoMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem
  $script:StopAutoMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem
  $script:QuitMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem
  $separatorOne = New-Object System.Windows.Forms.ToolStripSeparator
  $separatorTwo = New-Object System.Windows.Forms.ToolStripSeparator
  [void]$menu.Items.Add($script:ShowMenuItem)
  [void]$menu.Items.Add($script:AllowCurrentMenuItem)
  [void]$menu.Items.Add($script:RejectCurrentMenuItem)
  [void]$menu.Items.Add($separatorOne)
  [void]$menu.Items.Add($script:Auto15MenuItem)
  [void]$menu.Items.Add($script:Auto30MenuItem)
  [void]$menu.Items.Add($script:Auto60MenuItem)
  [void]$menu.Items.Add($script:CustomAutoMenuItem)
  [void]$menu.Items.Add($script:StopAutoMenuItem)
  [void]$menu.Items.Add($separatorTwo)
  [void]$menu.Items.Add($script:QuitMenuItem)
  $script:NotifyIcon.ContextMenuStrip = $menu
  $script:NotifyIcon.add_DoubleClick({ Show-Current })
  $script:ShowMenuItem.add_Click({ Show-Current })
  $script:AllowCurrentMenuItem.add_Click({ Send-Decision 'allow' })
  $script:RejectCurrentMenuItem.add_Click({ Send-Decision 'reject' })
  $script:Auto15MenuItem.add_Click({ Start-AutoApprove ([int]$script:Auto15MenuItem.Tag) })
  $script:Auto30MenuItem.add_Click({ Start-AutoApprove ([int]$script:Auto30MenuItem.Tag) })
  $script:Auto60MenuItem.add_Click({ Start-AutoApprove ([int]$script:Auto60MenuItem.Tag) })
  $script:CustomAutoMenuItem.add_Click({ Show-AutoApproveDialog })
  $script:StopAutoMenuItem.add_Click({ Stop-AutoApprove })
  $script:QuitMenuItem.add_Click({ Quit })
  $script:NotifyIcon.Visible = $true
} catch {
  Write-UiLog ('tray unavailable: ' + $_.Exception.Message)
  $script:NotifyIcon = $null
  $script:ShowMenuItem = $null
  $script:AllowCurrentMenuItem = $null
  $script:RejectCurrentMenuItem = $null
  $script:Auto15MenuItem = $null
  $script:Auto30MenuItem = $null
  $script:Auto60MenuItem = $null
  $script:CustomAutoMenuItem = $null
  $script:StopAutoMenuItem = $null
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
    if ($null -ne $script:AutoApprove -and [bool]$script:AutoApprove.active) {
      Stop-AutoApprove
    }
    $eventArgs.Cancel = $true
    Hide-HudWindow
  }
})

$window.Add_SizeChanged({
  if ($script:Shown -and -not $script:Quitting) {
    Reposition-Hud
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
$autoApproveButton.Add_Click({
  if ($null -ne $script:AutoApprove -and [bool]$script:AutoApprove.active) {
    Stop-AutoApprove
  } else {
    Start-AutoApprove $script:AutoMinutes
  }
})
$idleStopButton.Add_Click({ Stop-AutoApprove })

# --- Bootstrap ---------------------------------------------------------------
$script:SavedPosition = Load-SavedPosition

$script:Timer = New-Object System.Windows.Threading.DispatcherTimer
$script:Timer.Interval = [TimeSpan]::FromMilliseconds(350)
$script:Timer.Add_Tick({
  $script:Tick += 1
  Poll
  Update-Elapsed
  if ($script:Shown) { Reposition-Hud }
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
if ($AutoStartMinutes -gt 0) {
  Start-AutoApprove $AutoStartMinutes
}
if ($TestCustomDialog) {
  $script:OpenTimer = New-Object System.Windows.Threading.DispatcherTimer
  $script:OpenTimer.Interval = [TimeSpan]::FromMilliseconds(400)
  $script:OpenTimer.Add_Tick({
    $script:OpenTimer.Stop()
    Show-AutoApproveDialog
  })
  $script:OpenTimer.Start()
}
$script:LastSuccess = [DateTime]::UtcNow
$script:Timer.Start()
$script:App.Run()
Write-UiLog 'ui event loop ended'
