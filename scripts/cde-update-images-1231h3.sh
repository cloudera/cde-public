#!/usr/bin/env bash
# The steps will work irrespective of spark versions, since we are replacing only the image tag. It is not required to run these for Spark 2.x VCs

# The following script works in bash, confirm if you are in bash shell and on latest bash version and given kubectl version. (It could work on other bash versions, but not tested)

echo "-------------------------------------"

echo "Bash version"
echo $BASH_VERSION
# 5.2.37(1)-release
echo "kubectl version"
kubectl version --client
# Client Version: v1.30.*
 
echo "-------------------------------------"




# Accept DEX_APP_ID as a parameter with validation
if [ $# -eq 0 ]; then
    echo "Error: Missing DEX_APP_ID parameter"
    echo "Usage: $0 <dex-app-id>"
    exit 1
fi

DEX_APP_ID=$1

# Validate format
if [[ ! $DEX_APP_ID =~ ^dex-app-[a-zA-Z0-9_-]+$ ]]; then
    echo "Error: Invalid DEX_APP_ID format. It should be in the form 'dex-app-<app_id>'"
    exit 1
fi

# Check for DEX_APP_ID and optional KUBECONFIG parameters
if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    echo "Error: Incorrect number of parameters"
    echo "Usage: $0 <dex-app-id> [kubeconfig-path]"
    exit 1
fi

DEX_APP_ID=$1

# Set KUBECONFIG if provided as second parameter
if [ $# -eq 2 ]; then
    export KUBECONFIG=$2
    if [ ! -f "$KUBECONFIG" ]; then
        echo "Error: KUBECONFIG file not found: $KUBECONFIG"
        exit 1
    fi
else
    echo "Error: No KUBECONFIG provided"
    echo "Usage: $0 <dex-app-id> <kubeconfig-path>"
    exit 1
fi

# Print KUBECONFIG and DEX_APP_ID information
echo "DEX_APP_ID: $DEX_APP_ID"
echo "KUBECONFIG: ${KUBECONFIG:-<default>}"
echo "-------------------------------------"
# Other variables
set -x
NAMESPACE=$DEX_APP_ID
DEX_APP_SUFFIX=${DEX_APP_ID#dex-app-}
SPARK_DEFAULTS_CONFIGMAP="spark-defaults-conf-config-map-dex-app-${DEX_APP_SUFFIX}"
SPARK_RUNTIME_KEY="spark.kubernetes.container.image" 
SPARK_RUNTIME_KEY_ESCAPED="spark\.kubernetes\.container\.image"  

NEW_TAG="1.23.1-h3-b2"

# Step 1: Update Spark runtime
# 1. Backup the configmap before updating
kubectl -n $NAMESPACE get configmap $SPARK_DEFAULTS_CONFIGMAP -o=yaml > $SPARK_DEFAULTS_CONFIGMAP.yaml

# 2. Get the current image value
CURRENT_IMAGE=$(kubectl -n $NAMESPACE get configmap $SPARK_DEFAULTS_CONFIGMAP -o jsonpath="{.data.$SPARK_RUNTIME_KEY_ESCAPED}")

# 3. Replace the tag
NEW_IMAGE="${CURRENT_IMAGE%:*}:$NEW_TAG"

# 4. Patch the configmap
kubectl -n $NAMESPACE patch configmap $SPARK_DEFAULTS_CONFIGMAP --type merge -p "{\"data\":{\"$SPARK_RUNTIME_KEY\":\"$NEW_IMAGE\"}}"

# 5. Verify the update
kubectl -n $NAMESPACE get configmap $SPARK_DEFAULTS_CONFIGMAP -o=yaml | grep $NEW_TAG


 
# Step 2: Update Livy runtime
DEX_APP_CONFIGMAP=$DEX_APP_ID-api-cm
LIVY_RUNTIME_IMAGE_KEY_ESCAPED="dex\.yaml"
LIVY_RUNTIME_IMAGE_KEY="dex.yaml"

# 1. backup the configmap
kubectl -n $NAMESPACE get configmap $DEX_APP_CONFIGMAP -o yaml > $DEX_APP_CONFIGMAP.yaml

# 2. Get the current dex.yaml value and decode any escaped newlines
kubectl -n $NAMESPACE get configmap $DEX_APP_CONFIGMAP -o jsonpath="{.data.$LIVY_RUNTIME_IMAGE_KEY_ESCAPED}" > dex_app_config_value.yaml

# 3. Update the livyRuntime.image tag (replace only the tag after the last colon)
sed "s|\(cloudera/dex/dex-livy-runtime[^:]*:\)[^\"]*|\1$NEW_TAG|g" dex_app_config_value.yaml > dex_app_config_value_updated.yaml


# 4. Update the configmap with the new value
kubectl -n $NAMESPACE create configmap $DEX_APP_CONFIGMAP --from-file=$LIVY_RUNTIME_IMAGE_KEY=dex_app_config_value_updated.yaml --dry-run=client -o yaml | kubectl apply -f -

# 5. Verify update
kubectl -n $NAMESPACE get configmap $DEX_APP_CONFIGMAP -o yaml | grep $NEW_TAG
# output might be long, but presence ouput indicates the configmap is updated.

# 6. Clean up
rm dex_app_config_value_updated.yaml
rm dex_app_config_value.yaml

# 7. Restart dex-app-api deployment

kubectl -n $NAMESPACE rollout restart deployment dex-app-${DEX_APP_SUFFIX}-api

# Step 3: Update Livy server image
LIVY_SERVER_DEPLOYMENT="dex-app-${DEX_APP_SUFFIX}-livy"
LIVY_SERVER_CONTAINER="livy"

# 1. Backup the deployment object
kubectl -n $NAMESPACE get deployment $LIVY_SERVER_DEPLOYMENT -o yaml > $LIVY_SERVER_DEPLOYMENT.yaml

# 2. Get the current image
LIVY_SERVER_IMAGE=$(kubectl -n $NAMESPACE get deployment $LIVY_SERVER_DEPLOYMENT -o jsonpath="{.spec.template.spec.containers[?(@.name==\"$LIVY_SERVER_CONTAINER\")].image}")

echo "Current image: $LIVY_SERVER_IMAGE"



# 3. Replace the tag in the image 
NEW_IMAGE="${LIVY_SERVER_IMAGE%:*}:$NEW_TAG"
echo "Updating to: $NEW_IMAGE"

# 4. Update the deployment 
kubectl -n $NAMESPACE set image deployment/$LIVY_SERVER_DEPLOYMENT $LIVY_SERVER_CONTAINER=$NEW_IMAGE

# 5. Verify the update
kubectl -n $NAMESPACE get deployment $LIVY_SERVER_DEPLOYMENT -o yaml | grep $NEW_TAG
