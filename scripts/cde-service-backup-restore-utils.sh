#!/bin/bash

set -e # Any subsequent(*) commands which fail will cause the shell script to exit immediately

export CDE_UTIL_HOME_DIR=${PWD}
export CDE_BR_UTIL_PROP_FILE_PATH="${CDE_UTIL_HOME_DIR}/cde-service-backup-restore-utils.properties"

# the default prod cdp endpoint 
DEFAULT_CDP_ENDPOINT_URL="https://api.us-west-1.cdp.cloudera.com"

CDE_CLUSTER_ID_OLD=""
CDE_CLUSTER_ID_NEW=""
BACKUP_BASE_DIR=""

#### common parts begin ####
# The run_cmd() function has a bug which is also present in cde-utils.sh. It first forms the `cmd`
# variable which has `bash -c {command_to_execute}` then it again calls the `cmd` wrapped in another
# shell as `bash -c ${cmd}`. This leads to problem when yq's syntax for nested special characters is used
# Refer: https://mikefarah.gitbook.io/yq/operators/traverse-read#nested-special-characters
#
# The run_cmd() function gets called in multiple places so for now to fix the bug (and minimise the impact)
# where username has dot(.) [DEX-12768] or any special characters, the v2 functions has been added.
# We'll address the original bug later which has quite wide testing scope.
cmd_v2() {
    cmd="bash -c \"$1\""
    log_info "Running command: ${cmd}"
    bash -c "$1"
    exit_code="$?"
    return "$exit_code"
}

# used with commands that are intermediate steps, which should only be logged verbosely, and should not be affected by dry-run feature in the future. 
cmd_mid() {
    cmd="bash -c \"$1\""
    log_debug "Running command: ${cmd}"
    bash -c "$1"
    exit_code="$?"
    return "$exit_code"
}

log_info() {
  now="$(date +'%Y-%m-%d %T,%3N')"
  echo "${now} [INFO] ${1}" 1>&2
}

log_error() {
  error="$1"
  now="$(date +'%Y-%m-%d %T,%3N')"
  echo "${now} [ERROR] ${error}" 1>&2
}

log_debug() {
  if [[ -n "$CDE_DEBUG" ]]; then 
    now="$(date +'%Y-%m-%d %T,%3N')"
    echo "${now} [DEBUG] ${1}" 1>&2
  fi
}

#### common parts end ####

# input: cluster_id, vc_id
# output: CDE_VC_HOST
extract_vc_host() {
  local cluster_id="$1"
  local vc_id="$2"
  
  # a VC API URL is typically "https://8vqvpnpb.cde-z5kgzqpg.dex-priv.xcu2-8y8x.dev.cldr.work/dex/api/v1"
  cmd="$CDP_COMMAND de describe-vc --cluster-id $cluster_id --vc-id $vc_id | jq -r '.vc.vcApiUrl'"
  log_debug "Getting VC API URL with command: $cmd"
  url=$(eval "$cmd")
  log_debug "Got $url"
  
  # Match the host, e.g. dex-priv.xcu2-8y8x.dev.cldr.work
  cmd="echo $url | sed -E 's|.*cde-.{8}\.([^/]+)/dex/.*|\1|'"
  log_debug "Extracting host pattern with command: $cmd"
  CDE_VC_HOST=$(eval "$cmd")
  log_debug "The extracted VC host pattern is $CDE_VC_HOST"
}

# parse $base_dir/vcs-$cluster_id.json to get the vc ids and names into lists VC_IDS and VC_NAMES
# input: cluster_id, base_dir
# output: VC_IDS, VC_NAMES, CDE_VC_HOST
parse_vcs() {
  local cluster_id="$1"
  local base_dir="$2"
  
  if [ ! -d "$base_dir" ]; then
    cmd_mid "mkdir -p $base_dir"
  fi
  local vc_file="${base_dir}/vcs-${cluster_id}.json"

  cmd="$CDP_COMMAND de list-vcs --cluster-id $cluster_id > $vc_file"
  cmd_mid "$cmd"

  # Extract vcId and vcName from vcs.json, check only vcs in AppInstalled status, sorted by vcName
  cmd="jq -r '.vcs|map(select(.status == \"AppInstalled\"))|sort_by(.vcName)[].vcId' $vc_file"
  log_debug "Getting VC_IDS with: $cmd"
  # shellcheck disable=SC2207
  VC_IDS=($(eval "$cmd"))
  
  cmd="jq -r '.vcs|map(select(.status == \"AppInstalled\"))|sort_by(.vcName)[].vcName' $vc_file"
  log_debug "Getting VC_NAMES with: $cmd"
  # shellcheck disable=SC2207
  VC_NAMES=($(eval "$cmd"))
  
  if [[ -z "$CDE_VC_HOST" ]]; then
    extract_vc_host "$cluster_id" "${VC_IDS[0]}"
  fi
}

