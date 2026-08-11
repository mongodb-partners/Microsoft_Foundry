<#
.SYNOPSIS
    Tear down the Azure resources created by azure/deploy.ps1 for the simple-rag-movies sample.

.DESCRIPTION
    Deletes the resource group and everything in it (Azure AI Foundry account + project + agent,
    the embedding/vector-search Function, the MongoDB MCP Container App + its managed environment,
    storage), then purges the soft-deleted Foundry account so its globally-unique name frees up
    immediately for a re-deploy.

    Deleting a resource group only SOFT-deletes a Cognitive Services account. The name stays
    reserved for the retention period (about 48 hours) and the next same-name deploy fails with
    FlagMustBeSetForRestore. Purging is therefore the default, not an opt-in.

    Does NOT touch your MongoDB Atlas cluster - that lives outside Azure.

.PARAMETER ResourceGroup
    The resource group to delete. If omitted, it is read from deploy/config.json, else prompted.

.PARAMETER NoPurge
    Leave the Foundry account(s) soft-deleted instead of purging them. Their names stay reserved
    until the retention period expires, and a same-name re-deploy will fail until then. Only use
    this if you might want to restore the account.

.PARAMETER Yes
    Skip the interactive confirmation.

.EXAMPLE
    ./scripts/azure/teardown.ps1 -ResourceGroup rag-movies-rg

.EXAMPLE
    ./scripts/azure/teardown.ps1            # reads resourceGroup from deploy/config.json, prompts to confirm
#>
[CmdletBinding()]
param(
    [string]$ResourceGroup,
    [switch]$NoPurge,
    [switch]$Yes
)
$ErrorActionPreference = 'Stop'
function Fail($m) { Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }
function Info($m) { Write-Host "  $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "  $m" -ForegroundColor Green }

$SampleDir = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)   # scripts/azure -> scripts -> sample root

# Resolve the resource group: -ResourceGroup > deploy/config.json > prompt.
if (-not $ResourceGroup) {
    $cfgPath = Join-Path $SampleDir 'deploy/config.json'
    if (Test-Path $cfgPath) {
        try { $ResourceGroup = (Get-Content $cfgPath -Raw | ConvertFrom-Json).resourceGroup } catch {}
    }
}
if (-not $ResourceGroup) { $ResourceGroup = Read-Host "Resource group to DELETE" }
if ([string]::IsNullOrWhiteSpace($ResourceGroup)) { Fail "No resource group specified." }

$sub = az account show --query name -o tsv
if ((az group exists --name $ResourceGroup -o tsv) -ne 'true') {
    Fail "Resource group '$ResourceGroup' not found in the current subscription ('$sub'). Run 'az account set --subscription <id>' if it's elsewhere."
}

Write-Host "`nSubscription : $sub" -ForegroundColor Yellow
Write-Host "Resource group to DELETE (and everything in it): $ResourceGroup" -ForegroundColor Yellow
az resource list --resource-group $ResourceGroup --query "sort_by([].{name:name, type:type}, &type)" -o table

# Capture Cognitive Services (Foundry) accounts BEFORE deletion so we can purge them afterward.
$cogAccts = @()
try { $cogAccts = @(az cognitiveservices account list --resource-group $ResourceGroup --query "[].{name:name, location:location}" -o json | ConvertFrom-Json) } catch {}

if (-not $Yes) {
    Write-Host "`nThis is IRREVERSIBLE. Your MongoDB Atlas cluster is NOT affected." -ForegroundColor Yellow
    $ans = Read-Host "Type the resource group name to confirm"
    if ($ans -ne $ResourceGroup) { Fail "Confirmation '$ans' did not match '$ResourceGroup'. Aborted." }
}

Info "Deleting resource group '$ResourceGroup' (this can take a few minutes) ..."
az group delete --name $ResourceGroup --yes
if ($LASTEXITCODE -ne 0) { Fail "Resource group delete failed (see error above)." }
Ok "Resource group deleted."

if ($cogAccts.Count -gt 0 -and -not $NoPurge) {
    # NOTE: no 2>$null here. Silencing this is how a failed purge (wrong subscription, missing
    # permission) passes as success and the next deploy dies on FlagMustBeSetForRestore.
    foreach ($a in $cogAccts) {
        Info "Purging soft-deleted AI account '$($a.name)' in '$($a.location)' ..."
        az cognitiveservices account purge --name $a.name --location $a.location --resource-group $ResourceGroup -o none
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  WARNING: purge FAILED for '$($a.name)'. Its name stays reserved and the next deploy will fail." -ForegroundColor Yellow
            Write-Host "           Retry with: az cognitiveservices account purge --name $($a.name) --location $($a.location) --resource-group $ResourceGroup" -ForegroundColor DarkGray
        }
    }
    # Confirm rather than assume: list-deleted is the only source of truth.
    $stillDeleted = @()
    try { $stillDeleted = @(az cognitiveservices account list-deleted --query "[].name" -o json 2>$null | ConvertFrom-Json) } catch {}
    $blocking = @($cogAccts.name | Where-Object { $stillDeleted -contains $_ })
    if ($blocking.Count -gt 0) {
        Write-Host "  WARNING: still soft-deleted: $($blocking -join ', ')" -ForegroundColor Yellow
    } else {
        Ok "Soft-deleted AI account(s) purged; names are free to reuse."
    }
} elseif ($cogAccts.Count -gt 0) {
    Write-Host "  NOTE: -NoPurge was set, so $($cogAccts.name -join ', ') stay SOFT-DELETED." -ForegroundColor DarkGray
    Write-Host "        Their names stay reserved and a same-name re-deploy will fail until they expire." -ForegroundColor DarkGray
}

Write-Host "`nDone. MongoDB Atlas was left untouched (it lives outside Azure)." -ForegroundColor Green
