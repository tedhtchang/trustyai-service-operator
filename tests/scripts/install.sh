#!/bin/bash

echo "Installing DSC from test directory"
DSC_FILENAME=odh-core-dsc.yaml
HEADER="=============="

## Install the opendatahub-operator
pushd ~/peak
retry=5
if ! [ -z "${SKIP_OPERATOR_INSTALL}" ]; then
    ## SKIP_OPERATOR_INSTALL is used in the opendatahub-operator repo
    ## because openshift-ci will install the operator for us
    echo "Relying on odh operator installed by openshift-ci"
    ./setup.sh -t ~/peak/operatorsetup 2>&1
else
  echo
  echo "$HEADER Verifying Cluster Readiness $HEADER"
  echo -n "Waiting for catalog sources to appear..."

  start_t=$(date +%s) 2>&1
  ready=false 2>&1
  while ! $ready; do
    CATALOG_SOURCES=$(oc get catalogsources -n openshift-marketplace 2> /dev/null | grep 'community-operators')
    if [ ! -z "${CATALOG_SOURCES}" ]; then
      echo $CATALOG_SOURCES
      ready=true 2>&1
    else
      sleep 10
    fi
    if [ $(($(date +%s)-start_t)) -gt 300 ]; then
      echo "ERROR: Marketplace pods never started"
      exit 1
    fi
  done
  echo "[DONE]"

  echo -n "Waiting for ODH package manifests to download..."
  start_t=$(date +%s) 2>&1
  ready=false 2>&1
  while ! $ready; do
    MANIFESTS=$(oc get packagemanifests -n openshift-marketplace 2> /dev/null | grep 'opendatahub')
    echo $MANIFESTS
    if [ ! -z "${MANIFESTS}" ]; then
      echo $MANIFESTS
      ready=true 2>&1
    else
      sleep 10
    fi
    if [ $(($(date +%s)-start_t)) -gt 900 ]; then
      echo "ERROR: Package manifests never downloaded"
      exit 1
    fi
  done
  echo "[DONE]"

  echo
  echo "$HEADER Starting Operator Installation $HEADER"
  while [[ $retry -gt 0 ]]; do
    ./setup.sh -o ~/peak/operatorsetup\

    # approve installplans
    if [ $? -eq 0 ]; then
      retry=-1
    else
      echo "Trying restart of marketplace community operator pod"
      oc delete pod -n openshift-marketplace $(oc get pod -n openshift-marketplace -l marketplace.operatorSource=community-operators -o jsonpath="{$.items[*].metadata.name}")
      sleep 3m
    fi
    retry=$(( retry - 1))

    sleep 30
    echo "Approving Install Plans, if needed"
    oc patch installplan $(oc get installplan -n openshift-operators | grep $ODH_VERSION | awk '{print $1}') -n openshift-operators --type merge --patch '{"spec":{"approved":true}}' || true
    oc patch installplan $(oc get installplan -n openshift-operators | grep authorino | awk '{print $1}') -n openshift-operators --type merge --patch '{"spec":{"approved":true}}' || true

    echo
    echo "$HEADER Verifying Operator Installation $HEADER"
    for operator in opendatahub-operator authorino-operator knative-operator knative-openshift istio-operator; do
      echo -n "Checking $operator readiness..."
      finished=false 2>&1
      start_t=$(date +%s) 2>&1
      while ! $finished; do
          if [ ! -z "$(oc get pods -n openshift-operators  | grep $operator | grep '1/1')" ]; then
            echo "[DONE]"
            finished=true 2>&1
          else
            sleep 10
          fi

          if [ $(($(date +%s)-start_t)) -gt 300 ]; then
            echo "ERROR: $operator installation timeout, exiting test"
            exit 1
          fi
      done
    done

  done
fi

popd
## Point manifests repo uri in the KFDEF to the manifests in the PR
pushd ~/kfdef

if [ -z "$PULL_NUMBER" ] || [ $REPO_OWNER != "trustyai-explainability" ] || [ $REPO_NAME != "trustyai-service-operator" ]; then
  echo "No pull number and/or workflow is not originating from the original repo: using default ${DSC_FILENAME}"
  sed -i "s#trustyaiRepoPlaceholder#https://github.com/trustyai-explainability/trustyai-service-operator/tarball/main#" ./${DSC_FILENAME}
else
  echo "Setting TrustyAI devflags to use PR image"
  BRANCH_SHA=$(curl  https://api.github.com/repos/trustyai-explainability/trustyai-service-operator/pulls/${PULL_NUMBER} | jq ".head.sha"  | tr -d '"')
  sed -i "s#trustyaiRepoPlaceholder#https://api.github.com/repos/trustyai-explainability/trustyai-service-operator-ci/tarball/operator-${BRANCH_SHA}#" ./${DSC_FILENAME}
fi

if [ -z "${OPENSHIFT_TESTUSER_NAME}" ] || [ -z "${OPENSHIFT_TESTUSER_PASS}" ]; then
  OAUTH_PATCH_TEXT="$(cat $HOME/peak/operator-tests/trustyai-explainability/resources/oauth-patch.htpasswd.json)"
  echo "Creating HTPASSWD OAuth provider"
  oc apply -f $HOME/peak/operator-tests/trustyai-explainability/resources/htpasswd.secret.yaml

  # Test if any oauth identityProviders exists. If not, initialize the identityProvider list
  if ! oc get oauth cluster -o json | jq -e '.spec.identityProviders' ; then
    echo 'No oauth identityProvider exists. Initializing oauth .spec.identityProviders = []'
    oc patch oauth cluster --type json -p '[{"op": "add", "path": "/spec/identityProviders", "value": []}]'
  fi

  # Patch in the htpasswd identityProvider prevent deletion of any existing identityProviders like ldap
  #  We can have multiple identityProvdiers enabled aslong as their 'name' value is unique
  oc patch oauth cluster --type json -p '[{"op": "add", "path": "/spec/identityProviders/-", "value": '"$OAUTH_PATCH_TEXT"'}]'

  export OPENSHIFT_TESTUSER_NAME=admin
  export OPENSHIFT_TESTUSER_PASS=admin
fi


if ! [ -z "${SKIP_DSC_INSTALL}" ]; then
  ## SKIP_DSC_INSTALL is useful in an instance where the
  ## operator install comes with an init container to handle
  ## the DSC creation
  echo "Relying on existing DSC because SKIP_DSC_INSTALL was set"
else


  echo
  echo "$HEADER Installing ODH DSC and DSCI $HEADER"
  cat ./${DSC_FILENAME} > ${ARTIFACT_DIR}/${DSC_FILENAME}

  start_t=$(date +%s) 2>&1
  ready=1 2>&1
  while [ "$ready" -ne 0 ]; do
    oc apply -f ./odh-core-dsci.yaml
    oc apply -f ./${DSC_FILENAME}
    ready=$?
    if [ $(($(date +%s)-start_t)) -gt 300 ]; then
        echo "ERROR: ODH DSC Installation timeout"
        exit 1
    fi
    sleep 10
  done

  if [ "$ready" -ne 0 ]; then
    echo "ERROR: The installation failed"
    exit $ready
  fi
fi 
set +x
popd
