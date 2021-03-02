#!/usr/bin/env bash
# SFDC dependencies for aquiva buildpack

source $BP_DIR/lib/lib.sh
source $BP_DIR/lib/deps.sh

sfdx_create_scratch() {
  log "Creating scratch org ..."
  USERNAME=${1:-}
  ALIAS=${2:-}

  sfdx force:org:create \
    -v "$USERNAME" \
    -a "$ALIAS" \
    -f ./config/project-scratch-def.json \
    -c
}

sfdx_source_push() {
  log "Pushing source to the scratch ..."
  ALIAS=${1:-}
  DEVHUB_USERNAME=${2:-}

  handle_errors \
    "$ALIAS" \
    "$DEVHUB_USERNAME"

  sfdx force:source:push \
    -u "$ALIAS"
}

sfdx_run_test() {
  log "Running org tests ..."
  ALIAS=${1:-}
  DEVHUB_USERNAME=${2:-}

  handle_errors \
    "$ALIAS" \
    "$DEVHUB_USERNAME"

  ORG_TESTS=$(get_org_tests $ALIAS)

  if [[ ! "$STAGE" == "DEV" || ! "$ORG_TESTS" == "[]" ]]; then
    sfdx force:apex:test:run \
      -u "$ALIAS" \
      --verbose \
      -r human \
      -w 1000 \
      -y
  fi
}

sfdx_delete_scratch() {
  log "Removing scratch org ..."
  ALIAS=${1:-}
  USERNAME=${2:-}

  sfdx force:org:delete \
    -v "$USERNAME" \
    -u "$ALIAS" \
    -p
}

get_org_tests() {
  ALIAS=${1:-}

  SCRATCH_INFO="$(sfdx force:org:display -u $ALIAS --verbose --json)"
  SCRATCH_TOKEN=$(jq -r '.result.accessToken?' <<< $SCRATCH_INFO)
  SCRATCH_URL=$(jq -r '.result.instanceUrl?' <<< $SCRATCH_INFO)

  TEST_INFO="$(curl $SCRATCH_URL/_ui/common/apex/test/ApexTestQueueServlet \
    -X POST -d "action=GET_TESTS" \
    -H "content-type: application/x-www-form-urlencoded" \
    -H "cookie: sid=$SCRATCH_TOKEN")"

  echo "$(jq -r '.testClasses?' <<< ${TEST_INFO:10})"
}

create_package() {
  log "Creating Package ..."
  PACKAGE_NAME=${1:-}
  PACKAGE_TYPE=${2:-}
  USERNAME=${3:-}

  PACKAGE_PATH="$(cat sfdx-project.json |
    jq -r '.packageDirectories[]
      | select(.default==true)
      | .path')"

  sfdx force:package:create \
    -r "$PACKAGE_PATH" \
    -n "$PACKAGE_NAME" \
    -t "$PACKAGE_TYPE" \
    -v "$USERNAME"
}

set_package_namespace() {
  if [ "$STAGE" == "DEV" ]; then
    NAMESPACE=""
  else
    NAMESPACE="$PACKAGE_NAMESPACE"
  fi

  NEW_PROJECT_FILE="$(jq -r --arg NAMESPACE "$NAMESPACE" '.namespace=$NAMESPACE' sfdx-project.json)"
  echo "$NEW_PROJECT_FILE" > "./sfdx-project.json"
}

# Validation if the package exists on Dev Hub
check_package_on_devhub() {
  log "Searching Package on Dev Hub ..."
  USERNAME=${1:-}
  PACKAGE_NAME=${2:-}

  if [ "$STAGE" == "DEV" ]; then
    PACKAGE_TYPE="Unlocked"
  else
    PACKAGE_TYPE="Managed"
  fi

  IS_PACKAGE_EXISTS="$(sfdx force:package:list -v $USERNAME --json |
    jq -r --arg PACKAGE_NAME "$PACKAGE_NAME" --arg PACKAGE_TYPE "$PACKAGE_TYPE" '.result[]
      | select(.Name==$PACKAGE_NAME)
      | select(.ContainerOptions==$PACKAGE_TYPE)')"

  if [ -z "$IS_PACKAGE_EXISTS" ]; then
    log "Creating package on Dev Hub ..."
    set_package_namespace
    create_package \
      "$PACKAGE_NAME" \
      "$PACKAGE_TYPE" \
      "$USERNAME"
  fi

  check_package_in_project_file \
    "$PACKAGE_NAME" \
    "$PACKAGE_TYPE" \
    "$USERNAME"
}

