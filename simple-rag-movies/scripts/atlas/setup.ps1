<#
.SYNOPSIS
    Automate the MongoDB Atlas setup for the simple-rag-movies sample using the Atlas CLI.

.DESCRIPTION
    Turns the manual "MongoDB Atlas Setup" section of the README into one command. With the 'atlas'
    CLI logged in, this script does the whole thing:
      1. Ensures the Atlas CLI is installed and you are logged in (browser SSO via 'atlas auth login').
      2. Selects the Atlas organization to use (auto-picks if you have one, otherwise asks).
      3. Creates a NEW Atlas project (auto-named 'rag-movies-<suffix>').
      4. Creates a NEW free M0 cluster in that project.
      5. Creates a NEW database user with a freshly generated password.
      6. Adds a network-access entry so Azure can reach the cluster.
      7. Loads ONLY the sample_mflix dataset via mongorestore (the CLI loader pulls the full ~380 MB set that overflows a free M0; sample_mflix alone is ~123 MB and has the vectors we search).
      8. Creates the vector_index on embedded_movies.plot_embedding (1536 dims, cosine).
      9. Sets MDB_MCP_CONNECTION_STRING for this session and verifies connect + query + vector search.

    CHOOSING THE ORGANIZATION IS THE ONLY QUESTION YOU ARE ASKED. Everything else is named for you and
    reported as it is created; pass the parameters below if you want to override a name.

    THE ORGANIZATION IS ALSO THE ONLY THING REUSED. This sample is a throwaway demo, so the project,
    cluster, database, and database user are always created fresh. That keeps the demo isolated from
    anything else in your org, and makes cleanup a single "delete this project" instead of hunting
    individual resources. It also means we never rotate the password of an existing database user,
    which would break whatever else was using it.

    When it finishes, the connection string is already set for your terminal - just run
    ./scripts/azure/deploy.ps1 next. The secret is never printed.

    One-time prerequisite that CANNOT be automated: a MongoDB Atlas account with at least one
    organization. Create it once at https://cloud.mongodb.com, then run this script.

    Tools used: the Atlas CLI and mongorestore (MongoDB Database Tools). mongorestore is auto-installed
    on Windows via winget and preinstalled in the dev container; on mac/Linux install it if asked.

.PARAMETER OrgId
    Atlas organization id (the ONLY resource that is reused). If omitted, auto-selected when you have
    one org, else you pick interactively.

.PARAMETER ProjectName
    Override the auto-generated project name. Defaults to a unique 'rag-movies-<suffix>' so repeat runs
    never collide. Fails if a project with this name already exists (it is never reused).

.PARAMETER ClusterName
    Override the name of the new free M0 cluster. Default: rag-movies.

.PARAMETER Region
    Atlas region for the new M0 cluster (Azure naming). Default: US_EAST_2 (Azure eastus2).

.PARAMETER DbUser
    Override the username of the new database user. Default: raguser.

.PARAMETER NetworkCidr
    Network access entry to add. Default: 0.0.0.0/0 (open, for testing).

.PARAMETER NonInteractive
    Never prompt at all. Pass -OrgId with it when you belong to more than one organization.

.EXAMPLE
    ./scripts/atlas/setup.ps1
.EXAMPLE
    ./scripts/atlas/setup.ps1 -ProjectName rag-movies-demo -ClusterName rag-movies
.EXAMPLE
    ./scripts/atlas/setup.ps1 -NonInteractive -OrgId <orgId>
#>
[CmdletBinding()]
param(
    [string]$OrgId,
    [string]$ProjectName,
    [string]$ClusterName = 'rag-movies',
    [string]$Region = 'US_EAST_2',
    [string]$DbUser = 'raguser',
    [string]$NetworkCidr = '0.0.0.0/0',
    [switch]$NonInteractive
)
$ErrorActionPreference = 'Stop'

# Everything below the org is created fresh, so default to a unique project name per run.
if (-not $ProjectName) {
    $ProjectName = 'rag-movies-' + (-join ((97..122) + (48..57) | Get-Random -Count 6 | ForEach-Object { [char]$_ }))
}

