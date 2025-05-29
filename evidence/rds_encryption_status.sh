#!/bin/bash

# Helper script for AWS RDS Encryption at Rest Validation

# Steps:
# 1. List and check RDS instance encryption at rest
#    aws rds describe-db-instances --query "DBInstances[*].DBInstanceIdentifier"
#    aws rds describe-db-instances --db-instance-identifier [instance-name]

# 2. List and check RDS Aurora cluster encryption at rest
#    aws rds describe-db-clusters --query "DBClusters[*].DBClusterIdentifier"
#    aws rds describe-db-clusters --db-cluster-identifier [cluster-name]

# Output: Creates JSON report with RDS encryption at rest status

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
total_databases=0
encrypted_databases=0

# Create results object
results_json=$(jq -n '{results: {}}')

# Check RDS instances
rds_results=()
for instance in $(aws rds describe-db-instances --profile "$PROFILE" --region "$REGION" --query "DBInstances[*].DBInstanceIdentifier" --output text); do
    total_databases=$((total_databases + 1))
    instance_details=$(aws rds describe-db-instances --db-instance-identifier "$instance" --profile "$PROFILE" --region "$REGION")
    encrypted=$(echo "$instance_details" | jq -r '.DBInstances[0].StorageEncrypted')
    kms_key_id=$(echo "$instance_details" | jq -r '.DBInstances[0].KmsKeyId // "None"')
    engine=$(echo "$instance_details" | jq -r '.DBInstances[0].Engine')
    
    rds_results+=("$(jq -n \
        --arg name "$instance" \
        --arg type "rds_instance" \
        --argjson enc "$encrypted" \
        --arg kms "$kms_key_id" \
        --arg eng "$engine" \
        '{
            name: $name,
            type: $type,
            encrypted: $enc,
            kms_key_id: $kms,
            engine: $eng
        }')")
    if [ "$encrypted" = "true" ]; then
        encrypted_databases=$((encrypted_databases + 1))
    fi
done

# Check RDS Aurora clusters
aurora_results=()
for cluster in $(aws rds describe-db-clusters --profile "$PROFILE" --region "$REGION" --query "DBClusters[*].DBClusterIdentifier" --output text); do
    total_databases=$((total_databases + 1))
    cluster_details=$(aws rds describe-db-clusters --db-cluster-identifier "$cluster" --profile "$PROFILE" --region "$REGION")
    encrypted=$(echo "$cluster_details" | jq -r '.DBClusters[0].StorageEncrypted')
    kms_key_id=$(echo "$cluster_details" | jq -r '.DBClusters[0].KmsKeyId // "None"')
    engine=$(echo "$cluster_details" | jq -r '.DBClusters[0].Engine')
    
    aurora_results+=("$(jq -n \
        --arg name "$cluster" \
        --arg type "rds_aurora" \
        --argjson enc "$encrypted" \
        --arg kms "$kms_key_id" \
        --arg eng "$engine" \
        '{
            name: $name,
            type: $type,
            encrypted: $enc,
            kms_key_id: $kms,
            engine: $eng
        }')")
    if [ "$encrypted" = "true" ]; then
        encrypted_databases=$((encrypted_databases + 1))
    fi
done

# Combine results
results_json=$(jq -n \
    --argjson rds "[$(IFS=,; echo "${rds_results[*]}")]" \
    --argjson aurora "[$(IFS=,; echo "${aurora_results[*]}")]" \
    --arg total "$total_databases" \
    --arg encrypted "$encrypted_databases" \
    --arg percentage "$(( (encrypted_databases * 100) / total_databases ))" \
    '{
        results: {
            storage_inventory: {
                instances: $rds,
                clusters: $aurora
            },
            summary: {
                total_storage: ($total | tonumber),
                encrypted_storage: ($encrypted | tonumber),
                encryption_percentage: ($percentage | tonumber)
            }
        }
    }')

# Write results to JSON file
echo "$results_json" > "$OUTPUT_DIR/rds_encryption_status.json"

# Add to CSV
echo "rds_encryption_status,$(echo "$results_json" | jq -r '.results.summary | "Total: \(.total_storage), Encrypted: \(.encrypted_storage) (\(.encryption_percentage)%)"')" >> "$CSV_FILE"

exit 0 