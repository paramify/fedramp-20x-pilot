#!/bin/bash

# Helper script for Load Balancer Encryption Status Validation
#
# Steps:
# 1. Check Load Balancer encryption settings
#    aws elbv2 describe-load-balancers
#    aws elbv2 describe-listeners --load-balancer-arn <arn> --query "Listeners[*].{Port:Port,Protocol:Protocol,SslPolicy:SslPolicy}"
#
# Output: Creates JSON report with encryption status

# Exit on any error
set -e

# Check if required parameters are provided
if [ "$#" -ne 4 ]; then
    echo "Usage: $0 <profile> <region> <output_dir> <csv_file>"
    exit 1
fi

PROFILE="$1"
REGION="$2"
OUTPUT_DIR="$3"
CSV_FILE="$4"

# Component identifier
COMPONENT="load_balancer_encryption"
OUTPUT_JSON="$OUTPUT_DIR/$COMPONENT.json"

# ANSI color codes for better output readability
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Initialize JSON file
echo '{
  "metadata": {
    "region": "'"$REGION"'",
    "profile": "'"$PROFILE"'",
    "datetime": "'"$(date -u +"%Y-%m-%dT%H:%M:%SZ")"'"
  },
  "results": {
    "load_balancers": {
      "alb": {
        "total": 0,
        "encrypted": 0,
        "details": []
      },
      "nlb": {
        "total": 0,
        "encrypted": 0,
        "details": []
      }
    }
  },
  "summary": {}
}' > "$OUTPUT_JSON"

# Function to check load balancer encryption
check_load_balancer_encryption() {
    local lb_arn=$1
    local lb_type=$2
    
    # Get listeners with their SSL policies
    local listeners
    listeners=$(aws elbv2 describe-listeners --load-balancer-arn "$lb_arn" \
        --query "Listeners[*].{Port:Port,Protocol:Protocol,SslPolicy:SslPolicy}" \
        --profile "$PROFILE" --region "$REGION" 2>/dev/null)
    
    # Check if any listener uses HTTPS/SSL with secure policy
    local is_encrypted=false
    
    # Use a for loop to avoid subshell issues
    local ssl_policies
    ssl_policies=$(echo "$listeners" | jq -r '.[] | select(.Protocol == "HTTPS" or .Protocol == "TLS") | .SslPolicy')
    for ssl_policy in $ssl_policies; do
        if [[ -n "$ssl_policy" ]]; then
            if [[ "$ssl_policy" == *"FIPS"* ]] || [[ "$ssl_policy" == *"TLS13"* ]] || [[ "$ssl_policy" == *"TLS-1-2"* ]]; then
                is_encrypted=true
                break
            fi
        fi
    done
    
    echo "$is_encrypted"
}

# Start timing
start_time=$(date +%s.%N)

echo -e "${BLUE}Checking load balancer encryption...${NC}"

# Get all load balancers
load_balancers=$(aws elbv2 describe-load-balancers --profile "$PROFILE" --region "$REGION" 2>/dev/null)

# Process ALBs
alb_count=0
alb_encrypted=0
alb_details=()

# Process NLBs
nlb_count=0
nlb_encrypted=0
nlb_details=()

# Process each load balancer
while IFS=$'\t' read -r arn type; do
    if [[ "$type" == "application" ]]; then
        alb_count=$((alb_count + 1))
        is_encrypted=$(check_load_balancer_encryption "$arn" "application")
        if [[ "$is_encrypted" == "true" ]]; then
            alb_encrypted=$((alb_encrypted + 1))
        fi
        # Get SSL policy details for the output
        ssl_policy=$(aws elbv2 describe-listeners --load-balancer-arn "$arn" \
            --query "Listeners[*].{Port:Port,Protocol:Protocol,SslPolicy:SslPolicy}" \
            --profile "$PROFILE" --region "$REGION" 2>/dev/null | jq -r '.[0].SslPolicy // "none"')
        alb_details+=("{\"arn\":\"$arn\",\"encrypted\":$is_encrypted,\"ssl_policy\":\"$ssl_policy\"}")
    elif [[ "$type" == "network" ]]; then
        nlb_count=$((nlb_count + 1))
        is_encrypted=$(check_load_balancer_encryption "$arn" "network")
        if [[ "$is_encrypted" == "true" ]]; then
            nlb_encrypted=$((nlb_encrypted + 1))
        fi
        # Get SSL policy details for the output
        ssl_policy=$(aws elbv2 describe-listeners --load-balancer-arn "$arn" \
            --query "Listeners[*].{Port:Port,Protocol:Protocol,SslPolicy:SslPolicy}" \
            --profile "$PROFILE" --region "$REGION" 2>/dev/null | jq -r '.[0].SslPolicy // "none"')
        nlb_details+=("{\"arn\":\"$arn\",\"encrypted\":$is_encrypted,\"ssl_policy\":\"$ssl_policy\"}")
    fi
done < <(echo "$load_balancers" | jq -r '.LoadBalancers[] | [.LoadBalancerArn, .Type] | @tsv')

# Update JSON with load balancer information
jq --arg alb_count "$alb_count" --arg alb_encrypted "$alb_encrypted" \
   --arg nlb_count "$nlb_count" --arg nlb_encrypted "$nlb_encrypted" \
   --argjson alb_details "[$(IFS=,; echo "${alb_details[*]}")]" \
   --argjson nlb_details "[$(IFS=,; echo "${nlb_details[*]}")]" \
   '.results.load_balancers.alb.total = ($alb_count | tonumber) |
    .results.load_balancers.alb.encrypted = ($alb_encrypted | tonumber) |
    .results.load_balancers.alb.details = $alb_details |
    .results.load_balancers.nlb.total = ($nlb_count | tonumber) |
    .results.load_balancers.nlb.encrypted = ($nlb_encrypted | tonumber) |
    .results.load_balancers.nlb.details = $nlb_details' \
   "$OUTPUT_JSON" > tmp.json && mv tmp.json "$OUTPUT_JSON"

# Update summary in JSON
jq --arg alb_count "$alb_count" --arg alb_encrypted "$alb_encrypted" \
   --arg nlb_count "$nlb_count" --arg nlb_encrypted "$nlb_encrypted" \
   '.summary = {
      alb_total: ($alb_count | tonumber),
      alb_encrypted: ($alb_encrypted | tonumber),
      nlb_total: ($nlb_count | tonumber),
      nlb_encrypted: ($nlb_encrypted | tonumber),
      formatted_summary: ("ALB: " + $alb_encrypted + "/" + $alb_count + ", NLB: " + $nlb_encrypted + "/" + $nlb_count)
   }' "$OUTPUT_JSON" > tmp.json && mv tmp.json "$OUTPUT_JSON"

# Calculate execution time
end_time=$(date +%s.%N)
execution_time=$(echo "$end_time - $start_time" | bc)

# Add to CSV with formatted summary
echo "load_balancer_encryption,$(jq -r '.summary.formatted_summary' "$OUTPUT_JSON")" >> "$CSV_FILE"

# Print final summary
echo -e "\n${GREEN}Load Balancer Encryption Summary:${NC}"
echo -e "${BLUE}--------------------------------${NC}"
jq -r '.summary.formatted_summary' "$OUTPUT_JSON"

exit 0
