#!/bin/bash
# Helper script for IAM Identity Center validation

# Steps:
# A. Pull Identity Providers from IAM
#    aws iam list-saml-providers
#    aws iam get-saml-provider
#    aws iam list-open-id-connect-providers
#    aws iam get-open-id-connect-provider
#
# B. Pull Identity Center Information
#    aws sso-admin list-instances
#    aws sso-admin list-identity-providers
#    aws sso-admin list-permission-sets
#    aws sso-admin describe-permission-set
#
# Output: Creates JSON with Identity Provider and Identity Center details and writes to CSV

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
COMPONENT="iam_identity_center"
OUTPUT_JSON="$OUTPUT_DIR/$COMPONENT.json"

# ANSI color codes for better output readability
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Initialize JSON file
echo '{"results": {"iam_providers": {"saml": [], "oidc": []}, "identity_center": {"instances": [], "identity_providers": [], "permission_sets": []}}}' > "$OUTPUT_JSON"

# A. Get IAM Identity Providers
echo -e "${BLUE}Retrieving SAML providers...${NC}"
saml_providers=$(aws iam list-saml-providers --profile "$PROFILE" --query 'SAMLProviderList[*]' --output json)

# Process SAML providers
echo "$saml_providers" | jq -c '.[]' | while read -r provider; do
    provider_arn=$(echo "$provider" | jq -r '.Arn')
    
    echo -e "${BLUE}Processing SAML provider: $provider_arn${NC}"
    
    # Get SAML provider details
    provider_details=$(aws iam get-saml-provider --profile "$PROFILE" --saml-provider-arn "$provider_arn" --query 'SAMLProviderDocument' --output json)
    
    # Add provider to results
    jq --arg arn "$provider_arn" --argjson details "$provider_details" '.results.iam_providers.saml += [{"Arn": $arn, "Details": $details}]' "$OUTPUT_JSON" > tmp.json && mv tmp.json "$OUTPUT_JSON"
    
    # Add to CSV
    echo "$COMPONENT,saml_provider,$provider_arn,$(echo "$provider_details" | jq -r '.Issuer')" >> "$OUTPUT_CSV"
done

echo -e "${BLUE}Retrieving OpenID Connect providers...${NC}"
oidc_providers=$(aws iam list-open-id-connect-providers --profile "$PROFILE" --query 'OpenIDConnectProviderList[*]' --output json)

# Process OIDC providers
echo "$oidc_providers" | jq -c '.[]' | while read -r provider; do
    provider_arn=$(echo "$provider" | jq -r '.Arn')
    
    echo -e "${BLUE}Processing OIDC provider: $provider_arn${NC}"
    
    # Get OIDC provider details
    provider_details=$(aws iam get-open-id-connect-provider --profile "$PROFILE" --open-id-connect-provider-arn "$provider_arn" --query 'OpenIDConnectProviderDocument' --output json)
    
    # Add provider to results
    jq --arg arn "$provider_arn" --argjson details "$provider_details" '.results.iam_providers.oidc += [{"Arn": $arn, "Details": $details}]' "$OUTPUT_JSON" > tmp.json && mv tmp.json "$OUTPUT_JSON"
    
    # Add to CSV
    echo "$COMPONENT,oidc_provider,$provider_arn,$(echo "$provider_details" | jq -r '.issuer')" >> "$OUTPUT_CSV"
done

# B. Get Identity Center Information
echo -e "${BLUE}Retrieving Identity Center instances...${NC}"
instances=$(aws sso-admin list-instances --profile "$PROFILE" --region "$REGION" --query 'Instances[*]' --output json)

# Check if we got any instances
if [ "$(echo "$instances" | jq 'length')" -eq 0 ]; then
    echo -e "${GREEN}No IAM Identity Center instances found in this account/region${NC}"
else
    # Process instances
    echo "$instances" | jq -c '.[]' | while read -r instance; do
        instance_arn=$(echo "$instance" | jq -r '.InstanceArn')
        instance_id=$(echo "$instance" | jq -r '.InstanceId')
        
        if [ "$instance_id" = "null" ] || [ -z "$instance_id" ]; then
            echo -e "${YELLOW}Instance found without ID - checking next instance${NC}"
            continue
        fi
        
        echo -e "${BLUE}Processing Identity Center instance: $instance_id${NC}"
        
        # Add instance to results
        jq --argjson instance "$instance" '.results.identity_center.instances += [$instance]' "$OUTPUT_JSON" > tmp.json && mv tmp.json "$OUTPUT_JSON"
        
        # Add to CSV
        echo "$COMPONENT,instance,$instance_id,$(echo "$instance" | jq -r '.IdentityStoreId')" >> "$OUTPUT_CSV"

        # Get Identity Providers for this instance
        echo -e "${BLUE}Retrieving Identity Providers for instance $instance_id...${NC}"
        identity_providers=$(aws sso-admin list-identity-providers --profile "$PROFILE" --region "$REGION" --instance-arn "$instance_arn" --query 'IdentityProviders[*]' --output json)

        # Process Identity Providers
        echo "$identity_providers" | jq -c '.[]' | while read -r provider; do
            provider_id=$(echo "$provider" | jq -r '.IdentityProviderId')
            
            if [ "$provider_id" = "null" ] || [ -z "$provider_id" ]; then
                echo -e "${YELLOW}Provider found without ID - checking next provider${NC}"
                continue
            fi
            
            echo -e "${BLUE}Processing Identity Provider: $provider_id${NC}"
            
            # Add provider to results
            jq --argjson provider "$provider" '.results.identity_center.identity_providers += [$provider]' "$OUTPUT_JSON" > tmp.json && mv tmp.json "$OUTPUT_JSON"
            
            # Add to CSV
            echo "$COMPONENT,identity_provider,$provider_id,$(echo "$provider" | jq -r '.DisplayName')" >> "$OUTPUT_CSV"
        done

        # Get Permission Sets for this instance
        echo -e "${BLUE}Retrieving Permission Sets for instance $instance_id...${NC}"
        permission_sets=$(aws sso-admin list-permission-sets --profile "$PROFILE" --region "$REGION" --instance-arn "$instance_arn" --query 'PermissionSets[*]' --output json)

        # Process Permission Sets
        echo "$permission_sets" | jq -c '.[]' | while read -r permission_set_arn; do
            if [ "$permission_set_arn" = "null" ] || [ -z "$permission_set_arn" ]; then
                echo -e "${YELLOW}Permission set found without ARN - checking next permission set${NC}"
                continue
            fi
            
            echo -e "${BLUE}Processing Permission Set: $permission_set_arn${NC}"
            
            # Get Permission Set details
            permission_set_details=$(aws sso-admin describe-permission-set --profile "$PROFILE" --region "$REGION" --instance-arn "$instance_arn" --permission-set-arn "$permission_set_arn" --query 'PermissionSet' --output json 2>/dev/null)
            
            if [ $? -eq 0 ] && [ ! -z "$permission_set_details" ]; then
                # Add permission set to results
                jq --argjson ps "$permission_set_details" '.results.identity_center.permission_sets += [$ps]' "$OUTPUT_JSON" > tmp.json && mv tmp.json "$OUTPUT_JSON"
                
                # Add to CSV
                echo "$COMPONENT,permission_set,$permission_set_arn,$(echo "$permission_set_details" | jq -r '.Name')" >> "$OUTPUT_CSV"
            else
                echo -e "${YELLOW}Unable to retrieve details for permission set: $permission_set_arn - checking next permission set${NC}"
            fi
        done
    done
fi

echo -e "${GREEN}IAM Identity Center check finished${NC}"
exit 0 