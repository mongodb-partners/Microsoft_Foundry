<#
.SYNOPSIS
    One command to remove EVERYTHING this sample created, on both Azure and MongoDB Atlas.

.DESCRIPTION
    The teardown counterpart to setup-and-deploy.ps1. It runs the two teardown scripts in order:
      1. scripts/azure/teardown.ps1  deletes the Azure resource group (Foundry account + project +
         agent, the Function, the MongoDB MCP Container App, storage)
      2. scripts/atlas/teardown.ps1  deletes the Atlas project created for this run, and with it the
         cluster, databases, database users, and network access entries

    Azure goes first so nothing is still connecting to the cluster when it is removed.

    Each script keeps its own safety checks: Azure asks you to type the resource group name, Atlas
    only offers projects tagged 'createdBy=simple-rag-movies' and asks you to type the project name.
    Your Atlas ORGANIZATION and your Azure SUBSCRIPTION are never touched.

    The two sides are independent, so if one fails the other still runs and the failure is reported
    at the end.

.PARAMETER ResourceGroup
    Azure resource group to delete. If omitted, read from deploy/config.json, else prompted.

.PARAMETER NoPurge
    Leave the Foundry account soft-deleted instead of purging it. Its globally-unique name stays
    reserved and a same-name re-deploy will fail until the retention period expires.

.PARAMETER OrgId
    Atlas organization id. If omitted, auto-selected when you have one org, else you pick interactively.

.PARAMETER ProjectName
    Atlas project to delete. If omitted, you pick from the tagged projects. Required with -Yes.

.PARAMETER IncludeUntagged
    Let the Atlas step consider projects without the sample's tag. Use with care.

.PARAMETER Yes
    Skip the typed confirmations on both sides. Requires -ProjectName so there is no ambiguity.

.PARAMETER SkipAzure
    Only tear down MongoDB Atlas.

.PARAMETER SkipAtlas
    Only tear down Azure.

.EXAMPLE
    ./scripts/teardown-all.ps1
.EXAMPLE
    ./scripts/teardown-all.ps1 -ResourceGroup rag-movies-rg -ProjectName rag-movies-a1b2c3 -Yes
#>
[CmdletBinding()]
param(
    [string]$ResourceGroup,
    [switch]$NoPurge,
    [string]$OrgId,
    [string]$ProjectName,
    [switch]$IncludeUntagged,
    [switch]$Yes,
    [switch]$SkipAzure,
    [switch]$SkipAtlas
)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot

function Step($m) {
    Write-Host "`n============================================================" -ForegroundColor Magenta
    Write-Host " $m" -ForegroundColor Magenta
    Write-Host "============================================================" -ForegroundColor Magenta
}

if ($SkipAzure -and $SkipAtlas) { Write-Host "Both sides skipped; nothing to do." -ForegroundColor Yellow; exit 0 }

# Validate BEFORE destroying anything: -Yes means the Atlas step runs unattended, and that step
# refuses to guess which project to delete. Catching it here avoids removing Azure and then stopping.
if ($Yes -and -not $SkipAtlas -and -not $ProjectName) {
    Write-Host "ERROR: -Yes requires -ProjectName so the Atlas step knows exactly which project to delete." -ForegroundColor Red
    Write-Host "       Pass -ProjectName <name>, or add -SkipAtlas, or drop -Yes to confirm interactively." -ForegroundColor Red
    exit 1
}

Write-Host "`nThis removes the Azure resources AND the MongoDB Atlas project created by this sample." -ForegroundColor Yellow
Write-Host "It is permanent. Each step will show what it is about to delete and ask you to confirm." -ForegroundColor Yellow

$failed = @()

if (-not $SkipAzure) {
    Step "STEP 1 of 2  -  Azure"
    $azArgs = @{}
    if ($ResourceGroup) { $azArgs['ResourceGroup'] = $ResourceGroup }
    if ($NoPurge) { $azArgs['NoPurge'] = $true }
    if ($Yes) { $azArgs['Yes'] = $true }
    & "$here/azure/teardown.ps1" @azArgs
    if ($LASTEXITCODE -ne 0) {
        $failed += 'Azure'
        Write-Host "`nAzure teardown did not complete (see above). Continuing with Atlas." -ForegroundColor Yellow
    }
}

if (-not $SkipAtlas) {
    Step "STEP 2 of 2  -  MongoDB Atlas"
    $atlasArgs = @{}
    if ($OrgId) { $atlasArgs['OrgId'] = $OrgId }
    if ($ProjectName) { $atlasArgs['ProjectName'] = $ProjectName }
    if ($IncludeUntagged) { $atlasArgs['IncludeUntagged'] = $true }
    if ($Yes) { $atlasArgs['Yes'] = $true }
    & "$here/atlas/teardown.ps1" @atlasArgs
    if ($LASTEXITCODE -ne 0) { $failed += 'Atlas' }
}

if ($failed.Count -gt 0) {
    Step "Finished with errors"
    Write-Host " These did not complete: $($failed -join ', ')" -ForegroundColor Red
    Write-Host " Re-run this script, or run the individual teardown script for whichever side failed." -ForegroundColor Red
    exit 1
}

Step "All clean"
Write-Host " The Azure resources and the Atlas project created by this sample are gone." -ForegroundColor Green
Write-Host " Your Atlas organization and Azure subscription were not touched." -ForegroundColor Green
Write-Host " To build it again from scratch:  " -NoNewline; Write-Host "./scripts/setup-and-deploy.ps1" -ForegroundColor White
exit 0
