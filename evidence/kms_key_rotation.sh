#!/bin/bash

# Helper script for AWS KMS Key Rotation Validation

# Steps:
# 1. Check AWS Config rule for KMS key rotation
#    aws configservice describe-compliance-by-config-rule --config-rule-name "cmk-backing-key-rotation-enabled-conformance-pack-j3wepwlkw"
#
# 2. Get all KMS keys
#    aws kms list-keys
#
# 3. For each KMS key, get:
#    - Key details
#    aws kms describe-key
#    - Key rotation status
#    aws kms get-key-rotation-status
#    - Key policy
#    aws kms get-key-policy
#
# Output: Creates JSON report with KMS key rotation status

# Check if required parameters are provided
if [ "$#" -ne 4 ]; then
    echo "Usage: $0 <profile> <region> <output_dir> <csv_file>"
    exit 1
fi

PROFILE="$1"
REGION="$2"
OUTPUT_DIR="$3"
CSV_FILE="$4"

# Create output directory if it doesn't exist
mkdir -p "$(dirname "$OUTPUT_DIR")"
mkdir -p "$(dirname "$CSV_FILE")"

# Initialize counters
total_keys=0
rotated_keys=0

# Create results object
results_json=$(jq -n '{results: {}}')

# Check AWS Config rule compliance
config_rule_name="cmk-backing-key-rotation-enabled-conformance-pack-j3wepwlkw"
config_compliance=$(aws configservice describe-compliance-by-config-rule \
    --config-rule-name "$config_rule_name" \
    --profile "$PROFILE" \
    --region "$REGION" 2>/dev/null || echo '{"ComplianceByConfigRules": []}')

# Get all KMS keys
kms_results=()
for key_id in $(aws kms list-keys --profile "$PROFILE" --region "$REGION" --query "Keys[*].KeyId" --output text 2>/dev/null || echo ""); do
    if [ -z "$key_id" ]; then
        continue
    fi
    
    total_keys=$((total_keys + 1))
    
    # Get key details
    key_details=$(aws kms describe-key --key-id "$key_id" --profile "$PROFILE" --region "$REGION" 2>/dev/null || echo '{"KeyMetadata": {}}')
    key_rotation_status=$(aws kms get-key-rotation-status --key-id "$key_id" --profile "$PROFILE" --region "$REGION" 2>/dev/null || echo '{"KeyRotationEnabled": false}')
    
    # Extract key information
    key_arn=$(echo "$key_details" | jq -r '.KeyMetadata.Arn // "Unknown"')
    key_state=$(echo "$key_details" | jq -r '.KeyMetadata.KeyState // "Unknown"')
    key_usage=$(echo "$key_details" | jq -r '.KeyMetadata.KeyUsage // "Unknown"')
    is_rotated=$(echo "$key_rotation_status" | jq -r '.KeyRotationEnabled // false')
    
    if [ "$is_rotated" = "true" ]; then
        rotated_keys=$((rotated_keys + 1))
    fi
    
    # Get key policy
    key_policy=$(aws kms get-key-policy --key-id "$key_id" --policy-name default --profile "$PROFILE" --region "$REGION" 2>/dev/null || echo "{}")
    
    kms_results+=("$(jq -n \
        --arg id "$key_id" \
        --arg arn "$key_arn" \
        --arg state "$key_state" \
        --arg usage "$key_usage" \
        --argjson rotated "$is_rotated" \
        --argjson policy "$key_policy" \
        '{
            key_id: $id,
            key_arn: $arn,
            key_state: $state,
            key_usage: $usage,
            rotation_enabled: $rotated,
            key_policy: $policy
        }')")
done

# Calculate percentage safely
if [ "$total_keys" -eq 0 ]; then
    percentage=0
else
    percentage=$(( (rotated_keys * 100) / total_keys ))
fi

# Combine results
results_json=$(jq -n \
    --argjson keys "[$(IFS=,; echo "${kms_results[*]}")]" \
    --argjson config "$config_compliance" \
    --arg total "$total_keys" \
    --arg rotated "$rotated_keys" \
    --arg percentage "$percentage" \
    '{
        results: {
            kms_keys: {
                object: $keys
            },
            config_rule: $config,
            summary: {
                total_keys: ($total | tonumber),
                rotated_keys: ($rotated | tonumber),
                rotation_percentage: ($percentage | tonumber)
            }
        }
    }')

# Write results to JSON file
echo "$results_json" > "${OUTPUT_DIR}/kms_key_rotation.json"

# Add to CSV
echo "kms_key_rotation,$(echo "$results_json" | jq -r '.results.summary | "Total: \(.total_keys), Rotated: \(.rotated_keys) (\(.rotation_percentage)%)"')" >> "$CSV_FILE"

exit 0
