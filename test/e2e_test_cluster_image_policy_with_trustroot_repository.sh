#!/usr/bin/env bash
#
# Copyright 2022 The Sigstore Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.


set -ex

if [[ -z "${OIDC_TOKEN}" ]]; then
  if [[ -z "${ISSUER_URL}" ]]; then
    echo "Must specify either env variable OIDC_TOKEN or ISSUER_URL"
    exit 1
  else
    export OIDC_TOKEN=`curl -s ${ISSUER_URL}`
  fi
fi

if [[ -z "${KO_DOCKER_REPO}" ]]; then
  echo "Must specify env variable KO_DOCKER_REPO"
  exit 1
fi

if [[ -z "${FULCIO_URL}" ]]; then
  echo "Must specify env variable FULCIO_URL"
  exit 1
fi

if [[ -z "${REKOR_URL}" ]]; then
  echo "Must specify env variable REKOR_URL"
  exit 1
fi

if [[ -z "${TUF_ROOT_FILE}" ]]; then
  echo "must specify env variable TUF_ROOT_FILE"
  exit 1
fi

if [[ -z "${TUF_MIRROR}" ]]; then
  echo "must specify env variable TUF_MIRROR"
  exit 1
fi

if [[ "${NON_REPRODUCIBLE}"=="1" ]]; then
  echo "creating non-reproducible build by adding a timestamp"
  export TIMESTAMP=`date +%s`
else
  export TIMESTAMP="TIMESTAMP"
fi

# Initialize cosign with our TUF root
cosign initialize --mirror ${TUF_MIRROR} --root ${TUF_ROOT_FILE}

# To simplify testing failures, use this function to execute a kubectl to create
# our job and verify that the failure is expected.
assert_error() {
  local KUBECTL_OUT_FILE="/tmp/kubectl.failure.out"
  match="$@"
  echo looking for ${match}
  kubectl delete job demo -n ${NS} --ignore-not-found=true
  if kubectl create -n ${NS} job demo --image=${demoimage} 2> ${KUBECTL_OUT_FILE} ; then
    echo Failed to block expected Job failure!
    exit 1
  else
    echo Successfully blocked Job creation with expected error: "${match}"
    if ! grep -q "${match}" ${KUBECTL_OUT_FILE} ; then
      echo Did not get expected failure message, wanted "${match}", got
      cat ${KUBECTL_OUT_FILE}
      exit 1
    fi
  fi
}

# Publish test image
echo '::group:: publish test image demoimage'
pushd $(mktemp -d)
go mod init example.com/demo
cat <<EOF > main.go
package main
import "fmt"
func main() {
  fmt.Println("hello world TIMESTAMP")
}
EOF

sed -i'' -e "s@TIMESTAMP@${TIMESTAMP}@g" main.go
cat main.go
export demoimage=`ko publish -B example.com/demo`
echo Created image $demoimage
popd
echo '::endgroup::'

echo '::group:: Create and label new namespace for verification'
kubectl create namespace demo-trustroot-repository
kubectl label namespace demo-trustroot-repository policy.sigstore.dev/include=true
export NS=demo-trustroot-repository
echo '::endgroup::'

echo '::group:: Create CIP that requires keyless attestation with trustroot'
kubectl apply -f ./test/testdata/policy-controller/e2e/cip-keyless-with-trustroot-repository-with-attestations.yaml
# allow things to propagate
sleep 5
echo '::endgroup::'

echo '::group:: Create TrustRoot that specifies marshalled repository'
export ROOT_JSON=`kubectl -n tuf-system get secrets tuf-root -ojsonpath='{.data.root}'`
export REPOSITORY=`kubectl -n tuf-system get secrets tuf-root -ojsonpath='{.data.repository}'`

sed -i'' -e "s@ROOT_JSON@${ROOT_JSON}@g" ./test/testdata/trustroot/e2e/with-repository.yaml
sed -i'' -e "s@REPOSITORY@${REPOSITORY}@g" ./test/testdata/trustroot/e2e/with-repository.yaml
kubectl apply -f ./test/testdata/trustroot/e2e/with-repository.yaml

# allow things to propagate
sleep 5
echo '::endgroup::'

# This image has no attestation, so should fail
echo '::group:: test job rejection'
expected_error='no matching attestations'
assert_error ${expected_error}
echo '::endgroup::'

# Create an attestation but do not add it to Rekor and since our attestation
# specifies Rekor, this should still fail
echo '::group:: Create one keyless attestation and verify it, but no tlog upload'
echo -n 'foobar e2e test' > ./predicate-file-custom
COSIGN_EXPERIMENTAL=1 cosign attest --predicate ./predicate-file-custom --fulcio-url ${FULCIO_URL} --allow-insecure-registry ${demoimage} --no-tlog-upload --identity-token `curl $ISSUER_URL`
COSIGN_EXPERIMENTAL=1 cosign verify-attestation --type=custom --rekor-url= --allow-insecure-registry ${demoimage}
echo '::endgroup::'

# This image has an attestation, but was not added to TLog
echo '::group:: test job rejection'
expected_error='No leaf found for hash'
assert_error ${expected_error}
echo '::endgroup::'

# Create attestation and upload to tlog and it should now pass.
echo '::group:: Create one keyless attestation and verify it'
COSIGN_EXPERIMENTAL=1 cosign attest --predicate ./predicate-file-custom --fulcio-url ${FULCIO_URL} --rekor-url ${REKOR_URL} --allow-insecure-registry --yes ${demoimage} --identity-token ${OIDC_TOKEN}

COSIGN_EXPERIMENTAL=1 cosign verify-attestation --type=custom --rekor-url ${REKOR_URL} --allow-insecure-registry ${demoimage}
echo '::endgroup::'

echo '::group:: test job success'
# This now has a keyless attestation, so should pass.
export KUBECTL_SUCCESS_FILE="/tmp/kubectl.success.out"
if ! kubectl create -n ${NS} job demo --image=${demoimage} 2> ${KUBECTL_SUCCESS_FILE} ; then
  echo Failed to create job with keyless signature and an attestation
  cat ${KUBECTL_SUCCESS_FILE}
  exit 1
else
  echo Created the job with keyless signature and an attestation
fi
kubectl delete -n ${NS} job demo
echo '::endgroup::'


echo '::group::' Cleanup
kubectl delete cip --all
kubectl delete trustroot --all
kubectl delete ns ${NS}
echo '::endgroup::'
