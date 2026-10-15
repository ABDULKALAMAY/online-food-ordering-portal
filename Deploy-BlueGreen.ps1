param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('Prepare','Validate','Promote','Verify','Rollback')][string]$Action,
    [string]$Image = '',
    [string]$Release = '',
    [int]$RolloutTimeout = 90
)
$ErrorActionPreference = 'Stop'
$service = 'food-ordering-service'
$app = 'food-ordering-portal'
$container = 'food-ordering-portal'
$statePath = Join-Path $PSScriptRoot '.release-state.json'
function Kube {
    $arguments = $args
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $lines = & kubectl @arguments 2>&1
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $oldPreference }
    $text = ($lines | ForEach-Object { "$_" }) -join "`n"
    if ($code -ne 0) { throw "kubectl $($arguments -join ' ') failed ($code):`n$text" }
    return $text
}
function Save-State($value) {
    $value | ConvertTo-Json -Depth 30 | Set-Content -Path $statePath -Encoding UTF8
}
function Set-Traffic($color) {
    $patch = @{spec=@{selector=@{app=$app;version=$color}}}
    $patch | ConvertTo-Json -Depth 10 | Set-Content -Path '.release-service-patch.json' -Encoding UTF8
    Write-Host (Kube patch service $service --type merge --patch-file '.release-service-patch.json')
}
function Check-Service($expectedRelease) {
    # Each check creates a new connection, avoiding a forward pinned to an old Pod.
    $kubectlPath = (Get-Command kubectl -ErrorAction Stop).Source
    $forward = Start-Process -FilePath $kubectlPath -ArgumentList @('port-forward',"service/$service",'18054:80','--address=127.0.0.1') -WindowStyle Hidden -PassThru -RedirectStandardOutput '.release-forward.out' -RedirectStandardError '.release-forward.err'
    try {
        $up = $false
        for ($i=0; $i -lt 25; $i++) {
            if ($forward.HasExited) { throw 'Service port forwarding stopped.' }
            try {
                $page = Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:18054/' -TimeoutSec 2
                if ($page.StatusCode -eq 200 -and $page.Content.Contains('QuickBite')) { $up=$true; break }
            } catch { Start-Sleep -Seconds 1 }
        }
        if (!$up) { throw 'Service HTTP test failed.' }
        if ($expectedRelease) {
            $actual = (Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:18054/release.txt' -TimeoutSec 5).Content.Trim()
            if ($actual -ne $expectedRelease) { throw "Live Service returned $actual instead of $expectedRelease" }
        }
        Write-Host "PASS: active Service returns QuickBite; expected release=$expectedRelease"
    } finally {
        if (!$forward.HasExited) { Stop-Process -Id $forward.Id -Force }
    }
}
if ($Action -eq 'Prepare') {
    if (!$Image -or !$Release) { throw 'Prepare requires Image and Release.' }
    $svc = (Kube get service $service -o json) | ConvertFrom-Json
    $active = $svc.spec.selector.version
    if ($active -notin @('blue','green')) { throw "Unexpected active color: $active" }
    $candidate = if ($active -eq 'blue') { 'green' } else { 'blue' }
    $activeName = if ($active -eq 'blue') { $app } else { 'food-ordering-green' }
    $candidateName = if ($candidate -eq 'blue') { $app } else { 'food-ordering-green' }
    Write-Host (Kube rollout status "deployment/$activeName" --timeout=60s)
    $activeDeployment = (Kube get deployment $activeName -o json) | ConvertFrom-Json
    if ($activeDeployment.status.readyReplicas -ne 3) { throw 'The active release must have 3 ready replicas.' }
    $prior = Kube get deployment $candidateName --ignore-not-found=true -o json
    $priorRevision = ''
    if ($prior.Trim()) {
        $old = $prior | ConvertFrom-Json
        $priorRevision = $old.metadata.annotations.'deployment.kubernetes.io/revision'
    }
    $state = [pscustomobject]@{
        ActiveColor=$active; ActiveDeployment=$activeName;
        ActiveImage=$activeDeployment.spec.template.spec.containers[0].image;
        CandidateColor=$candidate; CandidateDeployment=$candidateName;
        PreviousCandidateRevision=$priorRevision; Release=$Release; Image=$Image; Switched=$false
    }
    Save-State $state
    $probe = @{httpGet=@{path='/health.html';port=80};initialDelaySeconds=3;periodSeconds=3;timeoutSeconds=2;failureThreshold=2}
    $deployment = @{
        apiVersion='apps/v1';kind='Deployment';metadata=@{name=$candidateName};
        spec=@{
            replicas=3;revisionHistoryLimit=6;progressDeadlineSeconds=60;
            strategy=@{type='RollingUpdate';rollingUpdate=@{maxSurge=1;maxUnavailable=0}};
            selector=@{matchLabels=@{app=$app;version=$candidate}};
            template=@{metadata=@{labels=@{app=$app;version=$candidate};annotations=@{'assessment/release'=$Release}};
                spec=@{containers=@(@{name=$container;image=$Image;imagePullPolicy='IfNotPresent';
                    ports=@(@{containerPort=80});readinessProbe=$probe;
                    livenessProbe=@{httpGet=@{path='/health.html';port=80};initialDelaySeconds=15;periodSeconds=5;timeoutSeconds=2;failureThreshold=3}})}}
        }
    }
    $deployment | ConvertTo-Json -Depth 30 | Set-Content -Path '.release-candidate.json' -Encoding UTF8
    Write-Host "ACTIVE=$active ($($state.ActiveImage)); CANDIDATE=$candidate ($Image). Public traffic stays on $active."
    Write-Host (Kube apply -f '.release-candidate.json')
    Write-Host (Kube rollout status "deployment/$candidateName" "--timeout=$($RolloutTimeout)s")
    exit 0
}
if (!(Test-Path $statePath)) {
    if ($Action -eq 'Rollback') { Write-Host 'No deployment was attempted; active traffic is unchanged.'; exit 0 }
    throw 'No release state file. Run Prepare first.'
}
$state = Get-Content -Raw $statePath | ConvertFrom-Json
switch ($Action) {
    'Validate' {
        $pods = ((Kube get pods -l "app=$app,version=$($state.CandidateColor)" -o json) | ConvertFrom-Json).items
        $ready = @($pods | Where-Object { !$_.metadata.deletionTimestamp -and $_.status.phase -eq 'Running' -and @($_.status.containerStatuses | Where-Object { !$_.ready }).Count -eq 0 })
        if ($ready.Count -ne 3) { throw "Expected 3 ready candidate Pods, got $($ready.Count)." }
        foreach ($pod in $ready) {
            $name=$pod.metadata.name
            $page=Kube exec $name '--' wget -qO- http://127.0.0.1/
            foreach ($required in @('QuickBite','Restaurant Details','Food Categories','Popular Menu Items','Thank you for your order!')) {
                if (!$page.Contains($required)) { throw "Candidate $name is missing $required" }
            }
            if ((Kube exec $name '--' wget -qO- http://127.0.0.1/health.html).Trim() -ne 'OK') { throw "Health check failed for $name" }
            if ((Kube exec $name '--' wget -qO- http://127.0.0.1/release.txt).Trim() -ne $state.Release) { throw "Wrong release on $name" }
            Write-Host "PASS: validated candidate Pod $name before traffic switch."
        }
    }
    'Promote' {
        Set-Traffic $state.CandidateColor
        $state.Switched=$true
        Save-State $state
        Start-Sleep -Seconds 3
        Check-Service $state.Release
        Write-Host "PROMOTED: public Service now selects $($state.CandidateColor)."
    }
    'Verify' {
        Write-Host (Kube get deployments $state.ActiveDeployment $state.CandidateDeployment)
        Write-Host (Kube get pods -l "app=$app" -o wide)
        Write-Host (Kube get service $service -o wide)
        Write-Host (Kube get endpointslices -l "kubernetes.io/service-name=$service")
        Check-Service $state.Release
    }
    'Rollback' {
        Set-Traffic $state.ActiveColor
        Write-Host (Kube rollout status "deployment/$($state.ActiveDeployment)" --timeout=60s)
        if ($state.PreviousCandidateRevision) {
            Write-Host (Kube rollout undo "deployment/$($state.CandidateDeployment)" "--to-revision=$($state.PreviousCandidateRevision)")
            Write-Host (Kube rollout status "deployment/$($state.CandidateDeployment)" --timeout=90s)
        } else {
            Write-Host (Kube scale "deployment/$($state.CandidateDeployment)" --replicas=0)
        }
        Check-Service ''
        Write-Host "ROLLBACK SUCCESS: traffic is on $($state.ActiveColor), stable image $($state.ActiveImage)."
        Write-Host (Kube get service $service -o wide)
        Write-Host (Kube get pods -l "app=$app,version=$($state.ActiveColor)")
    }
}
