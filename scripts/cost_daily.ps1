param(
    [int]$Days   = 14,
    [string]$Rg  = 'rg-askmaya-dev',
    # Defaults to the current `az` CLI context; override with -Sub <subscription-id>.
    [string]$Sub = (az account show --query id -o tsv)
)

$from = (Get-Date).AddDays(-$Days).ToString('yyyy-MM-dd')
$to   = (Get-Date).ToString('yyyy-MM-dd')

$body = @{
    type       = 'ActualCost'
    timeframe  = 'Custom'
    timePeriod = @{ from = $from; to = $to }
    dataset    = @{
        granularity = 'Daily'
        aggregation = @{ totalCost = @{ name = 'Cost'; function = 'Sum' } }
    }
} | ConvertTo-Json -Depth 10 -Compress

$tmp = New-TemporaryFile
Set-Content -Path $tmp -Value $body -Encoding utf8

$uri = "https://management.azure.com/subscriptions/$Sub/resourceGroups/$Rg/providers/Microsoft.CostManagement/query?api-version=2023-03-01"
$resp = az rest --method post --uri $uri --body "@$tmp" --headers "Content-Type=application/json" | ConvertFrom-Json
Remove-Item $tmp -Force

$rows = foreach ($r in $resp.properties.rows) {
    $d = [string]$r[1]
    [pscustomobject]@{
        Date = "{0}-{1}-{2}" -f $d.Substring(0,4), $d.Substring(4,2), $d.Substring(6,2)
        Cost = [math]::Round([double]$r[0], 2)
    }
}
$rows | Sort-Object Date | Format-Table -AutoSize

$last7 = ($rows | Sort-Object Date | Select-Object -Last 7 | Measure-Object Cost -Sum).Sum
Write-Host ("Last 7 days total: `${0}" -f [math]::Round($last7,2))
Write-Host ("Last 7 days/day:   `${0}" -f [math]::Round($last7/7,2))