# input: backup_id
wait_for_backup_completion() {
  local backup_id=$1
  while true; do
    cmd="$CDP_COMMAND de describe-backup --backup-id $backup_id | jq -r '.backup.status'"
    log_debug "Getting backup status with: $cmd"
    backup_status=$(eval "$cmd")
    if [ "$backup_status" == "completed" ]; then
      log_info "Backup $backup_id completed successfully"
      break
    elif [ "$backup_status" == "pending" ]; then
      log_info "Backup $backup_id status: $backup_status. Waiting..."
      sleep 6
    else
      log_error "Backup $backup_id $backup_status"
      exit 1
    fi
  done
}

# input: cluster_id
wait_for_cluster_restore() {
  local cluster_id="$1"
  last_log_time=$(date +%s) # Track the last time we logged information
  
  while true; do
    cmd="$CDP_CURL_COMMAND -X GET -f string ${CDP_ENDPOINT_URL}/dex/api/v1/cluster/${cluster_id}/initialization-status"
    log_debug "Getting initialization status with: $cmd"
    http_return=$(eval "$cmd")

    log_debug "Got service initialization status $http_return"
    init_status=$(echo "$http_return" | jq -r '.status')

    current_time=$(date +%s)                 #compute the current time in each iteration
    log_time_diff=$((current_time - last_log_time)) # Time since the last log

    if [ "$init_status" == "Initialized" ]; then
      log_info "Service and virtual clusters creation for $cluster_id completed successfully"
      break
    elif [ "$init_status" == "Provisioning" ] || [ "$init_status" == "Initializing" ]; then
      # Log less frequently (e.g., every 5 minutes) to avoid overwhelming logs
      if [ $log_time_diff -ge 300 ]; then
        log_info "Service and virtual clusters creation status: $init_status. Waiting..."
        last_log_time=$current_time
      fi
      sleep 120
    else
      log_error "Service and virtual clusters creation for $cluster_id failed: $init_status"
      exit 1
    fi
  done
}

# downloads the kubeconfig file for cluster and set it as KUBECONFIG
# input: cluster_id, base_dir
set_kubeconfig() {
  # skip
  if [[ -n "$CDE_SKIP_KUBECONFIG" ]]; then
    log_info "Skipping KUBECONFIG setting. Current KUBECONFIG: $KUBECONFIG"
    return 
  fi
  
  local cluster_id="$1"
  local base_dir="$2"

  if [ ! -d "$base_dir" ]; then
    cmd_mid "mkdir -p $base_dir"
  fi
    
  cmd_mid "cdpcurl --profile $CDP_PROFILE -f string ${CDP_ENDPOINT_URL}/dex/api/v1/cluster/${cluster_id}/kubeconfig > $base_dir/kubeconfig-$cluster_id 2> /dev/null"
  
  export KUBECONFIG="$base_dir/kubeconfig-$cluster_id"
  log_info "Setting KUBECONFIG to $KUBECONFIG"
}

# input: backup_id
# output: ENV_CRN
step_get_env_crn() {
  local backup_id="$1"
  cmd="$CDP_COMMAND de describe-backup --backup-id $backup_id | jq -r '.backup.environmentCrn'"
  log_debug "Getting env crn with: $cmd"
  ENV_CRN=$(eval "$cmd")
}

# input: backup_id
# output: RELATIVE_PATH
get_relative_path() {
  local backup_id="$1"
  
  cmd="$CDP_COMMAND de describe-backup --backup-id $backup_id | jq -r '.backup.archiveLocation'"
  log_debug "Getting relative path for backup with: $cmd"
  RELATIVE_PATH=$(eval "$cmd")
}

# input: cluster_id, base_dir
# Note: CDE_BACKUP_NO_CONTENTS_OPTIONS can be specified to control the behavior
step_backup_no_contents() {
  local cluster_id="$1"
  local base_dir="$2"
  local dir="$base_dir/$cluster_id"
  
  if [[ -z "$CDE_BACKUP_NO_CONTENTS_OPTIONS" ]]; then
    CDE_BACKUP_NO_CONTENTS_OPTIONS="includeJobs=false,includeJobResources=false,includeResources=false,includeResourceCredentials=false,includeCredentials=false,includeCredentialSecrets=false,includeJobRuns=false,validateArchive=false,jobFilter='created(lt)1970-01-01'"
  fi

  cmd="$CDP_COMMAND de create-backup \
         --service-id $cluster_id \
         --backup-vc-content-options $CDE_BACKUP_NO_CONTENTS_OPTIONS | \
         jq -r '.backupID'"
  log_info "Backing up service metadata with: $cmd"
  BACKUP_NO_CONTENTS_ID=$(eval "$cmd")

  cmd_mid "echo $BACKUP_NO_CONTENTS_ID > $dir/.backup-no-contents.id"
  log_info "Taken backup $BACKUP_NO_CONTENTS_ID of metadata for service $cluster_id, checking..."
  wait_for_backup_completion "$BACKUP_NO_CONTENTS_ID"
}

