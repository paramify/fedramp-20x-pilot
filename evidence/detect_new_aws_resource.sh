#TODO: Rework the frequecy interval check to reflect the 5 minute interval properly
#TODO: Verify the output is as intended

#!/bin/bash
# Helper script for AWS Config and EventBridge validation

# Steps:
# 1. Check AWS Config setup
#    aws configservice describe-configuration-recorders
#    aws configservice describe-configuration-recorder-status
#    aws configservice describe-delivery-channels
#
# 2. Check EventBridge rule for new resource detection
#    aws events list-rules --name "New-Resource-Launched-Alert-Rule"
#    aws events list-targets-by-rule --rule "New-Resource-Launched-Alert-Rule"
#    aws events describe-rule --name "New-Resource-Launched-Alert-Rule"
#
# 3. Check SNS topic for alerts
#    aws sns list-topics
#    aws sns list-subscriptions-by-topic --topic-arn <New_AWS_Resource_Launch_Detected>
#
# 4. Verify monitoring interval
#    Check if EventBridge rule schedule is 5 minutes or less
#
# Output: Creates JSON with validation results and writes to CSV

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
COMPONENT="detect_new_aws_resource"
OUTPUT_JSON="$OUTPUT_DIR/$COMPONENT.json"

# ANSI color codes for better output readability
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Initialize JSON file with empty arrays instead of empty objects
echo '{
    "results": {
        "aws_config": {
            "recorders": [],
            "status": [],
            "delivery_channels": []
        },
        "eventbridge": {
            "rules": {}
        },
        "sns": {
            "topics": {}
        },
        "validation_results": {
            "interval_checks": {}
        }
    }
}' > "$OUTPUT_JSON"

# 1. Check AWS Config setup
echo -e "${BLUE}Checking AWS Config setup...${NC}"

# Get configuration recorders
config_recorders=$(aws configservice describe-configuration-recorders --profile "$PROFILE" --region "$REGION" --query 'ConfigurationRecorders[*]' --output json)
recorder_status=$(aws configservice describe-configuration-recorder-status --profile "$PROFILE" --region "$REGION" --query 'ConfigurationRecordersStatus[*]' --output json)
delivery_channels=$(aws configservice describe-delivery-channels --profile "$PROFILE" --region "$REGION" --query 'DeliveryChannels[*]' --output json)