function Write-Phase($n, $t) { Write-Host "`n[$n] $t" -ForegroundColor Cyan }
function Info($m) { Write-Host "    $m" -ForegroundColor Gray }
function Ok($m)   { Write-Host "    $m" -ForegroundColor Green }
function Warn($m) { Write-Host "    $m" -ForegroundColor Yellow }
function Fail($m) { Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }
function Results($json) { if ($null -eq $json) { @() } elseif ($json.PSObject.Properties.Name -contains 'results') { @($json.results) } else { @($json) } }

# mongorestore's installer does NOT add its bin to PATH, so resolve it: check PATH first, else search the
# standard install locations and prepend the found bin to PATH for this session. Returns the path or $null.
function Resolve-MongoRestore {
    $cmd = Get-Command mongorestore -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($base in @("$env:ProgramFiles\MongoDB\Tools", "${env:ProgramFiles(x86)}\MongoDB\Tools")) {
        if ($base -and (Test-Path $base)) {
            $exe = Get-ChildItem $base -Recurse -Filter mongorestore.exe -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($exe) { $env:Path = (Split-Path $exe.FullName) + ';' + $env:Path; return $exe.FullName }
        }
    }
    return $null
}

# Show a numbered menu of items (each with .name and .id) plus a final "create new" option.
# Returns the chosen item, or $null to signal "create a new one".
function Select-OrCreate($items, $label, $createLabel) {
    Write-Host "    $label" -ForegroundColor Yellow
    for ($i = 0; $i -lt $items.Count; $i++) {
        Write-Host ("      {0}. {1}  ({2})" -f ($i + 1), $items[$i].name, $items[$i].id)
    }
    Write-Host ("      {0}. {1}" -f ($items.Count + 1), $createLabel) -ForegroundColor Cyan
    $n = 0
    do { $sel = Read-Host "    Number" } until ([int]::TryParse($sel, [ref]$n) -and $n -ge 1 -and $n -le ($items.Count + 1))
    if ($n -eq $items.Count + 1) { return $null }
    return $items[$n - 1]
}

# Make a winget/MSI install of the Atlas CLI visible in this session without a restart. Windows only:
# on Linux/mac the 'Machine'/'User' targets return null, which would blank out PATH.
if ($IsWindows) {
    $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path', 'User')
}

# Suppress the Atlas CLI "a new version is available" banner, which otherwise prints after every
# command. Session-scoped, so it does not touch the user's atlas config.
$env:MONGODB_ATLAS_SKIP_UPDATE_CHECK = 'true'

# ----- 0. Atlas CLI present + logged in -------------------------------------
Write-Phase 0 "Atlas CLI"
if (-not (Get-Command atlas -ErrorAction SilentlyContinue)) {
    Fail "Atlas CLI not found. Install it with:  winget install -e --id MongoDB.MongoDBAtlasCLI  (or see https://www.mongodb.com/docs/atlas/cli/current/install-atlas-cli/), then re-run."
}
Ok "atlas $((atlas --version 2>$null | Select-Object -First 1))"
# 'atlas auth whoami' returns 0 even when the session has EXPIRED, so probe with a real API call.
atlas organizations list -o json *> $null
if ($LASTEXITCODE -ne 0) {
    # On a first login the CLI also interviews you for a "Default Output Format". Pre-set it so the
    # user is not asked a question they have no reason to care about. Only when it is not already set.
    if (-not (atlas config describe default 2>$null | Select-String -Quiet '^output\s')) {
        atlas config set output plaintext *> $null
    }
    Info "Not logged in, or the Atlas CLI session expired. Launching 'atlas auth login' - approve the code in your browser (Microsoft/GitHub SSO works here) ..."
    atlas auth login
    if ($LASTEXITCODE -ne 0) { Fail "atlas auth login failed." }
    atlas organizations list -o json *> $null
    if ($LASTEXITCODE -ne 0) { Fail "Still cannot reach Atlas after logging in. Run 'atlas organizations list' to see the underlying error." }
}
Ok "$((atlas auth whoami 2>$null | Select-Object -First 1))"