# input: cluster_id, base_dir
# Note: CDE_FULL_BACKUP_OPTIONS can be specified to control the behavior
step_backup_full() {
  local cluster_id="$1"
  local base_dir="$2"
  local dir="$base_dir/$cluster_id"

  cmd="$CDP_COMMAND de create-backup \
           --service-id $cluster_id $CDE_FULL_BACKUP_OPTIONS | jq -r '.backupID'"
  log_info "Backing up full service with: $cmd"
  BACKUP_FULL_ID=$(eval "$cmd")

  cmd_mid "echo $BACKUP_FULL_ID >$dir/.backup-full.id"
  log_info "Taken full backup $BACKUP_FULL_ID for service $cluster_id, checking..."
  wait_for_backup_completion "$BACKUP_FULL_ID"
}

# input: backup_id, env_crn, service_id, service_name
# output: CDE_CLUSTER_ID_NEW
# Note: CDE_SERVICE_RESTORE_OPTIONS can be specified to control the behavior
step_restore_cluster() {
  local backup_id=$1
  local env_crn=$2
  local service_id=$3
  local service_name=$4

  restore_cmd="$CDP_COMMAND de restore-service \
                        --backup-id $backup_id \
                        --environment-crn $env_crn"
  if [[ -n "$service_id" ]]; then
    restore_cmd="$restore_cmd \
                  --service-id $service_id"
  fi 
  if [[ -n "$service_name" ]]; then
    restore_cmd="$restore_cmd \
                  --service-name $service_name"
  fi 
  
  cmd="$restore_cmd $CDE_SERVICE_RESTORE_OPTIONS| jq -r '.serviceID'"
  log_info "Restoring service with: $cmd"
  CDE_CLUSTER_ID_NEW=$(eval "$cmd")

  if [[ -z "$CDE_CLUSTER_ID_NEW" ]]; then
    log_error "Error when restoring from backup $backup_id"
    exit 1
  fi
  log_info "Started service restoration $CDE_CLUSTER_ID_NEW from backup $backup_id. Waiting for it to be completed..."
  wait_for_cluster_restore "$CDE_CLUSTER_ID_NEW"
}

