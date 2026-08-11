<#
.SYNOPSIS
    Delete the MongoDB Atlas resources created by atlas/setup.ps1 (a project and everything inside it).

.DESCRIPTION
    atlas/setup.ps1 creates a FRESH project per run and tags it 'createdBy=simple-rag-movies'. This
    script only offers projects carrying that tag, so it cannot wander into a project you created for
    something else. Deleting the project removes everything inside it in one step: the cluster, the
    databases, the database users, and the network access entries.

    Three layers of safety, because this is destructive and irreversible:
      1. Provenance  - only tagged projects are listed (override with -IncludeUntagged).
      2. Visibility  - it prints the clusters and database users it is about to destroy.
      3. Confirmation- you must type the project name exactly (skip with -Yes for automation).

    Your Atlas ORGANIZATION is never touched, and neither is anything in Azure. For the Azure side
    use ./scripts/azure/teardown.ps1.

.PARAMETER OrgId
    Atlas organization id. If omitted, auto-selected when you have one org, else you pick interactively.

.PARAMETER ProjectName
    Name of the project to delete. If omitted, you pick from the tagged projects in the org.

.PARAMETER IncludeUntagged
    Also consider projects WITHOUT the 'createdBy=simple-rag-movies' tag (for example projects created
    before tagging existed). Use with care: provenance can no longer be proven.

.PARAMETER Yes
    Skip the typed confirmation. Intended for automation.

.EXAMPLE
    ./scripts/atlas/teardown.ps1
.EXAMPLE
    ./scripts/atlas/teardown.ps1 -ProjectName rag-movies-a1b2c3 -Yes
#>
[CmdletBinding()]
param(
    [string]$OrgId,
    [string]$ProjectName,
    [switch]$IncludeUntagged,
    [switch]$Yes
)
$ErrorActionPreference = 'Stop'

$TagKey = 'createdBy'
$TagValue = 'simple-rag-movies'

function Write-Phase($n, $t) { Write-Host "`n[$n] $t" -ForegroundColor Cyan }
function Info($m) { Write-Host "    $m" -ForegroundColor Gray }
function Ok($m)   { Write-Host "    $m" -ForegroundColor Green }
function Warn($m) { Write-Host "    $m" -ForegroundColor Yellow }
function Fail($m) { Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }
function Results($json) { if ($null -eq $json) { @() } elseif ($json.PSObject.Properties.Name -contains 'results') { @($json.results) } else { @($json) } }

# True when the project carries our provenance tag. Handles both shapes Atlas has used for tags:
# an array of {key,value} objects, or a plain object/dictionary of key -> value.
function Test-SampleTag($proj) {
    if (-not $proj.tags) { return $false }
    foreach ($t in @($proj.tags)) {
        if ($t.key -eq $TagKey -and $t.value -eq $TagValue) { return $true }
        if (($t.PSObject.Properties.Name -contains $TagKey) -and $t.$TagKey -eq $TagValue) { return $true }
    }
    return $false
}

# Windows only: on Linux/mac the 'Machine'/'User' targets return null, which would blank out PATH.
if ($IsWindows) {
    $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path', 'User')
}

# Suppress the Atlas CLI "a new version is available" banner. Session-scoped.
$env:MONGODB_ATLAS_SKIP_UPDATE_CHECK = 'true'

# ----- 0. Atlas CLI present + logged in -------------------------------------
Write-Phase 0 "Atlas CLI"
if (-not (Get-Command atlas -ErrorAction SilentlyContinue)) {
    Fail "Atlas CLI not found. Install it with:  winget install -e --id MongoDB.MongoDBAtlasCLI  (or see https://www.mongodb.com/docs/atlas/cli/current/install-atlas-cli/), then re-run."
}
# 'atlas auth whoami' returns 0 even when the session has EXPIRED, so probe with a real API call.
atlas organizations list -o json *> $null
if ($LASTEXITCODE -ne 0) {
    # Pre-set the output format so a first login does not interview the user about it.
    if (-not (atlas config describe default 2>$null | Select-String -Quiet '^output\s')) {
        atlas config set output plaintext *> $null
    }
    Info "Not logged in, or the Atlas CLI session expired. Launching 'atlas auth login' ..."
    atlas auth login
    if ($LASTEXITCODE -ne 0) { Fail "atlas auth login failed." }
}
Ok "$((atlas auth whoami 2>$null | Select-Object -First 1))"

# ----- 1. Organization ------------------------------------------------------
Write-Phase 1 "Atlas organization"
if (-not $OrgId) {
    $orgsJson = atlas organizations list --output json 2>$null
    if ($LASTEXITCODE -ne 0) { Fail "Could not list Atlas organizations (a common cause is an expired session: run 'atlas auth login')." }
    $orgs = Results ($orgsJson | ConvertFrom-Json)
    if (-not $orgs -or $orgs.Count -eq 0) { Fail "No Atlas organizations found for this login." }
    if ($orgs.Count -eq 1) { $OrgId = $orgs[0].id; Ok "Organization: $($orgs[0].name) ($OrgId)" }
    else {
        Write-Host "    Select an organization:" -ForegroundColor Yellow
        for ($i = 0; $i -lt $orgs.Count; $i++) { Write-Host ("      {0}. {1}  ({2})" -f ($i + 1), $orgs[$i].name, $orgs[$i].id) }
        $n = 0
        do { $sel = Read-Host "    Number" } until ([int]::TryParse($sel, [ref]$n) -and $n -ge 1 -and $n -le $orgs.Count)
        $OrgId = $orgs[$n - 1].id
        Ok "Organization: $($orgs[$n - 1].name) ($OrgId)"
    }
}
else { Ok "Organization: $OrgId" }

