#!/bin/bash
# Helper script for AWS Config validation

# Steps:
# 1. Check AWS Config setup
#    - Get configuration recorder status
#    aws configservice describe-configuration-recorder-status
#    - View configuration recorder details
#    aws configservice describe-configuration-recorders
#    - Check delivery channel configuration
#    aws configservice describe-delivery-channels
#
# Output: Creates unique JSON file and appends to System-Monitoring files

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
COMPONENT="aws_config_monitoring"
UNIQUE_JSON="$OUTPUT_DIR/$COMPONENT.json"
SYSTEMS_MONITORING_JSON="$OUTPUT_DIR/Systems-Monitoring.json"

# ANSI color codes for better output readability
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Initialize unique JSON file
echo '{
    "results": {
        "configuration_recorders": [],
        "recorder_status": [],
        "delivery_channels": [],
        "summary": {}
    }
}' > "$UNIQUE_JSON"

# Initialize or update Systems-Monitoring.json if it doesn't exist
if [ ! -f "$SYSTEMS_MONITORING_JSON" ]; then
    echo '{
        "results": {}
    }' > "$SYSTEMS_MONITORING_JSON"
fi

# 1. Check AWS Config setup
echo -e "${BLUE}Checking AWS Config setup...${NC}"

# Get configuration recorder status
recorder_status=$(aws configservice describe-configuration-recorder-status --profile "$PROFILE" --region "$REGION" --query 'ConfigurationRecordersStatus[*]' --output json)

# Get configuration recorder details
config_recorders=$(aws configservice describe-configuration-recorders --profile "$PROFILE" --region "$REGION" --query 'ConfigurationRecorders[*]' --output json)

# Get delivery channel configuration
delivery_channels=$(aws configservice describe-delivery-channels --profile "$PROFILE" --region "$REGION" --query 'DeliveryChannels[*]' --output json)

