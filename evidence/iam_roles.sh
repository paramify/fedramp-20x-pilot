#!/bin/bash
# Helper script for AWS IAM roles validation

# Steps:
# 1. List all IAM roles
#    aws iam list-roles --query 'Roles[*].[RoleName,Arn,CreateDate]'
#
# 2. For each role, get:
#    - Role details
#    aws iam get-role
#    - Trust relationships
#    aws iam get-role (for AssumeRolePolicyDocument)
#    - Attached policies
#    aws iam list-attached-role-policies
#    - Instance profiles
#    aws iam list-instance-profiles-for-role
#    - Tags
#    aws iam list-role-tags
#
# Output: Creates JSON with IAM role details and writes to CSV

# Default values
EXCLUDE_AWS_ROLES=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --exclude-aws-managed-roles)
            EXCLUDE_AWS_ROLES=true
            shift
            ;;
        *)
            # Store positional arguments
            if [ -z "$PROFILE" ]; then
                PROFILE="$1"
            elif [ -z "$REGION" ]; then
                REGION="$1"
            elif [ -z "$OUTPUT_DIR" ]; then
                OUTPUT_DIR="$1"
            elif [ -z "$OUTPUT_CSV" ]; then
                OUTPUT_CSV="$1"
            fi
            shift
            ;;
    esac
done

# Check if required parameters are provided
if [ -z "$PROFILE" ] || [ -z "$REGION" ] || [ -z "$OUTPUT_DIR" ] || [ -z "$OUTPUT_CSV" ]; then
    echo "Usage: $0 [--exclude-aws-managed-roles] <profile> <region> <output_dir> <output_csv>"
    exit 1
fi

# Component identifier
COMPONENT="iam_roles"
OUTPUT_JSON="$OUTPUT_DIR/$COMPONENT.json"

# ANSI color codes for better output readability
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Initialize JSON file
echo '{"results": []}' > "$OUTPUT_JSON"

# Get all IAM roles
echo -e "${BLUE}Retrieving IAM roles...${NC}"
roles=$(aws iam list-roles --profile "$PROFILE" --query 'Roles[*].[RoleName,Arn,CreateDate]' --output json)

# Process each role
echo "$roles" | jq -c '.[]' | while read -r role; do
    role_name=$(echo "$role" | jq -r '.[0]')
    role_arn=$(echo "$role" | jq -r '.[1]')
    
    # Skip AWS managed roles if option is enabled
    if [ "$EXCLUDE_AWS_ROLES" = true ] && [[ "$role_arn" == arn:aws:iam::aws:role/* ]]; then
        echo -e "${YELLOW}Skipping AWS managed role: $role_name${NC}"
        continue
    fi
    
    echo -e "${BLUE}Processing role: $role_name${NC}"
    
    # Get role details
    role_data=$(aws iam get-role --profile "$PROFILE" --role-name "$role_name" --query 'Role' --output json)
    
    # Get trust relationships
    trust_policy=$(aws iam get-role --profile "$PROFILE" --role-name "$role_name" --query 'Role.AssumeRolePolicyDocument' --output json)
    
    # Get attached policies
    attached_policies=$(aws iam list-attached-role-policies --profile "$PROFILE" --role-name "$role_name" --query 'AttachedPolicies[*].[PolicyName,PolicyArn]' --output json)
    
    # Get instance profiles
    instance_profiles=$(aws iam list-instance-profiles-for-role --profile "$PROFILE" --role-name "$role_name" --query 'InstanceProfiles[*].[InstanceProfileName,InstanceProfileId]' --output json)
    
    # Get role tags
    role_tags=$(aws iam list-role-tags --profile "$PROFILE" --role-name "$role_name" --query 'Tags[*]' --output json)
    
    # Combine all role data
    role_info=$(jq -n \
        --argjson role "$role_data" \
        --argjson trust "$trust_policy" \
        --argjson policies "$attached_policies" \
        --argjson profiles "$instance_profiles" \
        --argjson tags "$role_tags" \
        '{
            "RoleName": $role.RoleName,
            "Arn": $role.Arn,
            "CreateDate": $role.CreateDate,
            "Description": $role.Description,
            "MaxSessionDuration": $role.MaxSessionDuration,
            "TrustPolicy": $trust,
            "AttachedPolicies": $policies,
            "InstanceProfiles": $profiles,
            "Tags": $tags
        }')
    
    # Add to JSON
    jq --argjson role "$role_info" '.results += [$role]' "$OUTPUT_JSON" > tmp.json && mv tmp.json "$OUTPUT_JSON"
    
    # Add to CSV
    echo "$COMPONENT,role,$role_name,$(echo "$role_info" | jq -r '.CreateDate'),$(echo "$role_info" | jq -r '.Description')" >> "$OUTPUT_CSV"
done

# Get account password policy
echo -e "${BLUE}Retrieving account password policy...${NC}"
password_policy=$(aws iam get-account-password-policy --profile "$PROFILE" --query 'PasswordPolicy' --output json)

# Add password policy to results
jq --argjson policy "$password_policy" '.results += [{"Type": "PasswordPolicy", "Policy": $policy}]' "$OUTPUT_JSON" > tmp.json && mv tmp.json "$OUTPUT_JSON"

# Add to CSV
echo "$COMPONENT,password_policy,$(echo "$password_policy" | jq -r '.MinimumPasswordLength'),$(echo "$password_policy" | jq -r '.RequireSymbols'),$(echo "$password_policy" | jq -r '.RequireNumbers')" >> "$OUTPUT_CSV"

exit 0 