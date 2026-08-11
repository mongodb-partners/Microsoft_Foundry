<#
.SYNOPSIS
    One-click Azure deploy for the simple-rag-movies sample.

.DESCRIPTION
    Provisions the ENTIRE Azure side of the sample in a single run, closing the gaps
    in the original README/deploy.ps1:

      1. Resource group
      2. Azure AI Foundry (AIServices) account + text-embedding-ada-002 deployment (ONE account for embeddings AND chat)
      3. Embedding Function: infra (bicep) + code via 'az' zip deploy (NO Azure Functions Core Tools needed)
      4. MongoDB MCP Server on Azure Container Apps
      5. Optional smoke test of the embedding endpoint
      6. Foundry project + gpt-5-mini on that SAME account + prompt agent wired to both MCP servers (MongoDB + semantic search)

    All values are captured and injected between steps automatically. No manual copy-paste of
    endpoints, keys, or URLs. Globally-unique names are generated deterministically so re-runs are stable.

    MANUAL PREREQUISITES (the "hard 20%" that cannot be automated by an unprivileged user):
      - MongoDB Atlas: cluster with sample_mflix loaded, 'vector_index' created, and
        Network Access allowing Azure egress. Run ./scripts/atlas/setup.ps1 first - it does all of
        this and sets MDB_MCP_CONNECTION_STRING for the current session.
      - A Foundry project where you hold 'Azure AI User' (+ 'Azure AI Project Manager' to create the MCP connection).

    The MongoDB connection string (with password) is read from the environment variable
    MDB_MCP_CONNECTION_STRING so it never lands in source control or a script parameter.

.PARAMETER ConfigPath
    Path to the JSON config. Defaults to ../deploy/config.json (falls back to config.example.json).

.EXAMPLE
    # atlas/setup.ps1 already set the connection string for this session:
    ./scripts/atlas/setup.ps1
    ./scripts/azure/deploy.ps1
.EXAMPLE
    # Or set it yourself, then deploy:
    $env:MDB_MCP_CONNECTION_STRING = "mongodb+srv://user:pass@cluster0.xxxx.mongodb.net/?appName=Cluster0"
    ./scripts/azure/deploy.ps1
#>
param(
    [string]$ConfigPath,
    [switch]$NonInteractive,    # skip prompts; use config.json values as-is
    [switch]$PurgeSoftDeleted   # purge a same-named soft-deleted Foundry account without asking
)

$ErrorActionPreference = 'Stop'

