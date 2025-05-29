#!/bin/bash
# Helper script for IAM policies validation

# Steps:
# 1. List all IAM policies
#    aws iam list-policies --scope Local --query 'Policies[*].[PolicyName,PolicyId,Arn]'
#
# 2. For each policy, get:
#    - Policy details
#    aws iam get-policy
#    - Policy version
#    aws iam get-policy-version
#    - Policy document
#    aws iam get-policy-version (for PolicyVersion.Document)
#    - Attached entities (users, groups, roles)
#    aws iam list-entities-for-policy
#
# Output: Creates JSON with IAM policy details and writes to CSV

# Check if required parameters are provided
if [ "$#" -lt 4 ]; then
    echo "Usage: $0 <profile> <region> <output_dir> <output_csv>"
    exit 1
fi

PROFILE="$1"
REGION="$2"
OUTPUT_DIR="$3"
OUTPUT_CSV="$4"

# Component identifier
COMPONENT="iam_policies"
OUTPUT_JSON="$OUTPUT_DIR/$COMPONENT.json"

# ANSI color codes for better output readability
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Initialize JSON file
echo '{"results": []}' > "$OUTPUT_JSON"

# Get all IAM policies
echo -e "${BLUE}Retrieving IAM policies...${NC}"
policies=$(aws iam list-policies --profile "$PROFILE" --scope Local --query 'Policies[*].[PolicyName,PolicyId,Arn]' --output json)

# Process each policy
echo "$policies" | jq -c '.[]' | while read -r policy; do
    policy_name=$(echo "$policy" | jq -r '.[0]')
    policy_id=$(echo "$policy" | jq -r '.[1]')
    policy_arn=$(echo "$policy" | jq -r '.[2]')
    
    echo -e "${BLUE}Processing policy: $policy_name${NC}"
    
    # Get policy details
    policy_data=$(aws iam get-policy --profile "$PROFILE" --policy-arn "$policy_arn" --query 'Policy' --output json)
    
    # Get default policy version
    default_version=$(echo "$policy_data" | jq -r '.DefaultVersionId')
    
    # Get policy document
    policy_doc=$(aws iam get-policy-version --profile "$PROFILE" --policy-arn "$policy_arn" --version-id "$default_version" --query 'PolicyVersion.Document' --output json)
    
    # Get attached entities
    attached_entities=$(aws iam list-entities-for-policy --profile "$PROFILE" --policy-arn "$policy_arn" --query '[PolicyGroups[*].GroupName,PolicyUsers[*].UserName,PolicyRoles[*].RoleName]' --output json)
    
    # Combine all policy data
    policy_info=$(jq -n \
        --argjson policy "$policy_data" \
        --argjson doc "$policy_doc" \
        --argjson entities "$attached_entities" \
        '{
            "PolicyName": $policy.PolicyName,
            "PolicyId": $policy.PolicyId,
            "Arn": $policy.Arn,
            "CreateDate": $policy.CreateDate,
            "UpdateDate": $policy.UpdateDate,
            "Description": $policy.Description,
            "PolicyDocument": $doc,
            "AttachedGroups": $entities[0],
            "AttachedUsers": $entities[1],
            "AttachedRoles": $entities[2]
        }')
    
    # Add to JSON
    jq --argjson policy "$policy_info" '.results += [$policy]' "$OUTPUT_JSON" > tmp.json && mv tmp.json "$OUTPUT_JSON"
    
    # Add to CSV
    echo "$COMPONENT,policy,$policy_name,$(echo "$policy_info" | jq -r '.CreateDate'),$(echo "$policy_info" | jq -r '.UpdateDate')" >> "$OUTPUT_CSV"
done

exit 0 