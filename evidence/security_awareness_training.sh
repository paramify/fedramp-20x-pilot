#!/bin/bash
# Helper script for Security Awareness Training validation

# Note: KnowBe4 API Requirements
# Source: https://help.sumologic.com/docs/send-data/hosted-collectors/cloud-to-cloud-integration-framework/knowbe4-api-source/
#
# KnowBe4 APIs are only limited to Platinum and Diamond customers.
#
# Before you begin setting up your KnowBe4 Source, which is required to connect to the KnowBe4 API,
# you'll need to configure your integration with the Region and KnowBe4 API Token.
#
# Region:
# The Region is the region where your KnowBe4 account is located. To know your region:
# 1. Sign in to the KnowBe4 application
# 2. At the top of the browser, you will see the Region inside the address bar
# 3. Choose the Region from the dropdown based on the location of your KnowBe4 account:
#    - US
#    - EU
#    - CA
#    - UK
#    - DE
#
# API Token:
# The API security token is used to authenticate with KnowBe4 API. To get the KnowBe4 API token:
# 1. Sign in to the KnowBe4 application as an Admin user
# 2. Navigate to the Account Settings
# 3. Click Account Integrations from the left menu, and then click API option
# 4. Under the API section, checkmark the Enable Reporting API Access
# 5. The KnowBe4 Secure API token is displayed
# 6. Save this API key to use while configuring the Source
# 7. Click Save Changes
#
# KnowBe4 API Documentation: 
# https://developer.knowbe4.com/rest/reporting
#
#
# Steps:
# 1. Get all users from KnowBe4 API
#    curl -H "Authorization: Bearer $API_KEY" https://us.api.knowbe4.com/v1/users
#
# 2. Get all training enrollments
#    curl -H "Authorization: Bearer $API_KEY" https://us.api.knowbe4.com/v1/training/enrollments
#
# Output: Creates unique JSON file and appends to Training-and-Awareness files

# Required parameters
if [ "$#" -lt 2 ]; then
    echo "Usage: $0 <output_dir> <output_csv>"
    exit 1
fi

# Load environment variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/.env" ]; then
    source "$SCRIPT_DIR/.env"
else
    echo "Error: .env file not found. Please create it from .env.example"
    exit 1
fi

OUTPUT_DIR="$1"
OUTPUT_CSV="$2"

# Component identifier
COMPONENT="security_awareness_training"
UNIQUE_JSON="$OUTPUT_DIR/$COMPONENT.json"
DIR_MONITORING_JSON="$OUTPUT_DIR/Training-and-Awareness.json"

# ANSI color codes for better output readability
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Initialize unique JSON file
echo '{
    "results": {
        "users": [],
        "enrollments": [],
        "user_training_status": {},
        "summary": {
            "total_users": 0,
            "completed_training": 0,
            "in_progress": 0,
            "not_started": 0,
            "completion_rate": 0
        }
    }
}' > "$UNIQUE_JSON"

# Initialize or update Training-and-Awareness.json if it doesn't exist
if [ ! -f "$DIR_MONITORING_JSON" ]; then
    echo '{
        "results": {}
    }' > "$DIR_MONITORING_JSON"
fi

# Check for KnowBe4 API key
if [ -z "$KNOWBE4_API_KEY" ]; then
    echo -e "${RED}Error: KNOWBE4_API_KEY environment variable is not set in .env file${NC}"
    exit 1
fi

# Check for KnowBe4 region
if [ -z "$KNOWBE4_REGION" ]; then
    echo -e "${RED}Error: KNOWBE4_REGION environment variable is not set in .env file${NC}"
    exit 1
fi

# Function to make API calls
make_api_call() {
    local endpoint=$1
    local url="https://${KNOWBE4_REGION}.api.knowbe4.com/v1/${endpoint}"
    local response
    response=$(curl -s -H "Authorization: Bearer ${KNOWBE4_API_KEY}" -H "Content-Type: application/json" "${url}")
    
    # Check if response is valid JSON
    if ! echo "$response" | jq . >/dev/null 2>&1; then
        echo "{}"
        return 1
    fi
    
    # Check for 404 status
    if echo "$response" | jq -e '.status == 404' >/dev/null 2>&1; then
        echo "{}"
        return 1
    fi
    
    echo "$response"
    return 0
}

# Get all users
echo -e "${BLUE}Fetching users from KnowBe4...${NC}"
users_response=$(make_api_call "users")
if [ $? -ne 0 ]; then
    echo -e "${RED}Error: Failed to fetch users${NC}"
    exit 1
fi