# Validation if the package exists in sfdx-project.json file
check_package_in_project_file() {
  log "Searching Package in project files ..."
  PACKAGE_NAME=${1:-}
  PACKAGE_TYPE=${2:-}
  USERNAME=${3:-}
  NAMESPACE="$PACKAGE_NAMESPACE"

  IS_PACKAGE_EXISTS="$(cat sfdx-project.json |
    jq -r --arg PACKAGE_NAME "$PACKAGE_NAME" '.packageDirectories[]
      | select(.package==$PACKAGE_NAME)')"

  PACKAGE_ID="$(sfdx force:package:list -v "$USERNAME" --json |
    jq -r --arg PACKAGE_NAME "$PACKAGE_NAME" --arg PACKAGE_TYPE "$PACKAGE_TYPE" '.result[]
      | select(.Name==$PACKAGE_NAME)
      | select(.ContainerOptions==$PACKAGE_TYPE)
      .Id')"

  # Create package if it's not exists
  if [ -z "$IS_PACKAGE_EXISTS" ]; then
    PACKAGE_PATH="$(cat sfdx-project.json |
      jq -r '.packageDirectories[]
        | select(.default==true)
        .path')"
    API_VERSION="$(cat sfdx-project.json | jq -r '.sourceApiVersion')"
    LOGIN_URL="$(cat sfdx-project.json | jq -r '.sfdcLoginUrl')"
    if [ "$STAGE" == "DEV" ]; then
      NAMESPACE=""
    fi
    SFDX_PROJECT_TEMPLATE="{ \
      \"packageDirectories\": [ \
          { \
              \"path\": \"$PACKAGE_PATH\", \
              \"default\": true, \
              \"package\": \"$PACKAGE_NAME\", \
              \"versionName\": \"ver 0.1\", \
              \"versionNumber\": \"1.0.0.NEXT\", \
              \"ancestorId\": \"\"
          } \
      ], \
      \"namespace\": \"$NAMESPACE\", \
      \"sfdcLoginUrl\": \"$LOGIN_URL\", \
      \"sourceApiVersion\": \"$API_VERSION\", \
      \"packageAliases\": { \
          \"$PACKAGE_NAME\": \"$PACKAGE_ID\" \
      } \
    }"

    echo "$SFDX_PROJECT_TEMPLATE" > "./sfdx-project.json"
  fi

}

# Set config variables for the target org
prepare_sfdc_environment() {
  log "Prepare Environment configs ..."
  INSTANCE_URL=${1:-}
  USERNAME=${2:-}
  SF_URL="https://$INSTANCE_URL"

  : $(sfdx force:config:set \
    instanceUrl="$SF_URL")

  : $(sfdx force:config:set \
    defaultusername="$USERNAME")
}

install_package_version() {
  log "Installing new package version ..."
  SFDX_PACKAGE_NAME=${1:-}
  DEVHUB_USERNAME=${2:-}
  TARGET_USERNAME=${3:-}
  TARGET_INSTANCE_URL=${4:-}
  DEV_HUB_INSTANCE_URL=${5:-}

  VERSION_NUMBER=$(get_package_version $SFDX_PACKAGE_NAME $DEVHUB_USERNAME)
  log "New Package Version: $VERSION_NUMBER"
  LATEST_VERSION="$(eval sfdx force:package:version:list \
    -v $DEVHUB_USERNAME \
    -p $SFDX_PACKAGE_NAME \
    --concise \
    --json |
    jq -r '.result
      | sort_by(-.MajorVersion, -.MinorVersion, -.PatchVersion, -.BuildNumber)
      | .[0].SubscriberPackageVersionId')"

  if [[ ! "$LATEST_VERSION" == "null" && ! "$STAGE" == "DEV" ]]; then
    UPDATED_PROJECT_FILE="$(cat sfdx-project.json | jq -r --arg ANCESTOR "$LATEST_VERSION" '.packageDirectories[].ancestorId=$ANCESTOR')"
  else
    UPDATED_PROJECT_FILE="$(cat sfdx-project.json | jq -r 'del(.packageDirectories[].ancestorId)')"
  fi
  echo "$UPDATED_PROJECT_FILE" > "./sfdx-project.json"

  log "Creating new Package Version"
  log "This may take some time ..."

  VERSION_NAME="version $(sed 's/\.NEXT$//' <<< "$VERSION_NUMBER")"
  COMMAND_CREATE="sfdx force:package:version:create \
    -p $SFDX_PACKAGE_NAME \
    --versionname '$VERSION_NAME' \
    -n $VERSION_NUMBER \
    -v $DEVHUB_USERNAME \
    -w 100 \
    --json -x "

  if [ ! "$STAGE" == "DEV" ]; then
    COMMAND_CREATE="${COMMAND_CREATE}-c"
  fi

  CREATE_RESULT="$(eval $COMMAND_CREATE)"
  echo "$CREATE_RESULT"

  PACKAGE_VERSION_ID="$(jq -r '.result.SubscriberPackageVersionId' <<< "$CREATE_RESULT")"

  prepare_sfdc_environment \
    "$DEV_HUB_INSTANCE_URL" \
    "$DEVHUB_USERNAME"

  if [ ! "$STAGE" == "DEV" ]; then
    sfdx force:package:version:promote \
      -p "$PACKAGE_VERSION_ID" \
      -v "$DEVHUB_USERNAME" \
      -n
  fi

  prepare_sfdc_environment \
    "$TARGET_INSTANCE_URL" \
    "$TARGET_USERNAME"

  sfdx force:package:install \
    -p "$PACKAGE_VERSION_ID" \
    -u "$TARGET_USERNAME" \
    -w 100 \
    -b 100 \
    -r

  echo "Package installation URL: https://login.salesforce.com/packaging/installPackage.apexp?p0=$PACKAGE_VERSION_ID"
}