# ----- 1. Organization (the only thing we reuse) ----------------------------
Write-Phase 1 "Atlas organization"
if (-not $OrgId) {
    # 'atlas auth login' runs its own first-run profile setup and already makes you pick a default
    # organization (and a default project, which is irrelevant here - this script always creates a
    # fresh one). There is no flag to skip that, so reuse the answer instead of asking twice.
    $profileOrg = (atlas config describe default 2>$null |
                   Select-String -Pattern '^\s*org_id\s+(\S+)' |
                   ForEach-Object { $_.Matches[0].Groups[1].Value } |
                   Select-Object -First 1)
    if ($profileOrg) {
        $OrgId = $profileOrg
        $orgName = (atlas organizations describe $OrgId --output json 2>$null | ConvertFrom-Json).name
        Ok "Organization: $(if ($orgName) { "$orgName ($OrgId)" } else { $OrgId })  [from your Atlas CLI profile]"
        Info "Pass -OrgId <id> to use a different one."
    }
}
if ($OrgId) {
    if (-not $orgName) { Ok "Organization: $OrgId" }
}
else {
    $orgsJson = atlas organizations list --output json 2>$null
    if ($LASTEXITCODE -ne 0) { Fail "Could not list Atlas organizations. Run 'atlas organizations list' to see the error (a common cause is an expired session: run 'atlas auth login')." }
    $orgs = Results ($orgsJson | ConvertFrom-Json)
    if (-not $orgs -or $orgs.Count -eq 0) { Fail "You are logged in but belong to NO Atlas organization. Create one at https://cloud.mongodb.com, then re-run." }
    if ($orgs.Count -eq 1) {
        $OrgId = $orgs[0].id
        Ok "Organization: $($orgs[0].name) ($OrgId)"
    }
    elseif ($NonInteractive) {
        Fail "You belong to multiple organizations; pass -OrgId in non-interactive mode. Available: $(($orgs | ForEach-Object { $_.name }) -join ', ')"
    }
    else {
        $org = Select-OrCreate $orgs "Select an organization:" "None of these (create one at cloud.mongodb.com first)"
        if (-not $org) { Fail "Create the organization at https://cloud.mongodb.com, then re-run and select it." }
        $OrgId = $org.id
        Ok "Organization: $($org.name) ($OrgId)"
    }
}

# That was the only question. Show what is about to be created so there are no surprises.
Write-Host "`n    Creating everything below fresh in that organization (no prompts from here on):" -ForegroundColor Yellow
Info "project        : $ProjectName"
Info "cluster        : $ClusterName   (free M0, AZURE / $Region)"
Info "database user  : $DbUser        (new password, generated)"
Info "network access : $NetworkCidr"
Info "data           : sample_mflix + the 'vector_index' vector index"
Info "Override any name by passing -ProjectName / -ClusterName / -DbUser / -NetworkCidr."

# ----- 2. Project: ALWAYS a fresh one ---------------------------------------
# Only the org is reused. A fresh project isolates the demo and makes cleanup one delete.
# The name is generated, not asked for: nothing is reused, so there is nothing for you to pick.
Write-Phase 2 "Atlas project '$ProjectName' (new)"
$projects = Results (atlas projects list --orgId $OrgId --output json 2>$null | ConvertFrom-Json)
if ($projects | Where-Object { $_.name -eq $ProjectName }) {
    Fail "A project named '$ProjectName' already exists in this organization. This sample always creates a FRESH project and never reuses one, so choose a different name (-ProjectName), or delete that project in Atlas first."
}
Info "Creating project '$ProjectName' ..."
# The createdBy tag is this project's provenance marker: atlas/teardown.ps1 will only delete projects
# carrying it, so teardown can never wander into a project you created for something else.
$new = atlas projects create $ProjectName --orgId $OrgId --tag createdBy=simple-rag-movies --output json 2>$null | ConvertFrom-Json
if (-not $new.id) { Fail "Could not create project '$ProjectName' (see error above; you need permission to create projects in this organization)." }
$ProjectId = $new.id
Ok "Created project '$ProjectName' ($ProjectId)."

