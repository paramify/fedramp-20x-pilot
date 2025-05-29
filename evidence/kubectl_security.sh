#!/bin/bash

# Helper script for EKS Kubernetes Security Configuration Validation

# Steps:
# 1. Examine pod security contexts and configurations
#    kubectl get pods -A -o jsonpath=....
#
# 2. Examine pod policies and validation configurations
#    kubectl get validatingwebhookconfigurations -A -o yaml
#
# 3. Check pod security policies
#    kubectl get psp -o yaml
#
# 4. Check network policies
#    kubectl get networkpolicies -A -o yaml
#
# Output: Creates JSON report with Kubernetes security configuration status

# Exit on any error
set -e

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
COMPONENT="kubectl_security"
OUTPUT_JSON="$OUTPUT_DIR/$COMPONENT.json"

# ANSI color codes for better output readability
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Function to check if kubectl is configured
check_kubectl() {
    if ! command -v kubectl &> /dev/null; then
        echo -e "${RED}Error: kubectl is not installed${NC}"
        return 1
    fi
    
    # Try to get cluster info with a timeout
    if ! timeout 10s kubectl cluster-info &> /dev/null; then
        echo -e "${RED}Error: kubectl is not properly configured or cluster is not accessible${NC}"
        return 1
    fi
    
    # Additional check to verify we can actually access the cluster
    if ! timeout 10s kubectl get nodes &> /dev/null; then
        echo -e "${RED}Error: Cannot access cluster nodes. Check your kubectl configuration.${NC}"
        return 1
    fi
    
    return 0
}

# Initialize JSON file
echo '{
  "metadata": {
    "region": "'"$REGION"'",
    "profile": "'"$PROFILE"'",
    "datetime": "'"$(date -u +"%Y-%m-%dT%H:%M:%SZ")"'"
  },
  "results": [],
  "summary": {
    "least_privilege_summary": {
      "total_containers": 0,
      "run_as_non_root": 0,
      "allow_privilege_escalation_false": 0,
      "read_only_root_filesystem": 0,
      "drop_all_capabilities": 0,
      "privileged_containers": [],
      "missing_context_containers": [],
      "excessive_capabilities_containers": []
    },
    "formatted_summary": ""
  }
}' > "$OUTPUT_JSON"

# Get list of EKS clusters
echo -e "${BLUE}Retrieving EKS clusters...${NC}"
clusters=$(aws eks list-clusters --profile "$PROFILE" --region "$REGION" --query "clusters" --output json 2>/dev/null)
if [ $? -ne 0 ]; then
    echo -e "${RED}Error: Failed to list EKS clusters${NC}"
    exit 1
fi

# Track if any cluster was successfully processed
any_cluster_successful=false
error_occurred=false

