# ai-sandbox.ps1: drive ai-sandbox.sh on the Proxmox host from a Windows
# desktop. Companion to ai-sandbox.sh and ai-sandbox-remote.sh
# (https://github.com/itsfja/AI-sandbox).
#
# The desktop never gets a root shell on the host: `init` installs a
# dedicated key that the host pins to ai-sandbox-remote.sh, which only
# accepts the verbs below (README: "Driving it from your desktop").
#
# Usage (Windows 10+, PowerShell; ssh/scp/ssh-keygen are built in):
#   .\ai-sandbox.ps1 init -PveHost root@192.168.3.188   once: key + host side
#                    [-PveScript /root/AI-sandbox/ai-sandbox.sh]  the host's script, if
#                                                       init should not find it itself
#   .\ai-sandbox.ps1 agents                             list agent profiles
#   .\ai-sandbox.ps1 status [agent]
#   .\ai-sandbox.ps1 up <agent> [-Code]                 build; -Code opens VS Code
#   .\ai-sandbox.ps1 down <agent>
#   .\ai-sandbox.ps1 reset <agent> [-Code]
#   .\ai-sandbox.ps1 secret <agent> [-Name VAR]         set the agent's key (pasted hidden,
#                    [-FromClipboard]                   or read from the clipboard)
#   .\ai-sandbox.ps1 profile <file.sh>                  upload a drop-in profile
#                                                       (host must allow it: REMOTE_PROFILES=on)
#   .\ai-sandbox.ps1 connect <agent> [folder]           VS Code into the sandbox
#   .\ai-sandbox.ps1 ssh <agent>                        terminal into the sandbox
#
# Settings: %USERPROFILE%\.ai-sandbox\desktop.env (written by init), plain
# KEY=value lines. PVE_HOST: -PveHost, then desktop.env, then $env:PVE_HOST.
#   PVE_HOST   root@<proxmox address>
#   PVE_KEY    desktop key pinned to ai-sandbox-remote.sh (default ~\.ssh\ai-sandbox-pve)
#   PVE_DIR    where ai-sandbox.sh lives on the host (default /root)

[CmdletBinding()]
param(
  [Parameter(Position = 0)][string]$Command = 'help',
  [Parameter(Position = 1)][string]$Target = '',
  [Parameter(Position = 2)][string]$Folder = '/root',
  [string]$PveHost = '',
  [string]$PveScript = '',
  [string]$Name = '',
  [switch]$Code,
  [switch]$FromClipboard
)

$ErrorActionPreference = 'Stop'
$CfgDir  = Join-Path $env:USERPROFILE '.ai-sandbox'
$CfgFile = Join-Path $CfgDir 'desktop.env'
$SshDir  = Join-Path $env:USERPROFILE '.ssh'
$SandboxKey = Join-Path $SshDir 'ai-sandbox'
$SshConfig  = Join-Path $SshDir 'config'

# The credential each agent's secrets.env expects (README "Agents").
$SecretNames = @{
  mistral  = 'MISTRAL_API_KEY'
  claude   = 'ANTHROPIC_API_KEY'
  gemini   = 'GEMINI_API_KEY'
  codex    = 'OPENAI_API_KEY'
  deepseek = 'DEEPSEEK_API_KEY'
}

function Die([string]$msg) { Write-Host "ai-sandbox: $msg" -ForegroundColor Red; exit 1 }
function Note([string]$msg) { Write-Host "ai-sandbox: $msg" }

function Read-Settings {
  # -PveHost > desktop.env (what init saved) > $env:PVE_HOST (shared with
  # vscode-connect.ps1) > nothing
  $s = @{ PVE_HOST = ''; PVE_KEY = (Join-Path $SshDir 'ai-sandbox-pve'); PVE_DIR = '/root' }
  if ($env:PVE_HOST) { $s.PVE_HOST = $env:PVE_HOST }
  if (Test-Path $CfgFile) {
    foreach ($line in Get-Content $CfgFile) {
      if ($line -match '^\s*([A-Z_]+)\s*=\s*(.*?)\s*$') { $s[$Matches[1]] = $Matches[2] }
    }
  }
  if ($PveHost) { $s.PVE_HOST = $PveHost }
  return $s
}

