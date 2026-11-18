// vision-gate on a macOS agent labelled 'xcode'. Same scripts as GitHub Actions.
pipeline {
  agent { label 'xcode' }
  options { timestamps(); timeout(time: 60, unit: 'MINUTES') }
  stages {
    stage('Toolchain') { steps { sh 'sw_vers && xcodebuild -version && swift --version' } }
    stage('Gates on macOS') { steps { sh 'scripts/ci/gates.sh' } }
    stage('Gates on iOS Simulator') { steps { sh 'scripts/ci/ios-sim.sh' } }
  }
  post { always { archiveArtifacts allowEmptyArchive: true, artifacts: 'build/reports/**' } }
}
