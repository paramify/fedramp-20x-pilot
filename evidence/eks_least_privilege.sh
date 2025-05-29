#!/bin/bash

# Helper script for AWS EKS Least Privilege and Security Configuration Validation

# Steps:
# 1. Check cluster's pod security standards and logging configuration
#    aws eks describe-cluster --name [cluster-name] --query "cluster.logging"
#
# 2. Review IAM roles associated with pods
#    aws eks list-pod-identity-associations --cluster-name [cluster-name]
#
# 3. Check existing EKS add-ons
#    aws eks list-addons --cluster-name [cluster-name]
#
# Output: Creates JSON report with EKS security configuration status

# Check if required parameters are provided
if [ "$#" -ne 4 ]; then
    echo "Usage: $0 <profile> <region> <output_dir> <csv_file>"
    exit 1
fi

PROFILE="$1"
REGION="$2"
OUTPUT_DIR="$3"
CSV_FILE="$4"

# Component identifier
COMPONENT="eks_least_privilege"
OUTPUT_JSON="$OUTPUT_DIR/$COMPONENT.json"

# ANSI color codes for better output readability
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Initialize JSON file
echo '{
  "results": [],
  "summary": {
    "clusters": {
      "total": 0,
      "logging_enabled": 0,
      "pod_identities": 0
    }
  }
}' > "$OUTPUT_JSON"

# Get list of EKS clusters
echo -e "${BLUE}Retrieving EKS clusters...${NC}"
clusters=$(aws eks list-clusters --profile "$PROFILE" --region "$REGION" --query "clusters" --output json)

# Initialize summary counters
total_clusters=0
logging_enabled=0
total_pod_identities=0

# Process each cluster
while read -r cluster_name; do
    echo -e "${BLUE}Processing cluster: $cluster_name${NC}"
    total_clusters=$((total_clusters + 1))
    
    # Get cluster logging configuration
    logging_config=$(aws eks describe-cluster \
        --profile "$PROFILE" \
        --region "$REGION" \
        --name "$cluster_name" \
        --query "cluster.logging" \
        --output json)
    
    # Get pod identity associations
    pod_identities=$(aws eks list-pod-identity-associations \
        --profile "$PROFILE" \
        --region "$REGION" \
        --cluster-name "$cluster_name" \
        --output json)
    
    # Get EKS add-ons
    addons=$(aws eks list-addons \
        --profile "$PROFILE" \
        --region "$REGION" \
        --cluster-name "$cluster_name" \
        --output json)
    
    # Update summary counters
    if echo "$logging_config" | jq -e '.clusterLogging[0].enabled == true' > /dev/null; then
        logging_enabled=$((logging_enabled + 1))
    fi
    pod_identity_count=$(echo "$pod_identities" | jq -r '.associations | length // 0')
    total_pod_identities=$((total_pod_identities + pod_identity_count))
    
    # Initialize cluster data
    cluster_data=$(jq -n \
        --arg name "$cluster_name" \
        --argjson logging "$logging_config" \
        --argjson identities "$pod_identities" \
        --argjson addons "$addons" \
        '{
            "clusterName": $name,
            "loggingConfig": $logging,
            "podIdentities": $identities,
            "addons": $addons
        }')
    
    # Add cluster data to results
    jq --argjson cluster "$cluster_data" '.results += [$cluster]' "$OUTPUT_JSON" > tmp.json && mv tmp.json "$OUTPUT_JSON"
    
    # Add to CSV
    echo "$COMPONENT,cluster,$cluster_name,$(echo "$cluster_data" | jq -r '.loggingConfig.clusterLogging[0].enabled'),$(echo "$cluster_data" | jq -r '.podIdentities.associations | length // 0')" >> "$CSV_FILE"
done < <(echo "$clusters" | jq -r '.[]')

# Update summary in JSON
jq --arg total "$total_clusters" \
   --arg logging "$logging_enabled" \
   --arg identities "$total_pod_identities" \
   '.summary.clusters = {
       "total": ($total | tonumber),
       "logging_enabled": ($logging | tonumber),
       "pod_identities": ($identities | tonumber)
   }' "$OUTPUT_JSON" > tmp.json && mv tmp.json "$OUTPUT_JSON"

exit 0