# ----- helpers ---------------------------------------------------------------
function Write-Phase($n, $msg) { Write-Host "`n[$n] $msg" -ForegroundColor Cyan }
function Write-Ok($msg)        { Write-Host "    $msg" -ForegroundColor Green }
function Write-Info($msg)      { Write-Host "    $msg" -ForegroundColor Gray }
function Fail($msg)            { Write-Host "ERROR: $msg" -ForegroundColor Red; exit 1 }
# Bicep parameter values need different quoting per platform, and getting it wrong is silent.
#
# Windows: 'az' is az.cmd, so cmd.exe re-parses the command line. An unquoted '&' in a value is a
# command separator, and a Mongo connection string truncates at '?retryWrites=true' while the rest
# ('w=majority', 'appName=...') gets run as commands. Literal quotes survive that.
#
# Linux/macOS: 'az' is executed directly, nothing re-parses anything, and those same literal quotes
# become part of the value. That produced ContainerAppInvalidName for '\"mongo-mcp-server\"' in a
# Codespace while Windows was fine.
function P($name, $value) {
    if ($IsWindows) { "$name=`"$value`"" } else { "$name=$value" }
}
function Ask($label, $default) {
    if ($NonInteractive) { return $default }
    $hint = if ($default) { " [$default]" } else { "" }
    $ans  = Read-Host "  $label$hint"
    if ([string]::IsNullOrWhiteSpace($ans)) { return $default } else { return $ans }
}
function AskSecret($label) {
    $sec  = Read-Host "  $label" -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try     { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}
function Select-Item($title, $items, $displayFn, $defaultIndex) {
    # Print a numbered menu and return the chosen item (Enter = the * default).
    if ($NonInteractive) { return $items[$defaultIndex] }
    Write-Host "  $title" -ForegroundColor Cyan
    for ($i = 0; $i -lt $items.Count; $i++) {
        $marker = if ($i -eq $defaultIndex) { '*' } else { ' ' }
        Write-Host ("   {0} {1}) {2}" -f $marker, ($i + 1), (& $displayFn $items[$i]))
    }
    $ans = Read-Host "  Enter a number [$($defaultIndex + 1)]"
    if ([string]::IsNullOrWhiteSpace($ans)) { return $items[$defaultIndex] }
    $n = 0
    if ([int]::TryParse($ans, [ref]$n) -and $n -ge 1 -and $n -le $items.Count) { return $items[$n - 1] }
    Fail "Invalid selection: '$ans'. Enter a number between 1 and $($items.Count)."
}

# ----- resolve paths ---------------------------------------------------------
$SampleDir = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)   # scripts/azure -> scripts -> sample root
if (-not $ConfigPath) {
    $ConfigPath = Join-Path $SampleDir 'deploy/config.json'
    if (-not (Test-Path $ConfigPath)) {
        $ConfigPath = Join-Path $SampleDir 'deploy/config.example.json'
        Write-Host "config.json not found; using config.example.json. Copy it to config.json to customize." -ForegroundColor Yellow
    }
}
if (-not (Test-Path $ConfigPath)) { Fail "Config file not found: $ConfigPath" }
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
Write-Info "Config: $ConfigPath"

# ----- ensure az + login (so we can show live tenant/subscription defaults) --
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Fail "Azure CLI (az) is required. Install: https://learn.microsoft.com/cli/azure/install-azure-cli"
}
az account show -o none 2>$null
if ($LASTEXITCODE -ne 0) {
    if ($NonInteractive) { Fail "Not logged in. Run 'az login' first." }
    Write-Info "Not logged in; launching 'az login' ..."
    az login -o none
    if ($LASTEXITCODE -ne 0) { Fail "az login failed." }
}

# ----- collect variables (interactive; config values are the defaults) -------
# Walks the same inputs we entered by hand during setup. Press Enter to accept [default].
if (-not $NonInteractive) { Write-Host "`nEnter deployment values (Enter = accept [default]):" -ForegroundColor Cyan }

# Tenant + subscription: pick from a numbered menu (no need to type names or ids).
$acct = az account show -o json | ConvertFrom-Json
if (-not ($cfg.PSObject.Properties.Name -contains 'tenantId')) {
    $cfg | Add-Member -NotePropertyName tenantId -NotePropertyValue '' -Force
}
if ($NonInteractive) {
    if (-not $cfg.tenantId)       { $cfg.tenantId       = $acct.tenantId }
    if (-not $cfg.subscriptionId) { $cfg.subscriptionId = $acct.id }
} else {
    $subsAll = az account list -o json | ConvertFrom-Json
    if (-not $subsAll -or @($subsAll).Count -eq 0) { Fail "No subscriptions found. Run 'az login' and retry." }

    # Directories (tenants) you're already signed in to, plus an escape hatch to add another.
    # az account list only fills tenantDisplayName for some tenants, so pull friendlier names
    # (display name, else the .onmicrosoft.com domain) from the tenants API.
    $tenantNames = @{}
    try {
        $tlist = az rest --method GET --url "https://management.azure.com/tenants?api-version=2022-12-01" -o json 2>$null | ConvertFrom-Json
        foreach ($t in @($tlist.value)) {
            if ($t.tenantId) {
                $tenantNames[[string]$t.tenantId] = if ($t.displayName) { $t.displayName } elseif ($t.defaultDomain) { $t.defaultDomain } else { [string]$t.tenantId }
            }
        }
    } catch { }
    $tenants = @($subsAll | Group-Object tenantId | ForEach-Object {
        $g = $_.Group[0]
        $name = if ($tenantNames.ContainsKey($_.Name)) { $tenantNames[$_.Name] }
                elseif ($g.tenantDisplayName)          { $g.tenantDisplayName }
                else                                   { $_.Name }
        [pscustomobject]@{ TenantId = $_.Name; Name = $name }
    } | Sort-Object Name)
    $tenantChoices = @($tenants) + [pscustomobject]@{ TenantId = '__OTHER__'; Name = 'Other - sign in to a different directory' }
    $preferTenant  = if ($cfg.tenantId) { $cfg.tenantId } else { $acct.tenantId }
    $tdefault = 0
    for ($i = 0; $i -lt $tenants.Count; $i++) { if ($tenants[$i].TenantId -eq $preferTenant) { $tdefault = $i; break } }

    $chosenTenant = Select-Item "Select the Azure directory (tenant):" $tenantChoices { param($t) "$($t.Name)  ($($t.TenantId))" } $tdefault
    if ($chosenTenant.TenantId -eq '__OTHER__') {
        $tid = Ask "Tenant ID or domain (e.g. contoso.onmicrosoft.com)" ""
        if ([string]::IsNullOrWhiteSpace($tid)) { Fail "A tenant id or domain is required." }
        Write-Info "Signing in to tenant $tid (a browser may open) ..."
        az login --tenant $tid -o none
        if ($LASTEXITCODE -ne 0) { Fail "Could not sign in to tenant $tid" }
        $acct         = az account show -o json | ConvertFrom-Json
        $subsAll      = az account list -o json | ConvertFrom-Json
        $cfg.tenantId = $acct.tenantId
    } else {
        $cfg.tenantId = $chosenTenant.TenantId
    }

    $subsInTenant = @($subsAll | Where-Object { $_.tenantId -eq $cfg.tenantId } | Sort-Object name)
    if ($subsInTenant.Count -eq 0) { Fail "No subscriptions found in the selected directory." }
    $preferSub = if ($cfg.subscriptionId) { $cfg.subscriptionId } else { $acct.id }
    $sdefault  = 0
    for ($i = 0; $i -lt $subsInTenant.Count; $i++) { if ($subsInTenant[$i].id -eq $preferSub) { $sdefault = $i; break } }
    $chosenSub = Select-Item "Select the subscription:" $subsInTenant { param($s) "$($s.name)  ($($s.id))" } $sdefault
    $cfg.subscriptionId = $chosenSub.id
    Write-Info "Using subscription: $($chosenSub.name)  ($($chosenSub.id))"
}
$cfg.resourceGroup         = Ask "Resource group"                                    $cfg.resourceGroup
$cfg.location              = Ask "Azure region (match your Mongo cluster region)"    $cfg.location

# Everything below is an implementation detail of the sample, not a decision a run needs to make,
# so it is reported rather than asked. Override any of it in deploy/config.json.
Write-Info "Using (override in deploy/config.json):"
Write-Info "  name prefix       : $($cfg.namePrefix)"
Write-Info "  embedding model   : $($cfg.embeddingModel) v$($cfg.embeddingModelVersion) ($($cfg.embeddingCapacity)K TPM)"
Write-Info "  MCP container app : $($cfg.mcpContainerAppName)"
Write-Info "  MCP image         : $($cfg.mcpImage) (read-only: $($cfg.mcpReadOnly))"

# MongoDB connection string (secret): environment variable first, else secure prompt
$connStr = $env:MDB_MCP_CONNECTION_STRING
if ([string]::IsNullOrWhiteSpace($connStr)) {
    if ($NonInteractive) { Fail "Set MDB_MCP_CONNECTION_STRING for non-interactive mode." }
    $connStr = AskSecret "MongoDB connection string (mongodb+srv://user:pass@...)"
}
if ([string]::IsNullOrWhiteSpace($connStr)) { Fail "MongoDB connection string is required." }

# ----- preflight -------------------------------------------------------------
Write-Phase 0 "Preflight checks"
# az presence + login + tenant already verified during variable collection.
# Select the chosen subscription (accepts a name or an id).
if (-not [string]::IsNullOrWhiteSpace($cfg.subscriptionId)) {
    az account set --subscription $cfg.subscriptionId
    if ($LASTEXITCODE -ne 0) { Fail "Could not set subscription $($cfg.subscriptionId)" }
}
$subId   = (az account show --query id       -o tsv)
$subName = (az account show --query name     -o tsv)
$tenId   = (az account show --query tenantId -o tsv)
$tenName = $tenId
try {
    $tl = az rest --method GET --url "https://management.azure.com/tenants?api-version=2022-12-01" -o json 2>$null | ConvertFrom-Json
    $tm = @($tl.value) | Where-Object { $_.tenantId -eq $tenId } | Select-Object -First 1
    if ($tm) { $tenName = if ($tm.displayName) { $tm.displayName } elseif ($tm.defaultDomain) { $tm.defaultDomain } else { $tenId } }
} catch { }

# Last checkpoint before anything is created. Picking the wrong subscription here is easy (the
# menu defaults to whatever 'az' was already pointed at) and the failure shows up much later as a
# confusing AuthorizationFailed, after resources have already been made in the wrong place.
Write-Host "`n============================================================" -ForegroundColor Yellow
Write-Host " EVERYTHING WILL BE CREATED IN THIS SUBSCRIPTION" -ForegroundColor Yellow
Write-Host "============================================================" -ForegroundColor Yellow
Write-Host ("   subscription   : {0}" -f $subName) -ForegroundColor White
Write-Host ("                    {0}" -f $subId)   -ForegroundColor DarkGray
Write-Host ("   directory      : {0}" -f $tenName) -ForegroundColor White
Write-Host ("                    {0}" -f $tenId)   -ForegroundColor DarkGray
Write-Host ("   resource group : {0}   region: {1}" -f $cfg.resourceGroup, $cfg.location) -ForegroundColor White
Write-Host "   Nothing has been created yet." -ForegroundColor DarkGray
if (-not $NonInteractive) {
    $go = Read-Host "`n   Continue? [y/N]"
    if ($go -notmatch '^\s*(y|yes)\s*$') {
        Write-Host "`nStopped. Nothing was created. Re-run and select the intended subscription." -ForegroundColor Yellow
        exit 1
    }
}
Write-Ok "Subscription: $subName  ($subId)"

# Register required providers (idempotent, fast if already registered)
foreach ($ns in @('Microsoft.App','Microsoft.OperationalInsights','Microsoft.CognitiveServices','Microsoft.Web','Microsoft.Storage')) {
    $state = az provider show --namespace $ns --query registrationState -o tsv 2>$null
    if ($state -ne 'Registered') {
        Write-Info "Registering provider $ns ..."
        az provider register --namespace $ns -o none 2>$null
    }
}
Write-Ok "Providers registered"

# ----- deterministic unique suffix ------------------------------------------
$md5   = [System.Security.Cryptography.MD5]::Create()
$bytes = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes("$subId-$($cfg.resourceGroup)"))
$suffix = ([System.BitConverter]::ToString($bytes) -replace '-','').Substring(0,6).ToLower()
$foundryAcct = "$($cfg.namePrefix)-foundry-$suffix"
$funcName    = "$($cfg.namePrefix)-embed-$suffix"
# Derived from subscription + resource group so re-runs land on the same globally-unique names.
Write-Info "Names: Foundry=$foundryAcct  Function=$funcName  MCP=$($cfg.mcpContainerAppName)"

# ----- 1. resource group -----------------------------------------------------
Write-Phase 1 "Resource group '$($cfg.resourceGroup)'"
$existingRgLocation = az group show --name $cfg.resourceGroup --query location -o tsv 2>$null
if ($existingRgLocation) {
    Write-Info "Already exists in '$existingRgLocation'. RG location is fixed metadata; resources still deploy to '$($cfg.location)'."
} else {
    az group create --name $cfg.resourceGroup --location $cfg.location -o none
    if ($LASTEXITCODE -ne 0) { Fail "Resource group create failed." }
    Write-Info "Created in '$($cfg.location)'."
}
Write-Ok "Resource group ready"

# ----- 2. Azure AI Foundry account + embedding model ------------------------
# ONE AIServices account hosts BOTH the embedding model (this phase) and the chat model +
# agent (phase 6). There is no separate Azure OpenAI resource.
Write-Phase 2 "Azure AI Foundry account + $($cfg.embeddingModel) deployment"
az cognitiveservices account show --name $foundryAcct --resource-group $cfg.resourceGroup -o none 2>$null
if ($LASTEXITCODE -ne 0) {
    # Deleting a resource group only SOFT-deletes a Cognitive Services account. The name stays
    # reserved for about 48 hours and 'create' then fails with FlagMustBeSetForRestore. Detect it
    # here, because that raw failure reads like a quota problem and sends you hunting the wrong thing.
    $tomb = $null
    try {
        $tomb = @(az cognitiveservices account list-deleted -o json 2>$null | ConvertFrom-Json |
                  Where-Object { $_.name -eq $foundryAcct })[0]
    } catch { }
    if ($tomb) {
        $tombLoc = if ($tomb.location)      { $tomb.location }      else { $cfg.location }
        $tombRg  = if ($tomb.resourceGroup) { $tomb.resourceGroup } else { $cfg.resourceGroup }
        Write-Host "    '$foundryAcct' is SOFT-DELETED in '$tombLoc' (left behind by an earlier teardown)." -ForegroundColor Yellow
        Write-Host "    The name stays reserved, so a clean account cannot be created until it is purged." -ForegroundColor Yellow
        Write-Host "    Purging is IRREVERSIBLE: the old account can no longer be restored afterwards." -ForegroundColor Yellow
        $doPurge = [bool]$PurgeSoftDeleted
        if (-not $doPurge -and -not $NonInteractive) {
            $doPurge = (Read-Host "    Purge it and create a fresh account? [y/N]") -match '^\s*(y|yes)\s*$'
        }
        if (-not $doPurge) {
            Write-Host "    Purge it yourself with:" -ForegroundColor DarkGray
            Write-Host "      az cognitiveservices account purge --name $foundryAcct --location $tombLoc --resource-group $tombRg" -ForegroundColor DarkGray
            Fail "Soft-deleted account '$foundryAcct' is blocking the deploy. Purge it, or re-run with -PurgeSoftDeleted."
        }
        Write-Info "Purging '$foundryAcct' ..."
        az cognitiveservices account purge --name $foundryAcct --location $tombLoc --resource-group $tombRg -o none
        if ($LASTEXITCODE -ne 0) { Fail "Purge failed for '$foundryAcct'. Confirm you are in the intended subscription: $subName ($subId)." }
        Write-Ok "Purged; the name is free."
    }
    Write-Info "Creating Azure AI Foundry account $foundryAcct ..."
    az cognitiveservices account create --name $foundryAcct --resource-group $cfg.resourceGroup `
        --location $cfg.location --kind AIServices --sku S0 --custom-domain $foundryAcct --yes -o none
    if ($LASTEXITCODE -ne 0) { Fail "Foundry account create failed (see error above). Possible quota/policy limit in $($cfg.location)." }
} else {
    Write-Info "Foundry account already exists, reusing."
}
az cognitiveservices account deployment show --name $foundryAcct --resource-group $cfg.resourceGroup `
    --deployment-name $cfg.embeddingModel -o none 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Info "Deploying model $($cfg.embeddingModel) ..."
    az cognitiveservices account deployment create --name $foundryAcct --resource-group $cfg.resourceGroup `
        --deployment-name $cfg.embeddingModel --model-name $cfg.embeddingModel `
        --model-version $cfg.embeddingModelVersion --model-format OpenAI `
        --sku-capacity $cfg.embeddingCapacity --sku-name Standard -o none
    if ($LASTEXITCODE -ne 0) { Fail "Model deployment failed (see error above). Check model availability/quota for $($cfg.embeddingModel) in $($cfg.location)." }
} else {
    Write-Info "Model deployment already exists, reusing."
}
$aoaiEndpoint = "https://$foundryAcct.openai.azure.com"
$aoaiKey      = az cognitiveservices account keys list --name $foundryAcct --resource-group $cfg.resourceGroup --query key1 -o tsv
Write-Ok "Foundry account ready (embeddings): $aoaiEndpoint"

# ----- 3. MongoDB MCP Server on Azure Container Apps -------------------------
# Deployed BEFORE the function: the MCP server is the only component that talks to MongoDB, and
# the function needs its URL (the function itself gets no database credential).
Write-Phase 3 "MongoDB MCP Server on Azure Container Apps"
$mcpBicep = Join-Path $SampleDir 'deploy/mcp-server/main.bicep'
$readOnly = "$($cfg.mcpReadOnly)".ToLower()   # Bicep bool params need lowercase true/false
$mcpJson = az deployment group create --resource-group $cfg.resourceGroup --template-file $mcpBicep `
    --parameters (P 'mdbConnectionString' $connStr) (P 'containerAppName' $cfg.mcpContainerAppName) `
                 (P 'containerImage' $cfg.mcpImage) (P 'readOnlyMode' $readOnly) `
    --query properties.outputs -o json
if ($LASTEXITCODE -ne 0) { Fail "MCP Server deploy failed (see error above)." }
$mcpUrl = ($mcpJson | ConvertFrom-Json).mcpServerUrl.value
Write-Ok "MCP Server ready: $mcpUrl"

# ----- 4. Embedding Function: infra + code (zip deploy, no func) --------------
Write-Phase 4 "Embedding Function (infra + code)"
$funcBicep = Join-Path $SampleDir 'deploy/embedding-function/main.bicep'
az deployment group create --resource-group $cfg.resourceGroup --template-file $funcBicep `
    --parameters (P 'functionAppName' $funcName) (P 'azureOpenAIEndpoint' $aoaiEndpoint) `
                 (P 'azureOpenAIKey' $aoaiKey) (P 'embeddingModel' $cfg.embeddingModel) `
                 (P 'mcpServerUrl' $mcpUrl) -o none
if ($LASTEXITCODE -ne 0) { Fail "Embedding Function infra deploy failed (see error above). Common cause: no Flex Consumption capacity/quota in $($cfg.location) - try another region or request quota." }
Write-Info "Infra deployed. Zipping source; Flex Consumption builds Python deps remotely (Oryx) ..."
$srcDir = Join-Path $SampleDir 'src/embedding-function'
$zip = Join-Path ([System.IO.Path]::GetTempPath()) "embed-fn-$suffix.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path (Join-Path $srcDir 'function_app.py'), (Join-Path $srcDir 'host.json'), (Join-Path $srcDir 'requirements.txt') -DestinationPath $zip -Force
# Flex Consumption performs a remote Oryx build from requirements.txt (no local wheel bundling).
az functionapp deployment source config-zip --resource-group $cfg.resourceGroup --name $funcName --src $zip -o none
if ($LASTEXITCODE -ne 0) { Fail "Function code deploy failed (see error above)." }
$embedUrl = "https://$funcName.azurewebsites.net/api/embed"
$embedMcpUrl = "https://$funcName.azurewebsites.net/api/mcp"
Write-Ok "Embedding Function ready: $embedUrl"
Write-Ok "Semantic-search MCP endpoint: $embedMcpUrl"

# ----- 5. Smoke test the embedding endpoint ---------------------------------
if ($cfg.runSmokeTest) {
    Write-Phase 5 "Smoke test: embedding endpoint"
    try {
        $body = @{ text = "hope and redemption" } | ConvertTo-Json
        $r = Invoke-RestMethod -Uri $embedUrl -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 120
        if ($r.dimensions -eq 1536) { Write-Ok "Embedding OK: $($r.dimensions) dims, model $($r.model)" }
        else { Write-Host "    Unexpected dimensions: $($r.dimensions)" -ForegroundColor Yellow }
    } catch {
        Write-Host "    Smoke test failed (function may be cold-starting): $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# ----- 6. Foundry: project + chat model + agent -----------------------------
# Reuses the AIServices account from phase 2 (which already hosts the embedding model) for the
# project, chat model, and agent - so there is ONE Azure AI resource, not two.
Write-Phase 6 "Foundry project + agent"
$chatModel   = if ($cfg.chatModel) { $cfg.chatModel } else { 'gpt-5-mini' }
$foundryProj = if ($cfg.foundryProjectName) { $cfg.foundryProjectName } else { "$($cfg.namePrefix)-project" }
Write-Info "Chat model: $chatModel   Foundry project: $foundryProj"

az cognitiveservices account project show --name $foundryAcct --project-name $foundryProj --resource-group $cfg.resourceGroup -o none 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Info "Creating project '$foundryProj' on '$foundryAcct' ..."
    az cognitiveservices account project create --name $foundryAcct --project-name $foundryProj `
        --resource-group $cfg.resourceGroup --location $cfg.location -o none
    if ($LASTEXITCODE -ne 0) { Fail "Foundry project create failed (see error above)." }
} else {
    Write-Info "Project '$foundryProj' already exists, reusing."
}
# --model-version is required. Auto-detect the latest GENERALLY AVAILABLE version (avoids deprecating ones).
$chatModelVersion = az cognitiveservices account list-models --name $foundryAcct --resource-group $cfg.resourceGroup `
    --query "reverse(sort_by([?name=='$chatModel' && lifecycleStatus=='GenerallyAvailable'], &version))[0].version" -o tsv 2>$null
if ([string]::IsNullOrWhiteSpace($chatModelVersion)) {
    Write-Host "    Could not auto-detect a GA version for '$chatModel' in '$($cfg.location)'. Deploy it manually before the agent can run." -ForegroundColor Yellow
} else {
    az cognitiveservices account deployment show --name $foundryAcct --resource-group $cfg.resourceGroup --deployment-name $chatModel -o none 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Info "Deploying chat model '$chatModel' v$chatModelVersion (GlobalStandard) ..."
        az cognitiveservices account deployment create --name $foundryAcct --resource-group $cfg.resourceGroup `
            --deployment-name $chatModel --model-name $chatModel --model-version $chatModelVersion `
            --model-format OpenAI --sku-name GlobalStandard --sku-capacity 30 -o none
        if ($LASTEXITCODE -ne 0) { Write-Host "    Chat model deploy failed (see error above). Try --sku-name Standard or a different version." -ForegroundColor Yellow }
    } else {
        Write-Info "Chat model '$chatModel' already deployed, reusing."
    }
}
$foundryEndpoint = "https://$foundryAcct.services.ai.azure.com/api/projects/$foundryProj"
Write-Ok "Project ready: $foundryEndpoint"

# Create the agent (data plane, REST v1) with both tools wired.
$agentName = if ($cfg.agentName) { $cfg.agentName } else { 'mongodb-search-agent' }
$instrPath = Join-Path $SampleDir 'docs/agent-instructions.md'
$instructions = if (Test-Path $instrPath) { Get-Content $instrPath -Raw } else { 'For thematic/semantic queries call the semantic_search MCP tool with the query text and answer from the returned documents. For exact-field filters and aggregations use the MongoDB tool. Never answer movie questions from your own knowledge.' }

# ONE MCP server for the agent: the Function. It exposes semantic_search AND re-advertises every
# tool from the MongoDB MCP server, forwarding calls there and joining the reply into one block.
#
# Foundry must NOT be pointed straight at the MongoDB MCP server. That server answers with two
# content blocks (a short summary, then the documents inside an <untrusted-user-data-...> fence)
# and Foundry's MCP client forwards only the first, so the agent is told "305 documents matched"
# and shown none of them. Going through the Function is what makes the data reach the model.
$tools = @(
    @{ type = 'mcp'; server_label = 'MongoDB'; server_url = $embedMcpUrl; require_approval = 'never' }
)
$agentBody = @{
    name        = $agentName
    description = 'MongoDB Atlas vector search RAG agent'
    definition  = @{ kind = 'prompt'; model = $chatModel; instructions = $instructions; tools = $tools }
} | ConvertTo-Json -Depth 60

Write-Info "Requesting Foundry access token ..."
$tok = az account get-access-token --scope "https://ai.azure.com/.default" --query accessToken -o tsv
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($tok)) { Fail "Could not get a Foundry access token (az account get-access-token)." }
Write-Info "Creating agent '$agentName' in the project ..."
$agentHeaders = @{ Authorization = "Bearer $tok" }
$agentUri     = "$foundryEndpoint/agents?api-version=v1"

# Report an agent API failure and hand back the HTTP status so the caller can decide what to do.
function Show-AgentError($errRecord) {
    $status = 0
    try { $status = [int]$errRecord.Exception.Response.StatusCode } catch { }
    Write-Host "    $($errRecord.Exception.Message)" -ForegroundColor Yellow
    if ($errRecord.ErrorDetails.Message) { Write-Host "    $($errRecord.ErrorDetails.Message)" -ForegroundColor DarkGray }
    # Only mention the role when the service actually refused on authorization. Printing this for
    # every failure sends people hunting permissions for conflicts and unreachable URLs.
    if ($status -eq 401 -or $status -eq 403) {
        Write-Host "    You need the 'Azure AI User' (Foundry User) data-plane role on this project." -ForegroundColor Yellow
    }
    return $status
}

$agent = $null
try {
    $agent = Invoke-RestMethod -Method Post -Uri $agentUri -Headers $agentHeaders -ContentType 'application/json' -Body $agentBody
} catch {
    $status = Show-AgentError $_
    if ($status -ne 409) { Fail "Agent creation failed (see above)." }

    # 409 means an agent of this name survived an earlier run: the Foundry account name is
    # deterministic, and a restored account keeps its agents. The survivor is NOT reusable - the
    # Container Apps environment gets a new random domain on every deploy, so its MongoDB MCP URL
    # no longer resolves and the agent fails at runtime with 424 Failed Dependency. Its
    # instructions are stale too. Replace it rather than leaving it in place.
    Write-Info "An agent named '$agentName' already exists from an earlier deploy."
    Write-Info "Replacing it so its tool URLs and instructions match what was just deployed ..."
    try {
        Invoke-RestMethod -Method Delete -Uri "$foundryEndpoint/agents/$($agentName)?api-version=v1" -Headers $agentHeaders | Out-Null
    } catch {
        Show-AgentError $_ | Out-Null
        Fail "Could not delete the stale agent '$agentName'. Remove it in the Foundry portal and re-run."
    }
    try {
        $agent = Invoke-RestMethod -Method Post -Uri $agentUri -Headers $agentHeaders -ContentType 'application/json' -Body $agentBody
    } catch {
        Show-AgentError $_ | Out-Null
        Fail "Agent re-creation failed after removing the stale one."
    }
    Write-Ok "Stale agent replaced."
}
Write-Ok "Agent ready: $agentName"

# ----- what to do next ------------------------------------------------------
# Deliberately no endpoint URLs here: they are internal plumbing (the agent already has them
# wired) and the person running this cannot do anything useful with them.
Write-Host "`n============================================================" -ForegroundColor Cyan
Write-Host " Done. Your agent is live. Here is how to try it:" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  1. Open   " -NoNewline; Write-Host "https://ai.azure.com" -ForegroundColor White
Write-Host "  2. Top right, check the directory is:  " -NoNewline; Write-Host $tenName -ForegroundColor White
Write-Host "  3. Open the project:                   " -NoNewline; Write-Host $foundryProj -ForegroundColor White
Write-Host "  4. Go to 'Agents' and select:          " -NoNewline; Write-Host $agentName -ForegroundColor White
Write-Host "  5. Open the playground and ask:"
Write-Host "        Find movies about hope and redemption" -ForegroundColor White
Write-Host ""
Write-Host "  It should answer from your MongoDB data, with a relevance score per movie."
Write-Host "  Also try a non-semantic one:  " -NoNewline; Write-Host "Show me movies from 1994" -ForegroundColor White
Write-Host ""
Write-Host " When you are finished, remove everything on both clouds:" -ForegroundColor Yellow
Write-Host "   ./scripts/teardown-all.ps1" -ForegroundColor White
Write-Host ""
exit 0
