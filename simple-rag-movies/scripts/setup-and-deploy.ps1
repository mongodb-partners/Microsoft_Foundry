<#
.SYNOPSIS
    One command to set up MongoDB Atlas AND deploy the Azure side + Foundry agent.

.DESCRIPTION
    Runs the two sample scripts in order, IN A SINGLE PowerShell process:
      1. scripts/atlas/setup.ps1   provisions Atlas and sets $env:MDB_MCP_CONNECTION_STRING
      2. scripts/azure/deploy.ps1  reads that env var and provisions Azure + the agent

    Because both run in the same process, the connection string set by step 1 is already in the
    environment when step 2 runs - there is no stdout capture, the secret is never printed, and the
    env var cannot be "lost" across a process boundary. This is the single file the Codespace runs.

    Child-script paths are resolved from this script's location, so you can run it from any directory.

.PARAMETER NonInteractive
    Pass through to both child scripts for unattended runs. Note each child still needs its own
    required parameters in that mode (Atlas: -OrgId when you belong to more than one org; Azure: config.json),
    so for fully-scripted CI it is usually clearer to call the two scripts directly.

.PARAMETER SkipAtlas
    Skip Atlas setup and go straight to the Azure deploy. Use only when MDB_MCP_CONNECTION_STRING
    is already set in the current session.

.EXAMPLE
    ./scripts/setup-and-deploy.ps1
.EXAMPLE
    ./scripts/setup-and-deploy.ps1 -SkipAtlas        # Atlas already done in this session
#>
[CmdletBinding()]
param(
    [switch]$NonInteractive,
    [switch]$SkipAtlas
)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot

function Step($m) {
    Write-Host "`n============================================================" -ForegroundColor Magenta
    Write-Host " $m" -ForegroundColor Magenta
    Write-Host "============================================================" -ForegroundColor Magenta
}

# Forward -NonInteractive to the child scripts if it was set.
$pass = @{}
if ($NonInteractive) { $pass['NonInteractive'] = $true }

if (-not $SkipAtlas) {
    # Clear any stale value so the check below only passes if THIS run sets it.
    $env:MDB_MCP_CONNECTION_STRING = ''
    Step "STEP 1 of 2  -  MongoDB Atlas setup"
    & "$here/atlas/setup.ps1" @pass
}

# The connection string is the contract between the two scripts. If it is not set, atlas-setup did
# not finish, so there is nothing to deploy against.
if ([string]::IsNullOrWhiteSpace($env:MDB_MCP_CONNECTION_STRING)) {
    Write-Host "`nMDB_MCP_CONNECTION_STRING is not set after Atlas setup, so the Azure deploy cannot continue." -ForegroundColor Red
    Write-Host "Re-run Atlas setup (drop -SkipAtlas), or set the variable yourself, then retry." -ForegroundColor Red
    exit 1
}

Step "STEP 2 of 2  -  Azure deploy + Foundry agent"
& "$here/azure/deploy.ps1" @pass
if ($LASTEXITCODE -ne 0) {
    Write-Host "`nAzure deploy did not complete cleanly (see the output above)." -ForegroundColor Red
    exit 1
}

Step "All done"
Write-Host " MongoDB Atlas, the Azure resources, and the Foundry agent are all set up." -ForegroundColor Green
Write-Host " Follow the numbered steps printed just above to open the agent and try it." -ForegroundColor Green
exit 0
