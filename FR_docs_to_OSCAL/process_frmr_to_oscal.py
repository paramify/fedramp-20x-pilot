#!/usr/bin/env python3
"""
Process FedRAMP Machine Readable (FRMR) documentation and generate OSCAL catalogs, profiles, and CSV files.
"""

import json
import csv
import os
import re
import requests
import uuid
from datetime import datetime
from typing import Dict, List, Any, Optional, Tuple
from collections import defaultdict

# Constants
FRMR_REPO_BASE = "https://raw.githubusercontent.com/FedRAMP/docs/refs/heads/main/data"
FRMR_API_BASE = "https://api.github.com/repos/FedRAMP/docs/contents/data"
OUTPUT_BASE_DIR = "OSCAL"

# Group title mappings for KSI themes
KSI_GROUP_TITLES = {
    "CNA": "Cloud Native Architecture",
    "SVC": "Service Configuration",
    "IAM": "Identity and Access Management",
    "MLA": "Monitoring, Logging, and Auditing",
    "CMT": "Change Management",
    "PIY": "Policy and Inventory",
    "TPR": "Third-Party Information Resources",
    "CED": "Cybersecurity Education",
    "RPL": "Recovery Planning",
    "INR": "Incident Response",
    "AFR": "Authorization by FedRAMP",
}


def fetch_frmr_file_list() -> List[str]:
    """Fetch list of all FRMR JSON files from GitHub."""
    try:
        response = requests.get(FRMR_API_BASE)
        response.raise_for_status()
        files = response.json()
        return [f["name"] for f in files if f["name"].endswith(".json") and f["name"].startswith("FRMR.")]
    except Exception as e:
        print(f"Error fetching file list: {e}")
        return []


def fetch_frmr_file(filename: str) -> Optional[Dict[str, Any]]:
    """Fetch and parse a single FRMR JSON file."""
    url = f"{FRMR_REPO_BASE}/{filename}"
    try:
        response = requests.get(url)
        response.raise_for_status()
        return response.json()
    except Exception as e:
        print(f"Error fetching {filename}: {e}")
        return None


def extract_version_from_frmr(data: Dict[str, Any]) -> Optional[str]:
    """Extract version from FRMR JSON file."""
    if "info" in data and "releases" in data["info"]:
        releases = data["info"]["releases"]
        if releases and len(releases) > 0:
            # Try to get the most recent published release
            published_releases = [r for r in releases if r.get("published_date")]
            if published_releases:
                latest = max(published_releases, key=lambda x: x.get("published_date", ""))
                return latest.get("id")
            # Fallback to first release ID
            return releases[0].get("id")
    return None


def normalize_control_id(ksi_id: str) -> str:
    """Convert KSI ID (e.g., 'KSI-CNA-01') to control ID (e.g., 'cna-01')."""
    # Remove 'KSI-' prefix and convert to lowercase
    if ksi_id.startswith("KSI-"):
        parts = ksi_id[4:].split("-")
        if len(parts) >= 2:
            return f"{parts[0].lower()}-{parts[1]}"
        # Fallback if format is unexpected
        return ksi_id[4:].lower().replace("_", "-")
    return ksi_id.lower().replace("ksi-", "").replace("_", "-")


def normalize_frr_control_id(frr_id: str, standard: str) -> str:
    """Convert FRR ID (e.g., 'FRR-ADS-01' or 'FRR-SCN-TR-01') to control ID (e.g., 'ads-01' or 'scn-TR-01')."""
    # Remove 'FRR-' prefix and convert to lowercase
    if frr_id.startswith("FRR-"):
        parts = frr_id[4:].split("-")
        if len(parts) >= 2:
            # Join all parts after the first one (standard) to preserve full ID
            # e.g., ["SCN", "TR", "01"] -> "scn-TR-01"
            return f"{parts[0].lower()}-{'-'.join(parts[1:])}"
        # Fallback if format is unexpected
        return f"{standard.lower()}-{frr_id.split('-')[-1]}"
    # Fallback: use standard abbreviation
    return f"{standard.lower()}-{frr_id.split('-')[-1]}"


