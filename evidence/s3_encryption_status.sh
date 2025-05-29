#!/bin/bash

# Helper script for AWS S3 Encryption at Rest Validation

# Steps:
# 1. List and check S3 bucket encryption at rest
#    aws s3api list-buckets --query "Buckets[*].Name"
#    aws s3api get-bucket-encryption --bucket [bucket-name]

# Output: Creates JSON report with S3 encryption at rest status

# Check if required parameters are provided
if [ "$#" -ne 4 ]; then
    echo "Usage: $0 <profile> <region> <output_dir> <csv_file>"
    exit 1
fi

PROFILE="$1"
REGION="$2"
OUTPUT_DIR="$3"
CSV_FILE="$4"

# Initialize counters
total_buckets=0
encrypted_buckets=0

# Create results object
results_json=$(jq -n '{results: {}}')

# Check S3 buckets
s3_results=()
for bucket in $(aws s3api list-buckets --profile "$PROFILE" --region "$REGION" --query "Buckets[*].Name" --output text); do
    total_buckets=$((total_buckets + 1))
    
    # Get bucket encryption configuration
    if aws s3api get-bucket-encryption --bucket "$bucket" --profile "$PROFILE" --region "$REGION" &> /dev/null; then
        # Get encryption details
        encryption_config=$(aws s3api get-bucket-encryption --bucket "$bucket" --profile "$PROFILE" --region "$REGION")
        sse_algorithm=$(echo "$encryption_config" | jq -r '.ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm // "None"')
        kms_key_id=$(echo "$encryption_config" | jq -r '.ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.KMSMasterKeyID // "None"')
        bucket_key_enabled=$(echo "$encryption_config" | jq -r '.ServerSideEncryptionConfiguration.Rules[0].BucketKeyEnabled // false')
        
        s3_results+=("$(jq -n \
            --arg name "$bucket" \
            --arg type "s3" \
            --arg sse "$sse_algorithm" \
            --arg kms "$kms_key_id" \
            --argjson key_enabled "$bucket_key_enabled" \
            '{
                name: $name,
                type: $type,
                encrypted: true,
                encryption_type: $sse,
                kms_key_id: $kms,
                bucket_key_enabled: $key_enabled
            }')")
        encrypted_buckets=$((encrypted_buckets + 1))
    else
        s3_results+=("$(jq -n \
            --arg name "$bucket" \
            --arg type "s3" \
            '{
                name: $name,
                type: $type,
                encrypted: false,
                encryption_type: "None",
                kms_key_id: "None",
                bucket_key_enabled: false
            }')")
    fi
done

# Combine results
results_json=$(jq -n \
    --argjson buckets "[$(IFS=,; echo "${s3_results[*]}")]" \
    --arg total "$total_buckets" \
    --arg encrypted "$encrypted_buckets" \
    --arg percentage "$(( (encrypted_buckets * 100) / total_buckets ))" \
    '{
        results: {
            storage_inventory: {
                object: $buckets
            },
            summary: {
                total_storage: ($total | tonumber),
                encrypted_storage: ($encrypted | tonumber),
                encryption_percentage: ($percentage | tonumber)
            }
        }
    }')

# Write results to JSON file
echo "$results_json" > "$OUTPUT_DIR/s3_encryption_status.json"

# Add to CSV
echo "s3_encryption_status,$(echo "$results_json" | jq -r '.results.summary | "Total: \(.total_storage), Encrypted: \(.encrypted_storage) (\(.encryption_percentage)%)"')" >> "$CSV_FILE"

exit 0 