param(
    [string]$From = (Get-Date).AddDays(-30).ToString('yyyy-MM-dd'),
    [string]$To   = (Get-Date).ToString('yyyy-MM-dd'),
    [string]$Rg   = 'rg-askmaya-dev',
    # Defaults to the current `az` CLI context; override with -Sub <subscription-id>.
    [string]$Sub  = (az account show --query id -o tsv)
)

$body = @{
    type       = 'ActualCost'
    timeframe  = 'Custom'
    timePeriod = @{ from = $From; to = $To }
    dataset    = @{
        granularity = 'None'
        aggregation = @{ totalCost = @{ name = 'Cost'; function = 'Sum' } }
        grouping    = @(@{ type = 'Dimension'; name = 'ServiceName' })
    }
} | ConvertTo-Json -Depth 10 -Compress

$tmp = New-TemporaryFile
Set-Content -Path $tmp -Value $body -Encoding utf8

$uri = "https://management.azure.com/subscriptions/$Sub/resourceGroups/$Rg/providers/Microsoft.CostManagement/query?api-version=2023-03-01"

$resp = az rest --method post --uri $uri --body "@$tmp" --headers "Content-Type=application/json" | ConvertFrom-Json
Remove-Item $tmp -Force

$days = ([datetime]$To - [datetime]$From).Days
$rows = foreach ($r in $resp.properties.rows) {
    [pscustomobject]@{
        Service   = $r[1]
        Cost      = [math]::Round([double]$r[0], 2)
        Currency  = $r[2]
    }
}

$rows = $rows | Sort-Object Cost -Descending
$rows | Format-Table -AutoSize

$total = ($rows | Measure-Object Cost -Sum).Sum
Write-Host ""
Write-Host ("Period:      {0} -> {1}  ({2} days)" -f $From, $To, $days)
Write-Host ("Total:       `${0}" -f [math]::Round($total, 2))
Write-Host ("Per day avg: `${0}" -f [math]::Round($total / [math]::Max($days,1), 2))