# ----- 3. Cluster: ALWAYS a fresh free M0 in the new project ----------------
Write-Phase 3 "Cluster '$ClusterName' (new)"
Info "Creating free M0 cluster '$ClusterName' (AZURE / $Region). This takes several minutes ..."
atlas clusters create $ClusterName --projectId $ProjectId --provider AZURE --region $Region --tier M0 --watch
if ($LASTEXITCODE -ne 0) {
    Fail "Cluster create failed (see error above). If the region was rejected, pass a different -Region (Azure M0 regions: https://www.mongodb.com/docs/atlas/reference/microsoft-azure/). If you have hit the free-tier limit, delete an old demo project in Atlas and re-run."
}
Ok "Cluster '$ClusterName' created."

# ----- 4. Database user: ALWAYS a new one -----------------------------------
# Never reuse an existing user: we generate a new password each run, and rotating the password of a
# user something else depends on would break that consumer. A fresh project has no users anyway.
Write-Phase 4 "Database user '$DbUser' (new)"
Info "Creating '$DbUser' with the atlasAdmin role and a randomly generated 24-character password."
$dbPass = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 24 | ForEach-Object { [char]$_ })
atlas dbusers create atlasAdmin --username $DbUser --password $dbPass --projectId $ProjectId *> $null
if ($LASTEXITCODE -ne 0) { Fail "Database user create failed (see error above)." }
Ok "Database user '$DbUser' created with a freshly generated password."

# ----- 5. Network access ----------------------------------------------------
Write-Phase 5 "Network access ($NetworkCidr)"
Info "Adding $NetworkCidr to the project's access list so Azure can reach the cluster."
Info "Why the whole range: the Function and the MCP Container App have no fixed egress IP, so a"
Info "single address cannot be allowlisted reliably. Pass -NetworkCidr to narrow it."
atlas accessLists create $NetworkCidr --type cidrBlock --projectId $ProjectId --comment "simple-rag-movies (Azure egress)" *> $null
Ok "Network access entry present ($NetworkCidr)."
if ($NetworkCidr -eq '0.0.0.0/0') { Warn "0.0.0.0/0 is open to the internet - fine for testing; tighten it for real use." }

# ----- 6. Load ONLY sample_mflix --------------------------------------------
# The atlas CLI 'sampleData load' has NO per-dataset option: it loads the FULL sample set (~380 MB),
# which overflows a free M0 (512 MB). So we mongorestore just the sample_mflix archive (~123 MB), which
# includes embedded_movies (the vectors we search). This needs the connection string, built here and
# reused in phase 8.
Write-Phase 6 "Sample dataset (sample_mflix only)"
$csj = atlas clusters connectionStrings describe $ClusterName --projectId $ProjectId --output json 2>$null | ConvertFrom-Json
$srv = $csj.standardSrv
if (-not $srv) { Fail "Could not read the SRV connection string for '$ClusterName'." }
$full = ($srv -replace '^mongodb\+srv://', "mongodb+srv://$DbUser`:$dbPass@") + "/?retryWrites=true&w=majority&appName=simple-rag-movies"
$clusterHost = ($srv -replace '^mongodb\+srv://', '')

$mongorestore = Resolve-MongoRestore
if (-not $mongorestore) {
    if ($IsWindows -and (Get-Command winget -ErrorAction SilentlyContinue)) {
        Info "mongorestore not found; installing MongoDB Database Tools via winget ..."
        winget install -e --id MongoDB.DatabaseTools --accept-source-agreements --accept-package-agreements | Out-Null
        $mongorestore = Resolve-MongoRestore
    }
    if (-not $mongorestore) {
        Fail "mongorestore (MongoDB Database Tools) is required to load only sample_mflix. Install it - Windows: 'winget install -e --id MongoDB.DatabaseTools'; Linux/mac: https://www.mongodb.com/try/download/database-tools - then re-run."
    }
}
Info "Using mongorestore: $mongorestore"

