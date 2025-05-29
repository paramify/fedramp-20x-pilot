#!/bin/bash
# Helper script for AWS GuardDuty validation

# Steps:
# 1. Check GuardDuty setup
#    - List detector IDs
#    aws guardduty list-detectors
#    - Get detector configuration details
#    aws guardduty get-detector --detector-id <detector-id>
#
# Output: Creates unique JSON file and appends to directory-based monitoring files

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
COMPONENT="guard_duty"
UNIQUE_JSON="$OUTPUT_DIR/$COMPONENT.json"
DIR_NAME=$(basename "$(dirname "$0")")
DIR_MONITORING_JSON="$OUTPUT_DIR/$DIR_NAME.json"

# ANSI color codes for better output readability
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Initialize unique JSON file
echo '{
    "results": {
        "detectors": [],
        "detector_details": {},
        "summary": {}
    }
}' > "$UNIQUE_JSON"

# Initialize or update directory monitoring JSON if it doesn't exist
if [ ! -f "$DIR_MONITORING_JSON" ]; then
    echo '{
        "results": {}
    }' > "$DIR_MONITORING_JSON"
fi

# 1. Check GuardDuty setup
echo -e "${BLUE}Checking GuardDuty setup...${NC}"

# Get detector IDs
detectors=$(aws guardduty list-detectors --profile "$PROFILE" --region "$REGION" --query 'DetectorIds[*]' --output json)

# Process each detector if any exist
if [ "$(echo "$detectors" | jq 'length')" -gt 0 ]; then
    echo "$detectors" | jq -r '.[]' | while read -r detector_id; do
        echo -e "${BLUE}Processing detector: $detector_id${NC}"
        
        # Get detector details
        detector_details=$(aws guardduty get-detector --profile "$PROFILE" --region "$REGION" --detector-id "$detector_id" --output json)
        
        # Add detector details to unique JSON
        jq --arg id "$detector_id" \
           --argjson details "$detector_details" \
           '.results.detector_details[$id] = $details' "$UNIQUE_JSON" > tmp.json && mv tmp.json "$UNIQUE_JSON"
        
        # Add to CSV
        status=$(echo "$detector_details" | jq -r '.Status // "DISABLED"')
        echo "$COMPONENT,detector_$detector_id,$status" >> "$OUTPUT_CSV"
    done
else
    echo -e "${YELLOW}No GuardDuty detectors found${NC}"
fi

# Update detectors list in unique JSON
jq --argjson detectors "$detectors" '.results.detectors = ($detectors // [])' "$UNIQUE_JSON" > tmp.json && mv tmp.json "$UNIQUE_JSON"

# Update directory monitoring JSON with all results
jq --argjson detectors "$detectors" \
   --argjson details "$(cat "$UNIQUE_JSON")" \
   --arg component "$COMPONENT" \
   '.results[$component] = $details.results' "$DIR_MONITORING_JSON" > tmp.json && mv tmp.json "$DIR_MONITORING_JSON"

# Main processing loop: build up a summary JSON object in a temp file
summary_json='{"detectors":{}}'
detector_count=0
all_enabled=true
overall_data_sources=""

