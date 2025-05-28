##############################################################################
# INSTRUCTIONS
#
# 1. Save this script in the parent directory (where the "Evidence" folder is located)
#
# 2. Make it executable:
# chmod +x run_evidence_validations.sh
#
# 3. Run it in different ways:
# Interactive mode
# ./run_evidence_validations.sh
#
# Run all validations
# ./run_evidence_validations.sh --all
#
# Run a specific family
# ./run_evidence_validations.sh --family KSI-CNA
#
# Run specific KSI validations
# ./run_evidence_validations.sh --ksi KSI-CNA-1
#
# Run multiple specific KSI validations
# ./run_evidence_validations.sh --ksi KSI-CNA-1,KSI-IAM-3,KSI-SC-2
#
##############################################################################

#!/bin/bash

# Main script to run KSI validation scripts
# This script can run all validations, a specific family, or specific KSI validations

# Colors for better output readability
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Define the KSI structure
KSI_FAMILIES=(
    "KSI-CNA"
    "KSI-SC"
    "KSI-IAM"
    "KSI-MLA"
    "KSI-CM"
    "KSI-PI"
    "KSI-3IR"
    "KSI-CE"
    "KSI-IR"
)

# Logging
LOG_DIR="logs"
mkdir -p "$LOG_DIR"
RUN_TIMESTAMP=$(date '+%Y-%m-%d_%H-%M-%S')
ERROR_LOG="$LOG_DIR/validation_errors_$RUN_TIMESTAMP.log"
JSON_LOG="$LOG_DIR/validation_errors_$RUN_TIMESTAMP.json"
CSV_LOG="$LOG_DIR/validation_errors_$RUN_TIMESTAMP.csv"
FAILED_VALIDATIONS=()

# Function to append KSI validation script error to central log
log_validation_error() {
    local ksi_id="$1"
    local exit_code="$2"
    local output="$3"
    local timestamp=$(date '+%Y-%m-%dT%H:%M:%S')

    # Strip color codes
    clean_output=$(echo "$output" | sed -r "s/\x1B\[[0-9;]*[mK]//g")

    # Write machine-friendly log block
    {
        echo "KSI_ID: $ksi_id"
        echo "TIMESTAMP: $timestamp"
        echo "EXIT_CODE: $exit_code"
        echo "OUTPUT_START"
        echo "$clean_output"
        echo "OUTPUT_END"
        echo "---"
    } >> "$ERROR_LOG"

    # Also append for summary export
    FAILED_VALIDATIONS+=("$ksi_id|$timestamp|$exit_code")
}


# Function to display help message
show_help() {
    printf "${BLUE}KSI Validation Runner${NC}\n"
    printf "Usage: $0 [options]\n"
    printf "\n"
    printf "Options:\n"
    printf "  -h, --help             Show this help message\n"
    printf "  -a, --all              Run all validation scripts\n"
    printf "  -f, --family FAMILY    Run all validations for a specific family\n"
    printf "                         (e.g., KSI-CNA, KSI-SC, etc.)\n"
    printf "  -k, --ksi KSI-ID       Run a specific KSI validation\n"
    printf "                         (e.g., KSI-CNA-1, KSI-IAM-3, etc.)\n"
    printf "                         Multiple IDs can be specified with comma separation\n"
    printf "\n"
    printf "If no options are provided, the script will run in interactive mode.\n"
}

# Function to run a specific KSI validation script
run_ksi_validation() {
    local ksi_id=$1

    # Extract family from KSI ID (e.g., KSI-CNA-1 -> KSI-CNA)
    local family=$(echo "$ksi_id" | cut -d'-' -f1,2)
    local script_path="Evidence/$family/$ksi_id/$ksi_id.sh"

    if [ ! -f "$script_path" ]; then
        printf "✖ ${RED}Error: Validation script for $ksi_id not found at $script_path${NC}\n"
        return 1
    fi

    printf "▶ ${YELLOW}Running validation for $ksi_id...${NC}\n"

    # Run script and capture output and exit code
    output=$(bash "$script_path" 2>&1)
    exit_code=$?

    # Print script output unless empty
    if [ -n "$output" ]; then
        echo "$output" | sed '${/^$/d;}'
    fi

    if [ $exit_code -eq 0 ]; then
        printf "✔ ${GREEN}Validation for $ksi_id completed successfully.${NC}\n\n"
    else
        printf "✖ ${RED}Validation for $ksi_id FAILED (exit code $exit_code).${NC}\n\n"
        log_validation_error "$ksi_id" "$exit_code" "$output"
    fi

    return $exit_code
}