def clean_prose(text: str) -> str:
    """Clean prose text by removing quotes and underscores around words."""
    if not text:
        return text
    
    # Remove opening and closing quotation marks
    text = text.strip()
    if text.startswith('"') and text.endswith('"'):
        text = text[1:-1]
    if text.startswith("'") and text.endswith("'"):
        text = text[1:-1]
    
    # Remove underscores from around words/phrases
    # Pattern: _word_ or _phrase_ where word/phrase contains letters, numbers, and spaces
    # This handles cases like "_cloud service offering_" -> "cloud service offering"
    # First, handle wrapped underscores: _word_ or _phrase_
    text = re.sub(r'_([A-Za-z0-9][A-Za-z0-9\s]*[A-Za-z0-9])_', r'\1', text)
    
    # Then handle leading underscore: _word (at word boundary)
    text = re.sub(r'\b_([A-Za-z0-9][A-Za-z0-9\s]*[A-Za-z0-9])\b', r'\1', text)
    
    # Then handle trailing underscore: word_ (at word boundary)
    text = re.sub(r'\b([A-Za-z0-9][A-Za-z0-9\s]*[A-Za-z0-9])_\b', r'\1', text)
    
    return text


def generate_title(name: str, control_id: str) -> str:
    """
    Generate a title from name field, or use control ID as fallback.
    
    If name is available and not empty, uses cleaned name.
    Otherwise, uses the control ID.
    """
    if name and name.strip():
        cleaned_name = clean_prose(name.strip())
        if cleaned_name:
            return cleaned_name
    
    # Fallback to control ID, formatted nicely (e.g., "scn-TR-01" -> "SCN-TR-01")
    return control_id.upper()


def parse_ksi_indicators(data: Dict[str, Any]) -> Tuple[List[Dict[str, Any]], Dict[str, str], Dict[str, List[str]]]:
    """Parse KSI sections and extract indicators."""
    controls = []
    control_impacts = {}  # control_id -> impact dict
    control_following_info = {}  # control_id -> following_information list
    
    if "KSI" not in data:
        return controls, control_impacts
    
    ksi_data = data["KSI"]
    
    for section_key, section_data in ksi_data.items():
        if not isinstance(section_data, dict) or "indicators" not in section_data:
            continue
        
        # Determine group ID and title
        group_id = section_key
        # Try to get title from name field first, then fallback to theme or hardcoded mapping
        group_title = (
            section_data.get("name") or 
            section_data.get("theme") or 
            KSI_GROUP_TITLES.get(group_id, group_id)
        )
        
        indicators = section_data.get("indicators", [])
        
        for indicator in indicators:
            if not isinstance(indicator, dict):
                continue
            
            indicator_id = indicator.get("id", "")
            if not indicator_id or not indicator_id.startswith("KSI-"):
                continue
            
            # Skip retired indicators
            if indicator.get("retired", False):
                continue
            
            # Extract control ID
            control_id = normalize_control_id(indicator_id)
            statement = indicator.get("statement", "")
            
            if not statement:
                continue
            
            # Clean the statement
            cleaned_statement = clean_prose(statement)
            
            # Get title from name field, or use control ID as fallback
            control_title = generate_title(indicator.get("name", ""), control_id)
            
            # Get impact levels (default to all false if not present)
            impact = indicator.get("impact", {})
            # Ensure impact has the required structure
            if not isinstance(impact, dict):
                impact = {}
            if "low" not in impact:
                impact["low"] = False
            if "moderate" not in impact:
                impact["moderate"] = False
            if "high" not in impact:
                impact["high"] = False
            
            control_impacts[control_id] = impact
            
            # Get following_information if present
            following_info = indicator.get("following_information", [])
            if following_info:
                control_following_info[control_id] = following_info
            
            # Build parts array
            parts = [
                {
                    "id": f"{control_id}_smt",
                    "name": "statement",
                    "prose": cleaned_statement
                }
            ]
            
            # Add following_information as additional parts if present
            if following_info:
                for idx, info_item in enumerate(following_info, 1):
                    cleaned_info = clean_prose(info_item)
                    parts.append({
                        "id": f"{control_id}_smt.item.{idx}",
                        "name": "item",
                        "prose": cleaned_info
                    })
            
            # Create control
            control = {
                "id": control_id,
                "title": control_title,
                "parts": parts
            }
            
            controls.append({
                "group_id": group_id,
                "group_title": group_title,
                "control": control
            })
    
    return controls, control_impacts, control_following_info