# Use process substitution for the detector loop so variable changes persist
while read -r detector_id; do
    echo -e "${BLUE}Processing detector: $detector_id${NC}"
    
    # Get detector details
    detector_details=$(aws guardduty get-detector --profile "$PROFILE" --region "$REGION" --detector-id "$detector_id" --output json 2>/dev/null)
    if [ $? -ne 0 ] || [ -z "$detector_details" ] || ! echo "$detector_details" | jq . >/dev/null 2>&1; then
        echo -e "${YELLOW}Warning: Failed to get details for detector $detector_id. Skipping.${NC}"
        continue
    fi
    detector_count=$((detector_count+1))
    
    # Check if detector is enabled
    if [ "$(echo "$detector_details" | jq -r '.Status')" != "ENABLED" ]; then
        all_enabled=false
    fi
    
    # Collect data source statuses with more detail (as JSON, not string)
    data_sources_status=$(echo "$detector_details" | jq '{
        cloudtrail: { status: .DataSources.CloudTrail.Status },
        dns_logs: { status: .DataSources.DNSLogs.Status },
        flow_logs: { status: .DataSources.FlowLogs.Status },
        s3_logs: { status: .DataSources.S3Logs.Status },
        kubernetes: { status: (if .DataSources.Kubernetes.AuditLogs.Status then .DataSources.Kubernetes.AuditLogs.Status else "DISABLED" end) }
    }')
    
    # Store the data sources status for the overall summary (first detector only)
    if [ -z "$overall_data_sources" ]; then
        overall_data_sources="$data_sources_status"
    fi
    
    # Create summary JSON for this detector
    detector_summary=$(jq -n \
        --arg id "$detector_id" \
        --arg status "$(echo "$detector_details" | jq -r '.Status')" \
        --arg created "$(echo "$detector_details" | jq -r '.CreatedAt')" \
        --arg updated "$(echo "$detector_details" | jq -r '.UpdatedAt')" \
        --arg freq "$(echo "$detector_details" | jq -r '.FindingPublishingFrequency')" \
        --argjson sources "$data_sources_status" \
        '{
            "detector_id": $id,
            "status": $status,
            "created_at": $created,
            "updated_at": $updated,
            "finding_publishing_frequency": $freq,
            "data_sources": $sources
        }')
    
    # Add detector summary to summary_json
    summary_json=$(echo "$summary_json" | jq --arg id "$detector_id" --argjson detsum "$detector_summary" '.detectors[$id] = $detsum')
    
    # Add detector summary to CSV
    echo "$COMPONENT,detector_${detector_id}_status,$(echo "$detector_details" | jq -r '.Status')" >> "$OUTPUT_CSV"
    echo "$COMPONENT,detector_${detector_id}_created,$(echo "$detector_details" | jq -r '.CreatedAt')" >> "$OUTPUT_CSV"
    echo "$COMPONENT,detector_${detector_id}_updated,$(echo "$detector_details" | jq -r '.UpdatedAt')" >> "$OUTPUT_CSV"
    echo "$COMPONENT,detector_${detector_id}_frequency,$(echo "$detector_details" | jq -r '.FindingPublishingFrequency')" >> "$OUTPUT_CSV"
    echo "$COMPONENT,detector_${detector_id}_cloudtrail_status,$(echo "$data_sources_status" | jq -r '.cloudtrail.status')" >> "$OUTPUT_CSV"
    echo "$COMPONENT,detector_${detector_id}_dns_logs_status,$(echo "$data_sources_status" | jq -r '.dns_logs.status')" >> "$OUTPUT_CSV"
    echo "$COMPONENT,detector_${detector_id}_flow_logs_status,$(echo "$data_sources_status" | jq -r '.flow_logs.status')" >> "$OUTPUT_CSV"
    echo "$COMPONENT,detector_${detector_id}_s3_logs_status,$(echo "$data_sources_status" | jq -r '.s3_logs.status')" >> "$OUTPUT_CSV"
    echo "$COMPONENT,detector_${detector_id}_kubernetes_status,$(echo "$data_sources_status" | jq -r '.kubernetes.status')" >> "$OUTPUT_CSV"
    
    # Generate console output for this detector
    echo -e "\nDetector ID: $detector_id"
    echo "  Status: $(echo "$detector_details" | jq -r '.Status // "UNKNOWN"')"
    echo "  Created At: $(echo "$detector_details" | jq -r '.CreatedAt // "N/A"')"
    echo "  Updated At: $(echo "$detector_details" | jq -r '.UpdatedAt // "N/A"')"
    echo "  Finding Publishing Frequency: $(echo "$detector_details" | jq -r '.FindingPublishingFrequency // "N/A"')"
    echo -e "\n  Data Sources Status:"
    echo "    - CloudTrail:"
    echo "      Status: $(echo "$detector_details" | jq -r '.DataSources.CloudTrail.Status // "UNKNOWN"')"
    echo "    - DNS Logs:"
    echo "      Status: $(echo "$detector_details" | jq -r '.DataSources.DNSLogs.Status // "UNKNOWN"')"
    echo "    - Flow Logs:"
    echo "      Status: $(echo "$detector_details" | jq -r '.DataSources.FlowLogs.Status // "UNKNOWN"')"
    echo "    - S3 Logs:"
    echo "      Status: $(echo "$detector_details" | jq -r '.DataSources.S3Logs.Status // "UNKNOWN"')"
    echo "    - Kubernetes Audit Logs:"
    echo "      Status: $(echo "$detector_details" | jq -r '.DataSources.Kubernetes.AuditLogs.Status // "DISABLED"')"
