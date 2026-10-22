<#
.SYNOPSIS
  library - interactive Google Drive <-> local library sync (books, papers, sioyek annotations).
.DESCRIPTION
  library                  interactive menu (vim keys: j/k move, enter/l open, h/esc back, q quit)
  library status           print sync status and exit
  library pull|push|merge [-Yes] [-Force]
  library setup            re-run first-time setup
  library uninstall        remove the tool from this device (asks before touching your files)

  Everything is driven by rclone. Per-device settings live in %APPDATA%\library-sync (never synced).
  Works on Windows PowerShell 5.1 and PowerShell 7+.
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [ValidateSet('menu', 'status', 'pull', 'push', 'merge', 'setup', 'uninstall', 'help', 'version')]
  [string]$Command = 'menu',
  [Alias('y')][switch]$Yes,
  [switch]$Force
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$Version = '1.2.0'
$Self = $PSCommandPath
$CfgDir = if ($env:LIBRARY_SYNC_HOME) { $env:LIBRARY_SYNC_HOME } else { Join-Path $env:APPDATA 'library-sync' }
$CfgFile = Join-Path $CfgDir 'config'
$StateFile = Join-Path $CfgDir 'state'
$FilterFile = Join-Path $CfgDir 'filters.rclone'
$ManifestFile = Join-Path $CfgDir 'manifest'
$AnnotDir = 'sioyek'
$MarkerDir = '.library-sync'
# logs\ and .trash\ are per-device: never selectable as a synced folder.
function Test-SyncFolder([string]$f) { return @('logs', '.trash') -notcontains $f.Split('/')[0] }
$CommonExts = @('pdf', 'epub', 'djvu', 'mobi', 'azw3', 'cbz', 'cbr', 'fb2', 'txt', 'md')
$MinRcloneMinor = 60
$HostId = if ($env:COMPUTERNAME) { $env:COMPUTERNAME -replace '[^A-Za-z0-9._-]', '_' } else { 'unknown' }
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$env:RCLONE_ASK_PASSWORD = 'false'

$Cfg = [ordered]@{
  LIBRARY_ROOT = (Join-Path $env:USERPROFILE 'library')
  REMOTE       = 'gdrive'
  REMOTE_PATH  = 'library'
  REMOTE_TRASH = 'library-trash'
  FOLDERS      = @('content', $AnnotDir)
  FILTER_MODE  = 'none'
  FILTER_EXT   = @()
  TRANSFERS    = 4
  CHECKERS     = 8
  TPSLIMIT     = 10
  BWLIMIT      = ''
  SIOYEK_ASKED = 0
}
$State = @{ LAST_PULL = ''; LAST_PUSH = ''; LAST_MERGE = '' }
# Runtime state (kept in one table so functions never need $script: scoping)
$Run = @{
  DiffReady = $false; RemoteMissing = $false; Rows = $null; Cnt = @{}; LocalN = 0; LocalB = 0; RemoteN = 0; RemoteB = 0
  Markers = ''; About = ''; DiffTime = ''; MenuPos = @{}; DirCache = (New-Object Collections.Hashtable ([StringComparer]::Ordinal))
  Rclone = $null; Sqlite = $null; Tmp = $null; KeyQueue = $null; Interactive = $false; LastRc = 0; MenuKey = ''; ViewAction = ''; RemoteOk = $false; ConfFile = ''; Prefetch = $null; Quit = $false
}

# ------------------------------------------------------------------ colours --
$Ansi = [char]27
$Interactive = -not [Console]::IsOutputRedirected -and -not [Console]::IsInputRedirected
if ($Interactive -and -not $env:NO_COLOR) {
  $C0 = "$Ansi[0m"; $CB = "$Ansi[1m"; $CD = "$Ansi[2m"; $CR = "$Ansi[31m"; $CG = "$Ansi[32m"; $CY = "$Ansi[33m"
  $CBL = "$Ansi[34m"; $CM = "$Ansi[35m"; $CC = "$Ansi[36m"; $CRV = "$Ansi[7m"
} else {
  $C0 = $CB = $CD = $CR = $CG = $CY = $CBL = $CM = $CC = $CRV = ''
}
$Run.Interactive = $Interactive

$CatKeys = @('changes', 'radd', 'rnew', 'ladd', 'lnew', 'ren', 'size', 'same')
$CatLabel = @{ changes = 'All changes'; radd = 'New on remote'; rnew = 'Newer on remote'; ladd = 'New locally'
  lnew = 'Newer locally'; ren = 'Renamed'; size = 'Conflicts'; same = 'In sync' }
$CatSym = @{ radd = [string][char]0x2193 + '+'; rnew = [string][char]0x2193 + '~'; ladd = [string][char]0x2191 + '+'
  lnew = [string][char]0x2191 + '~'; ren = ' ' + [char]0xBB; size = '!' + [char]0x2260; same = ' =' }
$CatCol = @{ radd = $CG; rnew = $CC; ladd = $CY; lnew = $CM; ren = $CBL; size = $CR; same = $CD }
$Arrow = [char]0x2192; $Sync = [char]0x21C4; $Tick = [char]0x2714; $Cross = [char]0x2718; $Ptr = [char]0x203A; $Ell = [char]0x2026