def parse_frr_requirements(data: Dict[str, Any], filename: str) -> Tuple[List[Dict[str, Any]], Dict[str, str], Dict[str, List[str]]]:
    """Parse FRR sections and extract requirements."""
    controls = []
    control_impacts = {}  # control_id -> impact dict
    control_following_info = {}  # control_id -> following_information list
    
    if "FRR" not in data:
        return controls, control_impacts
    
    # Extract standard abbreviation from filename (e.g., "FRMR.ADS.*.json" -> "ADS")
    standard_match = re.search(r'FRMR\.([A-Z]{3})\.', filename)
    if not standard_match:
        return controls, control_impacts
    
    standard = standard_match.group(1)
    group_id = standard
    # Try to get title from info.name, otherwise use standard abbreviation
    info = data.get("info", {})
    group_title = info.get("name", standard)
    
    frr_data = data["FRR"]
    
    # FRR structure: {"FRR": {"ADS": {"base": {...}, "impact": {...}, ...}}}
    # Get the standard's FRR data (e.g., frr_data["ADS"])
    standard_frr = frr_data.get(standard)
    if not standard_frr or not isinstance(standard_frr, dict):
        return controls, control_impacts
    
    # Process each FRR section within the standard (base, impact, exceptions, etc.)
    # Track seen requirement IDs to avoid duplicates
    seen_req_ids = set()
    
    for section_key, section_data in standard_frr.items():
        if not isinstance(section_data, dict) or "requirements" not in section_data:
            continue
        
        requirements = section_data.get("requirements", [])
        
        for req in requirements:
            if not isinstance(req, dict):
                continue
            
            req_id = req.get("id", "")
            if not req_id or not req_id.startswith("FRR-"):
                continue
            
            # Skip if we've already processed this requirement
            if req_id in seen_req_ids:
                continue
            seen_req_ids.add(req_id)
            
            statement = req.get("statement", "")
            if not statement:
                continue
            
            # Extract control ID (needed for title fallback)
            control_id = normalize_frr_control_id(req_id, standard)
            
            # Clean the statement
            cleaned_statement = clean_prose(statement)
            
            # Get title from name field, or use control ID as fallback
            control_title = generate_title(req.get("name", ""), control_id)
            
            # Get impact levels (default to all false if not present)
            impact = req.get("impact", {})
            # Ensure impact has the required structure
            if not isinstance(impact, dict):
                impact = {}
            if "low" not in impact:
                impact["low"] = False
            if "moderate" not in impact:
                impact["moderate"] = False
            if "high" not in impact:
                impact["high"] = False
            
            control_impacts[control_id] = impact
            
            # Get following_information if present
            following_info = req.get("following_information", [])
            if following_info:
                control_following_info[control_id] = following_info
            
            # Build parts array
            parts = [
                {
                    "id": f"{control_id}_smt",
                    "name": "statement",
                    "prose": cleaned_statement
                }
            ]
            
            # Add following_information as additional parts if present
            if following_info:
                for idx, info_item in enumerate(following_info, 1):
                    cleaned_info = clean_prose(info_item)
                    parts.append({
                        "id": f"{control_id}_smt.item.{idx}",
                        "name": "item",
                        "prose": cleaned_info
                    })
            
            # Create control
            control = {
                "id": control_id,
                "title": control_title,
                "parts": parts
            }
            
            controls.append({
                "group_id": group_id,
                "group_title": group_title,
                "control": control
            })
    
    return controls, control_impacts, control_following_info


