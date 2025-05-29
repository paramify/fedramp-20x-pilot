#!/bin/bash
# Helper script for AWS Config Conformance Packs validation

# Steps:
# 1. List all conformance packs
#    aws configservice describe-conformance-packs --query "ConformancePackNames[]" --output text
#
# 2. For each conformance pack, get:
#    - Status details
#    aws configservice describe-conformance-pack-status --conformance-pack-names "$pack"
#    - Compliance summary
#    aws configservice get-conformance-pack-compliance-summary --conformance-pack-names "$pack"
#    - Detailed compliance results
#    aws configservice get-conformance-pack-compliance-details --conformance-pack-name "$pack"
#
# Output: Creates JSON with conformance pack details and writes to CSV

# Required parameters
if [ "$#" -lt 4 ]; then
    echo "Usage: $0 <profile> <region> <output_dir> <output_csv>"
    exit 1
fi

PROFILE="$1"
REGION="$2"
OUTPUT_DIR="$3"
OUTPUT_CSV="$4"

# Component identifier
COMPONENT="aws_config_conformance_packs"
OUTPUT_JSON="$OUTPUT_DIR/$COMPONENT.json"

# Create output directory if it doesn't exist
mkdir -p "$OUTPUT_DIR"

# Initialize output files
echo '{"results": {}}' > "$OUTPUT_JSON"
echo "ConformancePack,Status,Compliant,NonCompliant,NotApplicable" > "$OUTPUT_CSV"

# Function to make API calls with retries
make_api_call() {
    local max_retries=3
    local retry_count=0
    local success=false
    local command="$1"
    
    while [ $retry_count -lt $max_retries ] && [ "$success" = false ]; do
        if eval "$command"; then
            success=true
        else
            retry_count=$((retry_count + 1))
            sleep $((2 ** retry_count))  # Exponential backoff
        fi
    done
    
    [ "$success" = true ]
}

# Start timing
start_time=$(date +%s.%N)

echo "Fetching conformance packs..."
conformance_packs=$(aws configservice describe-conformance-packs \
    --profile "$PROFILE" \
    --region "$REGION" \
    --query "ConformancePackDetails[].ConformancePackName" \
    --output json \
    --no-cli-pager)

# Check if we got any conformance packs
if [ -z "$conformance_packs" ] || [ "$conformance_packs" = "null" ] || [ "$conformance_packs" = "[]" ]; then
    echo "No conformance packs found in the specified region."
    echo "Please verify:"
    echo "1. AWS Config is enabled in the region"
    echo "2. You have the necessary permissions"
    echo "3. The region is correct"
    echo "4. The AWS profile is correctly configured"
    exit 1
fi