# input: cluster_id, base_dir
# output: file $base_dir/$cluster_id/dex-app-xxx.zip
# NOTE: CDE_BACKUP_OPTIONS can be specified to control the behavior of backup command. e.g. --include-active-airflow-pyenv=true
step_backup_vc_contents() {
  local cluster_id="$1"
  local base_dir="$2"
  local dir="$base_dir/$cluster_id"
  
  if [[ -z "$CDE_BACKUP_OPTIONS" ]]; then
    CDE_BACKUP_OPTIONS="--include-jobs=true --include-resources=true --include-credentials=true --include-credential-secrets=true"
    
    cmd_version="cde --version | cut -d' ' -f3"
    log_debug "Getting CDE CLI version with command: $cmd_version"
    cde_version=$(eval "$cmd_version")
    log_debug "Got CDE CLI version $cde_version"
    if ! [[ "$cde_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_error "Invalid CDE version number: $cde_version"
        exit 1
    fi
    
    if [[ "$(printf '%s\n' "1.21.0" "$cde_version" | sort -V | head -n1)" != "$cde_version" ]]; then
        # Version is greater than 1.21.0
        CDE_BACKUP_OPTIONS="$CDE_BACKUP_OPTIONS --include-active-airflow-pyenv=true"
    fi
    if [[ "$(printf '%s\n' "1.22.0" "$cde_version" | sort -V | head -n1)" != "$cde_version" ]]; then
        # Version is greater than 1.22.0
        CDE_BACKUP_OPTIONS="$CDE_BACKUP_OPTIONS --include-runs=true"
    fi
  fi

  parse_vcs "$cluster_id" "$base_dir"
  local vc_ids=("${VC_IDS[@]}")
  for vc_id in "${vc_ids[@]}"; do
    local vc_short_id=${vc_id:8}
    local cluster_short_id=${cluster_id:8}
    local endpoint="https://${vc_short_id}.cde-${cluster_short_id}.${CDE_VC_HOST}/dex/api/v1"
    cmd="$CDE_COMMAND --vcluster-endpoint $endpoint \
               backup create --local-path $dir/$vc_id.zip $CDE_BACKUP_OPTIONS"
    log_info "Backing up contents for VC: $vc_id"
    cmd_v2 "$cmd"
  done
}

# input: cluster_id, cluster_id_old, base_dir
# NOTE: CDE_RESTORE_OPTIONS can be specified to control the behavior of restore command. 
step_restore_vc_contents_from_separate() {
  local cluster_id="$1"
  local cluster_id_old="$2"
  local base_dir="$3"
  # reading from the old cluster dir
  local dir="$base_dir/$cluster_id_old"

  parse_vcs "$cluster_id" "$base_dir"
  local vc_ids=("${VC_IDS[@]}")
  parse_vcs "$cluster_id_old" "$base_dir"
  local vc_ids_old=("${VC_IDS[@]}")
  for i in "${!vc_ids[@]}"; do
    local vc_id="${vc_ids[$i]}"
    local vc_short_id=${vc_id:8}
    local cluster_short_id=${cluster_id:8}
    local vc_id_old=${vc_ids_old[$i]}
    
    local zip_file="$dir/${vc_id_old}.zip"

    # if the content file "$dir/${vc_id_old}.zip" does not exist or is less than 1 byte, skip it
    if [[ ! -s "$zip_file" ]]; then
      log_info "Skipping VC $vc_id_old: backup file not found or empty"
      continue
    fi

    # unzip archive file and modify pause status
    if [[ -n "$CDE_PAUSE_JOBS" ]]; then
      log_info "Modifying the local backup to pause job schedules"
      cmd_mid "rm -rf ./v1"
      cmd_mid "unzip -q $zip_file"
      step_mod_pause_spark_jobs "./v1"
      step_mod_pause_airflow_jobs "./v1"
      # write a new file
      zip_file="$dir/${vc_id_old}-mod.zip"
      cmd_mid "zip -q -r $zip_file './v1'"
      cmd_mid "rm -rf ./v1"
      log_info "Done"
    fi

    # do restore
    local endpoint="https://${vc_short_id}.cde-${cluster_short_id}.${CDE_VC_HOST}/dex/api/v1"
    local cmd="$CDE_COMMAND --vcluster-endpoint $endpoint \
                   backup restore --local-path $zip_file $CDE_RESTORE_OPTIONS"
    log_info "Restoring contents to VC: $vc_id"
    cmd_v2 "$cmd"
    
    # clean mod file
    if [ -n "$CDE_PAUSE_JOBS" ] && [[ "$zip_file" == *-mod.zip ]]; then
      cmd_mid "rm -rf $zip_file"
    fi
  done
}

# Notice: the archive file should be manually transferred from cluster-backups to user-backups
# e.g
#      RELA_PATH="cluster-hbkfrv7k/archive-cluster-hbkfrv7k-2024-09-13T13:00:45.zip"
#      aws s3 cp  \
#          s3://dex-priv-default-aws-storage/datalake/logs/dex-backups/cluster-backups/$RELA_PATH \
#          s3://dex-priv-default-aws-storage/datalake/logs/dex-backups/user-backups/$RELA_PATH
# input: cluster_id, cluster_id_old, base_dir
# NOTE: CDE_RESTORE_OPTIONS can be specified to control the behavior of restore command. 
step_restore_vc_contents_from_full() {
  local cluster_id="$1"
  local cluster_id_old="$2"
  local base_dir="$3"
  # reading from the old cluster dir
  local dir="$base_dir/$cluster_id_old"

  parse_vcs "$cluster_id" "$base_dir"
  local vc_ids=("${VC_IDS[@]}")
  parse_vcs "$cluster_id_old" "$base_dir"
  local vc_ids_old=("${VC_IDS[@]}")

  local full_id
  full_id=$(cat "$dir/.backup-full.id")
  if [[ -z "$full_id" ]]; then
    log_error "Backup up ID should not be null when restoring."
    exit 1
  fi
  get_relative_path "$full_id"
  local relative_path="$RELATIVE_PATH"

  for i in "${!vc_ids[@]}"; do
    local vc_id="${vc_ids[$i]}"
    local vc_short_id=${vc_id:8}
    local cluster_short_id=${cluster_id:8}
    local vc_id_old=${vc_ids_old[$i]}
    local endpoint="https://${vc_short_id}.cde-${cluster_short_id}.${CDE_VC_HOST}/dex/api/v1"
    local cmd="$CDE_COMMAND --vcluster-endpoint $endpoint \
                   backup restore --remote-path $relative_path --backup-set-filter app_id[eq]$vc_id_old $CDE_RESTORE_OPTIONS"

    log_info "restoring contents to VC: $vc_id"
    cmd_v2 "$cmd"
  done
}

# store airflow into $base_dir/$cluster_id/$vc_id/airflow
# input: cluster_id, base_dir
step_backup_airflows() {
  local cluster_id="$1"
  local base_dir="$2"
  local dir="$base_dir/$cluster_id"

  parse_vcs "$cluster_id" "$base_dir"
  local vc_ids=("${VC_IDS[@]}")

  set_kubeconfig "$cluster_id" "$base_dir"

  for vc_id in "${vc_ids[@]}"; do
    cmd="kubectl get pod -n $vc_id -l app=airflow,component=scheduler -o jsonpath=\"{.items[*].metadata.name}\""
    log_debug "Getting airflow pod with: $cmd"
    local airflow_pod
    airflow_pod=$(eval "$cmd")
    if [[ -z "$airflow_pod" ]]; then
      log_error "Failed to get airflow pod."
      exit 1
    fi

    log_info "Backing up airflow for VC: $vc_id, Airflow Pod: $airflow_pod"
    cmd_v2 "kubectl -n $vc_id exec $airflow_pod -- mkdir -p /tmp/export"
    cmd_v2 "kubectl -n $vc_id exec $airflow_pod -- airflow variables export /tmp/export/vars.json > /dev/null"
    cmd_v2 "kubectl -n $vc_id exec $airflow_pod -- airflow connections export --file-format json /tmp/export/cons.json > /dev/null"
    cmd_v2 "kubectl -n $vc_id cp $airflow_pod:/tmp/export $dir/$vc_id/airflow"
    
    # file cons.json contains connections as json objects, delete any connection that is named "cde_runtime" or any that matches $VC_NAMES
    local file_prefix="$dir/$vc_id/airflow"
    cmd_mid "cp $file_prefix/cons.json $file_prefix/cons-mod.json"
    cmd_mid "jq 'del(.cde_runtime_api)' $file_prefix/cons-mod.json > $file_prefix/cons.json.tmp && mv $file_prefix/cons.json.tmp $file_prefix/cons-mod.json"
    for j in "${!VC_NAMES[@]}"; do
      vc_name=${VC_NAMES[$j]}
      cmd_mid "jq 'del(.\"${vc_name}\")' $file_prefix/cons-mod.json > $file_prefix/cons.json.tmp && mv $file_prefix/cons.json.tmp $file_prefix/cons-mod.json"
    done
  done
}

step_restore_airflows() {
  local cluster_id="$1"
  local cluster_id_old="$2"
  local base_dir="$3"
  # reading from the old cluster dir
  local dir="$base_dir/$cluster_id_old"

  parse_vcs "$cluster_id" "$base_dir"
  local vc_ids=("${VC_IDS[@]}")
  parse_vcs "$cluster_id_old" "$base_dir"
  local vc_ids_old=("${VC_IDS[@]}")

  set_kubeconfig "$cluster_id" "$base_dir"

  for i in "${!vc_ids[@]}"; do
    local vc_id=${vc_ids[$i]}
    local vc_id_old=${vc_ids_old[$i]}
    cmd="kubectl get pod -n $vc_id -l app=airflow,component=scheduler -o jsonpath=\"{.items[*].metadata.name}\""
    log_debug "Getting airflow pod with: $cmd"
    local airflow_pod
    airflow_pod=$(eval "$cmd")
    if [[ -z "$airflow_pod" ]]; then
      log_error "Failed to get airflow pod."
      exit 1
    fi

    log_info "Restoring airflow for VC: $vc_id, Airflow Pod: $airflow_pod"
    local file_prefix="$dir/$vc_id_old/airflow"
    # copy individual file instead of the whole dir, to avoid dir copy issue
    cmd_v2 "kubectl exec $airflow_pod -n $vc_id -- mkdir -p /tmp/export"
    cmd_v2 "kubectl -n $vc_id cp $file_prefix/vars.json $airflow_pod:/tmp/export/vars.json"
    cmd_v2 "kubectl -n $vc_id cp $file_prefix/cons-mod.json $airflow_pod:/tmp/export/cons-mod.json"
    cmd_v2 "kubectl exec $airflow_pod -n $vc_id -- airflow variables import /tmp/export/vars.json > /dev/null"
    cmd_v2 "kubectl exec $airflow_pod -n $vc_id -- airflow connections import /tmp/export/cons-mod.json > /dev/null"
  done
}

# search in the unzipped archive file, modify spark job meta to pause them
step_mod_pause_spark_jobs() {
  local dir=$1
  # Traverse each file in $dir and check for all three patterns
  local files=""
  while IFS= read -r -d '' file; do
    if grep -q 'type: spark' "$file" && grep -q 'enabled: true' "$file" && grep -q 'paused: false' "$file"; then
      files+="$file"$'\n'
    fi
  done < <(find "$dir" -type f -print0)

  # Loop through files and replace the pattern
  for file in $files; do
    cmd_mid "sed -i 's/paused: false/paused: true/g' $file"
  done
}

# search in the unzipped archive file, modify airflow DAG to pause them
step_mod_pause_airflow_jobs() {
  local dir=$1
  # Recursively find files with pattern "is_paused_upon_creation=False"
  local files
  files=$(grep -r -l "is_paused_upon_creation=False" "$dir") || true

  # Loop through files and replace the pattern with "is_paused_upon_creation=True"
  for file in $files; do
    cmd_mid "sed -i 's/is_paused_upon_creation=False/is_paused_upon_creation=True/g' $file"
  done
}

# input: cluster_id, backup_base_dir
backup_service() {
  local cluster_id="$1"
  local base_dir="$2"
  local dir="$base_dir/$cluster_id"
  prepare_data_dir "$dir"

  if [[ -z "$SKIP_SERVICE" ]]; then
    # backup service and VCs metadata, store the ID in $dir/.backup-no-contents.id
    step_backup_no_contents "$cluster_id" "$base_dir"
  else
    log_info "Skipping service metadata backup"
  fi

  # full backup normally not in the routine. Only executed when specified
  if [[ -n "$ENABLE_BACKUP_FULL" ]]; then
    # backup full cluster, store the ID in $dir/.backup-full.id
    step_backup_full "$cluster_id" "$base_dir"
  fi

  if [[ -z "$SKIP_CONTENTS" ]]; then
    # backup vc contents, store them in $dir/dex-app-xxx.zip
    step_backup_vc_contents "$cluster_id" "$base_dir"
  else
    log_info "Skipping jobs and resources backup"
  fi

  if [[ -z "$SKIP_AIRFLOW" ]]; then
    # backup airflow, store them in $dir/dex-app-xxx/airflow
    step_backup_airflows "$cluster_id" "$base_dir"
  else
    log_info "Skipping airflow connections and variables backup"
  fi
  
  log_info "Backup finished successfully"
}

# input: cluster_id, cluster_name, cluster_id_old, backup_base_dir
# uses: SKIP_SERVICE, SKIP_AIRFLOW, SKIP_CONTENTS
restore_service() {
  local cluster_id="$1"
  local cluster_name="$2"
  local cluster_id_old="$3"
  local base_dir="$4"
  local dir="$base_dir/$cluster_id_old"

  # restore service, only when SKIP_SERVICE is not set
  if [[ -z "$SKIP_SERVICE" ]]; then
    BACKUP_ID=$(cat "$dir/.backup-no-contents.id")
    if [[ -z "$BACKUP_ID" ]]; then
      log_error "Backup up ID should not be null when restoring. Check $dir/.backup-no-contents.id"
      exit 1
    fi
    step_get_env_crn "$BACKUP_ID"
    log_info "Got env crn $ENV_CRN"
    
    step_restore_cluster "$BACKUP_ID" "$ENV_CRN" "$cluster_id" "$cluster_name"
    cluster_id="$CDE_CLUSTER_ID_NEW"
  else
    log_info "Skipping service provision"
  fi

  # restore airflow
  if [[ -z "$SKIP_AIRFLOW" ]]; then
    step_restore_airflows "$cluster_id" "$cluster_id_old" "$base_dir"
  else
    log_info "Skipping airflow restore"
  fi

  # restore vc contents
  if [[ -z "$SKIP_CONTENTS" ]]; then
    if [[ -z "$RESTORE_FROM_FULL" ]]; then
      step_restore_vc_contents_from_separate "$cluster_id" "$cluster_id_old" "$base_dir"
    else
      step_restore_vc_contents_from_full "$cluster_id" "$cluster_id_old" "$base_dir"
    fi
  else
    log_info "Skipping jobs and resources restore."
  fi
  
  log_info "Restore finished successfully"
}

prepare_data_dir() {
  local dir_path=${1}

  # Check and create the program data directory
  if [[ ! -e ${dir_path} ]]; then
    cmd_mid "mkdir -p ${dir_path}"
  elif [[ ! -d ${dir_path} ]]; then
    log_error "${dir_path} already exists, but is not a directory" 1>&2
    exit 1
  else
    log_debug "${dir_path} already exists"
  fi
}

# check that all the tools are well configured
check_cmds() {
  if [[ -z "$CDE_PRE_CHECK" ]] && [[ -z "$CDE_PRE_CHECK_INTERACTIVE" ]]; then
    return 
  fi
  
  local cluster_id="$1"
  local base_dir="$2"
  prepare_data_dir "$base_dir/$cluster_id"

  # if there's error, due to |jq, it will not exit by default. We'll find better ways later. 
  check_cmd "$CDP_COMMAND de describe-service --cluster-id $cluster_id | jq '.service.name'" "Does it show the service name"
  # if there's error, due to |jq, it will not exit by default. We'll find better ways later. 
  check_cmd "$CDP_CURL_COMMAND -X GET -f string ${CDP_ENDPOINT_URL}/dex/api/v1/cluster/${cluster_id} | jq '.name'" "Does it show the service name"

  if [[ -z "$SKIP_CONTENTS" ]]; then
    local vc_id
    parse_vcs "$cluster_id" "$base_dir"
    vc_id="${VC_IDS[0]}"
    local vc_short_id=${vc_id:8}
    local cluster_short_id=${cluster_id:8}
    local endpoint="https://${vc_short_id}.cde-${cluster_short_id}.${CDE_VC_HOST}/dex/api/v1"
    check_prompt_cmd "$CDE_COMMAND --vcluster-endpoint $endpoint job list --filter 'created[lt]1970-01-01'"
  fi

  if [[ -z "$SKIP_AIRFLOW" ]]; then 
    set_kubeconfig "$cluster_id" "$base_dir"
    # if there's error, due to |grep dex-base, it will not exit by default. We'll find better ways later. 
    check_cmd "kubectl get namespace | grep dex-base" "Does it show dex-base-<cluster-short-id>"
  fi
}

check_prompt_cmd() {
  local cmd="$1"
  log_info "Checking tool configuration: $cmd"
  eval "$cmd"
  log_info "Result: OK"
}

# checks if a command produces the expected output, by default execute the command and log result. 
# If PRE_CHECK_INTERACTIVE is set, continue/exit interactively, allows fast fail.
check_cmd() {
  local cmd="$1"
  local msg="$2"
  log_info "Checking tool configuration: $cmd"
  set +e
  RESULT=$(eval "$cmd" 2>&1)
  rc=$?
  if [ $rc -gt 0 ]; then
    log_error "$RESULT"
    log_error "Please check configuration of the corresponding command"
    exit $rc
  else 
    log_info "Result: $RESULT"
  fi
  set -e
  
  if [[ -n "$CDE_PRE_CHECK_INTERACTIVE" ]]; then
    read -r -p "$msg? (Y/n): " response
    response=${response:-Y}
    
    case $response in
      [Yy]* )
        ;;
      [Nn]* )
        log_info "Exiting the script."
        exit 1
        ;;
      * )
        log_info "Invalid response. Treating as 'N'. Exiting the script."
        exit 1
        ;;
    esac
  fi
}

