#!/bin/bash

# Helper script for AWS Block Storage Encryption at Rest Validation

# Steps:
# 1. Check EBS encryption default settings
#    aws ec2 get-ebs-encryption-by-default
#    aws ec2 get-ebs-default-kms-key-id

# 2. List and check EBS volume encryption at rest
#    aws ec2 describe-volumes --query "Volumes[*].VolumeId"
#    aws ec2 describe-volumes --volume-ids [volume-id]

# 3. List and check EFS file system encryption at rest
#    aws efs describe-file-systems --query "FileSystems[*].FileSystemId"
#    aws efs describe-file-systems --file-system-id [fs-id]

# Output: Creates JSON report with block storage encryption at rest status

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
total_storage=0
encrypted_storage=0

# Create results object
results_json=$(jq -n '{results: {}}')

# Check EBS encryption default settings
ebs_encryption_default=$(aws ec2 get-ebs-encryption-by-default --profile "$PROFILE" --region "$REGION" --query "EbsEncryptionByDefault" --output text)
ebs_default_kms_key=$(aws ec2 get-ebs-default-kms-key-id --profile "$PROFILE" --region "$REGION" --query "KmsKeyId" --output text)

# Check EBS volumes
ebs_results=()
for volume in $(aws ec2 describe-volumes --profile "$PROFILE" --region "$REGION" --query "Volumes[*].VolumeId" --output text); do
    total_storage=$((total_storage + 1))
    volume_details=$(aws ec2 describe-volumes --volume-ids "$volume" --profile "$PROFILE" --region "$REGION")
    encrypted=$(echo "$volume_details" | jq -r '.Volumes[0].Encrypted')
    kms_key_id=$(echo "$volume_details" | jq -r '.Volumes[0].KmsKeyId // "None"')
    state=$(echo "$volume_details" | jq -r '.Volumes[0].State')
    size=$(echo "$volume_details" | jq -r '.Volumes[0].Size')
    
    ebs_results+=("$(jq -n \
        --arg name "$volume" \
        --arg type "ebs" \
        --argjson enc "$encrypted" \
        --arg kms "$kms_key_id" \
        --arg st "$state" \
        --arg sz "$size" \
        '{
            name: $name,
            type: $type,
            encrypted: $enc,
            kms_key_id: $kms,
            state: $st,
            size_gb: ($sz | tonumber)
        }')")
    if [ "$encrypted" = "true" ]; then
        encrypted_storage=$((encrypted_storage + 1))
    fi
done

# Check EFS file systems
efs_results=()
for fs in $(aws efs describe-file-systems --profile "$PROFILE" --region "$REGION" --query "FileSystems[*].FileSystemId" --output text); do
    total_storage=$((total_storage + 1))
    fs_details=$(aws efs describe-file-systems --file-system-id "$fs" --profile "$PROFILE" --region "$REGION")
    encrypted=$(echo "$fs_details" | jq -r '.FileSystems[0].Encrypted')
    kms_key_id=$(echo "$fs_details" | jq -r '.FileSystems[0].KmsKeyId // "None"')
    
    efs_results+=("$(jq -n \
        --arg name "$fs" \
        --arg type "efs" \
        --argjson enc "$encrypted" \
        --arg kms "$kms_key_id" \
        '{
            name: $name,
            type: $type,
            encrypted: $enc,
            kms_key_id: $kms
        }')")
    if [ "$encrypted" = "true" ]; then
        encrypted_storage=$((encrypted_storage + 1))
    fi
done

# Combine results
results_json=$(jq -n \
    --argjson ebs "[$(IFS=,; echo "${ebs_results[*]}")]" \
    --argjson efs "[$(IFS=,; echo "${efs_results[*]}")]" \
    --arg total "$total_storage" \
    --arg encrypted "$encrypted_storage" \
    --arg percentage "$(( (encrypted_storage * 100) / total_storage ))" \
    --arg ebs_default "$ebs_encryption_default" \
    --arg ebs_kms "$ebs_default_kms_key" \
    '{
        results: {
            ebs_default_settings: {
                encryption_enabled_by_default: ($ebs_default == "true"),
                default_kms_key_id: $ebs_kms
            },
            storage_inventory: {
                ebs: $ebs,
                efs: $efs
            },
            summary: {
                total_storage: ($total | tonumber),
                encrypted_storage: ($encrypted | tonumber),
                encryption_percentage: ($percentage | tonumber)
            }
        }
    }')

# Write results to JSON file
echo "$results_json" > "$OUTPUT_DIR/block_storage_encryption_status.json"

# Add to CSV
echo "block_storage_encryption_status,$(echo "$results_json" | jq -r '.results.summary | "Total: \(.total_storage), Encrypted: \(.encrypted_storage) (\(.encryption_percentage)%)"')" >> "$CSV_FILE"

exit 0 