# ------------------------------------------------------------------ helpers --
function Say([string]$s = '') { [Console]::Out.WriteLine($s) }
function Write-Info([string]$s) { Say "$CBL::$C0 $s" }
function Write-Ok([string]$s) { Say "$CG$Tick$C0 $s" }
function Write-Warn([string]$s) { Say "$CY!$C0 $s" }
function Write-Err([string]$s) { Say "$CR$Cross$C0 $s" }
function Clear-Screen { if ($Run.Interactive) { [Console]::Write("$Ansi[H$Ansi[2J$Ansi[3J") } }
# Redraw in place (home, overwrite each line, clear the rest) - no full clear, so no flicker.
function Write-Frame([string]$s) { [Console]::Write("$Ansi[H" + $s.Replace("`n", "$Ansi[K`n") + "$Ansi[K$Ansi[J") }
function Set-Cursor([bool]$on) { if ($Run.Interactive) { try { [Console]::CursorVisible = $on } catch { } } }
function Get-Tilde([string]$p) {
  if ($p.StartsWith($env:USERPROFILE, [StringComparison]::OrdinalIgnoreCase)) { return '~' + $p.Substring($env:USERPROFILE.Length) }
  return $p
}
function Get-NowIso { (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz') }
function Get-TermSize {
  try { return @([Math]::Max([Console]::WindowHeight, 10), [Math]::Max([Console]::WindowWidth, 40)) } catch { return @(24, 80) }
}

function Format-Size($b) {
  $n = 0L
  if (-not [long]::TryParse([string]$b, [ref]$n)) { return '-' }
  if ($n -lt 1024) { return "${n}B" }
  $u = 'KB', 'MB', 'GB', 'TB'; $x = $n / 1024.0; $i = 0
  while ($x -ge 1024 -and $i -lt 3) { $x /= 1024; $i++ }
  return ('{0:0.0}{1}' -f $x, $u[$i])
}

function ConvertTo-Epoch([string]$iso) {
  if (-not $iso -or $iso -eq '-') { return 0L }
  $d = [DateTimeOffset]::MinValue
  if ([DateTimeOffset]::TryParse($iso, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$d)) { return $d.ToUnixTimeSeconds() }
  return 0L
}

function Format-Ago([string]$iso) {
  $t = ConvertTo-Epoch $iso
  if ($t -eq 0) { return 'never' }
  $d = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $t
  $rel = if ($d -lt 60) { 'just now' } elseif ($d -lt 3600) { '{0}m ago' -f [int][Math]::Floor($d / 60) } elseif ($d -lt 86400) { '{0}h ago' -f [int][Math]::Floor($d / 3600) } else { '{0}d ago' -f [int][Math]::Floor($d / 86400) }
  return '{0} ({1})' -f [DateTimeOffset]::FromUnixTimeSeconds($t).ToLocalTime().ToString('yyyy-MM-dd HH:mm'), $rel
}

# Read-Key -> normalised key: j k h l g G enter esc space tab btab bs ctrl-d ctrl-u or the character
function Read-Key {
  if ($null -ne $Run.KeyQueue) {
    if ($Run.KeyQueue.Count -eq 0) { return 'q' }
    return $Run.KeyQueue.Dequeue()
  }
  $k = [Console]::ReadKey($true)
  $ctrl = ($k.Modifiers -band [ConsoleModifiers]::Control) -ne 0
  switch ([string]$k.Key) {
    'UpArrow' { return 'k' } 'DownArrow' { return 'j' } 'LeftArrow' { return 'h' } 'RightArrow' { return 'l' }
    'Enter' { return 'enter' } 'Escape' { return 'esc' } 'Spacebar' { return 'space' } 'Backspace' { return 'bs' }
    'PageDown' { return 'ctrl-d' } 'PageUp' { return 'ctrl-u' } 'Home' { return 'g' } 'End' { return 'G' }
    'Tab' { if ($k.Modifiers -band [ConsoleModifiers]::Shift) { return 'btab' } return 'tab' }
  }
  if ($ctrl -and [string]$k.Key -eq 'D') { return 'ctrl-d' }
  if ($ctrl -and [string]$k.Key -eq 'U') { return 'ctrl-u' }
  return [string]$k.KeyChar
}

function Wait-AnyKey { [Console]::Write("`n${CD}press any key$Ell$C0"); $null = Read-Key; Say }

function Read-YesNo([string]$q, [string]$def = 'n') {
  $hint = if ($def -eq 'y') { '[Y/n]' } else { '[y/N]' }
  [Console]::Write("$q $CD$hint$C0 ")
  while ($true) {
    $k = Read-Key
    if ($k -ceq 'y' -or $k -ceq 'Y') { Say 'y'; return $true }
    if ($k -ceq 'n' -or $k -ceq 'N' -or $k -ceq 'q' -or $k -eq 'esc') { Say 'n'; return $false }
    if ($k -eq 'enter') { Say $def; return ($def -eq 'y') }
  }
}

# Read-Line PROMPT [DEFAULT] - empty answer keeps the default
function Read-Secret([string]$prompt) {
  if ($null -ne $Run.KeyQueue) { return '' }
  Set-Cursor $true
  $sec = Read-Host -Prompt $prompt -AsSecureString
  Set-Cursor $false
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
  try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Read-Line([string]$prompt, [string]$def = '') {
  Set-Cursor $true
  if ($null -ne $Run.KeyQueue) { $a = ''; } else {
    $p = if ($def) { "$prompt [$def]" } else { $prompt }
    $a = Read-Host -Prompt $p
  }
  Set-Cursor $false
  if ([string]::IsNullOrWhiteSpace($a)) { return $def }
  return $a.Trim()
}

function Test-RelPath([string]$p) {
  if ($p -match '^/|/$|\\|:|[\r\n]') { return $false }
  $x = "/$p/"
  return -not ($x.Contains('/../') -or $x.Contains('/./'))
}

function ConvertTo-GlobEscaped([string]$s) { return [regex]::Replace($s, '([\\*?\[\]{}])', '\$1') }

function Get-RPath([string]$sub = '') {
  $p = $Cfg.REMOTE_PATH
  if ($sub) { $p = if ($p) { "$p/$sub" } else { $sub } }
  return "$($Cfg.REMOTE):$p"
}

function Write-Atomic([string]$file, [string]$text) {
  $dir = Split-Path -Parent $file
  if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Force -Path $dir }
  $tmp = "$file.tmp.$PID"
  [IO.File]::WriteAllText($tmp, $text, $Utf8)
  Move-Item -LiteralPath $tmp -Destination $file -Force
}

# ------------------------------------------------------------------- config --
function Set-Kv([string]$k, [string]$v) {
  switch -CaseSensitive ($k) {
    'LIBRARY_ROOT' { if ($v -and [IO.Path]::IsPathRooted($v)) { $Cfg.LIBRARY_ROOT = $v } }
    'REMOTE' { if ($v -match '^[A-Za-z0-9_.][A-Za-z0-9_. -]*$') { $Cfg.REMOTE = $v } }
    'REMOTE_PATH' { if (Test-RelPath $v) { $Cfg.REMOTE_PATH = $v } }
    'REMOTE_TRASH' { if ($v -and (Test-RelPath $v)) { $Cfg.REMOTE_TRASH = $v } }
    'FOLDERS' { $Cfg.FOLDERS = @($v -split '\|' | Where-Object { $_ -and (Test-RelPath $_) -and (Test-SyncFolder $_) }) }
    'FILTER_MODE' { if ($v -cmatch '^(none|exclude|include)$') { $Cfg.FILTER_MODE = $v } }
    'FILTER_EXT' { $Cfg.FILTER_EXT = @($v -split '\s+' | Where-Object { $_ -match '^[A-Za-z0-9]{1,10}$' } | ForEach-Object { $_.ToLowerInvariant() }) }
    'TRANSFERS' { if ($v -match '^\d{1,3}$') { $Cfg.TRANSFERS = [int]$v } }
    'CHECKERS' { if ($v -match '^\d{1,3}$') { $Cfg.CHECKERS = [int]$v } }
    'TPSLIMIT' { if ($v -match '^\d{1,3}$') { $Cfg.TPSLIMIT = [int]$v } }
    'BWLIMIT' { if ($v -match '^[0-9A-Za-z.:, -]*$') { $Cfg.BWLIMIT = $v } }
    'SIOYEK_ASKED' { if ($v -eq '1') { $Cfg.SIOYEK_ASKED = 1 } }
    'LAST_PULL' { if ($v -match '^[0-9T:+.-]*$') { $State.LAST_PULL = $v } }
    'LAST_PUSH' { if ($v -match '^[0-9T:+.-]*$') { $State.LAST_PUSH = $v } }
    'LAST_MERGE' { if ($v -match '^[0-9T:+.-]*$') { $State.LAST_MERGE = $v } }
  }
}

# Parsed with an allow-list - nothing in these files is ever executed.
function Read-Kv([string]$file) {
  if (-not (Test-Path -LiteralPath $file)) { return $false }
  foreach ($line in [IO.File]::ReadAllLines($file)) {
    if ($line -match '^\s*#' -or $line.IndexOf('=') -lt 1) { continue }
    $i = $line.IndexOf('=')
    Set-Kv $line.Substring(0, $i) $line.Substring($i + 1).TrimEnd("`r")
  }
  return $true
}

function Save-Config {
  $t = "# library.ps1 per-device config - edit through the menu`n"
  foreach ($k in $Cfg.Keys) {
    $v = $Cfg[$k]
    if ($k -eq 'FOLDERS') { $v = @($v) -join '|' } elseif ($k -eq 'FILTER_EXT') { $v = @($v) -join ' ' }
    $t += "$k=$v`n"
  }
  Write-Atomic $CfgFile $t
}

function Save-State { Write-Atomic $StateFile ("LAST_PULL={0}`nLAST_PUSH={1}`nLAST_MERGE={2}`n" -f $State.LAST_PULL, $State.LAST_PUSH, $State.LAST_MERGE) }

function Get-FilterDesc {
  $e = @($Cfg.FILTER_EXT) -join ', '
  if ($Cfg.FILTER_MODE -eq 'none' -or @($Cfg.FILTER_EXT).Count -eq 0) { return 'all file types' }
  if ($Cfg.FILTER_MODE -eq 'exclude') { return "excluding $e" }
  return "only $e"
}

# ------------------------------------------------------------------- rclone --
function Update-RclonePath {
  $c = Get-Command rclone -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  $Run.Rclone = if ($c) { $c.Source } else { $null }
  return [bool]$Run.Rclone
}

# Windows command-line quoting (CommandLineToArgvW rules, which rclone/Go follow).
function ConvertTo-QuotedArg([string]$s) {
  if ($s.Length -gt 0 -and $s -notmatch '[\s"]') { return $s }
  $sb = New-Object Text.StringBuilder; [void]$sb.Append('"'); $bs = 0
  foreach ($c in $s.ToCharArray()) {
    if ($c -eq '\') { $bs++; continue }
    if ($c -eq '"') { [void]$sb.Append('\', $bs * 2 + 1).Append('"'); $bs = 0; continue }
    if ($bs) { [void]$sb.Append('\', $bs) }; $bs = 0
    [void]$sb.Append($c)
  }
  if ($bs) { [void]$sb.Append('\', $bs * 2) }
  return $sb.Append('"').ToString()
}

# Start rclone with captured output (async, so several can run in parallel).
function Start-Rc([string[]]$argv) {
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = $Run.Rclone
  $psi.Arguments = (@($argv | ForEach-Object { ConvertTo-QuotedArg $_ }) -join ' ')
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = $Utf8; $psi.StandardErrorEncoding = $Utf8
  $p = [Diagnostics.Process]::Start($psi)
  return [pscustomobject]@{ P = $p; Out = $p.StandardOutput.ReadToEndAsync(); Err = $p.StandardError.ReadToEndAsync() }
}
function Wait-Rc($h) { $h.P.WaitForExit(); return [pscustomobject]@{ Code = $h.P.ExitCode; Out = $h.Out.Result; Err = $h.Err.Result } }
function Invoke-Rc([string[]]$argv) { return Wait-Rc (Start-Rc $argv) }

function Get-BaseFlags {
  return @('--drive-skip-gdocs', '--tpslimit', [string]$Cfg.TPSLIMIT, '--checkers', [string]$Cfg.CHECKERS,
    '--contimeout', '20s', '--timeout', '5m', '--retries', '3', '--low-level-retries', '10')
}

function Get-RcloneMinor {
  $r = Invoke-Rc @('version')
  if ($r.Out -match 'rclone v1\.(\d+)') { return [int]$Matches[1] }
  return 0
}

function Get-RemoteType {
  $r = Invoke-Rc @('listremotes', '--long')
  foreach ($l in $r.Out -split "`r?`n") {
    $f = $l.Trim() -split '\s+'
    if ($f.Count -ge 2 -and $f[0] -ceq "$($Cfg.REMOTE):") { return $f[1] }
  }
  return ''
}

function Show-RcloneError([string]$text) {
  $lines = @($text -split "`r?`n" | Where-Object { $_ -match 'ERROR|NOTICE|Failed|error' })
  $lines | Select-Object -Last 8 | ForEach-Object { Say "  $CD$_$C0" }
  if ($text -match 'invalid_grant|token.*(expired|revoked)|couldn.t fetch token|oauth2') {
    Write-Warn 'Google Drive authorisation looks expired. Use Settings -> Drive connection -> Reconnect.'
  } elseif ($text -match 'no such host|dial tcp|timeout|network is unreachable') {
    Write-Warn 'Network problem - check your connection.'
  } elseif ($text -match "didn.t find section in config file|not found in config") {
    Write-Warn "Remote '$($Cfg.REMOTE)' is not configured. Use Settings -> Drive connection."
  }
}

# scoop keeps rclone.conf in rclone's app folder, hard-linked to scoop\persist. rclone saves by
# replacing the file, which breaks the link, so the next 'scoop update rclone' would lose the Drive
# login. Keep the config at rclone's usual %APPDATA%\rclone\rclone.conf instead (via RCLONE_CONFIG).
function Use-StableRcloneConfig {
  if ($env:RCLONE_CONFIG) { return }
  $target = Join-Path $env:APPDATA 'rclone\rclone.conf'
  $cur = ((Invoke-Rc @('config', 'file')).Out -split "`r?`n" | Where-Object { $_ } | Select-Object -Last 1)
  $scoop = (Get-ScoopRoot).TrimEnd('\') + '\'
  if (-not $cur -or $cur -ieq $target -or -not $cur.StartsWith($scoop, [StringComparison]::OrdinalIgnoreCase)) { return }
  if (-not (Test-Path -LiteralPath $target)) {
    $src = $null
    foreach ($c in $cur, (Join-Path $scoop 'persist\rclone\rclone.conf')) {
      if ((Test-Path -LiteralPath $c) -and (Get-Item -LiteralPath $c).Length -gt 0) { $src = $c; break }
    }
    $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target)
    if ($src) {
      Copy-Item -LiteralPath $src -Destination $target
      # Don't leave a second copy of the OAuth token behind.
      if ((Get-Item -LiteralPath $target).Length -eq (Get-Item -LiteralPath $src).Length) { [IO.File]::WriteAllText($src, '') }
      Write-Ok "Moved the rclone config out of scoop's app folder to $(Get-Tilde $target)"
    }
  }
  $env:RCLONE_CONFIG = $target; $Run.ConfFile = ''
  if ($Run.Interactive -and [Environment]::GetEnvironmentVariable('RCLONE_CONFIG', 'User') -ne $target) {
    [Environment]::SetEnvironmentVariable('RCLONE_CONFIG', $target, 'User')
  }
}

function Unlock-Rclone {
  if ($env:RCLONE_CONFIG_PASS -or $env:RCLONE_PASSWORD_COMMAND) { return }
  $f = ((Invoke-Rc @('config', 'file')).Out -split "`r?`n" | Where-Object { $_ } | Select-Object -Last 1)
  if (-not $f -or -not (Test-Path -LiteralPath $f)) { return }
  $head = [IO.File]::ReadAllText($f); if ($head.Length -gt 40) { $head = $head.Substring(0, 40) }
  if ($head -notmatch 'RCLONE_ENCRYPT_V0') { return }
  for ($i = 1; $i -le 3; $i++) {
    $env:RCLONE_CONFIG_PASS = Read-Secret 'rclone config password'
    if ((Invoke-Rc @('listremotes')).Code -eq 0) { return }
    Remove-Item Env:RCLONE_CONFIG_PASS
    Write-Err "Wrong password ($i/3)"
  }
  throw 'Could not unlock the rclone config.'
}

# One filter file selects the synced folders and applies this device's type filter.
# rclone uses first-match-wins, which gives "folder AND type" semantics.
function Build-Filters {
  if (@($Cfg.FOLDERS).Count -eq 0) { Write-Err "No folders selected. Use 'Folders' to pick some."; return $false }
  $useTypes = -not ($Cfg.FILTER_MODE -eq 'none' -or @($Cfg.FILTER_EXT).Count -eq 0)
  $l = New-Object Collections.Generic.List[string]
  $l.Add('# generated by library.ps1 - do not edit (rebuilt before every run)')
  foreach ($r in '- /.trash/**', '- /logs/**', '- desktop.ini', '- Thumbs.db', '- .DS_Store', '- ~$*', '- .~lock.*#', '- *.partial') { $l.Add($r) }
  foreach ($f in $Cfg.FOLDERS) {
    $ef = ConvertTo-GlobEscaped $f
    if ($f -ceq $AnnotDir -or $f.StartsWith("$AnnotDir/", [StringComparison]::Ordinal)) {
      foreach ($r in "- /$ef/**.db-journal", "- /$ef/**.db-wal", "- /$ef/**.db-shm", "+ /$ef/**") { $l.Add($r) }
    } elseif ($useTypes -and $Cfg.FILTER_MODE -eq 'exclude') {
      foreach ($e in $Cfg.FILTER_EXT) { $l.Add("- /$ef/**.$e") }
      $l.Add("+ /$ef/**")
    } elseif ($useTypes) {
      foreach ($e in $Cfg.FILTER_EXT) { $l.Add("+ /$ef/**.$e") }
    } else { $l.Add("+ /$ef/**") }
  }
  $l.Add('- **')
  Write-Atomic $FilterFile (($l -join "`n") + "`n")
  return $true
}

# --------------------------------------------------------------------- diff --
function ConvertFrom-Lsf([string]$text) {
  $d = New-Object 'Collections.Generic.Dictionary[string,string[]]' ([StringComparer]::Ordinal)
  foreach ($line in $text.Split("`n")) {
    $line = $line.TrimEnd("`r")
    if (-not $line) { continue }
    $f = $line.Split("`t")
    if ($f.Count -ge 3) { $d[$f[0]] = $f }
  }
  return , $d
}

# What a listing depends on; a prefetched listing is only used if this is unchanged.
function Get-ListSig { return "$($Cfg.LIBRARY_ROOT)|$(Get-RPath)|$([IO.File]::ReadAllText($FilterFile))" }

# Start the four Status listings in parallel (Build-Filters must have run).
function Start-Listings {
  $base = Get-BaseFlags
  $lf = @('lsf', '-R', '--files-only', '--fast-list', '--format', 'pst', '--separator', "`t", '--filter-from', $FilterFile, '--ignore-case') + $base
  $h = [pscustomobject]@{ At = Get-Date; Sig = Get-ListSig; L = $null; R = $null; M = $null; A = $null }
  if (Test-Path -LiteralPath $Cfg.LIBRARY_ROOT) { $h.L = Start-Rc ($lf + @('--', $Cfg.LIBRARY_ROOT)) }
  $h.R = Start-Rc ($lf + @('--', (Get-RPath)))
  $h.M = Start-Rc (@('cat') + $base + @('--', (Get-RPath $MarkerDir)))
  $h.A = Start-Rc (@('about', '--json') + $base + @('--', "$($Cfg.REMOTE):"))
  return $h
}

# Called while the main menu waits for a key, so Status (or a sync preview) is usually instant.
function Start-Prefetch {
  if ($Run.DiffReady -or -not $Run.Rclone -or @($Cfg.FOLDERS).Count -eq 0) { return }
  if ($Run.Prefetch -and ((Get-Date) - $Run.Prefetch.At).TotalSeconds -lt 60) { return }
  if (Build-Filters) { $Run.Prefetch = Start-Listings }
}

function Invoke-ComputeDiff {
  $Run.DiffReady = $false; $Run.RemoteMissing = $false
  if (-not (Build-Filters)) { return $false }
  $h = $Run.Prefetch; $Run.Prefetch = $null
  if (-not $h -or ((Get-Date) - $h.At).TotalSeconds -gt 120 -or $h.Sig -cne (Get-ListSig)) {
    Say "${CD}Listing $(Get-Tilde $Cfg.LIBRARY_ROOT) and $(Get-RPath) $Ell$C0"
    $h = Start-Listings
  }
  $lr = if ($h.L) { Wait-Rc $h.L } else { [pscustomobject]@{ Code = 0; Out = ''; Err = '' } }
  $rr = Wait-Rc $h.R
  $Run.Markers = (Wait-Rc $h.M).Out
  $Run.About = (Wait-Rc $h.A).Out
  if ($lr.Code) { Write-Err 'Listing local files failed:'; Show-RcloneError $lr.Err; return $false }
  $rout = $rr.Out
  if ($rr.Code) {
    if ($rr.Err -match 'directory not found') { $rout = ''; $Run.RemoteMissing = $true }
    else { Write-Err "Listing $(Get-RPath) failed:"; Show-RcloneError $rr.Err; return $false }
  }
  $loc = ConvertFrom-Lsf $lr.Out
  $rem = ConvertFrom-Lsf $rout
  $Run.LocalN = $loc.Count; $Run.RemoteN = $rem.Count
  $Run.LocalB = 0L; foreach ($v in $loc.Values) { $Run.LocalB += [long]$v[1] }
  $Run.RemoteB = 0L; foreach ($v in $rem.Values) { $Run.RemoteB += [long]$v[1] }
  $cnt = @{ same = 0; radd = 0; rnew = 0; ladd = 0; lnew = 0; ren = 0; size = 0 }
  $rows = New-Object Collections.Generic.List[object]
  foreach ($kv in $rem.GetEnumerator()) {
    $p = $kv.Key; $r = $kv.Value; $l = $null
    if ($loc.TryGetValue($p, [ref]$l)) {
      $cmp = [string]::CompareOrdinal($l[2], $r[2])
      $c = if ($l[1] -eq $r[1] -and $cmp -eq 0) { 'same' } elseif ($cmp -gt 0) { 'lnew' } elseif ($cmp -lt 0) { 'rnew' } else { 'size' }
      $rows.Add([pscustomobject]@{ C = $c; P = $p; Q = ''; D = ''; LS = $l[1]; LT = $l[2]; RS = $r[1]; RT = $r[2] })
      [void]$loc.Remove($p)
    } else {
      $c = 'radd'
      $rows.Add([pscustomobject]@{ C = $c; P = $p; Q = ''; D = ''; LS = '-'; LT = '-'; RS = $r[1]; RT = $r[2] })
    }
    $cnt[$c]++
  }
  foreach ($kv in $loc.GetEnumerator()) {
    $rows.Add([pscustomobject]@{ C = 'ladd'; P = $kv.Key; Q = ''; D = ''; LS = $kv.Value[1]; LT = $kv.Value[2]; RS = '-'; RT = '-' })
    $cnt.ladd++
  }
  $rows = Join-Renames $rows $cnt
  $keys = New-Object Collections.Generic.List[string]
  foreach ($r in $rows) { $keys.Add($r.P) }
  # Cast to [Array] so the non-generic overload sorts these exact arrays (not converted copies).
  $ka = [Array]$keys.ToArray(); $ra = [Array]$rows.ToArray()
  [Array]::Sort($ka, $ra, [Collections.IComparer][StringComparer]::Ordinal)
  $Run.Rows = $ra; $Run.Cnt = $cnt
  $Run.DiffTime = $h.At.ToString('HH:mm:ss'); $Run.DiffReady = $true
  return $true
}

# A file only on the remote and one only here with the same size and modification time is one
# file renamed or moved. The manifest (paths after the last sync) tells which side renamed it.
function Join-Renames($rows, $cnt) {
  $lk = New-Object 'Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
  $rk = New-Object 'Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
  $dup = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  foreach ($r in $rows) {
    if ($r.C -eq 'ladd') { $k = "$($r.LS)|$($r.LT)"; $d = $lk } elseif ($r.C -eq 'radd') { $k = "$($r.RS)|$($r.RT)"; $d = $rk } else { continue }
    if ($k.StartsWith('0|')) { continue }
    if ($d.ContainsKey($k)) { [void]$dup.Add($k) } else { $d[$k] = $r }
  }
  $out = New-Object Collections.Generic.List[object]
  $man = $null
  foreach ($kv in $rk.GetEnumerator()) {
    $l = $null
    if ($dup.Contains($kv.Key) -or -not $lk.TryGetValue($kv.Key, [ref]$l)) { continue }
    if ($null -eq $man) { $man = Read-Manifest }
    $r = $kv.Value
    $d = if ($man.Contains($l.P) -and -not $man.Contains($r.P)) { 'remote' } elseif ($man.Contains($r.P) -and -not $man.Contains($l.P)) { 'local' } else { '' }
    $out.Add([pscustomobject]@{ C = 'ren'; P = $r.P; Q = $l.P; D = $d; LS = $l.LS; LT = $l.LT; RS = $r.RS; RT = $r.RT })
    $l.C = ''; $r.C = ''; $cnt.ren++; $cnt.ladd--; $cnt.radd--
  }
  foreach ($r in $rows) { if ($r.C) { $out.Add($r) } }
  return , $out
}

# Paths present after the last successful sync.
function Save-Manifest {
  if (-not (Test-Path -LiteralPath $Cfg.LIBRARY_ROOT) -or -not (Build-Filters)) { return }
  $r = Invoke-Rc @('lsf', '-R', '--files-only', '--filter-from', $FilterFile, '--ignore-case', '--', $Cfg.LIBRARY_ROOT)
  if ($r.Code -eq 0) { Write-Atomic $ManifestFile $r.Out }
}

function Read-Manifest {
  $s = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  if (Test-Path -LiteralPath $ManifestFile) { foreach ($l in [IO.File]::ReadAllLines($ManifestFile)) { if ($l) { [void]$s.Add($l) } } }
  return , $s
}

# Display path; a rename shows old -> new.
function Get-RowPath($r) {
  if ($r.C -ne 'ren') { return $r.P }
  switch ($r.D) {
    'remote' { return "$($r.Q) $Arrow $($r.P)  (renamed on remote)" }
    'local' { return "$($r.P) $Arrow $($r.Q)  (renamed here)" }
    default { return "here: $($r.Q)  remote: $($r.P)" }
  }
}

# Merge: give each renamed file the same name on both sides ($unknown: l|r|b for undecided ones).
function Invoke-Renames([string]$unknown) {
  foreach ($r in $Run.Rows) {
    if ($r.C -ne 'ren') { continue }
    $side = if ($r.D -eq 'remote') { 'r' } elseif ($r.D -eq 'local') { 'l' } else { $unknown }
    if ($side -eq 'r') {
      $src = Join-Path $Cfg.LIBRARY_ROOT ($r.Q.Replace('/', '\')); $dst = Join-Path $Cfg.LIBRARY_ROOT ($r.P.Replace('/', '\'))
      if (Test-Path -LiteralPath $dst) { continue }
      try { $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst); [IO.File]::Move($src, $dst) }
      catch { Write-Err "Could not rename $($r.Q): $($_.Exception.Message)"; return $false }
      Say "  $CBL$($CatSym.ren)$C0 here: $($r.Q) $Arrow $($r.P)"; Add-LogLine "rename local $($r.Q) -> $($r.P)"
    } elseif ($side -eq 'l') {
      $x = Invoke-Rc (@('moveto') + (Get-BaseFlags) + @('--', (Get-RPath $r.P), (Get-RPath $r.Q)))
      if ($x.Code) { Write-Err "Could not rename $(Get-RPath $r.P)"; Show-RcloneError $x.Err; return $false }
      Say "  $CBL$($CatSym.ren)$C0 remote: $($r.P) $Arrow $($r.Q)"; Add-LogLine "rename remote $($r.P) -> $($r.Q)"
    }
  }
  return $true
}

function Get-DeviceLines {
  if (-not $Run.Markers) { return @(" ${CD}No device history on the remote yet$C0") }
  $out = @(); $lp = ConvertTo-Epoch $State.LAST_PULL
  $devs = @(); $cur = $null
  foreach ($line in $Run.Markers -split "`r?`n") {
    $i = $line.IndexOf('='); if ($i -lt 1) { continue }
    $k = $line.Substring(0, $i); $v = $line.Substring($i + 1)
    if ($k -eq 'host') { $cur = @{ host = $v; push = '-'; pull = '-' }; $devs += $cur }
    elseif ($cur -and $k -eq 'last_push') { $cur.push = $v }
    elseif ($cur -and $k -eq 'last_pull') { $cur.pull = $v }
  }
  foreach ($d in $devs) {
    $mark = ''
    if ($d.host -eq $HostId) { $mark = " $CD(this device)$C0" }
    elseif ((ConvertTo-Epoch $d.push) -gt $lp) { $mark = " $CY<- pushed after your last pull$C0" }
    $out += (' {0}{1,-16}{2} push {3,-28} pull {4}{5}' -f $CB, $d.host, $C0, (Format-Ago $d.push), (Format-Ago $d.pull), $mark)
  }
  return $out
}

function Get-StatusHeader {
  $c = $Run.Cnt
  $lines = @()
  $lines += " ${CB}Status$C0  $(Get-RPath) $Sync $(Get-Tilde $Cfg.LIBRARY_ROOT)  ${CD}(listed $($Run.DiffTime))$C0"
  $lines += (' {0}{1} {2} new on remote{3}  {4}{5} {6} newer on remote{3}  {7}{8} {9} new locally{3}  {10}{11} {12} newer locally{3}  {18}{19} {20} renamed{3}  {13}{14} {15} conflicts{3}  {16}= {17} in sync{3}' -f `
      $CG, $CatSym.radd, $c.radd, $C0, $CC, $CatSym.rnew, $c.rnew, $CY, $CatSym.ladd, $c.ladd, $CM, $CatSym.lnew, $c.lnew, $CR, $CatSym.size, $c.size, $CD, $c.same, $CBL, $CatSym.ren.Trim(), $c.ren)
  $s = " Local $($Run.LocalN) files ($(Format-Size $Run.LocalB)) $([char]0xB7) Remote $($Run.RemoteN) files ($(Format-Size $Run.RemoteB))"
  try { $a = $Run.About | ConvertFrom-Json; if ($a.used) { $s += " $([char]0xB7) Drive $(Format-Size $a.used) / $(Format-Size $a.total) used" } } catch { }
  $lines += "$s   $CD[$(Get-FilterDesc)]$C0"
  if ($Run.RemoteMissing) { $lines += " $CY$(Get-RPath) does not exist yet - it will be created on the first push$C0" }
  $lines += Get-DeviceLines
  return $lines
}

function Show-StatusText {
  Get-StatusHeader | ForEach-Object { Say $_ }
  Say
  $n = 0
  foreach ($r in $Run.Rows) {
    if ($r.C -eq 'same') { continue }
    Say (' {0}{1}{2} {3}  {4}(local {5} {6} | remote {7} {8}){2}' -f $CatCol[$r.C], $CatSym[$r.C], $C0, (Get-RowPath $r), $CD, (Format-Size $r.LS), (Get-Short $r.LT), (Format-Size $r.RS), (Get-Short $r.RT))
    $n++
  }
  if ($n -eq 0) { Write-Ok 'Everything is in sync.' }
}

function Get-Short([string]$t) { if ($t.Length -gt 16) { return $t.Substring(0, 16) } return $t }

# ------------------------------------------------------------------ widgets --
# Show-Menu HEADER(scriptblock) ITEMS("key|Label|Description") -> $Run.MenuKey ('q' on back)
function Show-Menu([string]$id, [scriptblock]$header, [string[]]$items) {
  $n = $items.Count
  $i = if ($Run.MenuPos.ContainsKey($id)) { [int]$Run.MenuPos[$id] } else { 0 }
  if ($i -ge $n) { $i = 0 }
  Set-Cursor $false
  # The header may run rclone; render it once, not on every keypress.
  $hdrText = (@(& $header) -join "`n") + "`n`n"
  while ($true) {
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append($hdrText)
    for ($j = 0; $j -lt $n; $j++) {
      $f = $items[$j].Split('|')
      if ($j -eq $i) { [void]$sb.Append((' {0}{1} {2,-2} {3,-14}{4} {5}' -f "$CC$CB", $Ptr, $f[0], $f[1], $C0, $f[2])).Append("`n") }
      else { [void]$sb.Append(('   {0}{1,-2}{2} {3,-14} {4}{5}{6}' -f $CC, $f[0], $C0, $f[1], $CD, $f[2], $C0)).Append("`n") }
    }
    [void]$sb.Append("`n ${CD}j/k move $([char]0xB7) enter select $([char]0xB7) shortcut key $([char]0xB7) q back$C0")
    Write-Frame $sb.ToString()
    $k = Read-Key
    if ($k -ceq 'j') { $i = ($i + 1) % $n }
    elseif ($k -ceq 'k') { $i = ($i - 1 + $n) % $n }
    elseif ($k -ceq 'g') { $i = 0 }
    elseif ($k -ceq 'G') { $i = $n - 1 }
    elseif ($k -eq 'enter' -or $k -ceq 'l') { $Run.MenuPos[$id] = $i; $Run.MenuKey = $items[$i].Split('|')[0]; return }
    elseif ($k -ceq 'q' -or $k -eq 'esc' -or $k -ceq 'h' -or $k -eq 'bs') { $Run.MenuKey = 'q'; return }
    else {
      for ($j = 0; $j -lt $n; $j++) {
        if ($k -ceq $items[$j].Split('|')[0]) { $Run.MenuPos[$id] = $j; $Run.MenuKey = $k; return }
      }
    }
  }
}

function Show-Pager([string]$title, [string[]]$lines, [switch]$End) {
  $n = $lines.Count; $sz = Get-TermSize; $h = $sz[0] - 3
  $top = if ($End) { $n - $h } else { 0 }
  while ($true) {
    $sz = Get-TermSize; $h = [Math]::Max(1, $sz[0] - 3); $w = $sz[1] - 2
    if ($top -gt $n - $h) { $top = $n - $h }; if ($top -lt 0) { $top = 0 }
    $sb = New-Object Text.StringBuilder
    $last = [Math]::Min($top + $h, $n)
    [void]$sb.Append(" $CB$title$C0  $CD$(if ($n) { $top + 1 } else { 0 })-$last/$n$C0`n")
    for ($i = $top; $i -lt $last; $i++) {
      $l = $lines[$i].Replace("`t", '    '); if ($l.Length -gt $w) { $l = $l.Substring(0, $w) }
      [void]$sb.Append(" $l`n")
    }
    [void]$sb.Append(" ${CD}j/k scroll $([char]0xB7) ctrl-d/u page $([char]0xB7) g/G top/bottom $([char]0xB7) q back$C0")
    Write-Frame $sb.ToString()
    $k = Read-Key
    if ($k -ceq 'j') { $top++ } elseif ($k -ceq 'k') { $top-- }
    elseif ($k -eq 'ctrl-d' -or $k -eq 'space') { $top += [int]($h / 2) } elseif ($k -eq 'ctrl-u') { $top -= [int]($h / 2) }
    elseif ($k -ceq 'g') { $top = 0 } elseif ($k -ceq 'G') { $top = $n }
    elseif ($k -ceq 'q' -or $k -eq 'esc' -or $k -ceq 'h' -or $k -eq 'enter') { return }
  }
}

# Show-Diff [category] -> $Run.ViewAction (p|u|m|r|q)
# Status view s/x: open the file (or its folder) here if it exists locally, otherwise on Google
# Drive in the browser. Returns an error message, or '' on success.
function Open-Row($r, [bool]$folder) {
  $lp = if ($r.C -eq 'radd') { '' } elseif ($r.C -eq 'ren') { $r.Q } else { $r.P }
  try {
    if ($lp) {
      $full = Join-Path $Cfg.LIBRARY_ROOT ($lp.Replace('/', '\'))
      if (-not (Test-Path -LiteralPath $full)) { return "Not found: $full" }
      if ($folder) { Start-Process -FilePath 'explorer.exe' -ArgumentList "/select,`"$full`"" } else { Start-Process -FilePath $full }
      return ''
    }
    $path = if ($Cfg.REMOTE_PATH) { "$($Cfg.REMOTE_PATH)/$($r.P)" } else { $r.P }
    if ($folder) { $i = $path.LastIndexOf('/'); $path = if ($i -ge 0) { $path.Substring(0, $i) } else { '' } }
    if (-not $path) { Start-Process -FilePath 'https://drive.google.com/drive/my-drive'; return '' }
    $id = Get-DriveId $path $folder
    if (-not $id) { return "Could not find $($Cfg.REMOTE):$path on Google Drive (browser links need a Drive remote)." }
    $url = if ($folder) { "https://drive.google.com/drive/folders/$id" } else { "https://drive.google.com/file/d/$id/view" }
    Start-Process -FilePath $url
    return ''
  } catch { return "Could not open: $($_.Exception.Message)" }
}

# Drive item ID of PATH (relative to the remote's root), or ''. A folder's own --stat carries no
# ID, so folders are looked up in their parent's listing.
function Get-DriveId([string]$path, [bool]$isDir) {
  $items = $null
  if ($isDir) {
    $i = $path.LastIndexOf('/')
    $parent = if ($i -ge 0) { $path.Substring(0, $i) } else { '' }
    $name = $path.Substring($i + 1)
    $x = Invoke-Rc (@('lsjson', '--dirs-only', '--no-modtime', '--no-mimetype') + (Get-BaseFlags) + @('--', "$($Cfg.REMOTE):$parent"))
    if ($x.Code -eq 0) { try { $items = @($x.Out | ConvertFrom-Json | Where-Object { $_.Name -ceq $name }) } catch { } }
  } else {
    $x = Invoke-Rc (@('lsjson', '--stat', '--no-modtime', '--no-mimetype') + (Get-BaseFlags) + @('--', "$($Cfg.REMOTE):$path"))
    if ($x.Code -eq 0) { try { $items = @($x.Out | ConvertFrom-Json) } catch { } }
  }
  if (-not $items) { return '' }
  $id = ''
  try { $id = [string]$items[0].ID } catch { }  # no ID property: not a Drive remote
  if ($id -match '^[A-Za-z0-9_-]+$') { return $id }
  return ''
}

function Show-Diff([string]$start = 'changes') {
  $ci = [Math]::Max(0, [array]::IndexOf($CatKeys, $start))
  $sel = 0; $top = 0; $q = ''; $reload = $true; $msg = ''
  $rows = New-Object Collections.Generic.List[object]
  $hdr = @(Get-StatusHeader)
  Set-Cursor $false
  while ($true) {
    $cat = $CatKeys[$ci]
    if ($reload) {
      $rows.Clear()
      foreach ($r in $Run.Rows) {
        if ($cat -eq 'changes') { if ($r.C -eq 'same') { continue } } elseif ($r.C -ne $cat) { continue }
        if ($q -and (Get-RowPath $r).IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        $rows.Add($r)
      }
      $sel = 0; $top = 0; $reload = $false
    }
    $n = $rows.Count; $sz = Get-TermSize
    $h = [Math]::Max(3, $sz[0] - $hdr.Count - 5)
    if ($sel -ge $n) { $sel = $n - 1 }; if ($sel -lt 0) { $sel = 0 }
    if ($sel -lt $top) { $top = $sel }; if ($sel -ge $top + $h) { $top = $sel - $h + 1 }
    $sb = New-Object Text.StringBuilder
    foreach ($l in $hdr) { [void]$sb.Append($l).Append("`n") }
    foreach ($ck in $CatKeys) {
      if ($ck -eq $cat) { [void]$sb.Append(" $CRV $($CatLabel[$ck]) $C0") } else { [void]$sb.Append(" $CD $($CatLabel[$ck]) $C0") }
    }
    [void]$sb.Append("`n")
    $pw = [Math]::Max(16, $sz[1] - 60)
    $title = if ($q) { "path  (filter: $q)" } else { 'path' }
    [void]$sb.Append((" $CD   {0} {1,8} {2,-16} {3,8} {4,-16}$C0`n" -f $title.PadRight($pw), 'local', '', 'remote', ''))
    $last = [Math]::Min($top + $h, $n)
    for ($i = $top; $i -lt $last; $i++) {
      $r = $rows[$i]; $p = Get-RowPath $r
      if ($p.Length -gt $pw) { $p = $Ell + $p.Substring($p.Length - $pw + 1) }
      $p = $p.PadRight($pw)
      $tail = ' {0,8} {1,-16} {2,8} {3,-16}' -f (Format-Size $r.LS), (Get-Short $r.LT), (Format-Size $r.RS), (Get-Short $r.RT)
      if ($i -eq $sel) { [void]$sb.Append(" $CRV$($CatSym[$r.C]) $p$tail$C0`n") }
      else { [void]$sb.Append(" $($CatCol[$r.C])$($CatSym[$r.C])$C0 $p$tail`n") }
    }
    if ($n -eq 0) { [void]$sb.Append("   $CD(nothing here)$C0`n") }
    $pos = if ($n) { $sel + 1 } else { 0 }
    if ($msg) { [void]$sb.Append("`n $CY$msg$C0") }
    else { [void]$sb.Append("`n $CD$pos/$n $([char]0xB7) j/k move $([char]0xB7) tab/h/l category $([char]0xB7) / search $([char]0xB7) s open $([char]0xB7) x folder $([char]0xB7) p pull $([char]0xB7) u push $([char]0xB7) m merge $([char]0xB7) r refresh $([char]0xB7) q back$C0") }
    Write-Frame $sb.ToString()
    $k = Read-Key; $msg = ''
    if ($k -ceq 'j') { $sel++ } elseif ($k -ceq 'k') { $sel-- }
    elseif ($k -eq 'ctrl-d') { $sel += [int]($h / 2) } elseif ($k -eq 'ctrl-u') { $sel -= [int]($h / 2) }
    elseif ($k -ceq 'g') { $sel = 0 } elseif ($k -ceq 'G') { $sel = $n - 1 }
    elseif ($k -eq 'tab' -or $k -ceq 'l' -or $k -eq ']') { $ci = ($ci + 1) % $CatKeys.Count; $reload = $true }
    elseif ($k -eq 'btab' -or $k -ceq 'h' -or $k -eq '[') { $ci = ($ci - 1 + $CatKeys.Count) % $CatKeys.Count; $reload = $true }
    elseif ($k -eq '/') { [Console]::Write("$Ansi[$($sz[0]);1H$Ansi[2K"); $q = Read-Line 'search' $q; $reload = $true }
    elseif (($k -ceq 's' -or $k -ceq 'x') -and $n) {
      [Console]::Write("$Ansi[$($sz[0]);1H$Ansi[2K $CD$(if ($k -ceq 'x') { 'Opening folder' } else { 'Opening' })$Ell$C0")
      $msg = Open-Row $rows[$sel] ($k -ceq 'x')
    }
    elseif ($k -ceq 'p' -or $k -ceq 'u' -or $k -ceq 'm' -or $k -ceq 'r') { $Run.ViewAction = $k; return }
    elseif ($k -ceq 'q' -or $k -eq 'esc') { $Run.ViewAction = 'q'; return }
  }
}

# --------------------------------------------------------------------- sync --
function Test-SioyekRunning { return [bool](Get-Process -Name sioyek -ErrorAction SilentlyContinue) }

function Test-AnnotDbChanged {
  foreach ($r in $Run.Rows) { if ($r.P -ceq "$AnnotDir/shared.db" -and @('rnew', 'lnew', 'size') -contains $r.C) { return $true } }
  return $false
}

function Test-AnnotChanges {
  foreach ($r in $Run.Rows) { if ($r.C -ne 'same' -and $r.P.StartsWith("$AnnotDir/", [StringComparison]::Ordinal)) { return $true } }
  return $false
}

function Write-Marker {
  $f = Join-Path $Run.Tmp 'marker.txt'
  $t = "host=$HostId`nos=Windows`nlast_pull=$(if ($State.LAST_PULL) { $State.LAST_PULL } else { '-' })`nlast_push=$(if ($State.LAST_PUSH) { $State.LAST_PUSH } else { '-' })`nlast_merge=$(if ($State.LAST_MERGE) { $State.LAST_MERGE } else { '-' })`n"
  [IO.File]::WriteAllText($f, $t, $Utf8)
  $r = Invoke-Rc (@('copyto') + (Get-BaseFlags) + @('--', $f, (Get-RPath "$MarkerDir/$HostId.txt")))
  if ($r.Code) { Write-Warn 'Could not update the device marker on the remote (sync itself succeeded).' }
}

function Add-LogLine([string]$s) {
  $d = Join-Path $Cfg.LIBRARY_ROOT 'logs'
  if (-not (Test-Path -LiteralPath $d)) { $null = New-Item -ItemType Directory -Force -Path $d }
  [IO.File]::AppendAllText((Join-Path $d 'library.log'), "$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) $HostId $s`n", $Utf8)
}

# Runs rclone attached to the console (live progress). Never call it where output is captured.
function Invoke-RcloneLive([string]$log, [string[]]$argv) {
  $prog = if ($Run.Interactive) { @('-P') } else { @('--stats-one-line', '--stats', '30s') }
  $d = Split-Path -Parent $log
  if (-not (Test-Path -LiteralPath $d)) { $null = New-Item -ItemType Directory -Force -Path $d }
  [IO.File]::AppendAllText($log, "`n==== $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) ${HostId}: rclone $($argv[0])`n", $Utf8)
  $full = @($argv[0]) + $prog + @('--log-file', $log, '--log-level', 'INFO') + $argv[1..($argv.Count - 1)]
  Set-Cursor $true
  & $Run.Rclone @full
  $Run.LastRc = $LASTEXITCODE
}

function Set-Last([string]$op) { $State["LAST_$($op.ToUpperInvariant())"] = Get-NowIso; Save-State; Save-Manifest; Save-SioyekBase; Write-Marker }

# Invoke-Sync pull|push|merge  -> $Run.LastRc
function Invoke-Sync([string]$op, [bool]$assumeYes = $false, [bool]$force = $false) {
  $Run.LastRc = 1
  if (-not $Run.DiffReady -and -not (Invoke-ComputeDiff)) { return }
  $c = $Run.Cnt; $over = 0; $del = 0; $destN = 0; $ren = $c.ren; $unk = 0; $revert = 0; $names = 'b'
  foreach ($r in $Run.Rows) {
    if ($r.C -ne 'ren') { continue }
    if (-not $r.D) { $unk++ } elseif (($op -eq 'pull' -and $r.D -eq 'local') -or ($op -eq 'push' -and $r.D -eq 'remote')) { $revert++ }
  }
  $root = Get-Tilde $Cfg.LIBRARY_ROOT
  $mergeDb = $op -ne 'push' -and (Test-AnnotDbChanged)
  switch ($op) {
    'pull' { $a = $c.radd; $b = $c.rnew + $c.size; $over = $c.lnew; $del = $c.ladd; $destN = $Run.LocalN; $title = "Pull  $(Get-RPath) $Arrow $root" }
    'push' { $a = $c.ladd; $b = $c.lnew + $c.size; $over = $c.rnew; $del = $c.radd; $destN = $Run.RemoteN; $title = "Push  $root $Arrow $(Get-RPath)" }
    'merge' { $a = $c.radd + $c.rnew + $c.size; $b = $c.ladd + $c.lnew; $title = "Merge  $(Get-RPath) $Sync $root  (newer wins, nothing is deleted)" }
  }
  while ($true) {
    Clear-Screen
    Say; Say " $CB$title$C0   $CD[$(Get-FilterDesc)]$C0"; Say
    if ($op -eq 'merge') {
      Say ('   {0}{1} {2,5}{3}  files to download (new or newer on remote)' -f $CG, [char]0x2193, $a, $C0)
      Say ('   {0}{1} {2,5}{3}  files to upload (new or newer locally)' -f $CY, [char]0x2191, $b, $C0)
      if ($ren) { Say ('   {0}{1} {2,5}{3}  renamed files get the same name on both sides (moved, not copied)' -f $CBL, [char]0xBB, $ren, $C0) }
      if ($unk) {
        $nl = @{ l = 'keep the names on this device'; r = 'keep the names on the remote'; b = 'keep both names (copies the file both ways)' }
        Say ("   {0}  {1,5}{2}  of them renamed on an unknown side: {3}{4}{2}  {5}(l / r / b to change){2}" -f $CY, $unk, $C0, $CB, $nl[$names], $CD)
      }
    } else {
      Say ('   {0}+ {1,5}{2}  new files to copy' -f $CG, $a, $C0)
      Say ('   {0}~ {1,5}{2}  changed files to update' -f $CC, $b, $C0)
      if ($ren) {
        $to = if ($op -eq 'pull') { 'remote' } else { 'local' }
        Say ('   {0}{1} {2,5}{3}  renamed files take the {4} name (moved, not copied)' -f $CBL, [char]0xBB, $ren, $C0, $to)
        if ($revert) {
          $there = if ($op -eq 'pull') { 'on this device' } else { 'on the remote' }
          Say ("   {0}! {1,5}{2}  of them were renamed {3} - {4} undoes that; Merge keeps the new names" -f $CY, $revert, $C0, $there, $op)
        }
      }
      if ($over) { Say ('   {0}! {1,5}{2}  destination files are NEWER and will be overwritten (old copy kept in trash)' -f $CR, $over, $C0) }
      if ($del) { Say ('   {0}{1} {2,5}{3}  files missing from the source will be removed (moved to trash)' -f $CR, $Cross, $del, $C0) }
    }
    if ($mergeDb -and $Run.Sqlite) { Say ('   {0}{1}      {2}  sioyek annotations from both sides are merged, not overwritten' -f $CBL, $Sync, $C0) }
    if ($a + $b + $over + $del + $ren -eq 0) {
      Write-Ok "Already in sync - nothing to $op."
      Set-Last $op; $Run.LastRc = 0; return
    }
    if ($op -ne 'push' -and (Test-SioyekRunning) -and (Test-AnnotChanges)) {
      Write-Warn 'sioyek is running and its annotation database will change - close sioyek first.'
    }
    Say
    if ($assumeYes) { break }
    if (-not $Run.Interactive) { Write-Err 'Not interactive: re-run with -Yes to confirm.'; return }
    [Console]::Write(" ${CB}y$C0 run  ${CB}v$C0 view changes  ${CB}n$C0 cancel ")
    $k = Read-Key
    if ($k -ceq 'y' -or $k -ceq 'Y') { Say; break }
    elseif ($k -ceq 'v') { Show-Diff 'changes' }
    elseif ($unk -and $op -eq 'merge' -and ($k -ceq 'l' -or $k -ceq 'r' -or $k -ceq 'b')) { $names = $k }
    else { Say; Write-Info 'Cancelled.'; return }
  }
  # Guard against mass deletion (e.g. pushing from an empty or wrongly-configured device).
  if ($del -ge 10 -and $del * 4 -gt $destN) {
    Write-Warn "This would remove $del of $destN files on the destination."
    if ($assumeYes) {
      if (-not $force) { Write-Err 'Refusing without -Force.'; return }
    } elseif ((Read-Line "Type 'delete' to continue") -cne 'delete') { Write-Info 'Cancelled.'; return }
  }
  # Replacing shared.db under a running sioyek loses whatever it writes back afterwards.
  if ($op -ne 'push' -and (Test-AnnotChanges) -and (Test-SioyekRunning)) {
    Write-Warn 'sioyek is still running - replacing its annotation database now can lose annotations.'
    if ($assumeYes) {
      if (-not $force) { Write-Err 'Close sioyek, or re-run with -Force.'; return }
    } elseif (-not (Read-YesNo ' Continue anyway?' 'n')) { Write-Info 'Cancelled.'; return }
  }
  if (-not (Build-Filters)) { return }
  $ts = (Get-Date).ToString('yyyy-MM-dd_HHmmss')
  $log = Join-Path (Join-Path $Cfg.LIBRARY_ROOT 'logs') "rclone-$op-$((Get-Date).ToString('yyyy-MM')).log"
  $x = (Get-BaseFlags) + @('--fast-list', '--transfers', [string]$Cfg.TRANSFERS, '--drive-chunk-size', '64M', '--filter-from', $FilterFile, '--ignore-case')
  if ($Cfg.BWLIMIT) { $x += @('--bwlimit', $Cfg.BWLIMIT) }
  if (-not (Test-Path -LiteralPath $Cfg.LIBRARY_ROOT)) { $null = New-Item -ItemType Directory -Force -Path $Cfg.LIBRARY_ROOT }
  $localTrash = Join-Path (Join-Path $Cfg.LIBRARY_ROOT '.trash') $ts
  $remoteTrash = "$($Cfg.REMOTE):$($Cfg.REMOTE_TRASH)/$ts"
  if ($mergeDb -and (Merge-SioyekDb $localTrash $remoteTrash) -eq 'fail') {
    $Run.DiffReady = $false
    Write-Err "$op cancelled, so neither annotation database gets overwritten."
    return
  }
  switch ($op) {
    'pull' { Invoke-RcloneLive $log (@('sync') + $x + @('--track-renames', '--backup-dir', $localTrash, '--', (Get-RPath), $Cfg.LIBRARY_ROOT)) }
    'push' { Invoke-RcloneLive $log (@('sync') + $x + @('--track-renames', '--backup-dir', $remoteTrash, '--', $Cfg.LIBRARY_ROOT, (Get-RPath))) }
    'merge' {
      $Run.LastRc = if (Invoke-Renames $names) { 0 } else { 1 }
      if ($Run.LastRc -eq 0) { Invoke-RcloneLive $log (@('copy') + $x + @('--update', '--backup-dir', $localTrash, '--', (Get-RPath), $Cfg.LIBRARY_ROOT)) }
      if ($Run.LastRc -eq 0) { Invoke-RcloneLive $log (@('copy') + $x + @('--update', '--backup-dir', $remoteTrash, '--', $Cfg.LIBRARY_ROOT, (Get-RPath))) }
    }
  }
  $rc = $Run.LastRc
  $Run.DiffReady = $false
  Say
  $opName = $op.Substring(0, 1).ToUpperInvariant() + $op.Substring(1)
  if ($rc -eq 0) {
    Set-Last $op; Add-LogLine "$op ok"
    Write-Ok "$opName finished. Log: $(Get-Tilde $log)"
  } else {
    Add-LogLine "$op FAILED rc=$rc"
    Write-Err "$opName failed (rclone exit $rc). Last errors from $(Get-Tilde $log):"
    Show-RcloneError ((Get-Content -LiteralPath $log -Tail 200 -Encoding UTF8) -join "`n")
  }
  $Run.LastRc = $rc
}

# ------------------------------------------------------------------ folders --
function Get-RemoteDirs([string]$path) {
  if (-not $Run.DirCache.ContainsKey($path)) {
    [Console]::Write("$Ansi[2K`r ${CD}Listing $($Cfg.REMOTE):$path $Ell$C0")
    $r = Invoke-Rc (@('lsf', '--dirs-only') + (Get-BaseFlags) + @('--', "$($Cfg.REMOTE):$path"))
    if ($r.Code) { $Run.LastErr = $r.Err; return $null }
    $Run.DirCache[$path] = @($r.Out -split "`r?`n" | ForEach-Object { $_.TrimEnd('/') } | Where-Object { $_ -and $_ -cne $MarkerDir })
  }
  return , @($Run.DirCache[$path])
}

# Select-Folders select|root   select: pick FOLDERS under REMOTE_PATH; root: pick REMOTE_PATH
function Select-Folders([string]$mode) {
  $picked = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  $cwd = ''; $base = ''; $sel = 0; $top = 0
  if ($mode -eq 'select') { $base = $Cfg.REMOTE_PATH; foreach ($f in $Cfg.FOLDERS) { [void]$picked.Add($f) } } else { $cwd = $Cfg.REMOTE_PATH }
  Set-Cursor $false
  while ($true) {
    $full = if ($base -and $cwd) { "$base/$cwd" } elseif ($base) { $base } else { $cwd }
    $dirs = Get-RemoteDirs $full
    if ($null -eq $dirs) {
      if ($cwd -and $Run.LastErr -match 'directory not found') { $cwd = if ($cwd.Contains('/')) { $cwd.Substring(0, $cwd.LastIndexOf('/')) } else { '' }; continue }
      Say; Write-Err "Could not list $($Cfg.REMOTE):$full"; Show-RcloneError $Run.LastErr; Wait-AnyKey; return
    }
    if ($full -ceq $Cfg.REMOTE_PATH) { $dirs = @($dirs | Where-Object { Test-SyncFolder $_ }) }
    $n = $dirs.Count; $sz = Get-TermSize; $h = [Math]::Max(3, $sz[0] - 8)
    if ($sel -ge $n) { $sel = $n - 1 }; if ($sel -lt 0) { $sel = 0 }
    if ($sel -lt $top) { $top = $sel }; if ($sel -ge $top + $h) { $top = $sel - $h + 1 }
    $sb = New-Object Text.StringBuilder
    if ($mode -eq 'select') {
      [void]$sb.Append(" ${CB}Folders to sync$C0  ${CD}(relative to $(Get-RPath))$C0`n selected: $CC$(@($picked) -join ' ')$C0`n")
    } else {
      [void]$sb.Append(" ${CB}Choose the library root on $($Cfg.REMOTE):$C0`n current choice: $CC$($Cfg.REMOTE):$cwd$C0`n")
    }
    [void]$sb.Append(" $CBL$($Cfg.REMOTE):/$full$C0`n`n")
    $last = [Math]::Min($top + $h, $n)
    for ($i = $top; $i -lt $last; $i++) {
      $rel = if ($cwd) { "$cwd/$($dirs[$i])" } else { $dirs[$i] }
      $mark = '   '
      if ($mode -eq 'select') {
        $mark = '[ ]'
        if ($picked.Contains($rel)) { $mark = "[${CG}x$C0]" }
        else {
          foreach ($k in $picked) {
            if ($rel.StartsWith("$k/", [StringComparison]::Ordinal)) { $mark = "[$CD$([char]0xB7)$C0]"; break }
            if ($k.StartsWith("$rel/", [StringComparison]::Ordinal)) { $mark = "[$CY-$C0]" }
          }
        }
      }
      if ($i -eq $sel) { [void]$sb.Append(" $CC$Ptr$C0 $mark $CB$($dirs[$i])/$C0`n") } else { [void]$sb.Append("   $mark $($dirs[$i])/`n") }
    }
    if ($n -eq 0) { [void]$sb.Append("   $CD(no sub-folders)$C0`n") }
    if ($mode -eq 'select') { [void]$sb.Append("`n ${CD}j/k move $([char]0xB7) l/enter open $([char]0xB7) h back $([char]0xB7) space toggle $([char]0xB7) a add path $([char]0xB7) s save $([char]0xB7) q cancel$C0") }
    else { [void]$sb.Append("`n ${CD}j/k move $([char]0xB7) l/enter open $([char]0xB7) h back $([char]0xB7) s use this folder $([char]0xB7) a type a path $([char]0xB7) q cancel$C0") }
    Write-Frame $sb.ToString()
    $k = Read-Key
    if ($k -ceq 'j') { $sel++ } elseif ($k -ceq 'k') { $sel-- } elseif ($k -ceq 'g') { $sel = 0 } elseif ($k -ceq 'G') { $sel = $n - 1 }
    elseif ($k -eq 'ctrl-d') { $sel += [int]($h / 2) } elseif ($k -eq 'ctrl-u') { $sel -= [int]($h / 2) }
    elseif ($k -ceq 'l' -or $k -eq 'enter') { if ($n) { $cwd = if ($cwd) { "$cwd/$($dirs[$sel])" } else { $dirs[$sel] }; $sel = 0; $top = 0 } }
    elseif ($k -ceq 'h' -or $k -eq 'bs') { $cwd = if ($cwd.Contains('/')) { $cwd.Substring(0, $cwd.LastIndexOf('/')) } else { '' }; $sel = 0; $top = 0 }
    elseif ($k -eq 'space') {
      if ($mode -eq 'select' -and $n) {
        $rel = if ($cwd) { "$cwd/$($dirs[$sel])" } else { $dirs[$sel] }
        if (-not $picked.Remove($rel)) { [void]$picked.Add($rel) }
      }
    }
    elseif ($k -ceq 'a') {
      [Console]::Write("$Ansi[$($sz[0]);1H$Ansi[2K")
      $p = (Read-Line 'path' $cwd).Trim('/')
      if ($p -and (Test-RelPath $p)) {
        if ($mode -eq 'select') { if (Test-SyncFolder $p) { [void]$picked.Add($p) } } else { $Cfg.REMOTE_PATH = $p; $Run.DiffReady = $false; Save-Config; return }
      }
    }
    elseif ($k -ceq 's' -or $k -ceq 'w') {
      if ($mode -eq 'select') {
        if ($picked.Count -eq 0) { Say; Write-Warn 'Select at least one folder.'; Wait-AnyKey; continue }
        $sorted = [string[]]@($picked); [Array]::Sort($sorted, [StringComparer]::Ordinal)
        $keep = New-Object Collections.Generic.List[string]
        foreach ($p in $sorted) {
          $nested = $false
          foreach ($k2 in $keep) { if ($p.StartsWith("$k2/", [StringComparison]::Ordinal)) { $nested = $true; break } }
          if (-not $nested) { $keep.Add($p) }
        }
        $Cfg.FOLDERS = $keep.ToArray()
      } else { $Cfg.REMOTE_PATH = $cwd }
      $Run.DiffReady = $false; Save-Config; return
    }
    elseif ($k -ceq 'q' -or $k -eq 'esc') { return }
  }
}

# ------------------------------------------------------------------ filters --
function Edit-Filters {
  $mode = $Cfg.FILTER_MODE; $sel = 0
  $on = New-Object 'Collections.Generic.HashSet[string]'
  $list = New-Object Collections.Generic.List[string]
  foreach ($e in $CommonExts) { $list.Add($e) }
  foreach ($e in $Cfg.FILTER_EXT) { [void]$on.Add($e); if (-not $list.Contains($e)) { $list.Add($e) } }
  $labels = @{ none = 'sync everything'; exclude = 'exclude selected'; include = 'only selected' }
  Set-Cursor $false
  while ($true) {
    $n = $list.Count
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append(" ${CB}File-type filter for this device$C0  ${CD}(sioyek annotations are always synced)$C0`n`n mode: ")
    foreach ($m in 'none', 'exclude', 'include') {
      if ($m -eq $mode) { [void]$sb.Append(" $CRV $($labels[$m]) $C0") } else { [void]$sb.Append(" $CD $($labels[$m]) $C0") }
    }
    [void]$sb.Append("`n`n")
    for ($i = 0; $i -lt $n; $i++) {
      $e = $list[$i]; $mark = if ($on.Contains($e)) { "[${CG}x$C0]" } else { '[ ]' }
      $line = if ($i -eq $sel) { " $CC$Ptr$C0 $mark $CB.$e$C0" } else { "   $mark .$e" }
      if ($mode -eq 'none' -and $C0) { $line = "$CD$($line.Replace($C0, "$C0$CD"))$C0" }
      [void]$sb.Append("$line`n")
    }
    [void]$sb.Append("`n ${CD}Files already on this device that become filtered are left alone (not deleted).$C0")
    [void]$sb.Append("`n ${CD}j/k move $([char]0xB7) space toggle $([char]0xB7) m/tab mode $([char]0xB7) a add extension $([char]0xB7) s save $([char]0xB7) q cancel$C0")
    Write-Frame $sb.ToString()
    $k = Read-Key
    if ($k -ceq 'j') { if ($sel -lt $n - 1) { $sel++ } } elseif ($k -ceq 'k') { if ($sel -gt 0) { $sel-- } }
    elseif ($k -ceq 'g') { $sel = 0 } elseif ($k -ceq 'G') { $sel = $n - 1 }
    elseif ($k -eq 'space') { $e = $list[$sel]; if (-not $on.Remove($e)) { [void]$on.Add($e) } }
    elseif ($k -ceq 'm' -or $k -eq 'tab') { $mode = switch ($mode) { 'none' { 'exclude' } 'exclude' { 'include' } default { 'none' } } }
    elseif ($k -ceq 'a') {
      [Console]::Write("$Ansi[$((Get-TermSize)[0]);1H$Ansi[2K")
      $x = (Read-Line 'extension (e.g. epub)').TrimStart('.').ToLowerInvariant()
      if ($x -match '^[a-z0-9]{1,10}$') { [void]$on.Add($x); if (-not $list.Contains($x)) { $list.Add($x) } }
    }
    elseif ($k -ceq 's' -or $k -ceq 'w') {
      $Cfg.FILTER_MODE = $mode
      $Cfg.FILTER_EXT = @($list | Where-Object { $on.Contains($_) })
      $Run.DiffReady = $false; Save-Config; return
    }
    elseif ($k -ceq 'q' -or $k -eq 'esc') { return }
  }
}

# -------------------------------------------------------------------- trash --
function Show-Trash {
  $stamp = '^\d{4}-\d{2}-\d{2}(_\d{6})?$'
  while ($true) {
    Clear-Screen
    $ltDir = Join-Path $Cfg.LIBRARY_ROOT '.trash'
    $ldirs = @(Get-ChildItem -LiteralPath $ltDir -Directory -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object { $_.Name })
    $lsize = 0L; if (Test-Path -LiteralPath $ltDir) { $m = Get-ChildItem -LiteralPath $ltDir -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum; if ($m.Sum) { $lsize = [long]$m.Sum } }
    Say " ${CB}Trash$C0 - files removed or overwritten by sync are kept here"; Say
    Say " local   $(Get-Tilde $ltDir)  $($ldirs.Count) snapshots, $(Format-Size $lsize)"
    $r = Invoke-Rc (@('lsf', '--dirs-only') + (Get-BaseFlags) + @('--', "$($Cfg.REMOTE):$($Cfg.REMOTE_TRASH)"))
    $rdirs = @($r.Out -split "`r?`n" | ForEach-Object { $_.TrimEnd('/') } | Where-Object { $_ } | Sort-Object)
    Say " remote  $($Cfg.REMOTE):$($Cfg.REMOTE_TRASH)  $($rdirs.Count) snapshots"; Say
    $ldirs | Select-Object -Last 5 | ForEach-Object { Say "   ${CD}local  $_$C0" }
    $rdirs | Select-Object -Last 5 | ForEach-Object { Say "   ${CD}remote $_$C0" }
    [Console]::Write("`n ${CB}c$C0 clean snapshots older than 30 days   ${CB}a$C0 empty all trash   ${CB}q$C0 back ")
    $k = Read-Key; Say
    if ($k -ceq 'c') { $cutoff = (Get-Date).AddDays(-30).ToString('yyyy-MM-dd') }
    elseif ($k -ceq 'a') { if ((Read-Line "Type 'empty' to permanently delete all snapshots") -cne 'empty') { continue }; $cutoff = '9999-99-99' }
    else { return }
    # Only touch directories whose names look like our snapshot stamps.
    foreach ($name in $ldirs) {
      if ($name -match $stamp -and [string]::CompareOrdinal($name.Substring(0, 10), $cutoff) -lt 0) {
        Remove-Item -LiteralPath (Join-Path $ltDir $name) -Recurse -Force; Write-Ok "local  $name removed"
      }
    }
    foreach ($name in $rdirs) {
      if ($name -match $stamp -and [string]::CompareOrdinal($name.Substring(0, 10), $cutoff) -lt 0) {
        $p = Invoke-Rc (@('purge') + (Get-BaseFlags) + @('--', "$($Cfg.REMOTE):$($Cfg.REMOTE_TRASH)/$name"))
        if ($p.Code -eq 0) { Write-Ok "remote $name removed (kept 30 days in Google Drive's own bin)" } else { Show-RcloneError $p.Err }
      }
    }
    Wait-AnyKey
  }
}

# --------------------------------------------------------------------- logs --
function Show-Logs {
  $dir = Join-Path $Cfg.LIBRARY_ROOT 'logs'
  $files = @(Get-ChildItem -LiteralPath $dir -Filter '*.log' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 9)
  if ($files.Count -eq 0) { Clear-Screen; Write-Info "No logs yet in $(Get-Tilde $dir)."; Wait-AnyKey; return }
  $items = @(); for ($i = 0; $i -lt $files.Count; $i++) { $items += "$($i + 1)|$($files[$i].Name)|$(Format-Size $files[$i].Length)" }
  Show-Menu 'logs' { " ${CB}Logs$C0  $(Get-Tilde $dir)" } $items
  if ($Run.MenuKey -eq 'q') { return }
  $f = $files[[int]$Run.MenuKey - 1]
  Show-Pager $f.Name @(Get-Content -LiteralPath $f.FullName -Tail 5000 -Encoding UTF8) -End
}

# ------------------------------------------------------------- dependencies --
function Get-ScoopRoot { if ($env:SCOOP) { return $env:SCOOP } return (Join-Path $env:USERPROFILE 'scoop') }
function Test-Scoop { return [bool](Get-Command scoop -ErrorAction SilentlyContinue) }
function Test-Sioyek { return [bool](Get-Command sioyek -ErrorAction SilentlyContinue) }
function Test-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Add-ScoopShimsToPath {
  $shims = Join-Path (Get-ScoopRoot) 'shims'
  if ((Test-Path -LiteralPath $shims) -and (($env:Path -split ';') -notcontains $shims)) { $env:Path = "$shims;$env:Path" }
}

function Install-Scoop {
  if (Test-Scoop) { return }
  Write-Info 'scoop (https://scoop.sh) installs tools per user, without admin rights.'
  if (-not (Read-YesNo ' Install scoop now?' 'y')) { return }
  if (Test-Admin) { Write-Err 'scoop refuses to install from an elevated shell - re-run from a normal PowerShell.'; return }
  $pol = Get-ExecutionPolicy
  if ($pol -eq 'Restricted' -or $pol -eq 'AllSigned' -or $pol -eq 'Undefined') {
    Write-Info "Execution policy is '$pol'; scoop needs RemoteSigned for the current user."
    if (-not (Read-YesNo ' Set-ExecutionPolicy RemoteSigned -Scope CurrentUser?' 'y')) { return }
    Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
  }
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  $inst = Join-Path $Run.Tmp 'install-scoop.ps1'
  Write-Info 'Downloading the official installer from https://get.scoop.sh (HTTPS)…'
  Invoke-RestMethod -Uri 'https://get.scoop.sh' -OutFile $inst
  & $inst | Out-Host
  Add-ScoopShimsToPath
  if (Test-Scoop) { Write-Ok 'scoop installed.' } else { Write-Err 'scoop installation did not complete.' }
}

function Invoke-Scoop([string[]]$a) {
  Say " will run: ${CC}scoop $($a -join ' ')$C0"
  & scoop @a | Out-Host
  Add-ScoopShimsToPath
}

function Install-Rclone {
  Install-Scoop
  if (-not (Test-Scoop)) { return }
  if (Read-YesNo ' Install rclone with scoop?' 'y') { Invoke-Scoop @('install', 'rclone') }
  [void](Update-RclonePath)
}

function Install-Sioyek {
  Install-Scoop
  if (-not (Test-Scoop)) { return }
  if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Info 'git is needed for scoop buckets.'
    Invoke-Scoop @('install', 'git')
  }
  Invoke-Scoop @('bucket', 'add', 'extras')
  Invoke-Scoop @('install', 'extras/sioyek')
  if (Read-YesNo ' Also install the Visual C++ runtime sioyek needs (extras/vcredist2022)?' 'n') { Invoke-Scoop @('install', 'extras/vcredist2022') }
}

function Test-Dependencies {
  Add-ScoopShimsToPath
  if (-not (Update-RclonePath)) {
    Write-Warn 'rclone is required and not installed.'
    Install-Rclone
    if (-not $Run.Rclone) { throw 'Cannot continue without rclone (https://rclone.org/install/).' }
  }
  $m = Get-RcloneMinor
  if ($m -and $m -lt $MinRcloneMinor) {
    Write-Warn "rclone v1.$m is old (v1.$MinRcloneMinor+ recommended)."
    if ((Test-Scoop) -and (Read-YesNo ' Update it with scoop?' 'y')) { Invoke-Scoop @('update', 'rclone') }
  }
  if ($Cfg.SIOYEK_ASKED -eq 0) {
    if (-not (Test-Sioyek) -and (Read-YesNo 'sioyek (PDF reader whose annotations this tool syncs) is not installed. Install it?' 'y')) { Install-Sioyek }
    if (-not (Update-SqlitePath) -and
      (Read-YesNo 'sqlite3 (lets Pull/Merge combine sioyek annotations made on different devices) is not installed. Install it?' 'y')) { Install-Sqlite }
    $Cfg.SIOYEK_ASKED = 1; Save-Config
  }
}

function Install-Sqlite {
  Install-Scoop
  if (Test-Scoop) { Invoke-Scoop @('install', 'sqlite') }
  [void](Update-SqlitePath)
}

# ------------------------------------------------------------------- remote --
function Get-RemoteHeader {
  param([string]$t)
  $st = if ($t) { "configured ($t)" } else { "${CY}not configured$C0" }
  if ($t -and $Run.RemoteOk) { $st += " $CG$Tick connected$C0" }
  if (-not $Run.ConfFile) { $Run.ConfFile = ((Invoke-Rc @('config', 'file')).Out -split "`r?`n" | Where-Object { $_ } | Select-Object -Last 1) }
  $f = $Run.ConfFile
  $cl = @()
  if ($t -eq 'drive') {
    if ((Invoke-Rc @('config', 'show', $Cfg.REMOTE)).Out -match '(?m)^client_id = \S') { $cl = @(" API client  ${CG}your own$C0") }
    else { $cl = @(" API client  ${CY}rclone's shared one$C0 ${CD}(i: use your own - private quota, fewer rate limits)$C0") }
  }
  return @(" ${CB}Google Drive connection$C0", '', " rclone remote $CC$($Cfg.REMOTE):$C0 is $st") + $cl + @(
    " ${CD}The OAuth token lives in $f; consider encrypting it (Settings).$C0")
}

# Sets $Run.RemoteOk.
function Test-Remote {
  $Run.RemoteOk = $false
  Write-Info "Testing $($Cfg.REMOTE): $Ell"
  $r = Invoke-Rc (@('lsf', '--dirs-only') + (Get-BaseFlags) + @('--', "$($Cfg.REMOTE):"))
  if ($r.Code) { Write-Err "Cannot reach $($Cfg.REMOTE):"; Show-RcloneError $r.Err; Wait-AnyKey; return }
  $Run.RemoteOk = $true
  $top = (@($r.Out -split "`r?`n" | Where-Object { $_ }) -join ' ')
  if ($top.Length -gt 200) { $top = $top.Substring(0, 200) + $Ell }
  Write-Ok "Connected. Top-level folders: $top"
  $r = Invoke-Rc (@('lsf', '--dirs-only', '--max-depth', '1') + (Get-BaseFlags) + @('--', (Get-RPath)))
  if ($r.Code -eq 0) { Write-Ok "Library root $(Get-RPath) found." }
  else {
    Write-Warn "$(Get-RPath) does not exist."
    if (Read-YesNo ' Browse Drive to choose the library root?' 'y') { $Run.DirCache.Clear(); Select-Folders 'root' }
  }
  [Console]::Write("`n${CD}press any key to continue$Ell$C0"); $null = Read-Key; Say
}

# Interactive (rclone OAuth prompt) - call as a statement.
function Set-OwnClientId([string]$type) {
  Say " ${CB}Use your own Google API client ID$C0"; Say
  Say " rclone's built-in client ID is shared by every rclone user, so it often hits Google's rate"
  Say ' limits. Your own gives you a private quota. One-time setup (about 10 minutes):'
  Say "  1. https://console.cloud.google.com $Arrow create a project (any name)"
  Say "  2. APIs & Services $Arrow Library $Arrow enable 'Google Drive API'"
  Say "  3. Google Auth Platform $Arrow Get started: External, your email; Audience $Arrow add yourself"
  Say "     as a test user, then 'Publish app' (otherwise the login expires every 7 days)"
  Say "  4. Clients $Arrow Create client $Arrow type 'Desktop app' $Arrow copy the client ID and secret"
  Say " ${CD}Details: https://rclone.org/drive/#making-your-own-client-id$C0"; Say
  $id = Read-Line ' Client ID (blank to cancel)'
  if (-not $id) { return }
  if ($id -notmatch '^[0-9A-Za-z-]+\.apps\.googleusercontent\.com$') { Write-Err 'That is not a client ID (it ends in .apps.googleusercontent.com).'; Wait-AnyKey; return }
  $secret = Read-Secret ' Client secret'
  if ($secret -notmatch '^[A-Za-z0-9_-]{10,}$') { Write-Err 'That does not look like a client secret.'; Wait-AnyKey; return }
  if ($type -eq 'drive') {
    $r = Invoke-Rc @('config', 'update', $Cfg.REMOTE, "client_id=$id", "client_secret=$secret", '--non-interactive')
    if ($r.Code) { Write-Err 'Could not save the credentials.'; Show-RcloneError $r.Err; Wait-AnyKey; return }
    Write-Info 'Saved. Now authorise again in the browser so the login is issued for your client.'
    Write-Info "Google's 'app not verified' warning is expected (it is your own app): Advanced $Arrow Go to $Ell"
    Set-Cursor $true
    & $Run.Rclone config reconnect "$($Cfg.REMOTE):"
  } else {
    Write-Info 'A browser window will open to authorise access.'
    Set-Cursor $true
    & $Run.Rclone config create $Cfg.REMOTE drive scope=drive "client_id=$id" "client_secret=$secret"
    Save-Config
  }
  Test-Remote
}

# Interactive (rclone OAuth prompts) - always call as a statement, never capture its output.
# Returns as soon as a connection has been set up and tested successfully.
function Set-Remote {
  $Run.RemoteOk = $false
  while ($true) {
    if ($Run.RemoteOk) { return }
    $long = @((Invoke-Rc @('listremotes', '--long')).Out -split "`r?`n" | Where-Object { $_.Trim() })
    $names = @($long | ForEach-Object { ($_.Trim() -split '\s+')[0].TrimEnd(':') })
    $type = ''
    foreach ($l in $long) { $f = $l.Trim() -split '\s+'; if ($f.Count -ge 2 -and $f[0] -ceq "$($Cfg.REMOTE):") { $type = $f[1] } }
    $items = @()
    if ($type) { $items += "d|Done|use '$($Cfg.REMOTE)' and go back" }
    $items += @("n|New connection|authorise Google Drive in the browser (creates remote '$($Cfg.REMOTE)')",
      "w|rclone wizard|full 'rclone config' (own client id, shared drives, ...)")
    if ($names.Count) { $items += "e|Use existing|choose one of: $($names -join ' ')" }
    if ($type) { $items += 't|Test|check the connection and the library root' }
    $items += "r|Reconnect|refresh an expired authorisation for '$($Cfg.REMOTE)'"
    $items += 'i|Own client ID|use your own Google API credentials (private quota, faster)'
    $hdr = { Get-RemoteHeader $type }  # $type resolves via dynamic scope inside Show-Menu
    Show-Menu 'remote' $hdr $items
    Clear-Screen
    switch -CaseSensitive ($Run.MenuKey) {
      'n' {
        $name = Read-Line 'Name for the new remote' $Cfg.REMOTE
        if ($name -notmatch '^[A-Za-z0-9_.][A-Za-z0-9_.-]*$') { Write-Err 'Invalid name.'; Wait-AnyKey; continue }
        $Cfg.REMOTE = $name
        Write-Info 'A browser window will open to authorise access (scope: full Drive, needed to see existing files).'
        Set-Cursor $true
        & $Run.Rclone config create $name drive scope=drive
        Save-Config; Test-Remote
      }
      'w' { Set-Cursor $true; & $Run.Rclone config; Test-Remote }
      'e' {
        $it = @(); for ($i = 0; $i -lt [Math]::Min(9, $names.Count); $i++) { $it += "$($i + 1)|$($names[$i])|" }
        Show-Menu 'remote-pick' $hdr $it
        if ($Run.MenuKey -eq 'q') { continue }
        $Cfg.REMOTE = $names[[int]$Run.MenuKey - 1]; Save-Config; Clear-Screen; Test-Remote
      }
      't' { Test-Remote }
      'r' { Set-Cursor $true; & $Run.Rclone config reconnect "$($Cfg.REMOTE):"; Test-Remote }
      'i' { Set-OwnClientId $type }
      'd' { return }
      'q' { return }
    }
  }
}

# ------------------------------------------------------------------- sioyek --
# Prefs is the file sioyek reads. Under scoop it is hard-linked to a copy in scoop\persist (Extra),
# which scoop re-links on every update, so both must carry the setting.
function Get-SioyekPaths {
  $app = Join-Path (Get-ScoopRoot) 'apps\sioyek\current'
  if (Test-Path -LiteralPath (Join-Path $app 'sioyek.exe')) {
    $persist = Join-Path (Get-ScoopRoot) 'persist\sioyek\prefs_user.config'
    $extra = if (Test-Path -LiteralPath $persist) { @($persist) } else { @() }
    return @{ Prefs = (Join-Path $app 'prefs_user.config'); Extra = $extra; Db = (Join-Path $app 'shared.db') }
  }
  $exe = Get-Command sioyek.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($exe) {
    $d = Split-Path -Parent $exe.Source
    if (Test-Path -LiteralPath (Join-Path $d 'prefs.config')) { return @{ Prefs = (Join-Path $d 'prefs_user.config'); Extra = @(); Db = (Join-Path $d 'shared.db') } }
  }
  $d = Join-Path $env:APPDATA 'sioyek'
  return @{ Prefs = (Join-Path $d 'prefs_user.config'); Extra = @(); Db = (Join-Path $d 'shared.db') }
}

# Overwrites in place, not via Write-Atomic: replacing the file would break scoop's hard link and
# sioyek would keep reading the old copy.
function Write-SioyekPrefs($sp, [string[]]$lines) {
  $text = ($lines -join "`n") + "`n"
  foreach ($f in @($sp.Prefs) + @($sp.Extra)) { [IO.File]::WriteAllText($f, $text, $Utf8) }
}

# Run against a copy of the local shared.db, this prints the SQL that merges r (remote) into it,
# given b (the database as it was after the last sync). Rows are compared by content (every column
# but the rowid key): added on the remote = r EXCEPT b, deleted on the remote = b EXCEPT r. On a
# unique-key clash the local row wins, except in opened_books, where the latest reading position
# wins. Keep identical to SIOYEK_MERGE_SQL in library.sh.
$SioyekMergeSql = @'
WITH c AS (
  SELECT t.name AS tbl,
    group_concat('"' || p.name || '"', ',') AS cols,
    group_concat('x."' || p.name || '" IS d."' || p.name || '"', ' AND ') AS eq
  FROM sqlite_master AS t, pragma_table_info(t.name) AS p
  WHERE t.type = 'table' AND t.name NOT LIKE 'sqlite%' AND p.pk = 0
  GROUP BY t.name)
SELECT
  printf('CREATE TABLE IF NOT EXISTS b."%s" AS SELECT * FROM main."%s" WHERE 0;', tbl, tbl) || char(10) ||
  printf('DELETE FROM main."%s" AS x WHERE EXISTS (SELECT 1 FROM (SELECT %s FROM b."%s" EXCEPT SELECT %s FROM r."%s") AS d WHERE %s);',
    tbl, cols, tbl, cols, tbl, eq) || char(10) ||
  printf('INSERT OR IGNORE INTO main."%s" (%s) SELECT %s FROM r."%s" EXCEPT SELECT %s FROM b."%s" EXCEPT SELECT %s FROM main."%s";',
    tbl, cols, cols, tbl, cols, tbl, cols, tbl) ||
  CASE WHEN tbl = 'opened_books' AND cols LIKE '%"path"%' AND cols LIKE '%"last_access_time"%' THEN char(10) ||
    printf('UPDATE main.opened_books AS x SET (%s) = (SELECT %s FROM r.opened_books AS d WHERE d.path IS x.path) WHERE EXISTS (SELECT 1 FROM r.opened_books AS d WHERE d.path IS x.path AND d.last_access_time > x.last_access_time);',
      cols, cols)
  ELSE '' END
FROM c;
'@

function Update-SqlitePath {
  $c = Get-Command sqlite3 -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  $Run.Sqlite = if ($c) { $c.Source } else { $null }
  return [bool]$Run.Sqlite
}

# SQL goes in on stdin as UTF-8 bytes (Windows PowerShell can't set the stdin encoding).
function Invoke-Sqlite([string]$db, [string]$sql) {
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = $Run.Sqlite
  $psi.Arguments = '-bail -batch ' + (ConvertTo-QuotedArg $db)
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = $Utf8; $psi.StandardErrorEncoding = $Utf8
  $p = [Diagnostics.Process]::Start($psi)
  $out = $p.StandardOutput.ReadToEndAsync(); $err = $p.StandardError.ReadToEndAsync()
  $b = $Utf8.GetBytes($sql); $p.StandardInput.BaseStream.Write($b, 0, $b.Length); $p.StandardInput.Close()
  $p.WaitForExit()
  return [pscustomobject]@{ Code = $p.ExitCode; Out = $out.Result; Err = $err.Result }
}

function ConvertTo-SqlString([string]$s) { return "'" + $s.Replace("'", "''") + "'" }

function Get-DbSchema([string]$db) {
  $r = Invoke-Sqlite $db "SELECT type || ' ' || name || ' ' || sql FROM sqlite_master WHERE name NOT LIKE 'sqlite%' ORDER BY name;"
  if ($r.Code) { return '' }
  return $r.Out
}

function Get-SioyekBase { return Join-Path $CfgDir 'sioyek-base.db' }

# After every successful sync the local shared.db equals the remote one: keep it as the merge base.
function Save-SioyekBase {
  if (@($Cfg.FOLDERS) -cnotcontains $AnnotDir) { return }
  $db = Join-Path (Join-Path $Cfg.LIBRARY_ROOT $AnnotDir) 'shared.db'
  if (Test-Path -LiteralPath $db) { Copy-Item -LiteralPath $db -Destination (Get-SioyekBase) -Force }
}

# Pull/Merge with shared.db changed: merge the remote database into the local one and upload the
# result, so the following rclone run finds both sides identical. Returns merged|skip|fail;
# on skip, the newer shared.db wins as before.
function Merge-SioyekDb([string]$localTrash, [string]$remoteTrash) {
  $rel = "$AnnotDir/shared.db"
  $local = Join-Path (Join-Path $Cfg.LIBRARY_ROOT $AnnotDir) 'shared.db'
  $base = Get-SioyekBase
  $hasBase = Test-Path -LiteralPath $base
  if (-not (Test-Path -LiteralPath $local)) { return 'skip' }
  # Unchanged here since the last sync: the remote copy already holds everything.
  if ($hasBase -and (Get-FileHash -LiteralPath $local).Hash -eq (Get-FileHash -LiteralPath $base).Hash) { return 'skip' }
  if (-not $Run.Sqlite) {
    Write-Warn 'sqlite3 is not installed, so the newer shared.db replaces the other (Settings -> Dependencies installs it).'
    return 'skip'
  }
  Write-Info "Merging sioyek annotations from both sides$Ell"
  $remote = Join-Path $Run.Tmp 'remote-shared.db'; $merged = Join-Path $Run.Tmp 'merged-shared.db'; $b = Join-Path $Run.Tmp 'base-shared.db'
  $r = Invoke-Rc (@('copyto') + (Get-BaseFlags) + @('--', (Get-RPath $rel), $remote))
  if ($r.Code) { Write-Err "Could not download $rel from the remote:"; Show-RcloneError $r.Err; return 'fail' }
  $schema = Get-DbSchema $local
  if (-not $schema -or $schema -cne (Get-DbSchema $remote)) {
    Write-Warn 'The two shared.db files come from different sioyek versions and cannot be merged - the newer one wins.'
    return 'skip'
  }
  # Without a usable base every row on either side counts as new: nothing gets deleted.
  if ($hasBase) { Copy-Item -LiteralPath $base -Destination $b -Force }
  if (-not $hasBase -or (Get-DbSchema $b) -cne $schema) { $b = ':memory:' }
  Copy-Item -LiteralPath $local -Destination $merged -Force
  $gen = Invoke-Sqlite $merged $SioyekMergeSql
  if ($gen.Code -eq 0) {
    $gen = Invoke-Sqlite $merged ("ATTACH {0} AS r;`nATTACH {1} AS b;`nBEGIN;`n{2}`nCOMMIT;`n" -f (ConvertTo-SqlString $remote), (ConvertTo-SqlString $b), $gen.Out)
  }
  if ($gen.Code) { Write-Err "Merging the annotation databases failed: $($gen.Err.Trim())"; return 'fail' }
  $null = New-Item -ItemType Directory -Force -Path (Join-Path $localTrash $AnnotDir)
  Copy-Item -LiteralPath $local -Destination (Join-Path (Join-Path $localTrash $AnnotDir) 'shared.db') -Force
  Copy-Item -LiteralPath $merged -Destination $local -Force
  $r = Invoke-Rc (@('copyto') + (Get-BaseFlags) + @('--backup-dir', "$remoteTrash/$AnnotDir", '--', $local, (Get-RPath $rel)))
  if ($r.Code) { Write-Err "Merged locally, but uploading $rel failed:"; Show-RcloneError $r.Err; return 'fail' }
  Write-Ok 'Merged sioyek annotations (previous copies kept in trash).'; Add-LogLine 'merged sioyek annotations'
  return 'merged'
}

function Set-SioyekDb {
  $sp = Get-SioyekPaths
  $target = Join-Path (Join-Path $Cfg.LIBRARY_ROOT $AnnotDir) 'shared.db'
  $targetCfg = $target.Replace('\', '/')
  Clear-Screen
  $current = ''
  if (Test-Path -LiteralPath $sp.Prefs) {
    $m = @(Get-Content -LiteralPath $sp.Prefs -Encoding UTF8 | Where-Object { $_ -match '^\s*shared_database_path\s+' })
    if ($m.Count) { $current = ($m[-1] -replace '^\s*shared_database_path\s+', '').Trim() }
  }
  Say " ${CB}Sioyek annotations$C0"; Say
  Say ' sioyek stores highlights/bookmarks in shared.db, keyed by file content (works across devices).'
  Say " prefs file : $(Get-Tilde $sp.Prefs)"
  Say " current db : $(if ($current) { $current } else { "$(Get-Tilde $sp.Db) (default)" })"
  Say " library db : $(Get-Tilde $target)"; Say
  if ($current -and ($current.Replace('\', '/') -eq $targetCfg)) { Write-Ok 'Already pointing at the library.'; Wait-AnyKey; return }
  if (-not (Read-YesNo " Point sioyek's shared.db at the library folder?" 'y')) { return }
  if (Test-SioyekRunning) { Write-Warn 'Close sioyek first.'; Wait-AnyKey; return }
  $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target), (Split-Path -Parent $sp.Prefs)
  if (-not (Test-Path -LiteralPath $target)) {
    $src = if ($current) { $current } else { $sp.Db }
    $r = Invoke-Rc (@('lsf') + (Get-BaseFlags) + @('--', (Get-RPath "$AnnotDir/shared.db")))
    if ($r.Code -eq 0 -and $r.Out.Trim()) { Write-Info "The remote already has $AnnotDir/shared.db - pull to get it (not copying the local one)." }
    elseif ((Test-Path -LiteralPath $src) -and (Read-YesNo " Copy your existing annotations ($(Get-Tilde $src)) into the library?" 'y')) {
      Copy-Item -LiteralPath $src -Destination $target; Write-Ok 'Copied.'
    }
  }
  $lines = @()
  if (Test-Path -LiteralPath $sp.Prefs) {
    Copy-Item -LiteralPath $sp.Prefs -Destination "$($sp.Prefs).bak" -Force
    $lines = @(Get-Content -LiteralPath $sp.Prefs -Encoding UTF8 | Where-Object { $_ -notmatch '^\s*shared_database_path' })
  }
  $lines += "shared_database_path $targetCfg"
  Write-SioyekPrefs $sp $lines
  Write-Ok "Updated $(Get-Tilde $sp.Prefs) (backup: .bak)"
  if (@($Cfg.FOLDERS) -cnotcontains $AnnotDir) { $Cfg.FOLDERS = @($Cfg.FOLDERS) + $AnnotDir; Save-Config; Write-Ok "Added '$AnnotDir' to synced folders." }
  if ($Run.Sqlite) { Write-Info 'Pull and Merge combine annotations made on different devices; Push overwrites the remote shared.db with this one.' }
  else { Write-Warn 'sqlite3 is not installed: if two devices annotate before syncing, the newer shared.db wins (Settings -> Dependencies installs it).' }
  Wait-AnyKey
}

# ----------------------------------------------------------------- settings --
function Install-Launcher {
  $root = $Cfg.LIBRARY_ROOT
  $p = [Environment]::GetEnvironmentVariable('Path', 'User'); if (-not $p) { $p = '' }
  if (($p -split ';') -contains $root) { Write-Ok "$root is already on your user PATH." }
  else {
    [Environment]::SetEnvironmentVariable('Path', (($p.TrimEnd(';') + ";$root").TrimStart(';')), 'User')
    $env:Path = "$env:Path;$root"
    Write-Ok "Added $root to your user PATH - open a new terminal and type 'library'."
  }
}

function Edit-Tuning {
  Clear-Screen
  Say " ${CB}Tuning$C0  ${CD}(Google allows ~10 API calls/s with rclone's shared client id)$C0"
  $v = Read-Line 'Parallel file transfers (1-32)' ([string]$Cfg.TRANSFERS); if ($v -match '^\d+$' -and [int]$v -ge 1 -and [int]$v -le 32) { $Cfg.TRANSFERS = [int]$v }
  $v = Read-Line 'Parallel checkers (1-64)' ([string]$Cfg.CHECKERS); if ($v -match '^\d+$' -and [int]$v -ge 1 -and [int]$v -le 64) { $Cfg.CHECKERS = [int]$v }
  $v = Read-Line 'API transactions/s (0 = unlimited)' ([string]$Cfg.TPSLIMIT); if ($v -match '^\d+$' -and [int]$v -le 100) { $Cfg.TPSLIMIT = [int]$v }
  $v = Read-Line 'Bandwidth limit (e.g. 10M, "off" to disable)' $(if ($Cfg.BWLIMIT) { $Cfg.BWLIMIT } else { 'off' })
  if ($v -eq 'off') { $Cfg.BWLIMIT = '' } elseif ($v -match '^[0-9A-Za-z.:, -]*$') { $Cfg.BWLIMIT = $v }
  Save-Config; Write-Ok 'Saved.'; Wait-AnyKey
}

function Show-Settings {
  while ($true) {
    $hdr = {
      " ${CB}Settings$C0", '',
      " config  $(Get-Tilde $CfgFile)",
      " rclone  $(((Invoke-Rc @('version')).Out -split "`r?`n")[0]) $([char]0xB7) remote $($Cfg.REMOTE) ($(Get-RemoteType))",
      " tuning  transfers $($Cfg.TRANSFERS) $([char]0xB7) checkers $($Cfg.CHECKERS) $([char]0xB7) tpslimit $($Cfg.TPSLIMIT) $([char]0xB7) bwlimit $(if ($Cfg.BWLIMIT) { $Cfg.BWLIMIT } else { 'off' })"
    }
    Show-Menu 'settings' $hdr @(
      '1|Drive connection|connect / reconnect / test Google Drive',
      "2|Library root|remote folder holding your library ($(Get-RPath))",
      "3|Local folder|where files live on this device ($(Get-Tilde $Cfg.LIBRARY_ROOT))",
      '4|Sioyek|keep sioyek annotations inside the library',
      '5|Dependencies|check / install rclone and sioyek (via scoop)',
      '6|Tuning|parallel transfers, API rate limit, bandwidth',
      '7|Encrypt config|password-protect rclone.conf (OAuth token)',
      "8|Launcher|add $(Get-Tilde $Cfg.LIBRARY_ROOT) to PATH so 'library' works anywhere",
      '9|Filter rules|show the generated rclone filter file',
      'u|Uninstall|remove library from this device (keeps your books unless you ask)')
    switch ($Run.MenuKey) {
      '1' { Set-Remote }
      '2' { $Run.DirCache.Clear(); Select-Folders 'root' }
      '3' {
        Clear-Screen
        $f = Read-Line 'Local library folder' $Cfg.LIBRARY_ROOT
        if ([IO.Path]::IsPathRooted($f)) {
          $Cfg.LIBRARY_ROOT = $f.TrimEnd('\'); $null = New-Item -ItemType Directory -Force -Path (Join-Path $Cfg.LIBRARY_ROOT 'logs')
          $Run.DiffReady = $false; Save-Config
          Write-Warn 'Existing files were not moved. Move them yourself or pull into the new folder.'; Wait-AnyKey
        }
      }
      '4' { Set-SioyekDb }
      '5' { Clear-Screen; $Cfg.SIOYEK_ASKED = 0; Test-Dependencies; Write-Ok "rclone: $($Run.Rclone)"; if (Test-Sioyek) { Write-Ok 'sioyek installed' }; if (Update-SqlitePath) { Write-Ok "sqlite3: $($Run.Sqlite)" }; Wait-AnyKey }
      '6' { Edit-Tuning }
      '7' {
        Clear-Screen
        if ((Get-RcloneMinor) -ge 65) { Set-Cursor $true; & $Run.Rclone config encryption set }
        else { Write-Info "Run 'rclone config' and choose 's) Set configuration password'."; Wait-AnyKey }
      }
      '8' { Clear-Screen; Install-Launcher; Wait-AnyKey }
      '9' { if (Build-Filters) { Show-Pager 'rclone filter rules' @([IO.File]::ReadAllLines($FilterFile)) } }
      'u' { if (Uninstall-Library) { $Run.Quit = $true; return } }
      'q' { return }
    }
  }
}

# ---------------------------------------------------------------- uninstall --
# Removes the tool from this device: scripts, logs, settings, the PATH entry and this device's
# record on the remote. Books and annotations stay unless the user explicitly asks (default no).
# Returns $true when uninstalled.
function Uninstall-Library {
  $root = $Cfg.LIBRARY_ROOT
  Clear-Screen
  $scripts = @('library.ps1', 'library.cmd', 'library.sh' | ForEach-Object { Join-Path $root $_ } | Where-Object { Test-Path -LiteralPath $_ })
  $logs = Join-Path $root 'logs'
  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User'); if (-not $userPath) { $userPath = '' }
  $onPath = ($userPath -split ';') -contains $root
  $hasRemote = $Run.Rclone -and (Get-RemoteType)
  Say " ${CB}Uninstall library from this device$C0"; Say
  Say ' Will remove:'
  foreach ($s in $scripts) { Say "   $(Get-Tilde $s)" }
  if (Test-Path -LiteralPath $logs) { Say "   $(Get-Tilde $logs)\  ${CD}(sync logs)$C0" }
  if (Test-Path -LiteralPath $CfgDir) { Say "   $(Get-Tilde $CfgDir)\  ${CD}(this device's settings)$C0" }
  if ($onPath) { Say "   $root from your user PATH" }
  if ($hasRemote) { Say "   $(Get-RPath "$MarkerDir/$HostId.txt")  ${CD}(this device's sync record)$C0" }
  Say; Say ' Will keep:'
  Say "   $(Get-Tilde $root)\ with your books, annotations and .trash, the copy on Google Drive,"
  Say '   rclone, scoop and sioyek'
  Say
  $delContent = $false
  if ((Test-Path -LiteralPath $root) -and (Read-YesNo " Also delete $(Get-Tilde $root) and every file in it from this device?" 'n')) {
    Write-Warn 'Deleted files do not go to trash. The copy on Google Drive is not touched.'
    if ((Read-Line " Type 'delete' to confirm") -ceq 'delete') { $delContent = $true } else { Write-Info 'Keeping your files.' }
  }
  $delLogin = $false
  if ($hasRemote) { $delLogin = Read-YesNo " Also remove the Google Drive login '$($Cfg.REMOTE)' from rclone?" 'n' }
  if (-not (Read-YesNo ' Uninstall now?' 'n')) { Write-Info 'Cancelled.'; Wait-AnyKey; return $false }
  Say
  if ($hasRemote) {
    $r = Invoke-Rc (@('deletefile') + (Get-BaseFlags) + @('--', (Get-RPath "$MarkerDir/$HostId.txt")))
    if ($r.Code -eq 0) { Write-Ok 'Removed this device from the remote sync records.' }
  }
  if ($delLogin) {
    $r = Invoke-Rc @('config', 'delete', $Cfg.REMOTE)
    if ($r.Code -eq 0) { Write-Ok "Removed rclone remote '$($Cfg.REMOTE)'." } else { Write-Warn "Could not remove rclone remote '$($Cfg.REMOTE)'." }
  }
  if ($delContent) {
    # sioyek would otherwise keep pointing at a database that no longer exists.
    $sp = Get-SioyekPaths
    if (Test-Path -LiteralPath $sp.Prefs) {
      $target = (Join-Path (Join-Path $root $AnnotDir) 'shared.db').Replace('\', '/')
      $lines = @(Get-Content -LiteralPath $sp.Prefs -Encoding UTF8)
      $keep = @($lines | Where-Object { -not ($_ -match '^\s*shared_database_path\s+(.*)$' -and $Matches[1].Trim().Replace('\', '/') -eq $target) })
      if ($keep.Count -ne $lines.Count) { Write-SioyekPrefs $sp $keep; Write-Ok 'sioyek uses its own annotation database again.' }
    }
  }
  if ($onPath) {
    [Environment]::SetEnvironmentVariable('Path', (($userPath -split ';' | Where-Object { $_ -and $_ -ne $root }) -join ';'), 'User')
    Write-Ok "Removed $root from your user PATH."
  }
  if (Test-Path -LiteralPath $CfgDir) { Remove-Item -LiteralPath $CfgDir -Recurse -Force; Write-Ok "Removed $(Get-Tilde $CfgDir)" }
  Set-Location -LiteralPath $env:USERPROFILE; [Environment]::CurrentDirectory = $env:USERPROFILE
  $full = [IO.Path]::GetFullPath($root).TrimEnd('\')
  if ($delContent -and $full -ne [IO.Path]::GetPathRoot($full).TrimEnd('\') -and $full -ne $env:USERPROFILE.TrimEnd('\')) {
    Remove-Item -LiteralPath $root -Recurse -Force; Write-Ok "Deleted $(Get-Tilde $root)"
  } else {
    if (Test-Path -LiteralPath $logs) { Remove-Item -LiteralPath $logs -Recurse -Force }
    foreach ($s in $scripts) { Remove-Item -LiteralPath $s -Force }
    Write-Ok "Removed the scripts and logs; your files are still in $(Get-Tilde $root)"
  }
  Say; Write-Ok 'library is uninstalled from this device.'
  return $true
}

# ---------------------------------------------------------------- first run --
function Install-Self {
  $root = $Cfg.LIBRARY_ROOT
  $srcDir = Split-Path -Parent $Self
  if ($srcDir.TrimEnd('\') -ieq $root.TrimEnd('\')) { return }
  foreach ($f in 'library.ps1', 'library.cmd') {
    $src = Join-Path $srcDir $f
    if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $root $f) -Force; Write-Ok "Installed $f to $(Get-Tilde $root)" }
  }
}

# The 'library' command runs the copy installed in the library folder. When a different copy is
# run (e.g. a newer download), offer to replace the installed one with it.
function Update-Self {
  $inst = Join-Path $Cfg.LIBRARY_ROOT 'library.ps1'
  if (-not $Run.Interactive -or -not (Test-Path -LiteralPath $inst) -or $Self -ieq $inst) { return }
  if ((Get-FileHash -LiteralPath $Self).Hash -eq (Get-FileHash -LiteralPath $inst).Hash) { return }
  $v = (Select-String -LiteralPath $inst -Pattern "^\`$Version = '([^']*)'" | Select-Object -First 1)
  $v = if ($v) { $v.Matches[0].Groups[1].Value } else { '?' }
  Write-Info "The installed copy ($(Get-Tilde $inst), v$v) differs from this one (v$Version)."
  if (Read-YesNo ' Replace the installed copy with this one?' 'y') { Install-Self }
}

function Start-FirstRun {
  Clear-Screen
  Say; Say " ${CB}library$C0 - Google Drive sync for books, papers and sioyek annotations"; Say
  Say ' Where should the library live on this device?'
  Say " ${CD}(files, logs and the scripts are kept here; settings go to $(Get-Tilde $CfgDir))$C0"
  $root = Read-Line ' Library folder' $Cfg.LIBRARY_ROOT
  $root = [Environment]::ExpandEnvironmentVariables($root)
  if ($root.StartsWith('~')) { $root = $env:USERPROFILE + $root.Substring(1) }
  if (-not [IO.Path]::IsPathRooted($root)) { throw 'Please give an absolute path.' }
  $Cfg.LIBRARY_ROOT = [IO.Path]::GetFullPath($root).TrimEnd('\')
  foreach ($d in 'content', $AnnotDir, 'logs') { $null = New-Item -ItemType Directory -Force -Path (Join-Path $Cfg.LIBRARY_ROOT $d) }
  Save-Config
  Install-Self
  if (Read-YesNo " Add $(Get-Tilde $Cfg.LIBRARY_ROOT) to your PATH so 'library' works in any terminal?" 'y') { Install-Launcher }
  Test-Dependencies
  Use-StableRcloneConfig
  Unlock-Rclone
  if (Get-RemoteType) { Test-Remote } else { Set-Remote }
  if ((Get-RemoteType) -and (Read-YesNo " Choose which Drive folders to sync now? (default: $(@($Cfg.FOLDERS) -join ', '))" 'n')) { Select-Folders 'select' }
  if (Test-Sioyek) { Set-SioyekDb }
  Write-Ok 'Setup complete. Tip: run Status first, then Pull.'
  Wait-AnyKey
}

# ---------------------------------------------------------------- main menu --
function Get-MainHeader {
  return @(
    " $CB${CC}library$C0 ${CD}v$Version $([char]0xB7) $HostId$C0", '',
    (' {0,-8} {1}' -f 'Local', (Get-Tilde $Cfg.LIBRARY_ROOT)),
    (' {0,-8} {1}   {2}trash {3} {4}:{5}{6}' -f 'Remote', (Get-RPath), $CD, $Arrow, $Cfg.REMOTE, $Cfg.REMOTE_TRASH, $C0),
    (' {0,-8} {1}' -f 'Folders', (@($Cfg.FOLDERS) -join ', ')),
    (' {0,-8} {1}' -f 'Filter', (Get-FilterDesc)),
    (' {0,-8} pull {1} {2} push {3}' -f 'Last', (Format-Ago $State.LAST_PULL), [char]0xB7, (Format-Ago $State.LAST_PUSH)))
}

function Get-HelpText {
  return @"
library $Version - keyboard
  j/k or arrows   move          g/G      top/bottom      ctrl-d/u  half page
  enter / l       select/open   h / esc  back            q         back / quit
  /               search (status view)                   tab       next category
  s / x           open file / its folder (status view; Drive files open in the browser)

Operations
  Status   lists both sides (in parallel) and classifies every file:
           $($CatSym.radd) only on remote · $($CatSym.rnew) newer on remote · $($CatSym.ladd) only local · $($CatSym.lnew) newer local
           $($CatSym.ren.Trim()) renamed/moved (same size and time, different path)
           $($CatSym.size) same time, different size · = identical (size + modification time)
  Pull     makes local identical to remote. Local files that would be deleted or
           overwritten are moved to $(Get-Tilde $Cfg.LIBRARY_ROOT)\.trash\<timestamp>.
  Push     makes remote identical to local. Remote files that would be deleted or
           overwritten are moved to $($Cfg.REMOTE):$($Cfg.REMOTE_TRASH)/<timestamp>.
  Merge    two-way copy: new and newer files flow both ways, nothing is deleted.
           Renamed files get the new name on both sides (the side that renamed
           since the last sync wins).
  Renames/moves are done as moves (server-side on Drive), never as re-transfers.
  sioyek's shared.db is merged row by row on Pull and Merge (needs sqlite3):
           highlights/bookmarks added or deleted on either side since the last
           sync are kept or deleted on both. Push uploads this device's copy.

Only the selected folders are synced; logs\, .trash\ and the scripts stay local.
The file-type filter is per device (e.g. PDFs only on a tablet); sioyek's
annotation folder is never filtered. Each sync leaves a marker in
$(Get-RPath $MarkerDir)/ so Status shows when other devices last synced.

Command line:  library status | pull | push | merge  [-Yes] [-Force]
Settings: $(Get-Tilde $CfgFile)   Logs: $(Get-Tilde (Join-Path $Cfg.LIBRARY_ROOT 'logs'))
"@ -split "`r?`n"
}

function Show-MainMenu {
  while ($true) {
    Start-Prefetch
    Show-Menu 'main' { Get-MainHeader } @(
      's|Status|compare local and remote - what is new where',
      "p|Pull|remote $Arrow local (mirror; removed files go to local trash)",
      "u|Push|local $Arrow remote (mirror; removed files go to remote trash)",
      'm|Merge|two-way: copy new/newer files both ways, never delete',
      'f|Folders|choose which Drive folders to sync',
      "x|Filters|file-type filter for this device ($(Get-FilterDesc))",
      't|Trash|inspect / clean sync backups',
      'o|Logs|view sync logs',
      'c|Settings|Drive connection, sioyek, dependencies, tuning',
      '?|Help|keys and how syncing works')
    Clear-Screen
    switch -CaseSensitive ($Run.MenuKey) {
      's' {
        if (-not (Invoke-ComputeDiff)) { Wait-AnyKey; break }
        while ($true) {
          Show-Diff
          $act = $Run.ViewAction
          if ($act -ceq 'p') { Clear-Screen; Invoke-Sync 'pull'; Wait-AnyKey; break }
          elseif ($act -ceq 'u') { Clear-Screen; Invoke-Sync 'push'; Wait-AnyKey; break }
          elseif ($act -ceq 'm') { Clear-Screen; Invoke-Sync 'merge'; Wait-AnyKey; break }
          elseif ($act -ceq 'r') { Clear-Screen; if (-not (Invoke-ComputeDiff)) { Wait-AnyKey; break } }
          else { break }
        }
      }
      'p' { Invoke-Sync 'pull'; Wait-AnyKey }
      'u' { Invoke-Sync 'push'; Wait-AnyKey }
      'm' { Invoke-Sync 'merge'; Wait-AnyKey }
      'f' { $Run.DirCache.Clear(); Select-Folders 'select' }
      'x' { Edit-Filters }
      't' { Show-Trash }
      'o' { Show-Logs }
      'c' { Show-Settings; if ($Run.Quit) { return } }
      '?' { Show-Pager 'Help' (Get-HelpText) }
      'q' { Clear-Screen; return }
    }
  }
}

function Enable-Vt {
  # Windows PowerShell 5.1 in the classic console may not process ANSI escapes by default.
  if ($PSVersionTable.PSVersion.Major -ge 6 -or $env:WT_SESSION -or -not $Run.Interactive) { return }
  try {
    Add-Type -Namespace LibrarySync -Name Con -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int h);
[DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr h, out uint m);
[DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr h, uint m);
'@
    $h = [LibrarySync.Con]::GetStdHandle(-11); $m = 0
    if ([LibrarySync.Con]::GetConsoleMode($h, [ref]$m)) { [void][LibrarySync.Con]::SetConsoleMode($h, $m -bor 4) }
  } catch { }
}

function Invoke-Main {
  if ($Command -eq 'help') { Get-Help $Self -Detailed; return }
  if ($Command -eq 'version') { Say $Version; return }
  $configured = Read-Kv $CfgFile
  if ($Command -eq 'uninstall') {
    if (-not $Run.Interactive) { throw 'Uninstall asks questions - run it in a terminal.' }
    Add-ScoopShimsToPath
    if (Update-RclonePath) { Use-StableRcloneConfig; Unlock-Rclone }
    $Run.LastRc = if (Uninstall-Library) { 0 } else { 1 }
    return
  }
  if ($Command -eq 'setup' -or -not $configured) {
    if (-not $Run.Interactive) { throw "Not configured yet - run 'library' in a terminal first." }
    Start-FirstRun
    $Command = 'menu'
  }
  [void](Read-Kv $StateFile)
  Update-Self
  Add-ScoopShimsToPath
  [void](Update-SqlitePath)
  if (-not (Update-RclonePath)) { Test-Dependencies }
  Use-StableRcloneConfig
  Unlock-Rclone
  switch ($Command) {
    'menu' {
      if (-not $Run.Interactive) { throw 'The menu needs a terminal. Try: library status' }
      Test-Dependencies
      if (-not (Get-RemoteType)) { Set-Remote }
      Show-MainMenu
    }
    'status' { if (Invoke-ComputeDiff) { Show-StatusText } else { $Run.LastRc = 1 } }
    default { Invoke-Sync $Command ([bool]$Yes) ([bool]$Force) }
  }
}

# Dot-sourcing (". .\library.ps1") only loads the functions - handy for testing.
if ($MyInvocation.InvocationName -ne '.') {
  $prevOut = [Console]::OutputEncoding
  [Console]::OutputEncoding = $Utf8; $OutputEncoding = $Utf8
  $Run.Tmp = Join-Path ([IO.Path]::GetTempPath()) ("library-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
  $null = New-Item -ItemType Directory -Path $Run.Tmp
  $exit = 0
  try {
    Enable-Vt
    Invoke-Main
    $exit = $Run.LastRc
  } catch {
    Write-Err $_.Exception.Message
    $exit = 1
  } finally {
    Set-Cursor $true
    Remove-Item -LiteralPath $Run.Tmp -Recurse -Force -ErrorAction SilentlyContinue
    [Console]::OutputEncoding = $prevOut
  }
  exit $exit
}
