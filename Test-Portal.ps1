param(
    [Parameter(Mandatory=$true)][string]$BaseUrl,
    [string]$ExpectedRelease = '',
    [switch]$CheckHealth
)
$ErrorActionPreference = 'Stop'
$page = Invoke-WebRequest -UseBasicParsing -Uri "$BaseUrl/" -TimeoutSec 10
if ($page.StatusCode -ne 200) { throw 'Portal HTTP status is not 200.' }
foreach ($text in @('QuickBite','Restaurant Details','Food Categories','Popular Menu Items',
                    'Margherita Pizza','Available',"Today's Special Offers",'Thank you for your order!')) {
    if (!$page.Content.Contains($text)) { throw "Missing portal content: $text" }
}
if ($ExpectedRelease) {
    $release = (Invoke-WebRequest -UseBasicParsing -Uri "$BaseUrl/release.txt" -TimeoutSec 10).Content.Trim()
    if ($release -ne $ExpectedRelease) { throw "Release mismatch: wanted $ExpectedRelease; received $release" }
}
if ($CheckHealth) {
    $health = Invoke-WebRequest -UseBasicParsing -Uri "$BaseUrl/health.html" -TimeoutSec 10
    if ($health.StatusCode -ne 200 -or $health.Content.Trim() -ne 'OK') { throw 'Health endpoint failed.' }
}
Write-Host "PASS: HTTP, portal content, release=$ExpectedRelease, health=$($CheckHealth.IsPresent)"