get_package_version() {
  SFDX_PACKAGE_NAME=${1:-}
  DEVHUB_USERNAME=${2:-}

  if [ "$STAGE" == "DEV" ]; then
    MANAGED_PACKAGE_ID="$(sfdx force:package:list \
      -v $DEVHUB_USERNAME --json | jq -r --arg PACKAGE_NAME "$PACKAGE_NAME" '.result[]
        | select(.Name==$PACKAGE_NAME)
        | select(.ContainerOptions=="Managed").Id')"
  fi

  if [ ! -z $MANAGED_PACKAGE_ID ]; then
    MANAGED_MINOR_VERSION="$(eval sfdx force:package:version:list \
      -v $DEVHUB_USERNAME \
      -p $MANAGED_PACKAGE_ID \
      --concise \
      --json |
      jq -r '.result
        | sort_by(-.MajorVersion, -.MinorVersion, -.PatchVersion, -.BuildNumber) | .[0].MinorVersion')"
  fi

  PACKAGE_VERSION_JSON="$(eval sfdx force:package:version:list \
    -v $DEVHUB_USERNAME \
    -p $SFDX_PACKAGE_NAME \
    --concise \
    --json |
    jq '.result | sort_by(-.MajorVersion, -.MinorVersion, -.PatchVersion, -.BuildNumber) | .[0] // ""')"

  IS_RELEASED=$(jq -r '.IsReleased?' <<< $PACKAGE_VERSION_JSON)
  MAJOR_VERSION=$(jq -r '.MajorVersion?' <<< $PACKAGE_VERSION_JSON)
  MINOR_VERSION=$(jq -r '.MinorVersion?' <<< $PACKAGE_VERSION_JSON)
  PATCH_VERSION=$(jq -r '.PatchVersion?' <<< $PACKAGE_VERSION_JSON)
  BUILD_VERSION="NEXT"

  if [ ! "$STAGE" == "DEV" ]; then BUILD_VERSION=0; fi;
  if [[ -z "$MAJOR_VERSION" || "$MAJOR_VERSION" == null ]]; then MAJOR_VERSION=1; fi;
  if [[ -z "$MINOR_VERSION" || "$MINOR_VERSION" == null ]]; then MINOR_VERSION=0; fi;
  if [[ -z "$PATCH_VERSION" || "$PATCH_VERSION" == null ]]; then PATCH_VERSION=0; fi;

  if [[ ! -z "$MANAGED_MINOR_VERSION" && ! "$MANAGED_MINOR_VERSION" == null ]]; then MINOR_VERSION=$MANAGED_MINOR_VERSION; fi;
  if [ "$IS_RELEASED" == "true" ]; then MINOR_VERSION=$(($MINOR_VERSION+1)); fi;

  VERSION_NUMBER="$MAJOR_VERSION.$MINOR_VERSION.$PATCH_VERSION.$BUILD_VERSION"

  echo "$VERSION_NUMBER"
}

prepare_metadata_format() {
  log "Preparing code for analysis ..."
  BUILD_DIR=${1:-}

  PACKAGE_PATH="$(cat sfdx-project.json |
    jq -r '.packageDirectories[]
      | select(.default==true)
      | .path')"

  if [[ -z "$PACKAGE_PATH" ]]; then echo "Project folder was not found" && exit 0; fi;

  if [[ ! -f "$BUILD_DIR/$PACKAGE_PATH/package.xml" ]]; then
    mkdir -p "$BUILD_DIR/temp-dir"
    sfdx force:source:convert -r "$BUILD_DIR/$PACKAGE_PATH" -d "$BUILD_DIR/temp-dir"
    export SOURCE_DIR="$BUILD_DIR/temp-dir"
  else
    export SOURCE_DIR="$BUILD_DIR/$PACKAGE_PATH"
  fi
}

run_analysis() {
  log "Starting code analysis ..."

  PACKAGE_PATH="$(cat sfdx-project.json |
    jq -r '.packageDirectories[]
      | select(.default==true)
      | .path')"

  sfdx isvte:mdscan -d "$SOURCE_DIR"
}