# Update unique JSON with results
jq --argjson status "$recorder_status" \
   --argjson recorders "$config_recorders" \
   --argjson channels "$delivery_channels" \
   '.results = {
       "configuration_recorders": ($recorders // []),
       "recorder_status": ($status // []),
       "delivery_channels": ($channels // [])
   }' "$UNIQUE_JSON" > tmp.json && mv tmp.json "$UNIQUE_JSON"

# Update System-Monitoring.json
jq --argjson status "$recorder_status" \
   --argjson recorders "$config_recorders" \
   --argjson channels "$delivery_channels" \
   --arg component "$COMPONENT" \
   '.results[$component] = {
       "configuration_recorders": ($recorders // []),
       "recorder_status": ($status // []),
       "delivery_channels": ($channels // [])
   }' "$SYSTEM_MONITORING_JSON" > tmp.json && mv tmp.json "$SYSTEM_MONITORING_JSON"

# Append results to CSV
# Add configuration recorder status
recording_status=$(echo "$recorder_status" | jq -r '.[0].recording // "false"')
echo "$COMPONENT,configuration_recorder_recording,$recording_status" >> "$OUTPUT_CSV"

# Add delivery channel status
if [ "$(echo "$delivery_channels" | jq 'length')" -gt 0 ]; then
    echo "$COMPONENT,delivery_channel,CONFIGURED" >> "$OUTPUT_CSV"
else
    echo "$COMPONENT,delivery_channel,NOT_CONFIGURED" >> "$OUTPUT_CSV"
fi

# Generate summary information
recorder_count=$(echo "$config_recorders" | jq 'length')
channel_count=$(echo "$delivery_channels" | jq 'length')
all_resources=$(echo "$config_recorders" | jq -r '.[0].recordingGroup.allSupported // false')
global_resources=$(echo "$config_recorders" | jq -r '.[0].recordingGroup.includeGlobalResources // false')
last_status=$(echo "$recorder_status" | jq -r '.[0].lastStatus // "N/A"')
last_error=$(echo "$recorder_status" | jq -r '.[0].lastErrorCode // "NONE"')
s3_bucket=$(echo "$delivery_channels" | jq -r '.[0].s3BucketName // "N/A"')
sns_topic=$(echo "$delivery_channels" | jq -r '.[0].snsTopicARN // "N/A"')
delivery_freq=$(echo "$delivery_channels" | jq -r '.[0].configSnapshotDeliveryProperties.deliveryFrequency // "N/A"')

# Create summary JSON
summary_json=$(jq -n \
  --arg status "$recording_status" \
  --arg channels "$channel_count" \
  --arg recorders "$recorder_count" \
  --arg all_res "$all_resources" \
  --arg global_res "$global_resources" \
  --arg last_stat "$last_status" \
  --arg last_err "$last_error" \
  --arg s3 "$s3_bucket" \
  --arg sns "$sns_topic" \
  --arg freq "$delivery_freq" \
  '{
    "summary": {
      "basic_status": {
        "recording_enabled": $status,
        "delivery_channels_configured": $channels
      },
      "configuration_details": {
        "recorder_count": $recorders,
        "all_resources_recorded": $all_res,
        "global_resources_included": $global_res
      },
      "status_details": {
        "last_status": $last_stat,
        "last_error": $last_err
      },
      "delivery_details": {
        "s3_bucket": $s3,
        "sns_topic": $sns,
        "delivery_frequency": $freq
      },
      "health_assessment": {
        "status": (if $status == "true" and $channels != "0" then "HEALTHY" else "REQUIRES_ATTENTION" end),
        "issues": (if $status != "true" then ["recording_disabled"] else [] end + if $channels == "0" then ["no_delivery_channel"] else [] end)
      }
    }
  }')

# Update unique JSON with summary
jq --argjson summary "$summary_json" '.results.summary = $summary.summary' "$UNIQUE_JSON" > tmp.json && mv tmp.json "$UNIQUE_JSON"

# Update directory monitoring JSON with summary
jq --arg component "$COMPONENT" \
   --argjson summary "$summary_json" \
   '.results[$component].summary = $summary.summary' "$SYSTEMS_MONITORING_JSON" > tmp.json && mv tmp.json "$SYSTEMS_MONITORING_JSON"

# Add summary to CSV
echo "$COMPONENT,summary_recording_enabled,$recording_status" >> "$OUTPUT_CSV"
echo "$COMPONENT,summary_delivery_channels,$channel_count" >> "$OUTPUT_CSV"
echo "$COMPONENT,summary_recorder_count,$recorder_count" >> "$OUTPUT_CSV"
echo "$COMPONENT,summary_all_resources,$all_resources" >> "$OUTPUT_CSV"
echo "$COMPONENT,summary_global_resources,$global_resources" >> "$OUTPUT_CSV"
echo "$COMPONENT,summary_last_status,$last_status" >> "$OUTPUT_CSV"
echo "$COMPONENT,summary_last_error,$last_error" >> "$OUTPUT_CSV"
echo "$COMPONENT,summary_s3_bucket,$s3_bucket" >> "$OUTPUT_CSV"
echo "$COMPONENT,summary_sns_topic,$sns_topic" >> "$OUTPUT_CSV"
echo "$COMPONENT,summary_delivery_frequency,$delivery_freq" >> "$OUTPUT_CSV"
echo "$COMPONENT,summary_health_status,$(if [ "$recording_status" = "true" ] && [ "$channel_count" -gt 0 ]; then echo "HEALTHY"; else echo "REQUIRES_ATTENTION"; fi)" >> "$OUTPUT_CSV"

# Generate console output
echo -e "\n${GREEN}Validation Summary:${NC}"

# Basic status
echo "AWS Config Recording Status: $recording_status"
echo "Delivery Channel Status: $(if [ "$channel_count" -gt 0 ]; then echo "CONFIGURED"; else echo "NOT_CONFIGURED"; fi)"

# Detailed statistics
echo -e "\n${BLUE}Detailed Statistics:${NC}"

# Configuration Recorder Details
echo "Configuration Recorder Details:"
echo "  - Number of Recorders: $recorder_count"
if [ "$recorder_count" -gt 0 ]; then
    echo "  - Recording All Resources: $all_resources"
    echo "  - Include Global Resources: $global_resources"
fi

# Recorder Status Details
echo -e "\nRecorder Status Details:"
if [ "$(echo "$recorder_status" | jq 'length')" -gt 0 ]; then
    echo "  - Last Status: $last_status"
    echo "  - Last Error Code: $last_error"
fi

# Delivery Channel Details
echo -e "\nDelivery Channel Details:"
echo "  - Number of Delivery Channels: $channel_count"
if [ "$channel_count" -gt 0 ]; then
    echo "  - S3 Bucket: $s3_bucket"
    echo "  - SNS Topic: $sns_topic"
    echo "  - Delivery Frequency: $delivery_freq"
fi

# Overall Health Assessment
echo -e "\n${YELLOW}Overall Health Assessment:${NC}"
if [ "$recording_status" = "true" ] && [ "$channel_count" -gt 0 ]; then
    echo "✅ AWS Config is properly configured and operational"
else
    echo "⚠️ AWS Config requires attention:"
    [ "$recording_status" != "true" ] && echo "  - Configuration recording is not enabled"
    [ "$channel_count" -eq 0 ] && echo "  - No delivery channel configured"
fi

exit 0
