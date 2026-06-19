$az = 'C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd'
$who = (& $az account show --query "{name:user.name,type:user.type}" -o json) | ConvertFrom-Json
Write-Host "Identity: $($who.name) ($($who.type))"
$cogt = (& $az account get-access-token --resource https://cognitiveservices.azure.com --query accessToken -o tsv)
$srct = (& $az account get-access-token --resource https://search.azure.com --query accessToken -o tsv)
Write-Host "cogTokenLen=$($cogt.Length) srchTokenLen=$($srct.Length)"

$tests = @(
  @{ n = 'Foundry openai/models (PUBLIC, authd)'; u = 'https://foundrygjmuxtm2g7vs4.openai.azure.com/openai/models?api-version=2024-10-21'; t = $cogt },
  @{ n = 'Search indexes (PUBLIC, authd)';        u = 'https://srchgjmuxtm2g7vs4.search.windows.net/indexes?api-version=2023-11-01';        t = $srct }
)
foreach ($x in $tests) {
  Write-Host "`n=== $($x.n) ==="
  try {
    $r = Invoke-WebRequest -Uri $x.u -Headers @{ Authorization = "Bearer $($x.t)" } -Method GET -TimeoutSec 25 -SkipHttpErrorCheck
    Write-Host "HTTP $($r.StatusCode)"
    $b = $r.Content
    if ($b.Length -gt 600) { $b = $b.Substring(0, 600) }
    Write-Host $b
  }
  catch {
    Write-Host "ERR: $($_.Exception.Message)"
  }
}