$archive = Join-Path ([System.IO.Path]::GetTempPath()) "sample_mflix-$([guid]::NewGuid().ToString('N').Substring(0,8)).archive"
Info "Downloading the sample_mflix dataset (~123 MB) ..."
Invoke-WebRequest -Uri 'https://atlas-education.s3.amazonaws.com/sample_mflix.archive' -OutFile $archive -UseBasicParsing

# mongorestore prints a size line per collection every few seconds, which buries everything else. Parse
# its output into ONE progress bar instead, and keep the raw log only so it can be shown if it fails.
Info "Restoring sample_mflix into the cluster ..."
$activity = 'Restoring sample_mflix'
$log = [System.Collections.Generic.List[string]]::new()
$totalColls = 0; $doneColls = 0; $totalDocs = 0; $status = ''
# Native stderr combined with $ErrorActionPreference='Stop' can turn ordinary progress output into a
# terminating error, so relax it just for this pipeline.
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& $mongorestore --drop --nsInclude='sample_mflix.*' --archive="$archive" --uri="$full" 2>&1 | ForEach-Object {
    $line = [string]$_
    $log.Add($line)
    if ($line -match 'reading metadata for') { $totalColls++ }
    elseif ($line -match 'finished restoring .+?\((\d+) document') { $doneColls++; $totalDocs += [int]$Matches[1] }
    elseif ($line -match '(sample_mflix\.\S+)\s+([\d.]+\s*[KMGT]?B)\s*$') { $status = "$($Matches[1])  $($Matches[2])" }
    if ($totalColls -gt 0) {
        $pct = [Math]::Min(100, [int](100 * $doneColls / $totalColls))
        $text = "$doneColls of $totalColls collections"
        if ($status) { $text += "  |  $status" }
        Write-Progress -Activity $activity -Status $text -PercentComplete $pct
    }
}
$rc = $LASTEXITCODE
$ErrorActionPreference = $prevEap
Write-Progress -Activity $activity -Completed
Remove-Item $archive -Force -ErrorAction SilentlyContinue
if ($rc -ne 0) {
    Warn "mongorestore output:"
    $log | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray }
    Fail "mongorestore failed. Ensure Network Access allows your IP (0.0.0.0/0 for testing) and the database user has readWrite."
}
Ok "sample_mflix loaded ($doneColls collections, $totalDocs documents)."

# ----- 7. Vector search index ('vector_index' is fixed; azure-deploy + the agent expect that name)
Write-Phase 7 "Vector index 'vector_index'"
$existingIdx = Results (atlas clusters search indexes list --clusterName $ClusterName --db sample_mflix --collection embedded_movies --projectId $ProjectId --output json 2>$null | ConvertFrom-Json)
if ($existingIdx | Where-Object { $_.name -eq 'vector_index' }) {
    Ok "Index 'vector_index' already exists, reusing."
}
else {
    $idxCfg = Join-Path ([System.IO.Path]::GetTempPath()) "vector-index-$([guid]::NewGuid().ToString('N').Substring(0,8)).json"
    # The index body goes under 'definition'. Putting 'fields' at the top level still works but makes
    # the CLI warn "you're using an old search index definition".
    @{
        database       = 'sample_mflix'
        collectionName = 'embedded_movies'
        type           = 'vectorSearch'
        name           = 'vector_index'
        definition     = @{ fields = @(@{ type = 'vector'; path = 'plot_embedding'; numDimensions = 1536; similarity = 'cosine' }) }
    } | ConvertTo-Json -Depth 6 | Set-Content $idxCfg -Encoding UTF8
    Info "Creating vector_index (embedded_movies.plot_embedding, 1536 dims, cosine) ..."
    atlas clusters search indexes create --clusterName $ClusterName --file $idxCfg --projectId $ProjectId *> $null
    $rc = $LASTEXITCODE
    Remove-Item $idxCfg -Force -ErrorAction SilentlyContinue
    if ($rc -ne 0) { Fail "Vector index create failed (see error above)." }
    Info "Waiting for the index to become queryable (usually 1-2 min) ..."
    $deadline = (Get-Date).AddMinutes(6)
    do {
        Start-Sleep -Seconds 12
        $idx = Results (atlas clusters search indexes list --clusterName $ClusterName --db sample_mflix --collection embedded_movies --projectId $ProjectId --output json 2>$null | ConvertFrom-Json) | Where-Object { $_.name -eq 'vector_index' }
        $status = "$($idx.status)$($idx.latestDefinitionVersion.status)"
    } while ($status -notmatch 'READY|STEADY|ACTIVE' -and (Get-Date) -lt $deadline)
    if ($status -match 'READY|STEADY|ACTIVE') { Ok "Index is queryable." } else { Warn "Index still building; it should be queryable within a couple minutes." }
}