check_install() {
  local target="$1"
  log_info "Checking if $target is installed"
  set +e
  RESULT=$(command -v "$target" 2>&1)
  rc=$?
  if [ $rc -gt 0 ]; then
    log_error "Tool $target not installed. Please check."
    exit $rc
  else 
    log_info "Result: $RESULT"
  fi
  set -e
}

check_installs() {
  check_install "cdp"
  check_install "cdpcurl"
  check_install "cde"
  check_install "jq"
  check_install "kubectl"
}

subcommand_usage() {
  echo "Usage: ${0} <sub-command>.
    Sub-commands:
                      help              Prints this message.
                      backup-service    Take backup of CDE service. 
                                            backup-service -s <service-id> [-b <directory>] [options]
                                        Options:
                                            --service-only          only backup service and VC metadata. 
                                            --contents-only         only backup the contents, namely airflow connections, variables, and the jobs and resources.
                                            --pre-check             checks whether tools are configured before backing up. Recommended on the first run.
                                         
                      restore-service   Restore a service and all its contents from backup.
                                            restore-service -s <original-service-id> [-t <new-service-id>] [-n <new-service-name>] [-b <backup-base-directory>] [options] 
                                        Options:
                                            -t|--new-service-id     the ID of the restored service. It should be an 8 character-long unique alphanumeric string that does not contain vowels. 
                                            -n|--new-service-name   the name of the restored service. 
                                            --service-only          only provision service and VC.
                                            --contents-only         only restore the contents, namely airflow connections, variables, and the jobs and resources.
                                            --pause-jobs            specify this to force pausing jobs when restoring. For airflow jobs, the underlying DAG will be modified to stop catch up.
    Global Options: 
        -b|--backup-base-dir  the base directory to store backup contents. Data will be collected in a sub directory with it's service-id as the directory name. If not specified, default value $HOME/.cde/service-backups will be used.
        --skip-kubeconfig     if not set, the script will download kubeconfig for the service and set KUBECONFIG environment variable. Specify this to skip the process and handle it on your own. 
        --verbose             verbose logging.
        --cdp-profile         specify the CDP profile to use. Overrides the properties file.
    
    Before running the script, make sure that CDP CLI and CDE CLI are well configured, and kubectl is authenticated to access the specified service. 
    "
}