# Process each cluster
while read -r cluster_name; do
    echo -e "${BLUE}Processing cluster: $cluster_name${NC}"
    
    # Update kubeconfig for the cluster
    if ! aws eks update-kubeconfig --region "$REGION" --name "$cluster_name" --profile "$PROFILE" 2>&1 | while read -r line; do
        if [[ $line =~ ^Updated\ context ]]; then
            echo -e "${BLUE}$line${NC}"
        else
            echo "$line"
        fi
    done; then
        echo -e "${RED}Error: Failed to update kubeconfig for cluster $cluster_name${NC}"
        error_occurred=true
        continue
    fi
    
    # Check kubectl configuration
    if ! check_kubectl; then
        echo -e "${RED}Error: kubectl configuration check failed for cluster $cluster_name${NC}"
        error_occurred=true
        continue
    fi
    
    # If we get here, we successfully processed at least one cluster
    any_cluster_successful=true
    
    # Get pod security contexts
    echo -e "${BLUE}Retrieving pod security contexts...${NC}"
    if ! pod_security_contexts=$(kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{range .spec.containers[*]} container: {.name}{"\n"} securityContext: {.securityContext}{"\n"}{end}{"\n"}{end}'); then
        echo -e "${RED}Error: Failed to retrieve pod security contexts for cluster $cluster_name${NC}"
        error_occurred=true
        continue
    fi
    
    # Get other security configurations
    if ! webhook_configs=$(kubectl get validatingwebhookconfigurations -A -o yaml); then
        echo -e "${RED}Error: Failed to retrieve webhook configurations for cluster $cluster_name${NC}"
        error_occurred=true
        continue
    fi
    
    if ! network_policies=$(kubectl get networkpolicies -A -o yaml); then
        echo -e "${RED}Error: Failed to retrieve network policies for cluster $cluster_name${NC}"
        error_occurred=true
        continue
    fi
    
    # Process security contexts and update summary
    if ! echo "$pod_security_contexts" | jq -R -s '
      split("\n\n")[] |
      select(length > 0) |
      split("\n") as $lines |
      {
        pod: ($lines[0]),
        container: ($lines[1] | sub("container: "; "")),
        context: ($lines[2] | sub("securityContext: "; "") | fromjson? // {})
      }' | jq -s '
      reduce .[] as $item (
        {
          total: 0,
          runAsNonRoot: 0,
          allowPrivilegeEscalationFalse: 0,
          readOnlyRootFilesystem: 0,
          dropAllCaps: 0,
          privilegedContainers: [],
          missingContextContainers: [],
          excessiveCapsContainers: []
        };
        .total += 1
        |
        if ($item.context | length == 0) then
          .missingContextContainers += [($item.container)]
        else (
          if $item.context.runAsNonRoot == true then .runAsNonRoot += 1 end
          |
          if $item.context.allowPrivilegeEscalation == false then .allowPrivilegeEscalationFalse += 1 end
          |
          if $item.context.readOnlyRootFilesystem == true then .readOnlyRootFilesystem += 1 end
          |
          if ($item.context.capabilities?.drop // []) | index("ALL") then .dropAllCaps += 1 end
          |
          if $item.context.privileged == true then .privilegedContainers += [($item.container)] end
          |
          if ($item.context.capabilities?.add // []) | length > 0 then .excessiveCapsContainers += [($item.container)] end
        )
      )' > tmp_summary.json; then
        echo -e "${RED}Error: Failed to process security contexts for cluster $cluster_name${NC}"
        error_occurred=true
        continue
    fi
    
    # Update the main JSON file with the summary
    if ! jq --slurpfile summary tmp_summary.json '.summary.least_privilege_summary = {
        "total_containers": $summary[0].total,
        "run_as_non_root": $summary[0].runAsNonRoot,
        "allow_privilege_escalation_false": $summary[0].allowPrivilegeEscalationFalse,
        "read_only_root_filesystem": $summary[0].readOnlyRootFilesystem,
        "drop_all_capabilities": $summary[0].dropAllCaps,
        "privileged_containers": $summary[0].privilegedContainers,
        "missing_context_containers": $summary[0].missingContextContainers,
        "excessive_capabilities_containers": $summary[0].excessiveCapsContainers
    }' "$OUTPUT_JSON" > tmp.json; then
        echo -e "${RED}Error: Failed to update JSON summary for cluster $cluster_name${NC}"
        error_occurred=true
        continue
    fi
    mv tmp.json "$OUTPUT_JSON"
    
    # Add cluster data to results
    cluster_data=$(jq -n \
        --arg name "$cluster_name" \
        --arg contexts "$pod_security_contexts" \
        --arg webhooks "$webhook_configs" \
        --arg network "$network_policies" \
        '{
            "clusterName": $name,
            "podSecurityContexts": $contexts,
            "validatingWebhooks": $webhooks,
            "networkPolicies": $network
        }')
    
    if ! jq --argjson cluster "$cluster_data" '.results += [$cluster]' "$OUTPUT_JSON" > tmp.json; then
        echo -e "${RED}Error: Failed to add cluster data to JSON for cluster $cluster_name${NC}"
        error_occurred=true
        continue
    fi
    mv tmp.json "$OUTPUT_JSON"
    
    # Generate formatted summary for this cluster
    formatted_summary=$(jq -r '
      .summary.least_privilege_summary |
      "Least Privilege Summary for Cluster '"$cluster_name"':\n" +
      "- Total Containers: \(.total_containers)\n" +
      "- With '\''runAsNonRoot'\'': \(.run_as_non_root)\n" +
      "- With '\''allowPrivilegeEscalation: false'\'': \(.allow_privilege_escalation_false)\n" +
      "- With '\''readOnlyRootFilesystem'\'': \(.read_only_root_filesystem)\n" +
      "- With '\''capabilities: drop [ALL]'\'': \(.drop_all_capabilities)\n" +
      "- Containers running as privileged: \(.privileged_containers | length) (\(.privileged_containers | unique | join(", ")))\n" +
      "- Containers with no securityContext defined: \(.missing_context_containers | length) (\(.missing_context_containers | unique | join(", ")))\n" +
      "- Containers with excessive capabilities: \(.excessive_capabilities_containers | length) (\(.excessive_capabilities_containers | unique | join(", ")))"
    ' "$OUTPUT_JSON")
    
    # Update JSON with formatted summary
    if ! jq --arg summary "$formatted_summary" '.summary.formatted_summary = $summary' "$OUTPUT_JSON" > tmp.json; then
        echo -e "${RED}Error: Failed to update formatted summary for cluster $cluster_name${NC}"
        error_occurred=true
        continue
    fi
    mv tmp.json "$OUTPUT_JSON"
    
    # Add to CSV with detailed metrics
    echo "$COMPONENT,cluster,$cluster_name,$(jq -r '.summary.least_privilege_summary | 
      "\(.total_containers),\(.run_as_non_root),\(.allow_privilege_escalation_false),\(.read_only_root_filesystem),\(.drop_all_capabilities),\(.privileged_containers | length),\(.missing_context_containers | length),\(.excessive_capabilities_containers | length)"' "$OUTPUT_JSON")" >> "$CSV_FILE"
    
    # Clean up temporary files
    rm -f tmp_summary.json
done < <(echo "$clusters" | jq -r '.[]')

# Check if any cluster was successfully processed
if [ "$any_cluster_successful" = false ]; then
    echo -e "${RED}Error: No clusters were successfully processed${NC}"
    exit 1
fi

# If any error occurred during processing, exit with error
if [ "$error_occurred" = true ]; then
    echo -e "${RED}Error: Some clusters had processing errors${NC}"
    exit 1
fi

# Print final summary
echo -e "\n${GREEN}Least Privilege Summary:${NC}"
echo -e "${BLUE}---------------------------${NC}"
jq -r '.summary.formatted_summary' "$OUTPUT_JSON"

exit 0 