#!/bin/bash

# Helper script for EKS Microservice Segmentation Validation

# Steps:
# 1. Check for default deny network policies across namespaces
#    kubectl get networkpolicies -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.spec.policyTypes}{"\n"}{end}'
#
# 2. Verify VPC CNI plugin configuration for network policy enforcement
#    kubectl describe daemonset aws-node -n kube-system | grep ENABLE_NETWORK_POLICY
#    kubectl describe daemonset aws-node -n kube-system | grep amazon-vpc-cni:
#
# 3. Examine security group policies for pods
#    kubectl get securitygrouppolicies.vpcresources.k8s.aws -A -o yaml
#
# 4. Check worker node security group configurations
#    aws ec2 describe-instances --filters "Name=tag:kubernetes.io/cluster/<CLUSTER_NAME>,Values=owned"
#    aws ec2 describe-instances --instance-ids <INSTANCE_ID> --query "Reservations[*].Instances[*].SecurityGroups"
#
# 5. Verify pod resource limits and isolation
#    kubectl get pods --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.spec.containers[*].resources}{"\n"}{end}'
#
# Output: Creates JSON report with microservice segmentation status and CSV metrics

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
COMPONENT="eks_microservice_segmentation"
OUTPUT_JSON="$OUTPUT_DIR/$COMPONENT.json"

# ANSI color codes for better output readability
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Initialize JSON file
echo '{
  "metadata": {
    "region": "'"$REGION"'",
    "profile": "'"$PROFILE"'",
    "datetime": "'"$(date -u +"%Y-%m-%dT%H:%M:%SZ")"'"
  },
  "results": [],
  "summary": {
    "clusters": {
      "total": 0,
      "with_default_deny": 0,
      "with_resource_limits": 0,
      "with_security_groups": 0
    }
  }
}' > "$OUTPUT_JSON"

# Get list of EKS clusters
echo -e "${BLUE}Retrieving EKS clusters...${NC}"
clusters=$(aws eks list-clusters --profile "$PROFILE" --region "$REGION" --query "clusters" --output json 2>&1)
if [ $? -ne 0 ]; then
    echo -e "${RED}Error: Failed to list EKS clusters. Error message:${NC}"
    echo "$clusters"
    exit 1
fi

# Check if any clusters were found
if [ "$(echo "$clusters" | jq -r '. | length')" -eq 0 ]; then
    echo -e "${YELLOW}No EKS clusters found in region $REGION${NC}"
    exit 0
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
    if ! timeout 10s kubectl cluster-info &> /dev/null; then
        echo -e "${RED}Error: kubectl is not properly configured or cluster is not accessible${NC}"
        error_occurred=true
        continue
    fi
    
    # If we get here, we successfully processed at least one cluster
    any_cluster_successful=true
    
    # 1. Check for default deny network policies
    echo -e "${BLUE}Checking for default deny network policies...${NC}"
    default_deny_policies=$(kubectl get networkpolicies -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.spec.policyTypes}{"\n"}{end}' | grep -i "deny")
    
    # 2. Check VPC CNI plugin configuration
    echo -e "${BLUE}Checking VPC CNI plugin configuration...${NC}"
    cni_config=$(kubectl describe daemonset aws-node -n kube-system | grep -E "ENABLE_NETWORK_POLICY|amazon-vpc-cni:")
    
    # 3. Check security group policies
    echo -e "${BLUE}Checking security group policies...${NC}"
    security_group_policies=$(kubectl get securitygrouppolicies.vpcresources.k8s.aws -A -o yaml 2>/dev/null || echo "")
    
    # 4. Get worker node security groups
    echo -e "${BLUE}Checking worker node security groups...${NC}"
    node_instance_ids=$(aws ec2 describe-instances \
        --filters "Name=tag:kubernetes.io/cluster/$cluster_name,Values=owned" \
        --query "Reservations[*].Instances[*].InstanceId" \
        --output text --region "$REGION" --profile "$PROFILE")
    
    node_security_groups=""
    for id in $node_instance_ids; do
        node_security_groups+=$(aws ec2 describe-instances \
            --instance-ids "$id" \
            --query "Reservations[*].Instances[*].SecurityGroups" \
            --output json --region "$REGION" --profile "$PROFILE")
    done
    
    # 5. Check pod resource limits and isolation
    echo -e "${BLUE}Checking pod resource limits and isolation...${NC}"
    pod_resources=$(kubectl get pods --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.spec.containers[*].resources}{"\n"}{end}')
    
    # Initialize cluster data
    cluster_data=$(jq -n \
        --arg name "$cluster_name" \
        --arg default_deny "$default_deny_policies" \
        --arg cni_config "$cni_config" \
        --arg security_groups "$security_group_policies" \
        --arg node_sgs "$node_security_groups" \
        --arg pod_resources "$pod_resources" \
        '{
            "clusterName": $name,
            "defaultDenyPolicies": $default_deny,
            "cniConfig": $cni_config,
            "securityGroupPolicies": $security_groups,
            "nodeSecurityGroups": $node_sgs,
            "podResources": $pod_resources
        }')
    
    # Add cluster data to results
    if ! jq --argjson cluster "$cluster_data" '.results += [$cluster]' "$OUTPUT_JSON" > tmp.json; then
        echo -e "${RED}Error: Failed to add cluster data to JSON for cluster $cluster_name${NC}"
        error_occurred=true
        continue
    fi
    mv tmp.json "$OUTPUT_JSON"
    
    # Update summary counters
    if [ -n "$default_deny_policies" ]; then
        jq '.summary.clusters.with_default_deny += 1' "$OUTPUT_JSON" > tmp.json && mv tmp.json "$OUTPUT_JSON"
    fi
    
    if echo "$pod_resources" | grep -q "limits\|requests"; then
        jq '.summary.clusters.with_resource_limits += 1' "$OUTPUT_JSON" > tmp.json && mv tmp.json "$OUTPUT_JSON"
    fi
    
    if [ -n "$security_group_policies" ]; then
        jq '.summary.clusters.with_security_groups += 1' "$OUTPUT_JSON" > tmp.json && mv tmp.json "$OUTPUT_JSON"
    fi
    
    # Add to CSV
    echo "$COMPONENT,cluster,$cluster_name,$([ -n "$default_deny_policies" ] && echo "true" || echo "false"),$(echo "$pod_resources" | grep -q "limits\|requests" && echo "true" || echo "false"),$([ -n "$security_group_policies" ] && echo "true" || echo "false")" >> "$CSV_FILE"
    
done < <(echo "$clusters" | jq -r '.[]')

# Update total clusters count
jq --arg total "$(echo "$clusters" | jq -r '. | length')" '.summary.clusters.total = ($total | tonumber)' "$OUTPUT_JSON" > tmp.json && mv tmp.json "$OUTPUT_JSON"

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
echo -e "\n${GREEN}Microservice Segmentation Summary:${NC}"
echo -e "${BLUE}--------------------------------${NC}"
jq -r '.summary.clusters | "Total Clusters: \(.total)\nClusters with Default Deny Policies: \(.with_default_deny)\nClusters with Resource Limits: \(.with_resource_limits)\nClusters with Security Groups: \(.with_security_groups)"' "$OUTPUT_JSON"

exit 0 