# load properties file $CDE_BR_UTIL_PROP_FILE_PATH if it exists
# make sure it does not override existing ENV Vars.
load_properties() {
 if [ -f "$CDE_BR_UTIL_PROP_FILE_PATH" ]; then
     # Save current environment variables if it is in the property file
     saved_vars=""
     while IFS='=' read -r key value; do
         # Skip comments and empty lines
         [[ $key =~ ^[[:space:]]*# ]] && continue
         [[ -z $key ]] && continue
         # Remove any leading/trailing whitespace
         key=$(echo "$key" | xargs)
         # Only save if the variable exists in current environment
         if [ -n "${!key+x}" ]; then
             saved_vars="$saved_vars$key=${!key};"
         fi
     done < "$CDE_BR_UTIL_PROP_FILE_PATH"
 
     # Source the file
     # shellcheck disable=SC1090
     source "$CDE_BR_UTIL_PROP_FILE_PATH"
 
     # Restore saved variables
     IFS=';' read -ra var_pairs <<< "$saved_vars"
     for pair in "${var_pairs[@]}"; do
         if [ -n "$pair" ]; then
             IFS='=' read -r key value <<< "$pair"
             declare -g "$key"="$value"
         fi
     done
 fi 
}

parse_commandline() {
  ## arguments priority.
    #Environment Variables
    #Optional Properties File (lowest priority)
  
  load_properties
  
  # Iterate over command-line arguments
  while [[ "$#" -gt 0 ]]; do
    _key="$1"
    case "$_key" in
    -s | --original-service-id)
      CDE_CLUSTER_ID_OLD="$2"
      shift
      ;;
    -t | --new-service-id)
      CDE_CLUSTER_ID_NEW="$2"
      shift
      ;;
    -n | --new-service-name)
      CDE_CLUSTER_NAME_NEW="$2"
      shift
      ;;
    -b | --backup-base-dir)
      BACKUP_BASE_DIR="$2"
      shift
      ;;
    --pause-jobs)
      CDE_PAUSE_JOBS=1
      ;;
    --contents-only)
      SKIP_SERVICE=1
      ;;
    --service-only)
      SKIP_AIRFLOW=1
      SKIP_CONTENTS=1
      ;;
    --full-service-backup)
      ENABLE_BACKUP_FULL=1
      ;;
    --restore-from-full)
      RESTORE_FROM_FULL=1
      ;;
    --cdp-profile)
      CDP_PROFILE="$2"
      shift
      ;;
    --verbose)
      CDE_DEBUG=1
      ;;
    --pre-check)
      CDE_PRE_CHECK=1
      ;;
    --pre-check-interactive)
      CDE_PRE_CHECK_INTERACTIVE=1
      ;;
    --skip-kubeconfig)
      CDE_SKIP_KUBECONFIG=1
      ;;
    *) # Handle unknown arguments
      echo "Unknown argument: $_key"
      return 1
      ;;
    esac
    shift
  done

  if [[ -n "$CDP_PROFILE" ]]; then
    CDP_CLI_OPTIONS="$CDP_CLI_OPTIONS --profile $CDP_PROFILE"
    CDP_CURL_OPTIONS="$CDP_CURL_OPTIONS --profile $CDP_PROFILE"
  fi
  CDP_COMMAND="cdp $CDP_CLI_OPTIONS"
  CDP_CURL_COMMAND="cdpcurl $CDP_CURL_OPTIONS"
  CDE_CLI_OPTIONS=""
  CDE_COMMAND="cde $CDE_CLI_OPTIONS"
  
  # set up CDP_ENDPOINT_URL for use with cdpcurl.
  # priority: env vars > properties file > cdp config > default prod cdp url
    # read from cdp config, only set when no value from env vars and properties file
  local cdp_url
  cdp_url=$($CDP_COMMAND configure get cdp_endpoint_url)
  if [[ -n "$cdp_url" ]] && [[ -z "$CDP_ENDPOINT_URL" ]]; then
    CDP_ENDPOINT_URL="$cdp_url"
  fi
  if [[ -z "$CDP_ENDPOINT_URL" ]]; then
    CDP_ENDPOINT_URL=$DEFAULT_CDP_ENDPOINT_URL
  fi
  # trim string
  CDP_ENDPOINT_URL=$(echo "$CDP_ENDPOINT_URL" | xargs)
  # if CDP_ENDPOINT_URL ends with /, remove that /
  CDP_ENDPOINT_URL=${CDP_ENDPOINT_URL%/}
  
  # for CDE CLI to use the cdp credential
  local atlus_url
  atlus_url=$($CDP_COMMAND configure get endpoint_url)
  if [[ -n "$cdp_url" ]]; then
    export CDE_CDP_ENDPOINT=$cdp_url
  fi
  if [[ -n "$atlus_url" ]]; then
    export CDE_ALTUS_ENDPOINT=$atlus_url
  fi
  if [ -z "${BACKUP_BASE_DIR}" ]; then
    BACKUP_BASE_DIR="$HOME/.cde/service-backups"
    log_info "No local backup base directory is specified. Using the default dir $BACKUP_BASE_DIR"
  fi 

  log_info "CDP_PROFILE: $CDP_PROFILE, CDP_ENDPOINT_URL: $CDP_ENDPOINT_URL, CDP command: $CDP_COMMAND, CDE command: $CDE_COMMAND"
}