done < <(echo "$detectors" | jq -r '.[]')

# After the main processing loop, count the number of detectors in summary_json for summary output
# Use jq to count the keys in the detectors object
summary_detector_count=$(echo "$summary_json" | jq '.detectors | length')

# Create overall summary JSON and combine with detector summaries
if [ -n "$overall_data_sources" ]; then
    echo "$overall_data_sources" > overall_data_sources.json
    summary_json=$(echo "$summary_json" | jq --arg count "$summary_detector_count" \
        --arg health "$(if [ "$all_enabled" = true ]; then echo "HEALTHY"; else echo "REQUIRES_ATTENTION"; fi)" \
        --slurpfile sources overall_data_sources.json \
        '{
            detector_count: $count,
            health_status: $health,
            issues: (if $health == "REQUIRES_ATTENTION" then ["detectors_disabled"] else [] end),
            data_sources: $sources[0]
        } + .')
    rm -f overall_data_sources.json
else
    summary_json=$(echo "$summary_json" | jq --arg count "$summary_detector_count" \
        --arg health "$(if [ "$all_enabled" = true ]; then echo "HEALTHY"; else echo "REQUIRES_ATTENTION"; fi)" \
        '{
            detector_count: $count,
            health_status: $health,
            issues: (if $health == "REQUIRES_ATTENTION" then ["detectors_disabled"] else [] end)
        } + .')
fi

# Update unique JSON with combined summary
jq --argjson summary "$summary_json" '.results.summary = $summary' "$UNIQUE_JSON" > tmp.json && mv tmp.json "$UNIQUE_JSON"

# Update directory monitoring JSON with combined summary
jq --arg component "$COMPONENT" \
   --argjson summary "$summary_json" \
   '.results[$component].summary = $summary' "$DIR_MONITORING_JSON" > tmp.json && mv tmp.json "$DIR_MONITORING_JSON"

# Add overall summary to CSV
echo "$COMPONENT,summary_detector_count,$summary_detector_count" >> "$OUTPUT_CSV"
echo "$COMPONENT,summary_health_status,$(if [ "$all_enabled" = true ]; then echo "HEALTHY"; else echo "REQUIRES_ATTENTION"; fi)" >> "$OUTPUT_CSV"

# Generate summary output
# Only print details, not 'Processing detector' in the summary section
echo -e "\n${GREEN}Validation Summary:${NC}"
echo "Number of GuardDuty Detectors: $summary_detector_count"
if [ "$summary_detector_count" -gt 0 ]; then
    echo -e "\n${BLUE}Detailed Statistics:${NC}"
    # Print only the details for each detector (no 'Processing detector' line)
    echo "$summary_json" | jq -r '.detectors | to_entries[] | "\nDetector ID: "+.key+"\n  Status: "+.value.status+"\n  Created At: "+.value.created_at+"\n  Updated At: "+.value.updated_at+"\n  Finding Publishing Frequency: "+.value.finding_publishing_frequency+"\n\n  Data Sources Status:\n    - CloudTrail:\n      Status: "+.value.data_sources.cloudtrail.status+"\n    - DNS Logs:\n      Status: "+.value.data_sources.dns_logs.status+"\n    - Flow Logs:\n      Status: "+.value.data_sources.flow_logs.status+"\n    - S3 Logs:\n      Status: "+.value.data_sources.s3_logs.status+"\n    - Kubernetes Audit Logs:\n      Status: "+.value.data_sources.kubernetes.status'
    echo -e "\n${YELLOW}Overall Health Assessment:${NC}"
    if [ "$all_enabled" = true ]; then
        echo "✅ GuardDuty is properly configured and operational"
    else
        echo "⚠️ GuardDuty requires attention:"
        echo "  - One or more detectors are not fully enabled"
        echo "  - Check the detailed statistics above for specific issues"
    fi
else
    echo -e "\n${RED}No GuardDuty detectors configured${NC}"
    echo "⚠️ GuardDuty requires attention:"
    echo "  - No detectors are configured in this region"
    echo "  - Consider enabling GuardDuty for enhanced security monitoring"
fi

exit 0
