#!/bin/bash
# Helper script for security group validation

# Steps:
# 1. List all security groups in the account
#    aws ec2 describe-security-groups --query 'SecurityGroups[*].GroupId'
#
# 2. For each security group, get detailed rules:
#    aws ec2 describe-security-groups --group-ids <sg_id> --query 'SecurityGroups[0].IpPermissions[*]'
#    aws ec2 describe-security-groups --group-ids <sg_id> --query 'SecurityGroups[0].IpPermissionsEgress[*]'
#
# Output: Creates JSON with security group rules and writes to CSV

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
COMPONENT="security_groups"
OUTPUT_JSON="$OUTPUT_DIR/$COMPONENT.json"

# ANSI color codes for better output readability
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Initialize JSON file
echo '{"results": []}' > "$OUTPUT_JSON"

# Check if we can list security groups
if ! aws ec2 describe-security-groups --region "$REGION" --profile "$PROFILE" > /dev/null 2>&1; then
    echo "${RED}Error:${NC} Failed to retrieve security groups." >&2
    exit 1
fi

# Get all security groups
sg_ids=$(aws ec2 describe-security-groups --profile="$PROFILE" --query 'SecurityGroups[*].GroupId' --output text)

for sg_id in $sg_ids; do
    echo -e "${BLUE}========== SECURITY GROUP: $sg_id ==========${NC}"
    
    # Initialize group data
    group_data=$(jq -n --arg id "$sg_id" '{"GroupId": $id, "Rules": []}')
    
    for direction in inbound outbound; do
        if [ "$direction" == "inbound" ]; then
            query_path='IpPermissions'
            label="INBOUND RULES"
        else
            query_path='IpPermissionsEgress'
            label="OUTBOUND RULES"
        fi
        
        echo -e "${BLUE}${label}\n(Protocol | From | To | CIDRs):${NC}"
        
        rules=$(aws ec2 describe-security-groups \
            --profile="$PROFILE" \
            --group-ids "$sg_id" \
            --query "SecurityGroups[0].$query_path[*].[IpProtocol,FromPort,ToPort,join(', ', IpRanges[*].CidrIp)]" \
            --output text)
        
        if [ -n "$rules" ]; then
            while IFS=$'\t' read -r protocol from to cidrs; do
                printf "|  %-4s|  %-5s|  %-5s|  %s  |\n" "$protocol" "${from:-None}" "${to:-None}" "${cidrs:- }"
                
                # Add to CSV
                echo "$COMPONENT,$sg_id,$label,$protocol,${from:-None},${to:-None},\"${cidrs:-}\"" >> "$OUTPUT_CSV"
                
                # Add rule to group data
                group_data=$(echo "$group_data" | jq --arg dir "$label" --arg p "$protocol" --arg f "${from:-null}" --arg t "${to:-null}" --arg c "${cidrs:-}" \
                    '.Rules += [{"Direction":$dir, "Protocol":$p, "FromPort":($f|tonumber?), "ToPort":($t|tonumber?), "CIDRs":$c}]')
                
            done <<< "$rules"
        else
            echo "(no rules)"
        fi
    done
    
    # Add group data to results
    jq --argjson data "$group_data" '.results += [$data]' "$OUTPUT_JSON" > tmp.json && mv tmp.json "$OUTPUT_JSON"
    
    echo ""
done

exit 0