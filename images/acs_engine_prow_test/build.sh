#!/bin/bash

set -o pipefail
set -x
set -e

OUTPUT_DIR=$HOME/output
mkdir ${OUTPUT_DIR}
OUTPUT_FILE=${OUTPUT_DIR}/build-log.txt
exec &> >(tee -a ${OUTPUT_FILE})

AZ_RG_NAME=${JOB_NAME}-${PROW_JOB_ID}
AZ_DEPLOYMENT_NAME=prow-${PROW_JOB_ID}

GS_BUCKET=${GS_BUCKET:-"gs://e2e-win-acs-engine"}
GS_BUCKET_FULL_PATH=${GS_BUCKET}/${REPO_NAME}_${REPO_OWNER}/${PULL_NUMBER}/${JOB_NAME}/${PROW_JOB_ID}/${BUILD_NUMBER}

ACS_GENERATE_DIR_REGEX="acs*"
ACS_API_MODEL_FILES=("kubernetes.json" "apimodel.json")
ACS_API_MODEL_SENSITIVE_KEYS=("secret" "clientId" "keyData" "clientPrivateKey" "caCertificate" "etcdServerPrivateKey" \
                              "apiServerCertificate" "clientCertificate" "etcdClientPrivateKey" "etcdServerCertificate" \
                              "caPrivateKey" "etcdClientCertificate" "etcdPeerCertificates" "etcdPeerPrivateKeys" "kubeConfigPrivateKey" \
                              "apiServerPrivateKey" "kubeConfigCertificate")

function redact_file {
    # redact sensitive information from the logs ( i.e clientSecret / clientId etc )
    for key in ${ACS_API_MODEL_SENSITIVE_KEYS[@]}; do
          sed -i "/\"${key}\": \[/,+2d" $1
          sed -i "/${key}/d" $1
    done
}

function copy_acs_engine_logs {
    # we use a regex here, not really pretty, but it will work since we know for a fact it's the only dir to match.
    # kubetest generates logs in a tempdir with the form acs[0-9]+
    pushd ${ACS_GENERATE_DIR_REGEX}
    for file in ${ACS_API_MODEL_FILES[@]}; do
            # first redact, then copy. If redating fails for some reason, the logs will end up on the server in clear
            # since pushing logs is automatic on exit
            redact_file $file
            cp $file $OUTPUT_DIR
    done
    popd
}

function upload_results {

    # Uploading results
    echo "Uploading results"
    gsutil cp -r ${OUTPUT_DIR} ${GS_BUCKET_FULL_PATH}

}

trap "upload_results" EXIT


REPO=${REPO:-"http://github.com/Azure/acs-engine"}
BRANCH=${BRANCH:-"master"}

function prepare_repo {

    git config --global user.email "e2e-win@xample.com"
    git config --global user.name "Prow Job Bot"
    git clone $REPO $ACS_DIR
    cd $ACS_DIR
    git checkout $BRANCH

    if [ "${JOB_TYPE}" == "presubmit" ]
    then
        # this is a pull request and we should pull the specific ref
        git fetch origin pull/$PULL_NUMBER/head:pr/$PULL_NUMBER
        git merge --no-ff --m "PR to test #${PULL_NUMBER}" pr/$PULL_NUMBER
    fi
    git status
}

# Init gcloud

gcloud auth activate-service-account --key-file=${GOOGLE_APPLICATION_CREDENTIALS}

ACS_DIR=${GOPATH}/src/github.com/Azure/acs-engine
mkdir -p $ACS_DIR

prepare_repo

# install glide
go get github.com/Masterminds/glide

# build acs-engine
echo "Installing dependencies"
glide install
echo "Building acs-engine"
make build

# Add acs-engine build dir to path

PATH=$PATH:${ACS_DIR}/bin

acs-engine version

# Download kubetest from latest win-e2e-build

KUBETEST_URL="https://k8swin.blob.core.windows.net/k8s-windows/testing/kubetest/kubetest_latest/kubetest"
wget https://k8swin.blob.core.windows.net/k8s-windows/testing/kubetest/kubetest_latest/kubetest -P $HOME
KUBETEST=${HOME}/kubetest
chmod +x ${KUBETEST}

# Clone kubernetes

KUBE_REPO=${KUBE_REPO:-"http://github.com/e2e-win/kubernetes"}
KUBE_DIR=${GOPATH}/src/k8s.io/kubernetes
mkdir -p $KUBE_DIR

git clone $KUBE_REPO $KUBE_DIR
cd $KUBE_DIR

# Building tests, ginkgo and kubectl
# Normally kubetest would build all k8s, but since we only need these components
# it's much faster to build by hand.

make WHAT="test/e2e/e2e.test cmd/kubectl vendor/github.com/onsi/ginkgo/ginkgo"


# Run kubetest
# Note environment variables are set by the prow job
echo "Running kubetest"


# TO DO (atuvenie): hyperkube and zip should be passed as params

${KUBETEST} --deployment=acsengine --provider=azure --test=true --up=true --down=false --ginkgo-parallel=12 --acsengine-resource-name=${AZ_DEPLOYMENT_NAME} --acsengine-agentpoolcount=4 --acsengine-resourcegroup-name=${AZ_RG_NAME} --acsengine-admin-password=Passw0rdAdmin --acsengine-admin-username=azureuser --acsengine-orchestratorRelease=1.11 --acsengine-hyperkube-url=atuvenie/hyperkube-amd64:1011960828217266176 --acsengine-win-binaries-url=https://k8szipstorage.blob.core.windows.net/mystoragecontainer/1011960828217266176.zip --acsengine-creds=$AZURE_CREDENTIALS --acsengine-public-key=$AZURE_SSH_PUBLIC_KEY_FILE --acsengine-winZipBuildScript=$WIN_BUILD --acsengine-location=westus2 --test_args="--ginkgo.dryRun=false --ginkgo.noColor --ginkgo.focus=\\[Conformance\\]|\\[NodeConformance\\]"