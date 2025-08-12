pipeline {
    options {
        buildDiscarder(logRotator(artifactDaysToKeepStr: '', artifactNumToKeepStr: '', daysToKeepStr: '5', numToKeepStr: '5'))
    }
    environment {
        MAINNET_RPC_URL = 'https://ethereum-rpc.publicnode.com'
        SEPOLIA_RPC_URL = 'https://ethereum-sepolia-rpc.publicnode.com'
        GIT_SHA = "${sh(returnStdout: true, script: 'echo ${GIT_COMMIT} | cut -c1-12').trim()}"
    }
    agent {
        node {
            label 'alpine1'
        }
    }
    stages {
        stage('Install') {
            parallel {
                stage('install') {
                    steps {
                        sh 'pnpm install'
                    }
                }
                stage('Debug') {
                    steps {
                        sh 'node --version'
                        sh 'npm --version'
                        sh 'yarn --version'
                        sh 'forge --version'
                        sh 'pre-commit --version'
                        sh 'printenv'
                        script {
                            def branchName = sh(returnStdout: true, script: 'git rev-parse --abbrev-ref HEAD').trim()
                            echo "The current branch name is: ${branchName}"
                            echo "GIT_SHA is: ${GIT_SHA}"
                        }
                    }
                }
            }
        }
        stage('Build and Test') {
            parallel {
                stage('forge') {
                    steps {
                        script {
                            sh 'sudo apk add jq'
                            withCredentials([gitUsernamePassword(credentialsId: 'github-token', usernameVariable: 'GIT_USERNAME', passwordVariable: 'GIT_PASSWORD')]) {
                                sh '''
                                    git config --global url."https://${GIT_USERNAME}:${GIT_PASSWORD}@github.com/".insteadOf "https://github.com/"
                                    forge soldeer install --recursive-deps --clean
                                    forge soldeer update
                                '''
                            }
                            sh "forge coverage --no-match-coverage='test/|script/' --ir-minimum --report lcov --report summary"
                            sh 'forge test -vvvv'
                        }
                    }
                }
                stage('lint') {
                    steps {
                        script {
                            sh 'pnpm run lint'
                        }
                    }
                }
            }
        }
    }
}