# Function to run all validations for a specific family
run_family_validations() {
    local family=$1
    local family_dir="Evidence/$family"
    
    if [ ! -d "$family_dir" ]; then
        printf "${RED}Error: Family directory $family_dir not found${NC}\n"
        return 1
    fi
    
    printf "${BLUE}Running all validations for $family family...${NC}\n"
    
    # Loop through all subdirectories in the family directory
    for ksi_dir in "$family_dir"/*; do
        if [ -d "$ksi_dir" ]; then
            local ksi_id=$(basename "$ksi_dir")
            run_ksi_validation "$ksi_id"
        fi
    done
    
    printf "${GREEN}All validations for $family family completed.${NC}\n"
    printf "\n"
}

# Function to run all validations
run_all_validations() {
    printf "${BLUE}Running all KSI validations...${NC}"
    
    for family in "${KSI_FAMILIES[@]}"; do
        run_family_validations "$family"
    done
    
    printf "${GREEN}All KSI validations completed.${NC}"
}

# Function to prompt for interactive mode
run_interactive() {
    printf "${BLUE}KSI Validation Runner - Interactive Mode${NC}"
    echo ""
    echo "Please select an option:"
    echo "1) Run all validations"
    echo "2) Run validations for a specific family"
    echo "3) Run a specific KSI validation"
    echo "h) Show help information"
    echo "q) Quit"
    echo ""
    read -p "Enter your choice (1, 2, 3, h, q): " choice
    
    case $choice in
        1)
            run_all_validations
            ;;
        2)
            echo ""
            echo "Available families:"
            for i in "${!KSI_FAMILIES[@]}"; do
                echo "$((i+1))) ${KSI_FAMILIES[$i]}"
            done
            echo ""
            read -p "Enter family number (1-${#KSI_FAMILIES[@]}): " family_num
            
            if [[ "$family_num" =~ ^[0-9]+$ ]] && [ "$family_num" -ge 1 ] && [ "$family_num" -le "${#KSI_FAMILIES[@]}" ]; then
                run_family_validations "${KSI_FAMILIES[$((family_num-1))]}"
            else
                printf "${RED}Invalid selection${NC}"
            fi
            ;;
        3)
            echo ""
            read -p "Enter KSI ID (e.g., KSI-CNA-1, KSI-IAM-3): " ksi_id
            
            if [[ "$ksi_id" =~ ^KSI-[A-Z0-9]+-[0-9]+$ ]]; then
                run_ksi_validation "$ksi_id"
            else
                printf "${RED}Invalid KSI ID format. Should be like KSI-CNA-1, KSI-IAM-3, etc.${NC}"
            fi
            ;;
        h|H)
            show_help
            ;;
        q|Q)
            echo "Exiting."
            exit 0
            ;;
        *)
            printf "${RED}Invalid choice${NC}"
            ;;
    esac
}

# Parse command line arguments
if [ $# -eq 0 ]; then
    # No arguments provided, run in interactive mode
    run_interactive
else
    # Parse arguments
    while [ "$1" != "" ]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            -a|--all)
                run_all_validations
                exit 0
                ;;
            -f|--family)
                shift
                if [ -n "$1" ]; then
                    run_family_validations "$1"
                else
                    printf "${RED}Error: Family name not specified${NC}"
                    show_help
                    exit 1
                fi
                exit 0
                ;;
            -k|--ksi)
                shift
                if [ -n "$1" ]; then
                    # Split comma-separated list of KSI IDs
                    IFS=',' read -ra KSI_IDS <<< "$1"
                    for ksi_id in "${KSI_IDS[@]}"; do
                        run_ksi_validation "$ksi_id"
                    done
                else
                    printf "${RED}Error: KSI ID not specified${NC}"
                    show_help
                    exit 1
                fi
                exit 0
                ;;
            *)
                printf "${RED}Unknown option: $1${NC}"
                show_help
                exit 1
                ;;
        esac
        shift
    done
fi

# Function to export array of failed validations to log (as JSON and CSV) 
export_failure_logs() {
    if [ ${#FAILED_VALIDATIONS[@]} -eq 0 ]; then
        echo "\n${GREEN}All validations completed successfully.${NC}\n"
        return
    fi

    echo "\n${RED}Some validations failed. See detailed log: $ERROR_LOG${NC}"

    echo "ksi_id,timestamp,exit_code" > "$CSV_LOG"
    echo "[" > "$JSON_LOG"
    local first=true

    for entry in "${FAILED_VALIDATIONS[@]}"; do
        IFS='|' read -r id timestamp code <<< "$entry"

        echo "$id,$timestamp,$code" >> "$CSV_LOG"

        if [ "$first" = true ]; then
            first=false
        else
            echo "," >> "$JSON_LOG"
        fi

        echo "  {\"ksi_id\": \"$id\", \"timestamp\": \"$timestamp\", \"exit_code\": $code}" >> "$JSON_LOG"
    done

    echo "]" >> "$JSON_LOG"

    echo "\n${BLUE}Error summary exported to:${NC}"
    echo " - CSV log:  file:/$PWD/$CSV_LOG"
    echo " - JSON log: file:/$PWD/$JSON_LOG"
    echo "\n"
}

export_failure_logs

exit 0