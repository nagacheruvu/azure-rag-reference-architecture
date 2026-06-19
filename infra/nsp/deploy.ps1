<#
.SYNOPSIS
  Deploy the Foundry + AI Search NSP template using a cert-based service
  principal, scoped least-privilege to ONE resource group.

.DESCRIPTION
  The SPN (a least-privileged app registration) has no subscription-level rights,
  so this script:
    1. Selects a privileged USER account (cached `az login`).
    2. Creates the target resource group (idempotent).
    3. Grants the SPN 'Contributor' on JUST that resource group.
    4. Signs in as the cert SPN and deploys infra/nsp/main-rg.bicep (RG scope).

  Control-plane deploy works for SPNs in this tenant. Run the DATA-plane
  validation (scripts/test_nsp.py) under your own user token afterwards — the
  SPN is blocked (403) on the Foundry/Search data planes.

.EXAMPLE
  ./infra/nsp/deploy.ps1 -PrincipalId <your-user-object-id>

.EXAMPLE
  $env:SPN_CERT_PEM = 'C:/secure/spn.pem'
  ./infra/nsp/deploy.ps1 -AccessMode Learning
#>
[CmdletBinding()]
param(
  # Cert-based SPN (client/object/tenant are identifiers, not secrets). Supply your own.
  [string]$ClientId = '<your-spn-client-id>',
  [string]$SpnObjectId = '<your-spn-object-id>',
  [string]$TenantId = (az account show --query tenantId -o tsv),

  # Certificate PEM (cert + private key). Set $env:SPN_CERT_PEM to its path.
  [string]$CertPath = $(if ($env:SPN_CERT_PEM) { $env:SPN_CERT_PEM } else { '' }),

  # Privileged user account (Owner/User Access Admin) used to create the RG + grant the SPN.
  [string]$PrivilegedAccount = '<your-user@example.com>',

  [string]$SubscriptionId = (az account show --query id -o tsv),
  [string]$EnvironmentName = 'nsp-demo',
  [string]$Location = 'eastus',
  [string]$SearchLocation = 'westus2',

  [ValidateSet('Learning', 'Enforced', 'Audit')]
  [string]$AccessMode = 'Learning',

  # Object ID of the USER who will run the data-plane validation. Granted Foundry
  # + Search data-plane roles. Leave empty to skip those grants.
  [string]$PrincipalId = ''
)

$ErrorActionPreference = 'Stop'

# --- Resolve the az CLI (not always on PATH in this workspace) --------------
$az = (Get-Command az -ErrorAction SilentlyContinue).Source
if (-not $az) { $az = (Get-Command az.cmd -ErrorAction SilentlyContinue).Source }
if (-not $az) { $az = 'C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd' }
if (-not (Test-Path $az)) { throw "Azure CLI not found. Install it or set the path." }
function Invoke-Az { & $az @args; if ($LASTEXITCODE -ne 0) { throw "az $($args -join ' ') failed ($LASTEXITCODE)" } }

if ([string]::IsNullOrWhiteSpace($CertPath) -or -not (Test-Path $CertPath)) {
  throw "Certificate PEM not found: '$CertPath'`nSet `$env:SPN_CERT_PEM to the path of your SPN certificate PEM (cert + private key)."
}

$rg = "rg-$EnvironmentName"

# === Phase 1: privileged user — create RG + grant SPN Contributor on it =====
Write-Host "[1/3] Selecting privileged account $PrivilegedAccount..." -ForegroundColor Cyan
$userId = & $az account list --query "[?user.name=='$PrivilegedAccount'] | [0].id" -o tsv 2>$null
if ([string]::IsNullOrWhiteSpace($userId)) {
  Write-Host "      not cached — launching interactive sign-in..."
  Invoke-Az login --output none
}
Invoke-Az account set --subscription $SubscriptionId

Write-Host "[1/3] Ensuring resource group $rg ($Location)..." -ForegroundColor Cyan
Invoke-Az group create --name $rg --location $Location --output none

$rgScope = "/subscriptions/$SubscriptionId/resourceGroups/$rg"
# Contributor → create the resources; User Access Administrator → write the
# role assignments the template defines (keyless Foundry↔Search trust + data-plane roles).
foreach ($role in @('Contributor', 'User Access Administrator')) {
  Write-Host "[1/3] Granting SPN $SpnObjectId '$role' on $rg..." -ForegroundColor Cyan
  $existing = & $az role assignment list --assignee $SpnObjectId --scope $rgScope --role $role --query "[0].id" -o tsv 2>$null
  if ([string]::IsNullOrWhiteSpace($existing)) {
    Invoke-Az role assignment create --assignee $SpnObjectId --role $role --scope $rgScope --output none
    Write-Host "      granted." 
    $script:granted = $true
  } else {
    Write-Host "      already present."
  }
}
if ($script:granted) {
  Write-Host "      waiting 45s for RBAC propagation..."
  Start-Sleep -Seconds 45
}

# === Phase 2: cert SPN — deploy at resource-group scope =====================
Write-Host "[2/3] Signing in as cert SPN $ClientId..." -ForegroundColor Cyan
Invoke-Az login --service-principal --username $ClientId --tenant $TenantId --certificate $CertPath --output none
Invoke-Az account set --subscription $SubscriptionId

$bicep = Join-Path $PSScriptRoot 'main-rg.bicep'
$deploymentName = "nsp-foundry-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
$params = @(
  "environmentName=$EnvironmentName"
  "location=$Location"
  "searchLocation=$SearchLocation"
  "accessMode=$AccessMode"
)
if ($PrincipalId) { $params += "principalId=$PrincipalId" }

Write-Host "[2/3] Deploying '$deploymentName' to $rg (Foundry=$Location, Search=$SearchLocation, mode=$AccessMode)..." -ForegroundColor Cyan
# Retry briefly in case the role assignment is still propagating.
$attempt = 0
while ($true) {
  $attempt++
  & $az deployment group create --resource-group $rg --name $deploymentName `
    --template-file $bicep --parameters $params --output none
  if ($LASTEXITCODE -eq 0) { break }
  if ($attempt -ge 4) { throw "Deployment failed after $attempt attempts." }
  Write-Host "      attempt $attempt failed (RBAC may still be propagating); retrying in 30s..."
  Start-Sleep -Seconds 30
}

# === Phase 3: outputs =======================================================
Write-Host "`n[3/3] Deployment complete. Outputs:" -ForegroundColor Green
& $az deployment group show --resource-group $rg --name $deploymentName --query "properties.outputs" -o jsonc

Write-Host "`nNext: validate the data plane under YOUR user token (SPN is 403 on data plane):" -ForegroundColor Yellow
Write-Host "  az login"
Write-Host "  python scripts/test_nsp.py --deployment $deploymentName --resource-group $rg"
