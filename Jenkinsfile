pipeline {
    agent any

    options {
        disableConcurrentBuilds()
        timeout(time: 45, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '10'))
    }

    environment {
        AWS_DEFAULT_REGION    = 'ap-south-1'
        AWS_ACCESS_KEY_ID     = credentials('aws-access-key-id')
        AWS_SECRET_ACCESS_KEY = credentials('aws-secret-access-key')
        ECR_REPO = 'expense-tracker'
        CLUSTER  = 'expense-cluster'
        SERVICE  = 'expense-api'
        FAMILY   = 'expense-api'
    }

    stages {
        stage('Prepare') {
            steps {
                script {
                    def sha = sh(returnStdout: true, script: 'git rev-parse --short=7 HEAD').trim()
                    def account = sh(returnStdout: true, script: 'aws sts get-caller-identity --query Account --output text').trim()
                    env.TAG = "${env.BUILD_NUMBER}-${sha}"
                    env.ECR_REGISTRY = "${account}.dkr.ecr.${env.AWS_DEFAULT_REGION}.amazonaws.com"
                    env.ECR_URI = "${env.ECR_REGISTRY}/${env.ECR_REPO}"
                }
                echo "Image will be ${env.ECR_URI}:${env.TAG}"
            }
        }

        stage('Test') {
            steps {
                sh '''
                    python3 -m venv "$WORKSPACE/.venv"
                    . "$WORKSPACE/.venv/bin/activate"
                    pip install --quiet -r requirements.txt
                    python -m pytest
                '''
            }
        }

        stage('Build image') {
            steps {
                sh 'docker build --pull -t $ECR_URI:$TAG .'
            }
        }

        stage('Security scan') {
            steps {
                sh '''
                    trivy image --no-progress --scanners vuln --severity HIGH,CRITICAL --exit-code 0 $ECR_URI:$TAG
                    trivy image --no-progress --scanners vuln --severity CRITICAL --ignore-unfixed --exit-code 1 $ECR_URI:$TAG
                '''
            }
        }

        stage('Push to ECR') {
            steps {
                sh '''
                    aws ecr get-login-password | docker login --username AWS --password-stdin $ECR_REGISTRY
                    docker push $ECR_URI:$TAG
                '''
            }
        }

        stage('Deploy to ECS') {
            steps {
                sh 'bash scripts/deploy.sh'
            }
        }

        stage('Smoke test') {
            steps {
                sh 'bash scripts/smoke-test.sh'
            }
            post {
                failure {
                    echo 'Smoke test failed. Rolling back.'
                    sh 'bash scripts/rollback.sh'
                }
            }
        }
    }

    post {
        success { echo "Released ${env.ECR_URI}:${env.TAG}" }
        failure { echo 'Pipeline failed. Open the red stage and read its log.' }
        always  { sh 'docker logout $ECR_REGISTRY || true' }
    }
}