# Process each conformance pack
for pack in $(echo "$conformance_packs" | jq -r '.[]'); do
    echo "Processing Conformance Pack: $pack"
    compliance_details=$(aws configservice get-conformance-pack-compliance-details \
        --profile "$PROFILE" \
        --region "$REGION" \
        --conformance-pack-name "$pack" \
        --output json \
        --no-cli-pager)
    
    if [ $? -ne 0 ]; then
        continue
    fi

    # Initialize combined results
    combined_results="$compliance_details"
    
    # Handle pagination if necessary
    next_token=$(echo "$compliance_details" | jq -r '.NextToken // empty')
    page_count=1
    
    while [ ! -z "$next_token" ]; do
        # echo "Fetching page $((page_count + 1)) for $pack..."
        next_page=$(aws configservice get-conformance-pack-compliance-details \
            --profile "$PROFILE" \
            --region "$REGION" \
            --conformance-pack-name "$pack" \
            --next-token "$next_token" \
            --output json \
            --no-cli-pager)
        
        if [ $? -ne 0 ]; then
            break
        fi
        
        # Combine results
        combined_results=$(echo "$combined_results" | jq -r --argjson next "$next_page" '.ConformancePackRuleEvaluationResults += $next.ConformancePackRuleEvaluationResults')
        
        # Get next token
        next_token=$(echo "$next_page" | jq -r '.NextToken // empty')
        page_count=$((page_count + 1))
        
        # Safety check - limit to 50 pages
        if [ $page_count -ge 50 ]; then
            echo "Warning: Reached maximum page limit for $pack"
            break
        fi
    done
    
    # Use combined results for processing
    compliance_details="$combined_results"
    
    # Get status details
    status_details=$(aws configservice describe-conformance-pack-status \
        --profile "$PROFILE" \
        --region "$REGION" \
        --conformance-pack-names "$pack" \
        --query "ConformancePackStatusDetails[]" \
        --output json \
        --no-cli-pager)
    
    if [ -z "$status_details" ] || [ "$status_details" = "null" ] || [ "$status_details" = "[]" ]; then
        continue
    fi
    
    # Get compliance summary
    compliance_summary=$(aws configservice get-conformance-pack-compliance-summary \
        --profile "$PROFILE" \
        --region "$REGION" \
        --conformance-pack-names "$pack" \
        --output json \
        --no-cli-pager)
    
    if [ -z "$compliance_summary" ] || [ "$compliance_summary" = "null" ] || [ "$compliance_summary" = "[]" ]; then
        continue
    fi
    
    # Extract values for CSV
    status=$(echo "$status_details" | jq -r '.[0].ConformancePackState // "UNKNOWN"')
    compliant=$(echo "$compliance_details" | jq -r '.ConformancePackRuleEvaluationResults[] | select(.ComplianceType == "COMPLIANT") | .EvaluationResultIdentifier.EvaluationResultQualifier.ConfigRuleName' | sort -u | wc -l)
    non_compliant=$(echo "$compliance_details" | jq -r '.ConformancePackRuleEvaluationResults[] | select(.ComplianceType == "NON_COMPLIANT") | .EvaluationResultIdentifier.EvaluationResultQualifier.ConfigRuleName' | sort -u | wc -l)
    not_applicable=$(echo "$compliance_details" | jq -r '.ConformancePackRuleEvaluationResults[] | select(.ComplianceType == "NOT_APPLICABLE") | .EvaluationResultIdentifier.EvaluationResultQualifier.ConfigRuleName' | sort -u | wc -l)
    
    # Write to CSV
    echo "$pack,$status,$compliant,$non_compliant,$not_applicable" >> "$OUTPUT_CSV"
    
    # Update JSON
    jq --arg pack "$pack" \
       --arg status "$status" \
       --argjson compliant "$compliant" \
       --argjson non_compliant "$non_compliant" \
       --argjson not_applicable "$not_applicable" \
       --argjson details "$compliance_details" \
       '.results[$pack] = {
           "status": $status,
           "compliant": $compliant,
           "non_compliant": $non_compliant,
           "not_applicable": $not_applicable,
           "details": $details
       }' "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" && mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON"

    # Add summary to JSON
    jq --arg pack "$pack" \
       --arg status "$status" \
       --argjson compliant "$compliant" \
       --argjson non_compliant "$non_compliant" \
       '.summary[$pack] = {
           "status": $status,
           "compliant_rules": $compliant,
           "non_compliant_rules": $non_compliant
       }' "$OUTPUT_JSON" > "$OUTPUT_JSON.tmp" && mv "$OUTPUT_JSON.tmp" "$OUTPUT_JSON"
    
    # Print summary
    echo "Status: $status | Compliant: $compliant | Non-Compliant: $non_compliant | Not Applicable: $not_applicable"
    
    # Remove detailed rule listings
    # echo "  Compliant Rules:"
    # echo "$compliance_details" | jq -r '.ConformancePackRuleEvaluationResults[] | select(.ComplianceType == "COMPLIANT") | .EvaluationResultIdentifier.EvaluationResultQualifier.ConfigRuleName' | sort -u | while read rule; do
    #     echo "    - $rule"
    # done
    
    # echo "  Non-Compliant Rules:"
    # echo "$compliance_details" | jq -r '.ConformancePackRuleEvaluationResults[] | select(.ComplianceType == "NON_COMPLIANT") | .EvaluationResultIdentifier.EvaluationResultQualifier.ConfigRuleName' | sort -u | while read rule; do
    #     echo "    - $rule"
    # done

done

# End timing
end_time=$(date +%s.%N)
execution_time=$(echo "$end_time - $start_time" | bc)
echo "Execution time: ${execution_time}s"

exit 0 