function Save-Settings($s) {
  New-Item -ItemType Directory -Force -Path $CfgDir | Out-Null
  $text = "PVE_HOST=$($s.PVE_HOST)`r`nPVE_KEY=$($s.PVE_KEY)`r`nPVE_DIR=$($s.PVE_DIR)`r`n"
  Set-Content -Path $CfgFile -Value $text -Encoding Ascii -NoNewline
}

function Assert-Agent([string]$a) {
  if ($a -cnotmatch '^[a-z][a-z0-9]{0,15}$') { Die "give an agent name, e.g. '.\ai-sandbox.ps1 $Command deepseek' ('.\ai-sandbox.ps1 agents' lists them)" }
}

function Assert-Ready($s) {
  if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
    Die "ssh not found; Settings > Apps > Optional Features > OpenSSH Client, then reopen the terminal"
  }
  if (-not $s.PVE_HOST) { Die "no Proxmox host set; run '.\ai-sandbox.ps1 init -PveHost root@<address>' first" }
  if (-not (Test-Path $s.PVE_KEY)) { Die "desktop key $($s.PVE_KEY) not found; run '.\ai-sandbox.ps1 init' first" }
}

function PveArgs($s, [switch]$Tty) {
  $a = @('-i', $s.PVE_KEY, '-o', 'IdentitiesOnly=yes', '-o', 'ConnectTimeout=10')
  if ($Tty) { $a += '-t' }
  return $a + @($s.PVE_HOST)
}

# Verbs run through ai-sandbox-remote.sh on the host. Interactive calls
# are made inline at script scope (not inside a function) so ssh writes
# straight to the console: a function would capture its output, and the
# work guard's "[y/N]" prompt would never show. Use -t for those.
function Get-PveOutput($s, [string]$verb) {
  $a = PveArgs $s
  $out = & ssh @a $verb
  if ($LASTEXITCODE -ne 0) { Die "'$verb' failed on $($s.PVE_HOST) (exit $LASTEXITCODE)" }
  return $out
}

