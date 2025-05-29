#!/bin/bash
# Helper script for AWS Component SSL/TLS Enforcement Status

# Steps:
# 1. Check S3 bucket policies for enforced HTTPS (aws:SecureTransport)
#    aws s3api list-buckets
#    aws s3api get-bucket-policy --bucket <bucket-name>
#
# 2. Check RDS parameter groups for rds.force_ssl = 1
#    aws rds describe-db-instances
#    aws rds describe-db-parameters --db-parameter-group-name <pg-name>
#
# Output: Creates JSON report with SSL enforcement status

set -e

if [ "$#" -ne 4 ]; then
    echo "Usage: $0 <profile> <region> <output_dir> <csv_file>"
    exit 1
fi

PROFILE="$1"
REGION="$2"
OUTPUT_DIR="$3"
CSV_FILE="$4"

COMPONENT="aws_component_ssl_enforcement"
OUTPUT_JSON="$OUTPUT_DIR/$COMPONENT.json"

# Initialize JSON file
echo '{
  "metadata": {
    "region": "'"$REGION"'",
    "profile": "'"$PROFILE"'",
    "datetime": "'"$(date -u +"%Y-%m-%dT%H:%M:%SZ")"'"
  },
  "results": {
    "s3": [],
    "rds": []
  },
  "summary": {}
}' > "$OUTPUT_JSON"

# 1. S3 Bucket SSL Enforcement
s3_buckets=$(aws s3api list-buckets --profile "$PROFILE" --region "$REGION" | jq -r '.Buckets[].Name')
s3_total=0
s3_ssl_enforced=0

# Create temporary file for S3 details
echo "[]" > s3_details.json

for bucket in $s3_buckets; do
    s3_total=$((s3_total+1))
    policy=$(aws s3api get-bucket-policy --bucket "$bucket" --profile "$PROFILE" --region "$REGION" 2>/dev/null || echo "")
    enforced="false"
    snippet=""
    if [[ -n "$policy" ]]; then
        # Check for aws:SecureTransport deny
        found=$(echo "$policy" | jq -e '.Policy | fromjson | .Statement[]? | select(.Effect=="Deny" and .Condition.Bool."aws:SecureTransport"=="false")' 2>/dev/null || echo "")
        if [[ -n "$found" ]]; then
            enforced="true"
            s3_ssl_enforced=$((s3_ssl_enforced+1))
            snippet=$(echo "$found" | jq -c '.')
        fi
    fi
    # Add to JSON array using jq
    jq --arg bucket "$bucket" --arg enforced "$enforced" --arg snippet "$snippet" \
       '. += [{"bucket": $bucket, "ssl_enforced": ($enforced == "true"), "policy_snippet": ($snippet | fromjson? // null)}]' \
       s3_details.json > tmp.json && mv tmp.json s3_details.json
done

# Update main JSON with S3 details
jq --slurpfile s3 s3_details.json '.results.s3 = $s3[0]' "$OUTPUT_JSON" > tmp.json && mv tmp.json "$OUTPUT_JSON"

# 2. RDS SSL Enforcement
rds_instances=$(aws rds describe-db-instances --profile "$PROFILE" --region "$REGION" | jq -r '.DBInstances[].DBInstanceIdentifier')
rds_total=0
rds_ssl_enforced=0

# Create temporary file for RDS details
echo "[]" > rds_details.json

for db in $rds_instances; do
    rds_total=$((rds_total+1))
    pgroups=$(aws rds describe-db-instances --db-instance-identifier "$db" --profile "$PROFILE" --region "$REGION" | jq -r '.DBInstances[0].DBParameterGroups[].DBParameterGroupName')
    enforced="false"
    for pg in $pgroups; do
        param=$(aws rds describe-db-parameters --db-parameter-group-name "$pg" --profile "$PROFILE" --region "$REGION" | jq -r '.Parameters[] | select(.ParameterName=="rds.force_ssl") | .ParameterValue')
        if [[ "$param" == "1" ]]; then
            enforced="true"
            rds_ssl_enforced=$((rds_ssl_enforced+1))
            break
        fi
    done
    # Convert parameter groups to JSON array
    pg_json=$(echo "$pgroups" | jq -R -s 'split("\n") | map(select(length > 0))')
    # Add to JSON array using jq
    jq --arg db "$db" --arg enforced "$enforced" --argjson pgroups "$pg_json" \
       '. += [{"db_instance": $db, "ssl_enforced": ($enforced == "true"), "parameter_groups": $pgroups}]' \
       rds_details.json > tmp.json && mv tmp.json rds_details.json
done

# Update main JSON with RDS details
jq --slurpfile rds rds_details.json '.results.rds = $rds[0]' "$OUTPUT_JSON" > tmp.json && mv tmp.json "$OUTPUT_JSON"

# Clean up temporary files
rm -f s3_details.json rds_details.json

# Summary
jq --arg s3_total "$s3_total" --arg s3_ssl_enforced "$s3_ssl_enforced" \
   --arg rds_total "$rds_total" --arg rds_ssl_enforced "$rds_ssl_enforced" \
   '.summary = {
      s3_total: ($s3_total|tonumber),
      s3_ssl_enforced: ($s3_ssl_enforced|tonumber),
      rds_total: ($rds_total|tonumber),
      rds_ssl_enforced: ($rds_ssl_enforced|tonumber),
      formatted_summary: ("S3 Buckets: " + $s3_total + ", SSL Enforced: " + $s3_ssl_enforced + "\n" +
                         "RDS Instances: " + $rds_total + ", SSL Enforced: " + $rds_ssl_enforced + "\n")
   }' "$OUTPUT_JSON" > tmp.json && mv tmp.json "$OUTPUT_JSON"

# Add to CSV with formatted summary
echo "aws_component_ssl_enforcement,$(echo "$(jq -r '.summary | "S3: \(.s3_ssl_enforced)/\(.s3_total), RDS: \(.rds_ssl_enforced)/\(.rds_total)"' "$OUTPUT_JSON")")" >> "$CSV_FILE"

# Print summary
echo -e "\nAWS Component SSL/TLS Enforcement Summary:"
jq -r '.summary.formatted_summary' "$OUTPUT_JSON"

exit 0 