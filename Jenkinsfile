pipeline {
    agent any
    options {
        timestamps()
        disableConcurrentBuilds()
        skipDefaultCheckout(true)
    }
    parameters {
        booleanParam(name: 'SIMULATE_FAULT', defaultValue: false,
            description: 'Remove health.html to demonstrate failed rollout and automatic recovery')
    }
    environment {
        DOCKER_IMAGE = 'abdulkalamay/online-food-ordering-portal'
    }
    stages {
        stage('1. Clone Code') {
            steps {
                git branch: 'main', url: 'https://github.com/ABDULKALAMAY/online-food-ordering-portal.git'
                script { env.IMAGE_TAG = "v2.0.${env.BUILD_NUMBER}" }
                powershell '''
                    if (Test-Path .release-state.json) { Remove-Item -LiteralPath .release-state.json }
                    docker version --format '{{.Server.Version}}'
                    if ($LASTEXITCODE -ne 0) { throw 'Docker Engine unavailable.' }
                '''
            }
        }
        stage('2. Build Versioned Image') {
            steps {
                powershell '''
                    $image = "$($env:DOCKER_IMAGE):$($env:IMAGE_TAG)"
                    docker build --build-arg "RELEASE_VERSION=$env:IMAGE_TAG" --build-arg "SIMULATE_FAULT=$env:SIMULATE_FAULT" -t $image .
                    if ($LASTEXITCODE -ne 0) { throw 'Image build failed.' }
                '''
            }
        }
        stage('3. Automated HTTP and Content Tests') {
            steps {
                powershell '& .\\Test-Image.ps1 -Image "$($env:DOCKER_IMAGE):$($env:IMAGE_TAG)" -Release $env:IMAGE_TAG'
            }
        }
        stage('4. Push to Docker Hub') {
            steps {
                withCredentials([usernamePassword(credentialsId: 'dockerhub', usernameVariable: 'DH_USER', passwordVariable: 'DH_TOKEN')]) {
                    powershell '''
                        $ErrorActionPreference = 'Stop'
                        $authDirectory = Join-Path $env:TEMP "jenkins-food-docker-$env:BUILD_NUMBER"
                        New-Item -ItemType Directory -Path $authDirectory -Force | Out-Null
                        try {
                            $token = $env:DH_TOKEN.Trim()
                            $username = $env:DH_USER.Trim()
                            if (!$token -or !$username) { throw 'Docker Hub credentials are empty.' }
                            # Isolate this build from credentials cached by the Windows service account.
                            $token | docker --config $authDirectory login --username $username --password-stdin
                            if ($LASTEXITCODE -ne 0) { throw 'Docker Hub login failed.' }
                            docker --config $authDirectory push "$($env:DOCKER_IMAGE):$($env:IMAGE_TAG)"
                            if ($LASTEXITCODE -ne 0) { throw 'Image push failed.' }
                        } finally {
                            $authFile = Join-Path $authDirectory 'config.json'
                            if (Test-Path -LiteralPath $authFile) { Remove-Item -LiteralPath $authFile }
                            if (Test-Path -LiteralPath $authDirectory) { Remove-Item -LiteralPath $authDirectory }
                        }
                    '''
                }
            }
        }
        stage('5. Deploy Inactive Colour') {
            steps {
                withCredentials([file(credentialsId: 'kuberconfig', variable: 'KUBECONFIG')]) {
                    powershell '& .\\Deploy-BlueGreen.ps1 -Action Prepare -Image "$($env:DOCKER_IMAGE):$($env:IMAGE_TAG)" -Release $env:IMAGE_TAG'
                }
            }
        }
        stage('6. Validate All Candidate Pods') {
            steps {
                withCredentials([file(credentialsId: 'kuberconfig', variable: 'KUBECONFIG')]) {
                    powershell '& .\\Deploy-BlueGreen.ps1 -Action Validate'
                }
            }
        }
        stage('7. Switch Traffic') {
            steps {
                withCredentials([file(credentialsId: 'kuberconfig', variable: 'KUBECONFIG')]) {
                    powershell '& .\\Deploy-BlueGreen.ps1 -Action Promote'
                }
            }
        }
        stage('8. Verify Live Application') {
            steps {
                withCredentials([file(credentialsId: 'kuberconfig', variable: 'KUBECONFIG')]) {
                    powershell '& .\\Deploy-BlueGreen.ps1 -Action Verify'
                }
            }
        }
    }
    post {
        failure {
            withCredentials([file(credentialsId: 'kuberconfig', variable: 'KUBECONFIG')]) {
                powershell '& .\\Deploy-BlueGreen.ps1 -Action Rollback'
            }
        }
        success { echo 'Release validated and promoted. NodePort: 30015.' }
    }
}