main() {
  subcommand="$1"
  if [ x"${subcommand}"x == "xx" ]; then
    subcommand="help"
  else
    shift # past sub-command
  fi

  # read the options if not help subcommand
  if [[ "${subcommand}" = "backup-service" ]] || [[ "${subcommand}" = "restore-service" ]]; then
    parse_commandline "$@"
  elif [[ "${subcommand}" != "help" ]]; then
    log_error "Unknown subcommand: ${subcommand}"
    subcommand_usage
    exit 1
  fi

  case $subcommand in
  help)
    subcommand_usage
    ;;
  backup-service)
    if [ -z "${CDE_CLUSTER_ID_OLD}" ]; then
      log_error "Missing service ID. Use -s to specify the CDE service ID, ex. -s cluster-pp6kb229"
      exit 1
    fi
    check_installs
    check_cmds "${CDE_CLUSTER_ID_OLD}" "${BACKUP_BASE_DIR}"
    backup_service "${CDE_CLUSTER_ID_OLD}" "${BACKUP_BASE_DIR}"
    ;;
  restore-service)
    if [ -z "${CDE_CLUSTER_ID_OLD}" ]; then
      log_error "Missing original service ID. Use -s to specify the CDE service ID, ex. -s cluster-pp6kb229"
      exit 1
    fi
    if [ -n "$SKIP_SERVICE" ] && [ -z "$CDE_CLUSTER_ID_NEW" ]; then
      log_error "When restoring only contents, the ID of the target service must be specified. ex. -t cluster-pp6kb229"
    fi
    check_installs
    restore_service "$CDE_CLUSTER_ID_NEW" "$CDE_CLUSTER_NAME_NEW" "$CDE_CLUSTER_ID_OLD" "$BACKUP_BASE_DIR"
    ;;
  *)
    log_error "unknown option "
    subcommand_usage
    exit 1
    ;;
  esac
  exit 0
}

main "$@"
exit 0
