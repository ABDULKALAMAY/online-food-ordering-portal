param([Parameter(Mandatory=$true)][string]$Image)
$ErrorActionPreference = 'Stop'
$username = $env:DH_USER.Trim()
$token = $env:DH_TOKEN.Trim()
if (!$username -or !$token) { throw 'Docker Hub credentials are empty.' }
$authDirectory = Join-Path $env:TEMP ("jenkins-food-docker-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $authDirectory | Out-Null
try {
    # Feed credentials directly to the process, independently of PowerShell's pipeline host.
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = (Get-Command docker -ErrorAction Stop).Source
    $start.Arguments = "--config `"$authDirectory`" login --username `"$username`" --password-stdin"
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $login = New-Object System.Diagnostics.Process
    $login.StartInfo = $start
    Write-Host "Authenticating Docker Hub account: $username"
    $null = $login.Start()
    $stdin = New-Object System.IO.StreamWriter($login.StandardInput.BaseStream, (New-Object System.Text.UTF8Encoding($false)))
    $stdin.Write($token)
    $stdin.Dispose()
    $stdout = $login.StandardOutput.ReadToEnd()
    $stderr = $login.StandardError.ReadToEnd()
    $login.WaitForExit()
    if ($stdout) { Write-Host $stdout.Trim() }
    if ($stderr) { Write-Host $stderr.Trim() }
    if ($login.ExitCode -ne 0) { throw 'Docker Hub login failed.' }
    $login.Dispose()
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