# Get all training enrollments
echo -e "${BLUE}Fetching training enrollments...${NC}"
enrollments_response=$(make_api_call "training/enrollments?exclude_archived_users=true&include_campaign_id=true")
if [ $? -ne 0 ]; then
    echo -e "${RED}Error: Failed to fetch enrollments${NC}"
    exit 1
fi

# Process each user
echo "$users_response" | jq -c '.[] | select(.status == "active")' | while read -r user; do
    user_id=$(echo "$user" | jq -r '.id')
    user_email=$(echo "$user" | jq -r '.email')
    
    # Add minimal user info to users array (excluding policy_acknowledged)
    minimal_user=$(echo "$user" | jq '{id: .id, email: .email, status: .status}')
    jq --argjson user "$minimal_user" '.results.users += [$user]' "$UNIQUE_JSON" > tmp.json && mv tmp.json "$UNIQUE_JSON"
    
    # Get user's enrollments
    user_enrollments=$(echo "$enrollments_response" | jq -c --arg user_id "$user_id" '.[] | select(.user.id == ($user_id|tonumber))')
    
    # Initialize user's training status
    user_status="not_started"
    if [ -n "$user_enrollments" ]; then
        # Add enrollments to the results
        echo "$user_enrollments" | while read -r enrollment; do
            jq --argjson enrollment "$enrollment" '.results.enrollments += [$enrollment]' "$UNIQUE_JSON" > tmp.json && mv tmp.json "$UNIQUE_JSON"
        done
        
        # Check if user has completed any training
        if echo "$enrollments_response" | jq -e --arg user_id "$user_id" '.[] | select(.user.id == ($user_id|tonumber) and .status == "Passed")' >/dev/null 2>&1; then
            user_status="completed"
        elif echo "$enrollments_response" | jq -e --arg user_id "$user_id" '.[] | select(.user.id == ($user_id|tonumber) and .status == "In Progress")' >/dev/null 2>&1; then
            user_status="in_progress"
        fi
    fi
    
    # Update user's training status
    jq --arg email "$user_email" \
       --arg status "$user_status" \
       '.results.user_training_status[$email] = $status' "$UNIQUE_JSON" > tmp.json && mv tmp.json "$UNIQUE_JSON"
    
    # Add to CSV
    echo "$COMPONENT,$user_email,$user_status" >> "$OUTPUT_CSV"
done

# Calculate summary statistics
total_users=$(jq '.results.users | length' "$UNIQUE_JSON")
completed_training=$(jq '.results.user_training_status | to_entries | map(select(.value == "completed")) | length' "$UNIQUE_JSON")
in_progress=$(jq '.results.user_training_status | to_entries | map(select(.value == "in_progress")) | length' "$UNIQUE_JSON")
not_started=$(jq '.results.user_training_status | to_entries | map(select(.value == "not_started")) | length' "$UNIQUE_JSON")
completion_rate=0
if [ "$total_users" -gt 0 ]; then
    completion_rate=$((completed_training * 100 / total_users))
fi

# Update summary in JSON
jq --arg total "$total_users" \
   --arg completed "$completed_training" \
   --arg in_progress "$in_progress" \
   --arg not_started "$not_started" \
   --arg rate "$completion_rate" \
   '.results.summary = {
       "total_users": ($total|tonumber),
       "completed_training": ($completed|tonumber),
       "in_progress": ($in_progress|tonumber),
       "not_started": ($not_started|tonumber),
       "completion_rate": ($rate|tonumber)
   }' "$UNIQUE_JSON" > tmp.json && mv tmp.json "$UNIQUE_JSON"

# Append summary to CSV
{
  echo "SUMMARY,Total Users,$total_users"
  echo "SUMMARY,Completed Training,$completed_training"
  echo "SUMMARY,In Progress,$in_progress"
  echo "SUMMARY,Not Started,$not_started"
  echo "SUMMARY,Completion Rate,${completion_rate}%"
} >> "$OUTPUT_CSV"

# Update Training-and-Awareness.json
jq --arg component "$COMPONENT" \
   --argjson results "$(cat "$UNIQUE_JSON")" \
   '.results[$component] = $results.results' "$DIR_MONITORING_JSON" > tmp.json && mv tmp.json "$DIR_MONITORING_JSON"

# Generate summary
echo -e "\n${GREEN}Validation Summary:${NC}"
echo -e "Total Active Users: $total_users"
echo -e "Completed Training: $completed_training"
echo -e "In Progress: $in_progress"
echo -e "Not Started: $not_started"
echo -e "Completion Rate: ${completion_rate}%"

exit 0 