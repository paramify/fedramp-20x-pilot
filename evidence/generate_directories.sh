##############################################################################
# INSTRUCTIONS
#
# 1. Save this script in the parent directory
#
# 2. Make it executable:
# chmod +x generate_directories.sh
#
# 3. Run it to create the directory structure:
# NOTE: This script will override any existing directories and files!! 
# ./generate_directories.sh
#
##############################################################################


#!/bin/bash

# Set metadata
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
PROFILE="your_profile_here"
ENVIRONMENT="your_environment_here"

# Create KSI directory structure using simple variables instead of associative arrays
# Each variable holds the subdirectories for a KSI family

KSI_CNA="KSI-CNA-1 KSI-CNA-2 KSI-CNA-3 KSI-CNA-4 KSI-CNA-5 KSI-CNA-6 KSI-CNA-7"
KSI_SC="KSI-SC-1 KSI-SC-2 KSI-SC-3 KSI-SC-4 KSI-SC-5 KSI-SC-6 KSI-SC-7"
KSI_IAM="KSI-IAM-1 KSI-IAM-2 KSI-IAM-3 KSI-IAM-4"
KSI_MLA="KSI-MLA-1 KSI-MLA-2 KSI-MLA-3 KSI-MLA-4 KSI-MLA-5 KSI-MLA-6"
KSI_CM="KSI-CM-1 KSI-CM-2 KSI-CM-3 KSI-CM-4 KSI-CM-5"
KSI_PI="KSI-PI-1 KSI-PI-2 KSI-PI-3 KSI-PI-4 KSI-PI-5 KSI-PI-6"
KSI_3IR="KSI-3IR-1 KSI-3IR-2 KSI-3IR-3 KSI-3IR-4 KSI-3IR-5"
KSI_CE="KSI-CE-1 KSI-CE-2"
KSI_IR="KSI-IR-1 KSI-IR-2 KSI-IR-3 KSI-IR-4 KSI-IR-5 KSI-IR-6"

# Function to create directories and files for a KSI family
create_ksi_family() {
    local FAMILY=$1
    local SUBDIRS=$2
    
    mkdir -p "Evidence/$FAMILY"
    
    for KSI_ID in $SUBDIRS; do
        mkdir -p "Evidence/$FAMILY/$KSI_ID"
        
        # Placeholder JSON
        cat <<EOF > "Evidence/$FAMILY/$KSI_ID/$KSI_ID.json"
{
"timestamp": "$TIMESTAMP",
"profile": "$PROFILE",
"environment": "$ENVIRONMENT",
"evidence": []
}
EOF

        # Placeholder CSV
        echo "timestamp,profile,environment,evidence" > "Evidence/$FAMILY/$KSI_ID/$KSI_ID.csv"
        echo "$TIMESTAMP,$PROFILE,$ENVIRONMENT," >> "Evidence/$FAMILY/$KSI_ID/$KSI_ID.csv"
        
        # Starter validation script
        cat <<EOF > "Evidence/$FAMILY/$KSI_ID/$KSI_ID.sh"
#!/bin/bash
# Validation script for $KSI_ID
# Timestamp: $TIMESTAMP
# Profile: $PROFILE
# Environment: $ENVIRONMENT

echo "Validation for $KSI_ID..."
# Insert evidence generation logic here
EOF
        chmod +x "Evidence/$FAMILY/$KSI_ID/$KSI_ID.sh"
    done
}

# Create Evidence parent folder
mkdir -p "Evidence"

# Create all KSI families and their subdirectories
create_ksi_family "KSI-CNA" "$KSI_CNA"
create_ksi_family "KSI-SC" "$KSI_SC"
create_ksi_family "KSI-IAM" "$KSI_IAM"
create_ksi_family "KSI-MLA" "$KSI_MLA"
create_ksi_family "KSI-CM" "$KSI_CM"
create_ksi_family "KSI-PI" "$KSI_PI"
create_ksi_family "KSI-3IR" "$KSI_3IR"
create_ksi_family "KSI-CE" "$KSI_CE"
create_ksi_family "KSI-IR" "$KSI_IR"

echo "KSI directory structure with placeholders created."