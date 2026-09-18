// Jenkins pipeline -- build the Win11 WebEdition developer VM in the vmbuilder container, SANITIZE
// it, and publish the OVA to GHCR (ghcr.io/tcp-software/win11-ova).
//
// Mirrors clockware-toolchains/Jenkinsfile: a Docker-capable agent, the 'tcp-ci' Secret-text GHCR
// PAT, a PUBLISH parameter, cleanWs() on completion. Publishing is GATED end to end:
//   build-vm.sh --sanitize  removes the clear-text GitHub NuGet token and REFUSES to export if a
//                           GitHub token or AWS key is still in the image, writing '<ova>.sanitized'.
//   publish-ova.sh          REFUSES to push unless that '<ova>.sanitized' marker is present.
// So an un-sanitized OVA -- which contains the build's GitHub PAT -- can never reach ghcr.
// Cloned private repos + the restored test DB are intentionally kept in the published image.
//
// CREDENTIALS / GHCR ACCOUNT
//   tcp-ci  (Secret text) -- the GHCR PAT (classic, write:packages/read:packages). Used for BOTH
//           the private-repo clone inside the guest (GH_TOKEN) and the GHCR push (GHCR_PAT). GHCR
//           rejects the gh OAuth token, GitHub App tokens, and SSH keys -- it must be a PAT.
//           Authenticates as the oosman-tcps GitHub account (GHCR_USER / GH_USER).
//
// AGENT SETUP: a node labelled 'Win11-Build-Machine' with:
//   - Docker usable by the Jenkins user (no sudo), and the vmbuilder image pullable from ghcr;
//   - the VirtualBox kernel module loaded (/dev/vboxdrv present) and the Jenkins user in vboxusers;
//   - a big writable data disk (default paths under /data + /mnt/data);
//   - a FAST, stable uplink (the OVA is ~80 GB; publishing over a slow link takes many hours).
//   Point WIN11_ISO / WIN11_CFG at a local Win11 ISO + cfg.zip (both providing them skips ghcr
//   pulls for those artifacts; the ISO must include the Windows 11 Pro edition).

pipeline {
    agent { label 'Win11-Build-Machine' }

    options {
        // One heavy VM build at a time on the agent (the container build + a Windows install +
        // toolchain easily saturate CPU/RAM/disk).
        lock(resource: 'win11-vm-build')
        // Windows install + full toolchain + clone + server build + DB restore + a ~80 GB export.
        timeout(time: 6, unit: 'HOURS')
    }

    parameters {
        booleanParam(name: 'PUBLISH', defaultValue: true,
                     description: 'Push the sanitized OVA to ghcr.io/tcp-software/win11-ova:latest')
        string(name: 'STOP_AT', defaultValue: 'all',
               description: 'build-vm.sh --stop-at stage (all = clone+build+db+servers; a publishable image needs all)')
    }

    environment {
        EXPORT_DIR = "${env.WIN11_EXPORT_DIR ?: '/data/win11vbox-vm'}"
        WIN11_ISO  = "${env.WIN11_ISO ?: '/data/downloads/Win11_25H2_English_x64_v2.iso'}"
        WIN11_CFG  = "${env.WIN11_CFG ?: '/data/downloads/cfg.zip'}"
        GHCR_REF   = 'ghcr.io/tcp-software/win11-ova:latest'
        // GHCR + git identity; the PAT itself comes from the 'tcp-ci' Secret-text credential.
        GHCR_USER  = 'oosman-tcps'
        GH_USER    = 'oosman-tcps'
    }

    stages {
        stage('Checkout') {
            steps { checkout scm }
        }

        stage('Build + sanitize + export') {
            steps {
                // GH_TOKEN = the PAT: used for the private clone inside the guest AND to
                // docker-login ghcr for the vmbuilder image pull.
                withCredentials([string(credentialsId: 'tcp-ci', variable: 'GH_TOKEN')]) {
                    sh '''
                        set -e
                        ./build-vm.sh --unattended --container --clean \
                            --stop-at "${STOP_AT}" \
                            --iso "${WIN11_ISO}" --cfg "${WIN11_CFG}" \
                            --export "${EXPORT_DIR}" --sanitize
                    '''
                }
            }
        }

        stage('Publish OVA') {
            when { expression { return params.PUBLISH } }
            steps {
                // GHCR_PAT = the same PAT, for the oras push. publish-ova.sh enforces the
                // '<ova>.sanitized' gate before it will upload.
                withCredentials([string(credentialsId: 'tcp-ci', variable: 'GHCR_PAT')]) {
                    sh 'EXPORT_DIR="${EXPORT_DIR}" GHCR_REF="${GHCR_REF}" GHCR_USER="${GHCR_USER}" ./publish-ova.sh'
                }
            }
        }
    }

    post {
        always {
            // Keep the host transcript for post-mortems; the OVA itself stays on the data disk.
            archiveArtifacts artifacts: '.logs/latest.log', allowEmptyArchive: true, fingerprint: false
            cleanWs()
        }
    }
}