def build_oscal_catalog(all_controls: List[Dict[str, Any]], version: str) -> Dict[str, Any]:
    """Build OSCAL catalog from all controls."""
    # Group controls by group_id
    groups_dict = defaultdict(lambda: {"id": "", "title": "", "controls": []})
    
    for item in all_controls:
        group_id = item["group_id"]
        group_title = item["group_title"]
        control = item["control"]
        
        groups_dict[group_id]["id"] = group_id
        groups_dict[group_id]["title"] = group_title
        groups_dict[group_id]["controls"].append(control)
    
    # Convert to list and sort by group ID
    groups = [groups_dict[gid] for gid in sorted(groups_dict.keys())]
    
    # Generate catalog UUID (deterministic based on version)
    catalog_uuid = str(uuid.uuid5(uuid.NAMESPACE_DNS, f"fedramp-20x-catalog-{version}"))
    
    now = datetime.now().strftime("%Y-%m-%dT%H:%M:%S.000000-04:00")
    
    catalog = {
        "catalog": {
            "uuid": catalog_uuid,
            "metadata": {
                "title": f"FedRAMP 20x Phase Two Catalog (v{version})",
                "published": now,
                "last-modified": now,
                "version": version,
                "oscal-version": "1.1.2"
            },
            "groups": groups
        }
    }
    
    return catalog, catalog_uuid


def build_oscal_profile(impact_level: str, control_ids: List[str], catalog_uuid: str, version: str) -> Dict[str, Any]:
    """Build OSCAL profile for a specific impact level."""
    profile_uuid = str(uuid.uuid5(uuid.NAMESPACE_DNS, f"fedramp-20x-{impact_level}-profile-{version}"))
    now = datetime.now().strftime("%Y-%m-%dT%H:%M:%S.000000-04:00")
    
    impact_title = impact_level.capitalize()
    
    profile = {
        "profile": {
            "uuid": profile_uuid,
            "metadata": {
                "title": f"FedRAMP 20x Phase Two {impact_title} Impact Profile",
                "published": now,
                "last-modified": now,
                "version": version,
                "oscal-version": "1.1.2"
            },
            "imports": [
                {
                    "href": f"#{catalog_uuid}",
                    "include-controls": [
                        {
                            "with-ids": sorted(control_ids)
                        }
                    ]
                }
            ]
        }
    }
    
    return profile


def generate_csv(all_controls: List[Dict[str, Any]], control_following_info: Dict[str, List[str]], output_path: str):
    """Generate Requirements_Paramified.csv file."""
    with open(output_path, 'w', newline='', encoding='utf-8') as csvfile:
        # Configure writer to quote all fields consistently
        writer = csv.writer(csvfile, quoting=csv.QUOTE_ALL)
        writer.writerow(["Control Part", "OSCAL_ID", "ParamifiedProse"])
        
        for item in all_controls:
            control = item["control"]
            control_id = control["id"]
            group_id = item["group_id"]
            
            # Use the full control ID sequence (e.g., "ads-ac-01" -> "ADS-AC-01")
            control_part = control_id.upper()
            oscal_id = f"{control_id}_smt"
            
            # Get the statement prose (from the first part)
            statement_prose = ""
            if control.get("parts") and len(control["parts"]) > 0:
                statement_prose = control["parts"][0].get("prose", "")
            
            # Start with the statement prose
            prose = statement_prose
            
            # Add following_information if present
            if control_id in control_following_info:
                following_info = control_following_info[control_id]
                if following_info:
                    # Format as bullet list with HTML dot (•)
                    # Add a newline before the list if prose doesn't end with one
                    if prose and not prose.rstrip().endswith(('\n', ':')):
                        prose += "\n"
                    elif prose and prose.rstrip().endswith(':'):
                        # If it ends with colon, add a newline after it
                        prose = prose.rstrip() + "\n"
                    
                    # Add bullet points
                    info_items = [f"• {clean_prose(item)}" for item in following_info]
                    prose += "\n".join(info_items)
            
            writer.writerow([control_part, oscal_id, prose])