# Run ssh with $text (ASCII: base64, a token, the init script) as its
# stdin, exactly, plus one LF. Piping a string into a native command would
# let Windows PowerShell 5.1 add CRLF and, on a UTF-8 console, a byte-order
# mark; .NET Framework's Process writes that mark too, from the console's
# input encoding, so that is set to ASCII just while ssh starts. ssh's
# stdout and stderr stay on the console. Returns ssh's exit code.
function Invoke-SshWithInput([string[]]$sshArgs, [string]$text) {
  if ($text -match '[^\x00-\x7F]') { Die "internal: non-ASCII input for ssh" }
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = (Get-Command ssh).Source
  $psi.Arguments = ($sshArgs | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' }) -join ' '
  $psi.UseShellExecute = $false
  $psi.RedirectStandardInput = $true
  $prev = $null
  try { $prev = [Console]::InputEncoding; [Console]::InputEncoding = [Text.Encoding]::ASCII } catch { $prev = $null }
  try { $p = [Diagnostics.Process]::Start($psi) }
  finally { if ($prev) { try { [Console]::InputEncoding = $prev } catch { } } }
  $bytes = [Text.Encoding]::ASCII.GetBytes($text + "`n")
  $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
  $p.StandardInput.Close()
  $p.WaitForExit()
  return $p.ExitCode
}

function Lock-KeyFile([string]$path) {
  # private key readable by this user only (Windows OpenSSH checks ACLs)
  icacls $path /inheritance:r 2>$null | Out-Null
  icacls $path /grant:r "$($env:USERNAME):F" 2>$null | Out-Null
}

# Point Host ai-sandbox-<agent> in ~\.ssh\config at the sandbox's current IP,
# fetching the sandbox key once. Rewrites only its own marked block (the
# same block vscode-connect.ps1 manages), then waits for ssh to answer.
function Update-SandboxEntry($s, [string]$agent) {
  $alias = "ai-sandbox-$agent"
  $ip = Get-PveOutput $s "ip $agent" | Select-Object -First 1
  if (-not $ip) { Die "the $agent sandbox is not running (no IP); run '.\ai-sandbox.ps1 up $agent' first" }
  if ($ip -notmatch '^[0-9A-Fa-f:.]+$') { Die "unexpected answer for the $agent IP: $ip" }
  New-Item -ItemType Directory -Force -Path $SshDir | Out-Null
  if (-not (Test-Path $SandboxKey)) {
    $key = (Get-PveOutput $s 'key') -join "`n"
    if ($key -notmatch 'PRIVATE KEY') { Die "the host did not return a private key" }
    [IO.File]::WriteAllText($SandboxKey, $key + "`n")
    Lock-KeyFile $SandboxKey
    Note "sandbox key saved once at $SandboxKey (permanent; rebuilds reuse it)"
  }
  $begin = "# BEGIN $alias (managed by ai-sandbox.ps1; do not edit between markers)"
  $end = "# END $alias"
  $block = @"
$begin
Host $alias
    HostName $ip
    User root
    IdentityFile ~/.ssh/ai-sandbox
    IdentitiesOnly yes
    # disposable sandbox: every rebuild mints a FRESH host key; scoped to this alias only
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
$end
"@
  $conf = ''
  if (Test-Path $SshConfig) { $conf = Get-Content -Raw $SshConfig }
  if ($null -eq $conf) { $conf = '' }
  # drop any managed block for this alias (either script's), and a legacy
  # unmarked 'Host <alias>' block from the manual export flow
  $conf = [regex]::Replace($conf, '(?s)# BEGIN ' + [regex]::Escape($alias) + ' \(managed by [^)]*\).*?# END ' + [regex]::Escape($alias) + '\r?\n?', '')
  $conf = [regex]::Replace($conf, '(?ms)^Host ' + [regex]::Escape($alias) + '[ \t]*\r?\n.*?(?=^(?:Host|Match)[ \t]|\z)', '')
  if ([string]::IsNullOrWhiteSpace($conf)) { $conf = $block } else { $conf = $conf.TrimEnd("`r", "`n") + "`r`n" + $block }
  Set-Content -Path $SshConfig -Value $conf -Encoding Ascii
  Note "ssh config: Host $alias -> $ip"
  foreach ($i in 1..15) {
    if (Test-SandboxSsh $alias) { return $alias }
    Start-Sleep -Seconds 2
  }
  Die "ssh $alias does not answer; check '.\ai-sandbox.ps1 status $agent'"
}

# rc 0 from "ssh <alias> true". Under $ErrorActionPreference = 'Stop',
# Windows PowerShell turns a redirected stderr line from a native command
# (even ssh's "Permanently added ... to known hosts") into a terminating
# error, so this probe runs with 'Continue' and ssh logs errors only.
function Test-SandboxSsh([string]$alias) {
  $ErrorActionPreference = 'Continue'
  ssh -o BatchMode=yes -o ConnectTimeout=5 -o LogLevel=ERROR $alias true 2>$null | Out-Null
  return ($LASTEXITCODE -eq 0)
}

function Open-Code($s, [string]$agent, [string]$folder) {
  if (-not (Get-Command code -ErrorAction SilentlyContinue)) {
    Die "'code' CLI not found; in VS Code: Command Palette > 'Shell Command: Install code command in PATH'"
  }
  $alias = Update-SandboxEntry $s $agent
  if (-not $folder.StartsWith('/')) { $folder = '/' + $folder }
  Note "opening VS Code in ssh-remote+$alias$folder ..."
  code --folder-uri "vscode-remote://ssh-remote+$alias$folder"
}

# Base64 of a text file with LF line endings: a Windows checkout may have
# CRLF, and base64 survives PowerShell's pipe encoding byte for byte.
function ConvertTo-LfBase64([string]$path) {
  $text = ([IO.File]::ReadAllText((Resolve-Path $path))) -replace "`r`n", "`n"
  return [Convert]::ToBase64String((New-Object Text.UTF8Encoding $false).GetBytes($text))
}

# ----------------------------------------------------------------------------
$s = Read-Settings
switch ($Command) {
  'init' {
    if (-not $s.PVE_HOST) { Die "usage: .\ai-sandbox.ps1 init -PveHost root@<proxmox address>" }
    if ($s.PVE_HOST -notmatch '^[A-Za-z0-9._-]+@[A-Za-z0-9.:_-]+$') { Die "PVE_HOST must look like root@192.168.3.188" }
    if ($s.PVE_DIR -notmatch '^/[A-Za-z0-9._/-]*$') { Die "PVE_DIR must be an absolute path like /root" }
    if ($PveScript -and $PveScript -notmatch '^/[A-Za-z0-9._/-]+$') { Die "-PveScript must be an absolute path on the host, like /root/AI-sandbox/ai-sandbox.sh" }
    foreach ($tool in 'ssh', 'ssh-keygen') {
      if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { Die "$tool not found; Settings > Apps > Optional Features > OpenSSH Client" }
    }
    $remote = Join-Path $PSScriptRoot 'ai-sandbox-remote.sh'
    $main = Join-Path $PSScriptRoot 'ai-sandbox.sh'
    if (-not (Test-Path $remote) -or -not (Test-Path $main)) { Die "run this from a checkout of the repo (ai-sandbox-remote.sh and ai-sandbox.sh beside it)" }
    New-Item -ItemType Directory -Force -Path $SshDir | Out-Null
    if (-not (Test-Path $s.PVE_KEY)) {
      Note "creating the desktop key $($s.PVE_KEY) (a passphrase is recommended)"
      ssh-keygen -t ed25519 -f $s.PVE_KEY -C 'ai-sandbox-remote'
      if ($LASTEXITCODE -ne 0) { Die "ssh-keygen failed" }
    }
    $pub = (Get-Content "$($s.PVE_KEY).pub" | Select-Object -First 1)
    if ($pub -notmatch '^[a-z0-9@.-]+ [A-Za-z0-9+/]+=* ?[A-Za-z0-9@._-]*$') { Die "unexpected public key format in $($s.PVE_KEY).pub" }
    # One login does it all: a script on stdin carries both files (base64)
    # and the public key. It installs the dispatcher, points it at the
    # ai-sandbox.sh the host already runs (-PveScript, an existing copy, the
    # GUI hooks' script or a git clone; a fresh copy only when there is
    # none), and pins the key to the dispatcher.
    $d = $s.PVE_DIR
    $nl = "`n"
    $setup = @(
      'set -euo pipefail',
      "d='$d'",
      't="$(mktemp -d)"; trap ''rm -rf "$t"'' EXIT',
      'base64 -d > "$t/remote" <<''B64''', (ConvertTo-LfBase64 $remote), 'B64',
      'base64 -d > "$t/main" <<''B64''', (ConvertTo-LfBase64 $main), 'B64',
      'install -m 755 "$t/remote" "$d/ai-sandbox-remote.sh"',
      "`"`$d/ai-sandbox-remote.sh`" install-script `"`$t/main`" '$PveScript'",
      "printf '%s\n' '$pub' | `"`$d/ai-sandbox-remote.sh`" install-key",
      '# end'
    ) -join $nl
    Note "setting up $($s.PVE_HOST) with your normal login (this once only)"
    $rc = Invoke-SshWithInput @($s.PVE_HOST, 'bash -s') $setup
    if ($rc -ne 0) { Die "host setup failed (output above)" }
    Save-Settings $s
    Note "settings saved to $CfgFile; checking the restricted key ..."
    $a = PveArgs $s
    & ssh @a agents
    if ($LASTEXITCODE -ne 0) { Die "the restricted key does not work yet (output above)" }
    Note "ready. Next: .\ai-sandbox.ps1 secret <agent>, then .\ai-sandbox.ps1 up <agent> -Code"
  }
  'agents' {
    Assert-Ready $s
    $a = PveArgs $s
    & ssh @a agents
    exit $LASTEXITCODE
  }
  'status' {
    Assert-Ready $s
    $verb = 'status'
    if ($Target) { Assert-Agent $Target; $verb = "status $Target" }
    $a = PveArgs $s
    & ssh @a $verb
    exit $LASTEXITCODE
  }
  { $_ -in 'up', 'down', 'reset' } {
    Assert-Ready $s; Assert-Agent $Target
    $a = PveArgs $s -Tty
    & ssh @a "$Command $Target"
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    if ($Code -and $Command -ne 'down') { Open-Code $s $Target $Folder }
  }
  'secret' {
    Assert-Ready $s; Assert-Agent $Target
    $var = $Name
    if (-not $var) { $var = $SecretNames[$Target] }
    if (-not $var) { Die "no default secret name for '$Target'; pass -Name VAR_NAME" }
    if ($var -cnotmatch '^[A-Z][A-Z0-9_]{0,63}$') { Die "invalid -Name '$var'" }
    if ($FromClipboard) {
      $plain = Get-Clipboard -Raw
    } else {
      Note "paste the key and press Enter; nothing is shown. In the classic PowerShell window, paste with a right-click (Ctrl+V may not paste into a hidden prompt)."
      $sec = Read-Host -AsSecureString "$var for $Target"
      $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
      try { $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
      finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
    }
    if ($plain) { $plain = $plain.Trim() }
    if (-not $plain) { Die "nothing entered; nothing changed" }
    # the host's rule, checked here too so a failed paste gets a useful message
    if ($plain -cnotmatch '^[A-Za-z0-9_.:/+=@-]+$' -or $plain.Length -lt 8) {
      $n = $plain.Length
      $plain = $null
      Die ("that is not a key ($n character(s), or characters a key never contains); nothing changed.`n" +
        "  The paste probably did not go through. Paste with a right-click, or copy the key and run:`n" +
        "  .\ai-sandbox.ps1 secret $Target -FromClipboard")
    }
    # stdin, never argv: the value stays out of process lists and logs
    $a = PveArgs $s
    $rc = Invoke-SshWithInput ($a + @("secret $Target $var")) $plain
    $plain = $null
    exit $rc
  }
  'profile' {
    Assert-Ready $s
    if (-not $Target -or -not (Test-Path $Target)) { Die "usage: .\ai-sandbox.ps1 profile <path\to\agent.sh>" }
    $agent = [IO.Path]::GetFileNameWithoutExtension($Target)
    Assert-Agent $agent
    $a = PveArgs $s
    exit (Invoke-SshWithInput ($a + @("profile $agent")) (ConvertTo-LfBase64 $Target))
  }
  'connect' {
    Assert-Ready $s; Assert-Agent $Target
    Open-Code $s $Target $Folder
  }
  'ssh' {
    Assert-Ready $s; Assert-Agent $Target
    $alias = Update-SandboxEntry $s $Target
    ssh $alias
    exit $LASTEXITCODE
  }
  default {
    foreach ($line in Get-Content $PSCommandPath) {
      if ($line -notmatch '^#') { break }
      $line -replace '^# ?', ''
    }
    if ($Command -ne 'help') { exit 1 }
  }
}
