param([Parameter(Mandatory=$true)][string]$Image)
$ErrorActionPreference = 'Stop'
$username = $env:DH_USER.Trim()
$token = $env:DH_TOKEN.Trim()
if (!$username -or !$token) { throw 'Docker Hub credentials are empty.' }
$authDirectory = Join-Path $env:TEMP ("jenkins-food-docker-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $authDirectory | Out-Null
try {
    # Authenticate directly with the registry, then provide a temporary Docker auth file.
    # This avoids Docker Desktop's login endpoint under the Windows LocalSystem account.
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${username}:$token"))
    $repository = ($Image -split ':')[0]
    $scope = [Uri]::EscapeDataString("repository:${repository}:pull,push")
    $response = Invoke-RestMethod -Uri "https://auth.docker.io/token?service=registry.docker.io&scope=$scope" -Headers @{Authorization="Basic $encoded"} -TimeoutSec 20
    if (!$response.token) { throw 'Docker Hub did not return an authentication token.' }
    $payload = $response.token.Split('.')[1].Replace('-','+').Replace('_','/')
    while ($payload.Length % 4) { $payload += '=' }
    $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
    $access = @($claims.access | Where-Object { $_.name -eq $repository })
    if (!$access -or $access[0].actions -notcontains 'push') { throw 'Docker Hub credential does not grant push access.' }
    Write-Host "Authenticating Docker Hub account: $username"
    Write-Host 'Docker Hub authentication and repository push permission verified.'
    $config = @{auths=@{'https://index.docker.io/v1/'=@{auth=$encoded}}} | ConvertTo-Json -Depth 6
    [IO.File]::WriteAllText((Join-Path $authDirectory 'config.json'), $config, (New-Object Text.UTF8Encoding($false)))
    $token = ''
    $ErrorActionPreference = 'Continue'
    $output = & docker --config $authDirectory push $Image 2>&1
    $pushCode = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    $output | ForEach-Object { Write-Host "$_" }
    if ($pushCode -ne 0) { throw 'Docker image push failed.' }
} finally {
    $token = ''
    $authFile = Join-Path $authDirectory 'config.json'
    if (Test-Path -LiteralPath $authFile) { Remove-Item -LiteralPath $authFile }
    if (Test-Path -LiteralPath $authDirectory) { Remove-Item -LiteralPath $authDirectory }
}
