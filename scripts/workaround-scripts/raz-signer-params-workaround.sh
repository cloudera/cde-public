#!/bin/bash

# --- Configuration ---
NAMESPACE=$2
CONFIGMAP_NAME="clientconfigs-default-hadoop-conf"
XML_KEY="core-site.xml"
BACKUP_FILE="${CONFIGMAP_NAME}.original.yaml"

# --- PROPERTIES TO CHANGE ---
PROP_TO_REMOVE_1="fs.s3a.custom.signers"
PROP_TO_REMOVE_2="fs.s3a.s3.signing-algorithm"

PROP_TO_ADD_1_NAME="fs.s3a.http.signer.class"
PROP_TO_ADD_1_VALUE="org.apache.ranger.raz.hook.s3.RazS3SignerPlugin"

PROP_TO_ADD_2_NAME="fs.s3a.http.signer.enabled"
PROP_TO_ADD_2_VALUE="true"
# --------------------------

# Stop the script if any command fails
set -e

# Function to check for required tools
check_deps() {
  for cmd in kubectl jq xmlstarlet base64; do
    if ! command -v $cmd &> /dev/null; then
      echo "ERROR: '$cmd' is not installed. Please install it to continue."
      exit 1
    fi
  done
  echo "All required tools (kubectl, jq, xmlstarlet, base64) are present."
}

# Get the current base64-encoded data from the ConfigMap
get_current_xml_data() {
#   echo "Fetching current ConfigMap..."
  kubectl get cm "$CONFIGMAP_NAME" -n "$NAMESPACE" -o json | \
    jq -r ".binaryData[\"$XML_KEY\"]"
}

# Function to run the test modifications
run_test() {
  echo "--- Backing up original ConfigMap to $BACKUP_FILE ---"
  kubectl get cm "$CONFIGMAP_NAME" -n "$NAMESPACE" -o yaml > "$BACKUP_FILE"
  if [ $? -ne 0 ]; then
    echo "ERROR: Failed to back up ConfigMap. Does it exist in namespace '$NAMESPACE'?"
    exit 1
  fi
  echo "Backup successful."

  echo "\n--- Modifying $XML_KEY ---"
  
  # Get, decode, and modify the XML
  local original_xml
  original_xml=$(get_current_xml_data | base64 --decode)

  if [ -z "$original_xml" ]; then
    echo "ERROR: Could not decode $XML_KEY from ConfigMap. Is the key correct?"
    exit 1
  fi

  local modified_xml
  modified_xml=$(echo "$original_xml" | \
    xmlstarlet ed -d "//property[name='$PROP_TO_REMOVE_1']" | \
    xmlstarlet ed -d "//property[name='$PROP_TO_REMOVE_2']" | \
    xmlstarlet ed -s "//configuration" -t elem -n "property" \
                   -s "//property[last()]" -t elem -n "name" -v "$PROP_TO_ADD_1_NAME" \
                   -s "//property[last()]" -t elem -n "value" -v "$PROP_TO_ADD_1_VALUE" | \
    xmlstarlet ed -s "//configuration" -t elem -n "property" \
                   -s "//property[last()]" -t elem -n "name" -v "$PROP_TO_ADD_2_NAME" \
                   -s "//property[last()]" -t elem -n "value" -v "$PROP_TO_ADD_2_VALUE"
  )
  
  echo "\n--- Re-encoding and patching ConfigMap '$CONFIGMAP_NAME' ---"

  # Re-encode for binaryData. Use -w 0 for no line wraps.
  local new_base64_data
  new_base64_data=$(echo "$modified_xml" | base64 -w 0)
  
#   Create the patch string. Note the patch path is /binaryData, not /data
  local patch_string
  patch_string=$(printf '[{"op": "replace", "path": "/binaryData/%s", "value":"%s"}]' "$XML_KEY" "$new_base64_data")

#   Apply the patch
  kubectl patch cm "$CONFIGMAP_NAME" -n "$NAMESPACE" --type='json' -p="$patch_string"

  echo "\n--- ConfigMap has been patched ---"
}

# Function to restore the original ConfigMap
restore_config() {
  if [ ! -f "$BACKUP_FILE" ]; then
    echo "ERROR: Backup file $BACKUP_FILE not found."
    echo "Cannot restore. Please check the ConfigMap manually."
    exit 1
  fi

  echo "--- Restoring original ConfigMap from $BACKUP_FILE ---"
  kubectl apply -f "$BACKUP_FILE"
  echo "--- Restore complete. ---"
}

# --- Main script logic ---
usage() {
  echo "Usage: $0 [command] [vc-id, ex: dex-app-c59x5d57]"
  echo "Commands:"
  echo "  run_test   Backs up the ConfigMap, applies your modifications, and patches the cluster."
  echo "  restore    Restores the original ConfigMap from the local backup."
}

# Check dependencies first
check_deps

# Parse command
case "$1" in
  run_test)
    run_test
    ;;
  restore)
    restore_config
    ;;
  *)
    usage
    exit 1
    ;;
esac

