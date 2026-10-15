param([Parameter(Mandatory=$true)][string]$Image,[Parameter(Mandatory=$true)][string]$Release)
$ErrorActionPreference='Stop'
$name='food-ordering-ci-test'
$existing = docker ps -aq --filter "name=^/$name$"
if ($existing) { docker rm -f $name | Out-Null }
try {
    docker run -d --name $name -p 18053:80 $Image
    if ($LASTEXITCODE -ne 0) { throw 'Could not start the image test container.' }
    $started=$false
    for ($i=0;$i -lt 20;$i++) {
        try {
            Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:18053/' -TimeoutSec 2 | Out-Null
            $started=$true; break
        } catch { Start-Sleep -Seconds 1 }
    }
    if (!$started) { throw 'Image did not start serving HTTP.' }
    # Main-page tests deliberately remain independent of Kubernetes readiness checks.
    # The fault simulation removes only health.html, allowing a failed-rollout demonstration.
    & "$PSScriptRoot/Test-Portal.ps1" -BaseUrl 'http://127.0.0.1:18053' -ExpectedRelease $Release
} finally {
    docker rm -f $name | Out-Null
}
