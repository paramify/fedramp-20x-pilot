#!/bin/bash
# Helper script for WAF DoS rules validation

# Steps:
# 1. List all WAFv2 Web ACLs in the region
#    aws wafv2 list-web-acls --scope REGIONAL --query 'WebACLs[*].[Id, Name]'
#
# 2. For each Web ACL, get detailed configuration:
#    aws wafv2 get-web-acl --scope REGIONAL --name <name> --id <id>
#
# 3. Extract and analyze rules for:
#    - Rate-based rules (DoS protection)
#    - AWS managed rule groups with DoS protection
#
# Output: Creates JSON with WAF rules and writes to CSV

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
COMPONENT="waf_dos_rules"
OUTPUT_JSON="$OUTPUT_DIR/$COMPONENT.json"

# ANSI color codes for better output readability
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Initialize JSON file
echo '{"results": []}' > "$OUTPUT_JSON"

# Check if we can list WAFv2 web ACLs
if ! aws wafv2 list-web-acls --scope REGIONAL --region "$REGION" --profile "$PROFILE"> /dev/null 2>&1; then
    echo "${RED}Error:${NC} Failed to retrieve WAFv2 web ACLs." >&2
    exit 1
fi

# Get all Web ACLs in the region
echo -e "${GREEN}Retrieving Web ACLs in region $REGION...${NC}"
web_acls=$(aws wafv2 list-web-acls --scope REGIONAL --region "$REGION" --profile "$PROFILE" --query 'WebACLs[*].[Id, Name]' --output text)

if [ -z "$web_acls" ]; then
    echo -e "${YELLOW}No Web ACLs found in region $REGION.${NC}"
    exit 0
fi

# Process each Web ACL
while IFS=$'\t' read -r acl_id acl_name; do
    echo -e "${BLUE}========== WEB ACL: $acl_name ($acl_id) ==========${NC}"
    
    # Initialize ACL data
    acl_data=$(jq -n --arg id "$acl_id" --arg name "$acl_name" '{"WebACLId": $id, "WebACLName": $name, "Rules": []}')
    
    # Get detailed ACL configuration
    echo -e "${GREEN}Retrieving detailed configuration...${NC}"
    acl_details=$(aws wafv2 get-web-acl --scope REGIONAL --region "$REGION" --profile "$PROFILE" --name "$acl_name" --id "$acl_id")
    
    # Extract rules from the ACL
    rules=$(echo "$acl_details" | jq -r '.WebACL.Rules[]')
    
    if [ -z "$rules" ]; then
        echo -e "${YELLOW}No rules found for this Web ACL.${NC}"
        # Add empty Web ACL to results
        jq --argjson data "$acl_data" '.results += [$data]' "$OUTPUT_JSON" > tmp.json && mv tmp.json "$OUTPUT_JSON"
        continue
    fi
    
    # Process each rule in the Web ACL
    echo -e "${BLUE}RULES (Name | Type | Rate Limit | Action):${NC}"
    
    # Loop through each rule using jq
    echo "$acl_details" | jq -c '.WebACL.Rules[]' | while read -r rule; do
        rule_name=$(echo "$rule" | jq -r '.Name')
        rule_id=$(echo "$rule" | jq -r '.RuleId // "N/A"')
        
        # Determine rule type and extract DoS protection relevant details
        if echo "$rule" | jq -e '.Statement.RateBasedStatement' > /dev/null; then
            rule_type="Rate-Based"
            rate_limit=$(echo "$rule" | jq -r '.Statement.RateBasedStatement.Limit')
            rule_action=$(echo "$rule" | jq -r '.Action | keys[0]')
            
            echo -e "| ${GREEN}$rule_name${NC} | $rule_type | $rate_limit req/5min | $rule_action |"
            
            # Add to CSV
            echo "$COMPONENT,$acl_id,$acl_name,$rule_id,$rule_name,$rule_type,$rate_limit,$rule_action" >> "$OUTPUT_CSV"
            
            # Add rule to ACL data
            acl_data=$(echo "$acl_data" | jq --arg id "$rule_id" --arg name "$rule_name" --arg type "$rule_type" \
                --arg limit "$rate_limit" --arg action "$rule_action" \
                '.Rules += [{"RuleId": $id, "RuleName": $name, "RuleType": $type, "RateLimit": ($limit|tonumber), "Action": $action}]')
            
        elif echo "$rule" | jq -e '.Statement.ManagedRuleGroupStatement' > /dev/null; then
            vendor=$(echo "$rule" | jq -r '.Statement.ManagedRuleGroupStatement.VendorName')
            name=$(echo "$rule" | jq -r '.Statement.ManagedRuleGroupStatement.Name')
            rule_type="Managed ($vendor)"
            
            # Check if this is an AWS managed rule for DoS protection
            if [[ "$name" == *"DDoS"* || "$name" == *"DoS"* || "$name" == *"RateLimit"* || "$name" == *"AWSManagedRulesATPRuleSet"* || "$name" == *"AWSManagedRulesBotControlRuleSet"* ]]; then
                action=$(echo "$rule" | jq -r '.OverrideAction | keys[0] // "None"')
                echo -e "| ${GREEN}$rule_name${NC} | $rule_type: $name | Managed DoS Protection | Override: $action |"
                
                # Add to CSV
                echo "$COMPONENT,$acl_id,$acl_name,$rule_id,$rule_name,$rule_type: $name,Managed,$action" >> "$OUTPUT_CSV"
                
                # Add rule to ACL data
                acl_data=$(echo "$acl_data" | jq --arg id "$rule_id" --arg name "$rule_name" --arg type "$rule_type: $name" \
                    --arg action "$action" \
                    '.Rules += [{"RuleId": $id, "RuleName": $name, "RuleType": $type, "RateLimit": "Managed", "Action": $action}]')
            else
                echo -e "| $rule_name | $rule_type: $name | N/A | Override: $(echo "$rule" | jq -r '.OverrideAction | keys[0] // "None"') |"
            fi
        else
            rule_type="Regular"
            rule_action=$(echo "$rule" | jq -r '.Action | keys[0] // "N/A"')
            echo -e "| $rule_name | $rule_type | N/A | $rule_action |"
        fi
    done
    
    # Add ACL data to results
    jq --argjson data "$acl_data" '.results += [$data]' "$OUTPUT_JSON" > tmp.json && mv tmp.json "$OUTPUT_JSON"
    
    echo ""
done <<< "$web_acls"

exit 0