# ----- 2. Pick the project (tagged projects only, unless overridden) --------
Write-Phase 2 "Project to delete"
$projJson = atlas projects list --orgId $OrgId --output json 2>$null
if ($LASTEXITCODE -ne 0) { Fail "Could not list projects in this organization." }
$allProjects = Results ($projJson | ConvertFrom-Json)
if (-not $allProjects -or $allProjects.Count -eq 0) { Fail "This organization has no projects." }

$tagged = @($allProjects | Where-Object { Test-SampleTag $_ })
$candidates = if ($IncludeUntagged) { @($allProjects) } else { $tagged }

if (-not $IncludeUntagged -and $candidates.Count -eq 0) {
    Warn "No projects in this organization carry the '$TagKey=$TagValue' tag."
    Warn "Projects created before tagging existed will not be listed. Re-run with -IncludeUntagged to see all"
    Warn "projects, but then double-check the name: provenance cannot be proven."
    Fail "Nothing safe to delete."
}

if ($ProjectName) {
    $match = @($candidates | Where-Object { $_.name -eq $ProjectName })
    if (-not $match) {
        $where = if ($IncludeUntagged) { "this organization" } else { "the tagged projects (use -IncludeUntagged to widen the search)" }
        Fail "Project '$ProjectName' was not found among $where."
    }
    $project = $match[0]
}
elseif ($Yes) { Fail "Pass -ProjectName together with -Yes so there is no ambiguity about what gets deleted." }
else {
    Write-Host "    Select the project to DELETE:" -ForegroundColor Yellow
    for ($i = 0; $i -lt $candidates.Count; $i++) {
        $mark = if (Test-SampleTag $candidates[$i]) { "" } else { "  [not tagged by this sample]" }
        Write-Host ("      {0}. {1}  ({2}){3}" -f ($i + 1), $candidates[$i].name, $candidates[$i].id, $mark)
    }
    $n = 0
    do { $sel = Read-Host "    Number" } until ([int]::TryParse($sel, [ref]$n) -and $n -ge 1 -and $n -le $candidates.Count)
    $project = $candidates[$n - 1]
}
$ProjectName = $project.name
$ProjectId = $project.id
Ok "Selected: $ProjectName ($ProjectId)"
if (-not (Test-SampleTag $project)) { Warn "This project is NOT tagged '$TagKey=$TagValue', so it was probably not created by this sample. Be certain before continuing." }

# ----- 3. Show exactly what will be destroyed -------------------------------
Write-Phase 3 "Contents to be destroyed"
$clusters = Results (atlas clusters list --projectId $ProjectId --output json 2>$null | ConvertFrom-Json)
$dbUsers  = Results (atlas dbusers list --projectId $ProjectId --output json 2>$null | ConvertFrom-Json)
if ($clusters.Count -gt 0) { $clusters | ForEach-Object { Info "cluster       : $($_.name)" } } else { Info "cluster       : (none)" }
if ($dbUsers.Count -gt 0)  { $dbUsers  | ForEach-Object { Info "database user : $($_.username)" } } else { Info "database user : (none)" }
Info "project       : $ProjectName  (and its network access entries)"

# ----- 4. Confirm -----------------------------------------------------------
Write-Phase 4 "Confirm"
if (-not $Yes) {
    Write-Host "    This is PERMANENT. All data in the cluster above will be lost." -ForegroundColor Yellow
    $typed = Read-Host "    Type the project name '$ProjectName' to confirm"
    if ($typed -ne $ProjectName) { Fail "Names do not match. Nothing was deleted." }
}

# ----- 5. Delete clusters, then the project ---------------------------------
# Atlas will not delete a project that still contains clusters, so clusters go first.
Write-Phase 5 "Deleting"
foreach ($c in $clusters) {
    Info "Deleting cluster '$($c.name)' (this takes a few minutes) ..."
    # The CLI's --watch spinner garbles itself when captured, so keep its output and show it only on failure.
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = atlas clusters delete $c.name --projectId $ProjectId --force --watch 2>&1
    $rc = $LASTEXITCODE
    $ErrorActionPreference = $prevEap
    if ($rc -ne 0) {
        $out | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray }
        Fail "Could not delete cluster '$($c.name)'. Nothing else was removed; re-run once it is gone."
    }
    Ok "Cluster '$($c.name)' deleted."
}

# The project can stay briefly locked right after a cluster delete, so retry a few times.
$deleted = $false
for ($attempt = 1; $attempt -le 5 -and -not $deleted; $attempt++) {
    atlas projects delete $ProjectId --force *> $null
    if ($LASTEXITCODE -eq 0) { $deleted = $true; break }
    Info "Project not deletable yet (attempt $attempt); waiting ..."
    Start-Sleep -Seconds 10
}
if (-not $deleted) {
    atlas projects delete $ProjectId --force   # show the real error on the final try
    Fail "Could not delete project '$ProjectName'. Check for remaining resources in Atlas, then re-run."
}
Ok "Project '$ProjectName' deleted."

# The connection string in this session points at a cluster that no longer exists.
if ($env:MDB_MCP_CONNECTION_STRING) {
    $env:MDB_MCP_CONNECTION_STRING = ''
    Info "Cleared MDB_MCP_CONNECTION_STRING for this session (the cluster it referenced is gone)."
}

Write-Host "`n============================================================" -ForegroundColor Cyan
Write-Host " Atlas cleanup complete." -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Your organization was not touched."
Write-Host "  Azure resources are separate: " -NoNewline; Write-Host "./scripts/azure/teardown.ps1" -ForegroundColor White
exit 0
