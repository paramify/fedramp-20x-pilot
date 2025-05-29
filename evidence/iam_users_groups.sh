#!/bin/bash
# Helper script for IAM users and groups validation

# Steps:
# 1. List all IAM users
#    aws iam list-users --query 'Users[*].[UserName,CreateDate,PasswordLastUsed]'
#
# 2. List all IAM groups
#    aws iam list-groups --query 'Groups[*].[GroupName,CreateDate]'
#
# 3. For each user, get:
#    - User details
#    aws iam get-user
#    - Group memberships
#    aws iam list-groups-for-user
#    - Access keys
#    aws iam list-access-keys
#    - MFA devices
#    aws iam list-mfa-devices
#    - Login profile
#    aws iam get-login-profile
#
# 4. For each group, get:
#    - Group details
#    aws iam get-group
#    - Group policies
#    aws iam list-attached-group-policies
#
# Output: Creates JSON with IAM user/group details and writes to CSV

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
COMPONENT="iam_users_groups"
OUTPUT_JSON="$OUTPUT_DIR/$COMPONENT.json"

# ANSI color codes for better output readability
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Initialize JSON file
echo '{"results": {"users": [], "groups": []}}' > "$OUTPUT_JSON"

# Get all IAM users
echo -e "${BLUE}Retrieving IAM users...${NC}"
users=$(aws iam list-users --profile "$PROFILE" --query 'Users[*].[UserName,CreateDate,PasswordLastUsed]' --output json)

# Process each user
echo "$users" | jq -c '.[]' | while read -r user; do
    username=$(echo "$user" | jq -r '.[0]')
    echo -e "${BLUE}Processing user: $username${NC}"
    
    # Get user details
    user_data=$(aws iam get-user --profile "$PROFILE" --user-name "$username" --query 'User' --output json)
    
    # Get user groups
    groups=$(aws iam list-groups-for-user --profile "$PROFILE" --user-name "$username" --query 'Groups[*].GroupName' --output json)
    
    # Get access keys
    access_keys=$(aws iam list-access-keys --profile "$PROFILE" --user-name "$username" --query 'AccessKeyMetadata[*].[AccessKeyId,Status,CreateDate]' --output json)
    
    # Get MFA devices
    mfa_devices=$(aws iam list-mfa-devices --profile "$PROFILE" --user-name "$username" --query 'MFADevices[*].[SerialNumber,EnableDate]' --output json)
    
    # Check for login profile
    has_login_profile=false
    if aws iam get-login-profile --profile "$PROFILE" --user-name "$username" > /dev/null 2>&1; then
        has_login_profile=true
    fi
    
    # Combine all user data
    user_info=$(jq -n \
        --argjson user "$user_data" \
        --argjson groups "$groups" \
        --argjson access_keys "$access_keys" \
        --argjson mfa_devices "$mfa_devices" \
        --arg has_login "$has_login_profile" \
        '{
            "UserName": $user.UserName,
            "CreateDate": $user.CreateDate,
            "PasswordLastUsed": $user.PasswordLastUsed,
            "Groups": $groups,
            "AccessKeys": $access_keys,
            "MFADevices": $mfa_devices,
            "HasLoginProfile": ($has_login | test("true"))
        }')
    
    # Add to JSON
    jq --argjson user "$user_info" '.results.users += [$user]' "$OUTPUT_JSON" > tmp.json && mv tmp.json "$OUTPUT_JSON"
    
    # Add to CSV
    echo "$COMPONENT,user,$username,$(echo "$user_info" | jq -r '.CreateDate'),$(echo "$user_info" | jq -r '.PasswordLastUsed'),$(echo "$user_info" | jq -r '.HasLoginProfile')" >> "$OUTPUT_CSV"
done

# Get all IAM groups
echo -e "\n${BLUE}Retrieving IAM groups...${NC}"
groups=$(aws iam list-groups --profile "$PROFILE" --query 'Groups[*].[GroupName,CreateDate]' --output json)

# Process each group
echo "$groups" | jq -c '.[]' | while read -r group; do
    groupname=$(echo "$group" | jq -r '.[0]')
    echo -e "${BLUE}Processing group: $groupname${NC}"
    
    # Get group details
    group_data=$(aws iam get-group --profile "$PROFILE" --group-name "$groupname" --query 'Group' --output json)
    
    # Get group policies
    policies=$(aws iam list-attached-group-policies --profile "$PROFILE" --group-name "$groupname" --query 'AttachedPolicies[*].[PolicyName,PolicyArn]' --output json)
    
    # Combine all group data
    group_info=$(jq -n \
        --argjson group "$group_data" \
        --argjson policies "$policies" \
        '{
            "GroupName": $group.GroupName,
            "CreateDate": $group.CreateDate,
            "Policies": $policies
        }')
    
    # Add to JSON
    jq --argjson group "$group_info" '.results.groups += [$group]' "$OUTPUT_JSON" > tmp.json && mv tmp.json "$OUTPUT_JSON"
    
    # Add to CSV
    echo "$COMPONENT,group,$groupname,$(echo "$group_info" | jq -r '.CreateDate')" >> "$OUTPUT_CSV"
done

exit 0 