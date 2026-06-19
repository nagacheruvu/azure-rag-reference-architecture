<#
  Deploy the private MCP server to Azure Container Apps (internal-only ingress)
  on the mcp subnet, then wire private DNS so the agent subnet resolves the
  internal ACA FQDN. Run AFTER the Pass 1 bicep deployment succeeds.

  Usage:
    pwsh scripts/deploy_mcp_aca.ps1 -ResourceGroup rg-nsp-demo -Location eastus
#>
param(
  [string]$ResourceGroup = 'rg-nsp-demo',
  [string]$Location = 'eastus',
  [string]$DeploymentName = 'agentmcp-p1',
  [string]$EnvName = 'mcp-env',
  [string]$AppName = 'askmaya-mcp',
  [string]$ImageRepo = 'askmaya-mcp'
)

$ErrorActionPreference = 'Stop'
$az = 'C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd'
$src = Join-Path $PSScriptRoot '..\src\mcp-server'

# --- Read Pass 1 outputs ----------------------------------------------------
$out = & $az deployment group show -g $ResourceGroup -n $DeploymentName --query properties.outputs -o json | ConvertFrom-Json
$mcpSubnetId = $out.mcpSubnetId.value
Write-Host "MCP subnet: $mcpSubnetId"

# --- ACR (create if missing) + remote build --------------------------------
$acrName = ('acrmcp' + (($ResourceGroup + $Location).GetHashCode().ToString('x')).Substring(0,6)).ToLower()
$acrExists = & $az acr show -g $ResourceGroup -n $acrName --query name -o tsv 2>$null
if (-not $acrExists) {
  Write-Host "Creating ACR $acrName ..."
  & $az acr create -g $ResourceGroup -n $acrName --sku Basic --admin-enabled true -o none
}
$image = "$acrName.azurecr.io/${ImageRepo}:latest"

# Remote build (use --no-wait to dodge the Windows UnicodeEncodeError, then poll).
Write-Host "Submitting ACR build for $image ..."
& $az acr build -r $acrName -t "${ImageRepo}:latest" $src --no-wait -o none
do {
  Start-Sleep -Seconds 10
  $status = & $az acr task list-runs -r $acrName --query "[0].status" -o tsv
  Write-Host "  build status: $status"
} while ($status -in @('Queued','Running','Started'))
if ($status -ne 'Succeeded') { throw "ACR build failed: $status" }

# --- Container Apps internal environment on mcp subnet ----------------------
$envExists = & $az containerapp env show -g $ResourceGroup -n $EnvName --query name -o tsv 2>$null
if (-not $envExists) {
  Write-Host "Creating internal ACA environment $EnvName ..."
  & $az containerapp env create -g $ResourceGroup -n $EnvName -l $Location `
    --infrastructure-subnet-resource-id $mcpSubnetId --internal-only true -o none
}

# --- Container app (internal ingress, target 8080) --------------------------
$acrPwd = & $az acr credential show -n $acrName --query "passwords[0].value" -o tsv
& $az containerapp create -g $ResourceGroup -n $AppName --environment $EnvName `
  --image $image --target-port 8080 --ingress internal --min-replicas 1 --max-replicas 1 `
  --registry-server "$acrName.azurecr.io" --registry-username $acrName --registry-password $acrPwd -o none

$fqdn = & $az containerapp show -g $ResourceGroup -n $AppName --query properties.configuration.ingress.fqdn -o tsv
Write-Host "MCP app FQDN (internal): $fqdn"

# --- Private DNS for the ACA env default domain -----------------------------
$defaultDomain = & $az containerapp env show -g $ResourceGroup -n $EnvName --query properties.defaultDomain -o tsv
$staticIp = & $az containerapp env show -g $ResourceGroup -n $EnvName --query properties.staticIp -o tsv
$vnetName = $out.vnetName.value
Write-Host "ACA env domain=$defaultDomain staticIp=$staticIp"

$zoneExists = & $az network private-dns zone show -g $ResourceGroup -n $defaultDomain --query name -o tsv 2>$null
if (-not $zoneExists) {
  & $az network private-dns zone create -g $ResourceGroup -n $defaultDomain -o none
  & $az network private-dns link vnet create -g $ResourceGroup -z $defaultDomain `
    -n 'link-mcp' --virtual-network $vnetName --registration-enabled false -o none
}
# Wildcard A record -> env static IP so the agent subnet resolves the app FQDN.
& $az network private-dns record-set a delete -g $ResourceGroup -z $defaultDomain -n '*' --yes -o none 2>$null
& $az network private-dns record-set a add-record -g $ResourceGroup -z $defaultDomain -n '*' --ipv4-address $staticIp -o none

Write-Host ""
Write-Host "MCP server URL for the agent:  https://$fqdn/mcp"
Write-Host "Save this for create_agent_test.py (MCP_SERVER_URL)."