def main():
    """Main processing function."""
    print("Fetching FRMR file list...")
    frmr_files = fetch_frmr_file_list()
    print(f"Found {len(frmr_files)} FRMR files")
    
    all_controls = []
    all_control_impacts = {}
    all_control_following_info = {}  # control_id -> following_information list
    versions = []
    
    # Process each FRMR file
    for filename in frmr_files:
        print(f"Processing {filename}...")
        data = fetch_frmr_file(filename)
        if not data:
            continue
        
        # Extract version
        version = extract_version_from_frmr(data)
        if version:
            versions.append(version)
        
        # Process KSI files
        if filename.startswith("FRMR.KSI."):
            controls, impacts, following_info = parse_ksi_indicators(data)
            all_controls.extend(controls)
            all_control_impacts.update(impacts)
            all_control_following_info.update(following_info)
            print(f"  Found {len(controls)} KSI controls")
        
        # Process standards files with FRR sections
        elif "FRR" in data:
            controls, impacts, following_info = parse_frr_requirements(data, filename)
            all_controls.extend(controls)
            all_control_impacts.update(impacts)
            all_control_following_info.update(following_info)
            print(f"  Found {len(controls)} FRR controls")
    
    if not all_controls:
        print("No controls found. Exiting.")
        return
    
    # Determine version (use most recent or default)
    if versions:
        # Sort versions and use the latest
        version = max(versions)
    else:
        version = datetime.now().strftime("%Y-%m-%d")
    
    print(f"\nUsing version: {version}")
    print(f"Total controls: {len(all_controls)}")
    
    # Build OSCAL catalog
    print("\nBuilding OSCAL catalog...")
    catalog, catalog_uuid = build_oscal_catalog(all_controls, version)
    
    # Build profiles by impact level
    print("Building OSCAL profiles...")
    impact_controls = {
        "low": [],
        "moderate": [],
        "high": []
    }
    
    for item in all_controls:
        control_id = item["control"]["id"]
        impact = all_control_impacts.get(control_id, {})
        
        if impact.get("low", False):
            impact_controls["low"].append(control_id)
        if impact.get("moderate", False):
            impact_controls["moderate"].append(control_id)
        if impact.get("high", False):
            impact_controls["high"].append(control_id)
    
    profiles = {}
    for impact_level in ["low", "moderate", "high"]:
        control_ids = impact_controls[impact_level]
        profiles[impact_level] = build_oscal_profile(impact_level, control_ids, catalog_uuid, version)
        print(f"  {impact_level.capitalize()} profile: {len(control_ids)} controls")
    
    # Create output directory
    output_dir = os.path.join(OUTPUT_BASE_DIR, f"v{version}")
    os.makedirs(output_dir, exist_ok=True)
    print(f"\nWriting files to {output_dir}/...")
    
    # Write catalog
    catalog_path = os.path.join(output_dir, "catalog.json")
    with open(catalog_path, 'w', encoding='utf-8') as f:
        json.dump(catalog, f, indent=2, ensure_ascii=False)
    print(f"  Written: {catalog_path}")
    
    # Write profiles
    for impact_level, profile in profiles.items():
        profile_path = os.path.join(output_dir, f"20x_{impact_level}_profile.json")
        with open(profile_path, 'w', encoding='utf-8') as f:
            json.dump(profile, f, indent=2, ensure_ascii=False)
        print(f"  Written: {profile_path}")
    
    # Write CSV
    csv_path = os.path.join(output_dir, "Requirements_Paramified.csv")
    generate_csv(all_controls, all_control_following_info, csv_path)
    print(f"  Written: {csv_path}")
    
    print("\nProcessing complete!")


if __name__ == "__main__":
    main()

