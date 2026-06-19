$ErrorActionPreference = 'Stop'
function Get-Price($filter) {
  $url = "https://prices.azure.com/api/retail/prices?currencyCode=USD&`$filter=$filter"
  $items = @()
  while ($url) {
    $r = Invoke-RestMethod -Uri $url -Method GET
    $items += $r.Items
    $url = $r.NextPageLink
    if ($items.Count -gt 400) { break }
  }
  return $items
}

Write-Host "===== AZURE AI SEARCH (Basic, westus2) ====="
Get-Price "serviceName eq 'Cognitive Search' and armRegionName eq 'westus2' and skuName eq 'Basic'" |
  Select-Object skuName, meterName, unitOfMeasure, retailPrice, type |
  Format-Table -Auto | Out-Host

Write-Host "===== PRIVATE ENDPOINT / PRIVATE LINK (eastus) ====="
Get-Price "serviceName eq 'Virtual Network Private Link' and armRegionName eq 'eastus'" |
  Where-Object { $_.type -eq 'Consumption' } |
  Select-Object meterName, unitOfMeasure, retailPrice |
  Sort-Object meterName | Get-Unique -AsString |
  Format-Table -Auto | Out-Host

Write-Host "===== AZURE PRIVATE DNS (global) ====="
Get-Price "serviceName eq 'Azure DNS' and meterName eq 'Private Zones'" |
  Select-Object meterName, unitOfMeasure, retailPrice, armRegionName |
  Select-Object -First 3 | Format-Table -Auto | Out-Host

Write-Host "===== AZURE CONTAINER INSTANCES (Linux, eastus) ====="
Get-Price "serviceName eq 'Container Instances' and armRegionName eq 'eastus'" |
  Where-Object { $_.type -eq 'Consumption' -and $_.meterName -notlike '*Windows*' -and ($_.meterName -like '*vCPU*' -or $_.meterName -like '*Memory*') } |
  Select-Object meterName, unitOfMeasure, retailPrice |
  Format-Table -Auto | Out-Host
