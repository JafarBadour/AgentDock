# AgentPlantation - This PC (Windows) setup
#
# Installs what local agents on This PC need: Python (runs ADSM), Node.js,
# and the ACP adapter(s). AgentPlantation installs and starts ADSM itself from the
# app on first connect.
#
#   irm https://raw.githubusercontent.com/JafarBadour/AgentDock/main/scripts/windows-setup.ps1 | iex
#
# Adapters: Claude by default. Pick others with AGENTDOCK_AGENTS, e.g.
#   $env:AGENTDOCK_AGENTS = "claude,codex"; irm ... | iex
#
# Idempotent: safe to re-run. Uses winget (Windows 10 1809+ / Windows 11);
# installers may show an administrator prompt.

$ErrorActionPreference = 'Stop'

function Say($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Ok($msg) { Write-Host "    ok  $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "    !   $msg" -ForegroundColor Yellow }

function Have($cmd) { [bool](Get-Command $cmd -ErrorAction SilentlyContinue) }

# winget installs update the machine/user PATH, not this session's.
function Refresh-Path {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$machine;$user"
}

function Winget-Install($id) {
    if (-not (Have winget)) {
        throw "winget is not available. Install '$id' manually, then re-run."
    }
    winget install --id $id -e --silent --accept-source-agreements --accept-package-agreements
    # -1978335189: already installed / no applicable upgrade.
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335189) {
        throw "winget install $id failed (exit $LASTEXITCODE)"
    }
    Refresh-Path
}

function Python-Ok {
    foreach ($py in @('python', 'py')) {
        if (-not (Have $py)) { continue }
        # The Microsoft Store stub named python.exe opens the Store instead.
        $out = & $py -c "import sys; print(sys.version_info >= (3, 9))" 2>$null
        if ($LASTEXITCODE -eq 0 -and "$out".Trim() -eq 'True') { return $true }
    }
    return $false
}

$agents = if ($env:AGENTDOCK_AGENTS) { $env:AGENTDOCK_AGENTS } else { 'claude' }
$agents = $agents.ToLower().Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }

Say "AgentPlantation - This PC setup ($($agents -join ', '))"

# --- Python (ADSM) ------------------------------------------------------------
Say "Python 3.9+ (runs ADSM)"
if (Python-Ok) {
    Ok (& python --version 2>$null)
} else {
    Winget-Install 'Python.Python.3.12'
    if (-not (Python-Ok)) { throw "Python still not found on PATH; open a new terminal and re-run." }
    Ok "Python installed"
}

# --- Node.js ------------------------------------------------------------------
Say "Node.js + npm"
if ((Have node) -and (Have npm)) {
    Ok "node $(node --version) / npm $(npm --version)"
} else {
    Winget-Install 'OpenJS.NodeJS.LTS'
    if (-not (Have npm)) { throw "npm still not found on PATH; open a new terminal and re-run." }
    Ok "node $(node --version) / npm $(npm --version)"
}

# --- Adapters -----------------------------------------------------------------
if ($agents -contains 'claude') {
    Say "Claude Code CLI"
    if (Have claude) {
        Ok "already installed: $((Get-Command claude).Source)"
    } else {
        Invoke-RestMethod https://claude.ai/install.ps1 | Invoke-Expression
        Refresh-Path
        $env:Path = "$env:USERPROFILE\.local\bin;$env:Path"
        if (Have claude) { Ok "claude installed" } else { Warn "claude not on PATH yet; open a new terminal" }
    }

    Say "Claude ACP adapter (@agentclientprotocol/claude-agent-acp)"
    npm install -g @agentclientprotocol/claude-agent-acp
    if ($LASTEXITCODE -ne 0) { throw "npm install -g @agentclientprotocol/claude-agent-acp failed" }
    Ok "adapter installed"
}

if ($agents -contains 'codex') {
    Say "Codex ACP adapter (@agentclientprotocol/codex-acp, bundles the Codex CLI)"
    npm install -g @agentclientprotocol/codex-acp
    if ($LASTEXITCODE -ne 0) { throw "npm install -g @agentclientprotocol/codex-acp failed" }
    Ok "adapter installed"
}

if ($agents -contains 'cursor') {
    Warn "Cursor agents on This PC are not supported on Windows yet - skipped."
}

Say "Done"
Write-Host @"

Next - sign in (pick ONE per agent):
  Claude:  run  claude  in a terminal and log in, or save an Anthropic API key
           in AgentPlantation -> Settings
  Codex:   save an OpenAI API key in AgentPlantation -> Settings

Then restart AgentPlantation, create an agent on This PC and send a message.
ADSM is installed and started by the app on first connect.
"@