# ----- 8. Connection string (set as an env var; never printed) --------------
Write-Phase 8 "Connection string"
if (-not $full) {
    $csj = atlas clusters connectionStrings describe $ClusterName --projectId $ProjectId --output json 2>$null | ConvertFrom-Json
    $srv = $csj.standardSrv
    if (-not $srv) { Fail "Could not read the SRV connection string for '$ClusterName'." }
    $full = ($srv -replace '^mongodb\+srv://', "mongodb+srv://$DbUser`:$dbPass@") + "/?retryWrites=true&w=majority&appName=simple-rag-movies"
    $clusterHost = ($srv -replace '^mongodb\+srv://', '')
}
# Env vars are process-scoped, so setting this here persists to your shell AFTER the script returns,
# as long as you ran it in-session as ./scripts/atlas/setup.ps1 (not 'pwsh -File', which is a child process).
$env:MDB_MCP_CONNECTION_STRING = $full
Ok "MDB_MCP_CONNECTION_STRING is now set for this session (cluster: $clusterHost). The secret was not printed."

# ----- 9. Verify: connect, query, and run a real vector search --------------
Write-Phase 9 "Verify (connect + query + vector search)"
$verify = Join-Path $PSScriptRoot 'verify.py'
$py = Get-Command python -ErrorAction SilentlyContinue
if (-not $py) { $py = Get-Command python3 -ErrorAction SilentlyContinue }
if (-not $py) {
    Warn "Python not found; skipping automated verification. Install Python, then run:  python scripts/atlas/verify.py"
}
elseif (-not (Test-Path $verify)) {
    Warn "atlas/verify.py not found next to this script; skipping verification."
}
else {
    & $py.Source -c "import pymongo" 2>$null
    if ($LASTEXITCODE -ne 0) {
        Info "Installing pymongo + dnspython for the verification step ..."
        & $py.Source -m pip install --quiet --disable-pip-version-check pymongo dnspython 2>$null
    }
    & $py.Source $verify   # inherits MDB_MCP_CONNECTION_STRING from this session
    if ($LASTEXITCODE -ne 0) { Warn "Verification did not fully pass (see above). If the vector index is still building, wait a minute and re-run:  python scripts/atlas/verify.py" }
}

Write-Host "`n============================================================" -ForegroundColor Cyan
Write-Host " Atlas is ready. Next step:" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  MDB_MCP_CONNECTION_STRING is set for this terminal session."
Write-Host "  Just run:  " -NoNewline; Write-Host "./scripts/azure/deploy.ps1" -ForegroundColor White
Write-Host "`n(The connection string holds a password, so it was not printed. Re-run this script anytime to regenerate and re-set it.)" -ForegroundColor DarkGray

# Clean success code so an orchestrator can trust $LASTEXITCODE (a non-fatal verify warning above
# may otherwise leave a stray non-zero code from python).
exit 0