# Add AWS Config results
jq --argjson recorders "$config_recorders" \
   --argjson status "$recorder_status" \
   --argjson channels "$delivery_channels" \
   '.results.aws_config = {
       "recorders": ($recorders // []),
       "status": ($status // []),
       "delivery_channels": ($channels // [])
   }' "$OUTPUT_JSON" > tmp.json && mv tmp.json "$OUTPUT_JSON"

# 2. Check EventBridge rules
echo -e "${BLUE}Checking EventBridge rules...${NC}"

# Get specific rule for new resource detection
rules=$(aws events list-rules --profile "$PROFILE" --region "$REGION" --name "New-Resource-Launched-Alert-Rule" --query 'Rules[*]' --output json)

# Process each rule if any exist
if [ "$(echo "$rules" | jq 'length')" -gt 0 ]; then
    echo "$rules" | jq -c '.[]' | while read -r rule; do
        rule_name=$(echo "$rule" | jq -r '.Name')
        echo -e "${BLUE}Processing rule: $rule_name${NC}"
        
        # Get rule targets
        targets=$(aws events list-targets-by-rule --profile "$PROFILE" --region "$REGION" --rule "$rule_name" --query 'Targets[*]' --output json)
        
        # Get rule details including schedule
        rule_details=$(aws events describe-rule --profile "$PROFILE" --region "$REGION" --name "$rule_name" --output json)
        schedule=$(echo "$rule_details" | jq -r '.ScheduleExpression // empty')
        
        # Add rule details
        jq --arg name "$rule_name" \
           --argjson targets "$targets" \
           --arg schedule "$schedule" \
           --argjson rule "$rule" \
           '.results.eventbridge.rules[$name] = {
               "rule": $rule,
               "targets": ($targets // []),
               "schedule": $schedule
           }' "$OUTPUT_JSON" > tmp.json && mv tmp.json "$OUTPUT_JSON"
        
        # Add to CSV with actual schedule
        echo "$COMPONENT,eventbridge_rule,$rule_name,$schedule" >> "$OUTPUT_CSV"
    done
else
    echo -e "${YELLOW}No EventBridge rule found with name 'New-Resource-Launched-Alert-Rule'${NC}"
fi

# 3. Check SNS topics and subscriptions
echo -e "${BLUE}Checking SNS topics...${NC}"

# Get all SNS topics
topics=$(aws sns list-topics --profile "$PROFILE" --region "$REGION" --query 'Topics[*]' --output json)

# Process each topic if any exist
if [ "$(echo "$topics" | jq 'length')" -gt 0 ]; then
    echo "$topics" | jq -c '.[]' | while read -r topic; do
        topic_arn=$(echo "$topic" | jq -r '.TopicArn')
        topic_name=$(echo "$topic_arn" | awk -F':' '{print $NF}')
        
        # Only process the specific topic
        if [[ "$topic_name" == "New_AWS_Resource_Launch_Detected" ]]; then
            echo -e "${BLUE}Processing topic: $topic_name${NC}"
            
            # Get topic subscriptions
            subscriptions=$(aws sns list-subscriptions-by-topic --profile "$PROFILE" --region "$REGION" --topic-arn "$topic_arn" --query 'Subscriptions[*]' --output json)
            
            # Add topic details
            jq --arg name "$topic_name" \
               --argjson topic "$topic" \
               --argjson subs "$subscriptions" \
               '.results.sns.topics[$name] = {
                   "topic": $topic,
                   "subscriptions": ($subs // [])
               }' "$OUTPUT_JSON" > tmp.json && mv tmp.json "$OUTPUT_JSON"
            
            # Add to CSV
            echo "$COMPONENT,sns_topic,$topic_name,$(echo "$subscriptions" | jq -r 'length // 0')" >> "$OUTPUT_CSV"
        fi
    done
else
    echo -e "${YELLOW}No SNS topics found${NC}"
fi

# 4. Verify monitoring interval
echo -e "${BLUE}Verifying monitoring intervals...${NC}"

# Check each rule's schedule if any rules exist
if [ "$(jq -r '.results.eventbridge.rules | length' "$OUTPUT_JSON")" -gt 0 ]; then
    jq -r '.results.eventbridge.rules | keys[]' "$OUTPUT_JSON" | while read -r rule_name; do
        schedule=$(jq -r --arg name "$rule_name" '.results.eventbridge.rules[$name].schedule' "$OUTPUT_JSON")
        
        # Verify schedule is 5 minutes or less
        if [[ "$schedule" == *"rate(5 minutes)"* ]] || [[ "$schedule" == *"rate(1 minute)"* ]] || [[ "$schedule" == *"rate(2 minutes)"* ]] || [[ "$schedule" == *"rate(3 minutes)"* ]] || [[ "$schedule" == *"rate(4 minutes)"* ]]; then
            interval_check="PASS"
        else
            interval_check="FAIL"
        fi
        
        # Add interval check to results
        jq --arg name "$rule_name" \
           --arg check "$interval_check" \
           --arg schedule "$schedule" \
           '.results.validation_results.interval_checks[$name] = {
               "status": $check,
               "schedule": $schedule
           }' "$OUTPUT_JSON" > tmp.json && mv tmp.json "$OUTPUT_JSON"
        
        # Add to CSV
        echo "$COMPONENT,interval_check,$rule_name,$interval_check" >> "$OUTPUT_CSV"
    done
else
    echo -e "${YELLOW}No EventBridge rules found to check intervals${NC}"
fi

# Generate summary
echo -e "\n${GREEN}Validation Summary:${NC}"
echo "AWS Config Recording Status: $(jq -r '.results.aws_config.status[0].recording // "false"' "$OUTPUT_JSON")"

# Check EventBridge rule state
rule_state=$(jq -r '.results.eventbridge.rules["New-Resource-Launched-Alert-Rule"].rule.State // "DISABLED"' "$OUTPUT_JSON")
echo "EventBridge Rule 'New-Resource-Launched-Alert-Rule': $rule_state"

# Check SNS topic
sns_topic_count=$(jq -r '.results.sns.topics | length' "$OUTPUT_JSON")
if [ "$sns_topic_count" -gt 0 ]; then
    echo "SNS Topic 'New_AWS_Resource_Launch_Detected': FOUND"
else
    echo "SNS Topic 'New_AWS_Resource_Launch_Detected': NOT FOUND"
fi

# Check monitoring interval
if [ "$(jq -r '.results.eventbridge.rules | length' "$OUTPUT_JSON")" -gt 0 ]; then
    interval_status=$(jq -r '.results.validation_results.interval_checks["New-Resource-Launched-Alert-Rule"].status // "FAIL"' "$OUTPUT_JSON")
    interval_schedule=$(jq -r '.results.validation_results.interval_checks["New-Resource-Launched-Alert-Rule"].schedule // "Not configured"' "$OUTPUT_JSON")
    echo "Monitoring Interval Check: $interval_status (Schedule: $interval_schedule)"
fi

exit 0 