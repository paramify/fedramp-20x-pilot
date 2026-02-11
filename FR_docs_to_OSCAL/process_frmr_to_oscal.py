#!/usr/bin/env python3
"""
Process FedRAMP Machine Readable (FRMR) documentation and generate OSCAL catalogs, profiles, and CSV files.

Updated for v0.9.0-beta consolidated FRMR.documentation.json format.
Supports both legacy multi-file format (v0.4.0-alpha) and new single-file format (v0.9.0-beta+).
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
FRMR_REPO_BASE = "https://raw.githubusercontent.com/FedRAMP/docs/refs/heads/main"
FRMR_API_BASE = "https://api.github.com/repos/FedRAMP/docs/contents"
FRMR_CONSOLIDATED_FILE = "FRMR.documentation.json"
OUTPUT_BASE_DIR = "OSCAL"

# Group title mappings for KSI themes (fallback only)
KSI_GROUP_TITLES = {
    "CNA": "Cloud Native Architecture",
    "SVC": "Service Configuration",
    "IAM": "Identity and Access Management",
    "MLA": "Monitoring, Logging, and Auditing",
    "CMT": "Change Management",
    "PIY": "Policy and Inventory",
    "SCR": "Supply Chain Risk",
    "CED": "Cybersecurity Education",
    "RPL": "Recovery Planning",
    "INR": "Incident Response",
    "AFR": "Authorization by FedRAMP",
    # Legacy mapping
    "TPR": "Third-Party Information Resources",
}


def detect_format_version(data: Dict[str, Any]) -> str:
    """Detect whether the data is v0.9.0-beta+ (consolidated) or legacy (multi-file) format.
    
    Returns 'consolidated' or 'legacy'.
    """
    info = data.get("info", {})
    # v0.9.0-beta has info.version as a string directly
    if "version" in info and isinstance(info["version"], str):
        return "consolidated"
    # Legacy format has info.releases as a list
    if "releases" in info and isinstance(info["releases"], list):
        return "legacy"
    # If we have top-level FRD, KSI, FRR keys alongside info, it's consolidated
    if any(key in data for key in ["FRD", "KSI"]):
        top_level_keys = set(data.keys())
        if top_level_keys.intersection({"FRD", "KSI", "FRR"}):
            return "consolidated"
    return "legacy"


def fetch_frmr_file_list() -> List[str]:
    """Fetch list of FRMR JSON files from GitHub.
    
    First tries to detect the consolidated format (v0.9.0-beta+).
    Falls back to legacy multi-file format if consolidated file is not found.
    """
    # First, try to fetch the consolidated file directly
    url = f"{FRMR_REPO_BASE}/{FRMR_CONSOLIDATED_FILE}"
    try:
        response = requests.head(url, allow_redirects=True, timeout=10)
        if response.status_code == 200:
            print(f"  Detected consolidated format ({FRMR_CONSOLIDATED_FILE})")
            return [FRMR_CONSOLIDATED_FILE]
    except Exception:
        pass

    # Fallback: try legacy multi-file format
    print("  Consolidated file not found, trying legacy multi-file format...")
    try:
        response = requests.get(FRMR_API_BASE, timeout=30)
        response.raise_for_status()
        files = response.json()
        frmr_files = [
            f["name"] for f in files
            if f.get("type") == "file"
            and f["name"].endswith(".json")
            and f["name"].startswith("FRMR.")
        ]
        if frmr_files:
            print(f"  Detected legacy multi-file format ({len(frmr_files)} files)")
            return frmr_files
    except Exception as e:
        print(f"Error fetching file list: {e}")

    return []


def fetch_frmr_file(filename: str) -> Optional[Dict[str, Any]]:
    """Fetch and parse a single FRMR JSON file."""
    url = f"{FRMR_REPO_BASE}/{filename}"
    try:
        response = requests.get(url, timeout=60)
        response.raise_for_status()
        return response.json()
    except Exception as e:
        print(f"Error fetching {filename}: {e}")
        return None


def extract_version_from_frmr(data: Dict[str, Any]) -> Optional[str]:
    """Extract version from FRMR JSON file. Supports both consolidated and legacy formats."""
    if not isinstance(data, dict) or "info" not in data:
        return None

    info = data["info"]

    # Consolidated format (v0.9.0-beta+): info.version is a string
    if "version" in info and isinstance(info["version"], str):
        return info["version"]

    # Legacy format: info.releases is a list of release objects
    if "releases" in info:
        releases = info["releases"]
        if releases and len(releases) > 0:
            published_releases = [r for r in releases if r.get("published_date")]
            if published_releases:
                latest = max(published_releases, key=lambda x: x.get("published_date", ""))
                return latest.get("id")
            return releases[0].get("id")

    return None


def normalize_control_id(raw_id: str, prefix: str = "KSI-") -> str:
    """Convert a KSI or FRR ID to an OSCAL control ID.
    
    Handles both old numeric formats and new descriptive formats:
    - 'KSI-CNA-01' -> 'cna-01'
    - 'KSI-CNA-RNT' -> 'cna-rnt'
    - 'KSI-SCR-MIT' -> 'scr-mit'
    - 'KSI-RSC-MON' -> 'rsc-mon'  (note: cross-theme indicator)
    """
    if raw_id.startswith(prefix):
        remainder = raw_id[len(prefix):]
    else:
        remainder = raw_id

    parts = remainder.split("-")
    if len(parts) >= 2:
        # Join all parts with dash, lowercased
        return "-".join(p.lower() for p in parts)

    # Fallback
    return remainder.lower().replace("_", "-")


def normalize_frr_control_id(frr_id: str, standard: str) -> str:
    """Convert FRR ID to control ID.
    
    Handles both old and new formats:
    - 'FRR-ADS-01' -> 'ads-01'
    - 'FRR-ADS-PBI' -> 'ads-pbi'
    - 'FRR-SCN-TR-01' -> 'scn-tr-01'
    """
    if frr_id.startswith("FRR-"):
        remainder = frr_id[4:]
    else:
        remainder = frr_id

    parts = remainder.split("-")
    if len(parts) >= 2:
        return "-".join(p.lower() for p in parts)

    return f"{standard.lower()}-{frr_id.split('-')[-1].lower()}"


def clean_prose(text: str) -> str:
    """Clean prose text by removing quotes, underscores, and markdown bold markers."""
    if not text:
        return text

    text = text.strip()

    # Remove opening and closing quotation marks
    if text.startswith('"') and text.endswith('"'):
        text = text[1:-1]
    if text.startswith("'") and text.endswith("'"):
        text = text[1:-1]

    # Remove markdown bold markers **text**
    text = re.sub(r'\*\*(.+?)\*\*', r'\1', text)

    # Remove underscores from around words/phrases
    text = re.sub(r'_([A-Za-z0-9][A-Za-z0-9\s]*[A-Za-z0-9])_', r'\1', text)
    text = re.sub(r'\b_([A-Za-z0-9][A-Za-z0-9\s]*[A-Za-z0-9])\b', r'\1', text)
    text = re.sub(r'\b([A-Za-z0-9][A-Za-z0-9\s]*[A-Za-z0-9])_\b', r'\1', text)

    return text


def generate_title(name: str, control_id: str) -> str:
    """Generate a title from name field, or use control ID as fallback."""
    if name and name.strip():
        cleaned_name = clean_prose(name.strip())
        if cleaned_name:
            return cleaned_name
    return control_id.upper()


# ---------------------------------------------------------------------------
# Consolidated format (v0.9.0-beta+) parsers
# ---------------------------------------------------------------------------

def get_indicator_statement(indicator: Dict[str, Any], level: str = "moderate") -> str:
    """Extract the statement for a given indicator, handling varies_by_level.
    
    For the catalog we pick the most inclusive statement.
    Priority: explicit 'statement' field > varies_by_level[level] > first available level.
    """
    # Direct statement field (most indicators)
    statement = indicator.get("statement", "")
    if statement:
        return statement

    # varies_by_level structure
    varies = indicator.get("varies_by_level")
    if varies and isinstance(varies, dict):
        # Try requested level first
        if level in varies:
            level_data = varies[level]
            if isinstance(level_data, dict):
                return level_data.get("statement", "")
            elif isinstance(level_data, str):
                return level_data
        # Fallback to moderate > low > high
        for fallback in ["moderate", "low", "high"]:
            if fallback in varies:
                level_data = varies[fallback]
                if isinstance(level_data, dict):
                    stmt = level_data.get("statement", "")
                elif isinstance(level_data, str):
                    stmt = level_data
                else:
                    stmt = ""
                if stmt:
                    return stmt

    return ""


def extract_impact_from_indicator(indicator: Dict[str, Any]) -> Dict[str, bool]:
    """Determine which impact levels an indicator applies to.
    
    In v0.9.0-beta:
    - If 'varies_by_level' exists, the indicator applies to levels present as keys.
    - If a level's statement contains '**Optional:**', that level is excluded (not included in profile).
    - If only 'statement' exists (no varies_by_level), it applies to all levels.
    - Old format: explicit 'impact' dict with boolean flags.
    """
    impact = {"low": False, "moderate": False, "high": False}

    # Check for varies_by_level (new format)
    varies = indicator.get("varies_by_level")
    if varies and isinstance(varies, dict):
        for level in ["low", "moderate", "high"]:
            if level in varies:
                level_data = varies[level]
                # Extract statement to check for optional marker
                if isinstance(level_data, dict):
                    stmt = level_data.get("statement", "")
                elif isinstance(level_data, str):
                    stmt = level_data
                else:
                    stmt = ""
                
                # If statement contains "Optional:", exclude from this impact level
                if stmt and ("**Optional:**" in stmt or "Optional:" in stmt):
                    impact[level] = False
                else:
                    impact[level] = True
        return impact

    # If there's a direct statement (no varies_by_level), it applies to all levels
    if indicator.get("statement"):
        impact["low"] = True
        impact["moderate"] = True
        impact["high"] = True
        return impact

    # Legacy format: explicit impact dict
    old_impact = indicator.get("impact", {})
    if isinstance(old_impact, dict):
        impact["low"] = old_impact.get("low", False)
        impact["moderate"] = old_impact.get("moderate", False)
        impact["high"] = old_impact.get("high", False)

    return impact


def parse_ksi_consolidated(data: Dict[str, Any]) -> Tuple[List[Dict[str, Any]], Dict[str, Dict[str, bool]], Dict[str, List[str]]]:
    """Parse KSI section from consolidated FRMR.documentation.json (v0.9.0-beta+).
    
    Structure:
    {
      "KSI": {
        "info": { ... },
        "data": {
          "CNA": {
            "id": "KSI-CNA",
            "name": "Cloud Native Architecture",
            "short_name": "CNA",
            "theme": "...",
            "indicators": {
              "KSI-CNA-RNT": { "name": "...", "statement": "...", ... },
              "KSI-CNA-MAS": { ... },
              ...
            }
          },
          ...
        }
      }
    }
    """
    controls = []
    control_impacts = {}
    control_following_info = {}

    ksi_section = data.get("KSI", {})

    # The themes live under "data" in v0.9.0-beta
    ksi_data = ksi_section.get("data", ksi_section)

    # Skip metadata keys
    skip_keys = {"info", "data"}

    # If ksi_data itself has a "data" key we already extracted, iterate its children
    # Otherwise iterate ksi_section directly (for formats that don't nest under "data")
    themes = ksi_data if isinstance(ksi_data, dict) else {}

    for theme_key, theme_data in themes.items():
        if theme_key in skip_keys:
            continue
        if not isinstance(theme_data, dict):
            continue

        # Extract theme metadata
        group_id = theme_data.get("short_name") or theme_key
        theme_name = (
            theme_data.get("name")
            or theme_data.get("theme")
            or KSI_GROUP_TITLES.get(group_id, group_id)
        )

        indicators_obj = theme_data.get("indicators", {})
        if not isinstance(indicators_obj, dict):
            continue

        for indicator_id, indicator in indicators_obj.items():
            if not isinstance(indicator, dict):
                continue

            # Skip retired
            if indicator.get("retired", False):
                continue

            # Normalize the control ID
            control_id = normalize_control_id(indicator_id, prefix="KSI-")

            # Get statement (prefer moderate for catalog)
            statement = get_indicator_statement(indicator, level="moderate")
            if not statement:
                continue

            cleaned_statement = clean_prose(statement)
            control_title = generate_title(indicator.get("name", ""), control_id)

            # Impact levels
            impact = extract_impact_from_indicator(indicator)
            control_impacts[control_id] = impact

            # Following information
            following_info = indicator.get("following_information", [])
            if following_info:
                control_following_info[control_id] = following_info

            # Build OSCAL parts
            parts = [
                {
                    "id": f"{control_id}_smt",
                    "name": "statement",
                    "prose": cleaned_statement,
                }
            ]

            if following_info:
                for idx, info_item in enumerate(following_info, 1):
                    parts.append(
                        {
                            "id": f"{control_id}_smt.item.{idx}",
                            "name": "item",
                            "prose": clean_prose(info_item),
                        }
                    )

            control = {
                "id": control_id,
                "title": control_title,
                "parts": parts,
            }

            controls.append(
                {
                    "group_id": group_id,
                    "group_title": theme_name,
                    "control": control,
                }
            )

    return controls, control_impacts, control_following_info


def parse_frr_consolidated(data: Dict[str, Any]) -> Tuple[List[Dict[str, Any]], Dict[str, Dict[str, bool]], Dict[str, List[str]]]:
    """Parse FRR sections from consolidated FRMR.documentation.json (v0.9.0-beta+).
    
    In the consolidated format, each standard (ADS, SCN, VDR, etc.) is a top-level key
    containing its own FRR section. We need to iterate all top-level keys that have
    an 'FRR' sub-section, or look for the FRR data embedded in the standard's 'data' key.
    
    Possible structures:
    1) Top-level keys like "ADS", "SCN", etc. each with their own nested structure
    2) A single "FRR" key containing all standards
    """
    controls = []
    control_impacts = {}
    control_following_info = {}
    seen_req_ids = set()

    # Strategy: iterate all top-level keys in data looking for FRR-containing structures
    for top_key, top_value in data.items():
        if not isinstance(top_value, dict):
            continue
        # Skip known non-FRR sections
        if top_key in ("info", "FRD", "KSI"):
            continue

        # Check if this section has FRR data
        frr_data = None
        section_info = {}

        if top_key == "FRR":
            # Direct FRR key at top level
            frr_data = top_value
            section_info = data.get("info", {})
        elif "FRR" in top_value:
            # Standard with nested FRR (e.g., data["ADS"]["FRR"])
            frr_data = top_value["FRR"]
            section_info = top_value.get("info", {})
        elif "data" in top_value:
            # Standard with data.FRR nesting
            inner = top_value["data"]
            if isinstance(inner, dict) and "FRR" in inner:
                frr_data = inner["FRR"]
                section_info = top_value.get("info", {})

        if not frr_data or not isinstance(frr_data, dict):
            continue

        # Determine the standard abbreviation
        standard = section_info.get("short_name") or top_key
        group_id = standard
        group_title = section_info.get("name") or KSI_GROUP_TITLES.get(standard, standard)

        # Process FRR data which may be organized by sub-sections
        _process_frr_section(
            frr_data, standard, group_id, group_title,
            controls, control_impacts, control_following_info, seen_req_ids,
        )

    return controls, control_impacts, control_following_info


def _process_frr_section(
    frr_data: Dict[str, Any],
    standard: str,
    group_id: str,
    group_title: str,
    controls: List[Dict[str, Any]],
    control_impacts: Dict[str, Dict[str, bool]],
    control_following_info: Dict[str, List[str]],
    seen_req_ids: set,
):
    """Recursively process an FRR section, handling both flat and nested structures."""

    # Check if this level has a "requirements" list directly
    if "requirements" in frr_data and isinstance(frr_data["requirements"], list):
        for req in frr_data["requirements"]:
            _process_single_frr_requirement(
                req, standard, group_id, group_title,
                controls, control_impacts, control_following_info, seen_req_ids,
            )
        return

    # Check if this level has a "data" dict with requirement entries
    data_section = frr_data.get("data", frr_data)
    if not isinstance(data_section, dict):
        return

    for section_key, section_value in data_section.items():
        if section_key in ("info", "data", "front_matter"):
            continue
        if not isinstance(section_value, dict):
            continue

        # Could be a sub-section with its own requirements list
        if "requirements" in section_value and isinstance(section_value["requirements"], list):
            for req in section_value["requirements"]:
                _process_single_frr_requirement(
                    req, standard, group_id, group_title,
                    controls, control_impacts, control_following_info, seen_req_ids,
                )
        # Could be a nested sub-section dict (e.g., "both", "low", "moderate")
        elif isinstance(section_value, dict):
            # Check if entries look like individual requirements (have "statement")
            has_nested_reqs = False
            for inner_key, inner_val in section_value.items():
                if isinstance(inner_val, dict) and ("statement" in inner_val or "requirements" in inner_val):
                    has_nested_reqs = True
                    break

            if has_nested_reqs:
                # Iterate entries that look like requirements or sub-sections
                for inner_key, inner_val in section_value.items():
                    if not isinstance(inner_val, dict):
                        continue
                    if "requirements" in inner_val and isinstance(inner_val["requirements"], list):
                        for req in inner_val["requirements"]:
                            _process_single_frr_requirement(
                                req, standard, group_id, group_title,
                                controls, control_impacts, control_following_info, seen_req_ids,
                            )
                    elif "statement" in inner_val:
                        # This entry IS a requirement keyed by its ID
                        req = dict(inner_val)
                        if "id" not in req:
                            req["id"] = inner_key
                        _process_single_frr_requirement(
                            req, standard, group_id, group_title,
                            controls, control_impacts, control_following_info, seen_req_ids,
                        )


def _process_single_frr_requirement(
    req: Dict[str, Any],
    standard: str,
    group_id: str,
    group_title: str,
    controls: List[Dict[str, Any]],
    control_impacts: Dict[str, Dict[str, bool]],
    control_following_info: Dict[str, List[str]],
    seen_req_ids: set,
):
    """Process a single FRR requirement dict into an OSCAL control."""
    if not isinstance(req, dict):
        return

    req_id = req.get("id", "")
    if not req_id:
        return

    # Determine prefix
    prefix = "FRR-"
    if not req_id.startswith(prefix):
        # Might be a raw key like "FRR-ADS-01" or just "ADS-01"
        prefix = ""

    if req_id in seen_req_ids:
        return
    seen_req_ids.add(req_id)

    # Get statement (handle varies_by_level too)
    statement = req.get("statement", "")
    if not statement:
        varies = req.get("varies_by_level")
        if varies and isinstance(varies, dict):
            for level in ["moderate", "low", "high"]:
                if level in varies:
                    level_data = varies[level]
                    if isinstance(level_data, dict):
                        statement = level_data.get("statement", "")
                    elif isinstance(level_data, str):
                        statement = level_data
                    if statement:
                        break
    if not statement:
        return

    # Control ID
    if req_id.startswith("FRR-"):
        control_id = normalize_frr_control_id(req_id, standard)
    else:
        control_id = normalize_control_id(req_id, prefix="")

    cleaned_statement = clean_prose(statement)
    control_title = generate_title(req.get("name", ""), control_id)

    # Impact (use same logic as KSI indicators to exclude optional)
    impact = extract_impact_from_indicator(req)
    control_impacts[control_id] = impact

    # Following information
    following_info = req.get("following_information", [])
    if following_info:
        control_following_info[control_id] = following_info

    # Build parts
    parts = [
        {
            "id": f"{control_id}_smt",
            "name": "statement",
            "prose": cleaned_statement,
        }
    ]

    if following_info:
        for idx, info_item in enumerate(following_info, 1):
            parts.append(
                {
                    "id": f"{control_id}_smt.item.{idx}",
                    "name": "item",
                    "prose": clean_prose(info_item),
                }
            )

    control = {
        "id": control_id,
        "title": control_title,
        "parts": parts,
    }

    controls.append(
        {
            "group_id": group_id,
            "group_title": group_title,
            "control": control,
        }
    )


# ---------------------------------------------------------------------------
# Legacy format parsers (v0.4.0-alpha multi-file)
# ---------------------------------------------------------------------------

def parse_ksi_indicators_legacy(data: Dict[str, Any]) -> Tuple[List[Dict[str, Any]], Dict[str, Dict[str, bool]], Dict[str, List[str]]]:
    """Parse KSI sections from legacy multi-file format."""
    controls = []
    control_impacts = {}
    control_following_info = {}

    if "KSI" not in data:
        return controls, control_impacts, control_following_info

    ksi_data = data["KSI"]

    for section_key, section_data in ksi_data.items():
        if not isinstance(section_data, dict) or "indicators" not in section_data:
            continue

        group_id = section_key
        group_title = (
            section_data.get("name")
            or section_data.get("theme")
            or KSI_GROUP_TITLES.get(group_id, group_id)
        )

        indicators = section_data.get("indicators", [])

        for indicator in indicators:
            if not isinstance(indicator, dict):
                continue

            indicator_id = indicator.get("id", "")
            if not indicator_id or not indicator_id.startswith("KSI-"):
                continue

            if indicator.get("retired", False):
                continue

            control_id = normalize_control_id(indicator_id, prefix="KSI-")
            statement = indicator.get("statement", "")
            if not statement:
                continue

            cleaned_statement = clean_prose(statement)
            control_title = generate_title(indicator.get("name", ""), control_id)

            impact = indicator.get("impact", {})
            if not isinstance(impact, dict):
                impact = {}
            for lvl in ("low", "moderate", "high"):
                if lvl not in impact:
                    impact[lvl] = False
            control_impacts[control_id] = impact

            following_info = indicator.get("following_information", [])
            if following_info:
                control_following_info[control_id] = following_info

            parts = [
                {
                    "id": f"{control_id}_smt",
                    "name": "statement",
                    "prose": cleaned_statement,
                }
            ]
            if following_info:
                for idx, info_item in enumerate(following_info, 1):
                    parts.append(
                        {
                            "id": f"{control_id}_smt.item.{idx}",
                            "name": "item",
                            "prose": clean_prose(info_item),
                        }
                    )

            control = {"id": control_id, "title": control_title, "parts": parts}
            controls.append(
                {"group_id": group_id, "group_title": group_title, "control": control}
            )

    return controls, control_impacts, control_following_info


def parse_frr_requirements_legacy(data: Dict[str, Any], filename: str) -> Tuple[List[Dict[str, Any]], Dict[str, Dict[str, bool]], Dict[str, List[str]]]:
    """Parse FRR sections from legacy multi-file format."""
    controls = []
    control_impacts = {}
    control_following_info = {}

    if "FRR" not in data:
        return controls, control_impacts, control_following_info

    standard_match = re.search(r'FRMR\.([A-Z]{3})\.', filename)
    if not standard_match:
        return controls, control_impacts, control_following_info

    standard = standard_match.group(1)
    group_id = standard
    info = data.get("info", {})
    group_title = info.get("name", standard)

    frr_data = data["FRR"]
    standard_frr = frr_data.get(standard)
    if not standard_frr or not isinstance(standard_frr, dict):
        return controls, control_impacts, control_following_info

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

            if req_id in seen_req_ids:
                continue
            seen_req_ids.add(req_id)

            statement = req.get("statement", "")
            if not statement:
                continue

            control_id = normalize_frr_control_id(req_id, standard)
            cleaned_statement = clean_prose(statement)
            control_title = generate_title(req.get("name", ""), control_id)

            impact = req.get("impact", {})
            if not isinstance(impact, dict):
                impact = {}
            for lvl in ("low", "moderate", "high"):
                if lvl not in impact:
                    impact[lvl] = False
            control_impacts[control_id] = impact

            following_info = req.get("following_information", [])
            if following_info:
                control_following_info[control_id] = following_info

            parts = [
                {
                    "id": f"{control_id}_smt",
                    "name": "statement",
                    "prose": cleaned_statement,
                }
            ]
            if following_info:
                for idx, info_item in enumerate(following_info, 1):
                    parts.append(
                        {
                            "id": f"{control_id}_smt.item.{idx}",
                            "name": "item",
                            "prose": clean_prose(info_item),
                        }
                    )

            control = {"id": control_id, "title": control_title, "parts": parts}
            controls.append(
                {"group_id": group_id, "group_title": group_title, "control": control}
            )

    return controls, control_impacts, control_following_info


# ---------------------------------------------------------------------------
# OSCAL output builders (unchanged logic, shared by both formats)
# ---------------------------------------------------------------------------

def get_existing_file_data(output_dir: str, version: str) -> Tuple[Dict[str, Dict[str, str]], Dict[str, Dict[str, Any]]]:
    """Get existing timestamps and content from files if they exist and version matches."""
    timestamps = {}
    existing_content = {}
    catalog_path = os.path.join(output_dir, "catalog.json")

    if os.path.exists(catalog_path):
        try:
            with open(catalog_path, "r", encoding="utf-8") as f:
                existing_catalog = json.load(f)
                if existing_catalog.get("catalog", {}).get("metadata", {}).get("version") == version:
                    metadata = existing_catalog["catalog"]["metadata"]
                    timestamps["catalog"] = {
                        "published": metadata.get("published"),
                        "last-modified": metadata.get("last-modified"),
                    }
                    catalog_copy = json.loads(json.dumps(existing_catalog))
                    catalog_copy["catalog"]["metadata"].pop("published", None)
                    catalog_copy["catalog"]["metadata"].pop("last-modified", None)
                    existing_content["catalog"] = catalog_copy
        except Exception as e:
            print(f"  Warning: Could not read existing catalog: {e}")

    for impact_level in ["low", "moderate", "high"]:
        profile_path = os.path.join(output_dir, f"20x_{impact_level}_profile.json")
        if os.path.exists(profile_path):
            try:
                with open(profile_path, "r", encoding="utf-8") as f:
                    existing_profile = json.load(f)
                    if existing_profile.get("profile", {}).get("metadata", {}).get("version") == version:
                        metadata = existing_profile["profile"]["metadata"]
                        timestamps[f"profile_{impact_level}"] = {
                            "published": metadata.get("published"),
                            "last-modified": metadata.get("last-modified"),
                        }
                        profile_copy = json.loads(json.dumps(existing_profile))
                        profile_copy["profile"]["metadata"].pop("published", None)
                        profile_copy["profile"]["metadata"].pop("last-modified", None)
                        existing_content[f"profile_{impact_level}"] = profile_copy
            except Exception as e:
                print(f"  Warning: Could not read existing {impact_level} profile: {e}")

    return timestamps, existing_content


def content_has_changed(new_content: Dict[str, Any], existing_content: Optional[Dict[str, Any]]) -> bool:
    """Compare content (excluding timestamps) to detect if it has changed."""
    if not existing_content:
        return True

    new_copy = json.loads(json.dumps(new_content))
    if "catalog" in new_copy:
        new_copy["catalog"]["metadata"].pop("published", None)
        new_copy["catalog"]["metadata"].pop("last-modified", None)
    elif "profile" in new_copy:
        new_copy["profile"]["metadata"].pop("published", None)
        new_copy["profile"]["metadata"].pop("last-modified", None)

    return json.dumps(new_copy, sort_keys=True) != json.dumps(existing_content, sort_keys=True)


def build_oscal_catalog(
    all_controls: List[Dict[str, Any]],
    version: str,
    existing_timestamps: Optional[Dict[str, str]] = None,
    content_changed: bool = True,
) -> Tuple[Dict[str, Any], str]:
    """Build OSCAL catalog from all controls."""
    groups_dict = defaultdict(lambda: {"id": "", "title": "", "controls": []})

    for item in all_controls:
        gid = item["group_id"]
        groups_dict[gid]["id"] = gid
        groups_dict[gid]["title"] = item["group_title"]
        groups_dict[gid]["controls"].append(item["control"])

    groups = [groups_dict[gid] for gid in sorted(groups_dict.keys())]

    catalog_uuid = str(uuid.uuid5(uuid.NAMESPACE_DNS, f"fedramp-20x-catalog-{version}"))

    if existing_timestamps and "published" in existing_timestamps:
        published = existing_timestamps["published"]
    else:
        published = datetime.now().strftime("%Y-%m-%dT%H:%M:%S.000000-04:00")

    if content_changed or not existing_timestamps:
        last_modified = datetime.now().strftime("%Y-%m-%dT%H:%M:%S.000000-04:00")
    else:
        last_modified = existing_timestamps.get("last-modified", published)

    catalog = {
        "catalog": {
            "uuid": catalog_uuid,
            "metadata": {
                "title": f"FedRAMP 20x Catalog (v{version})",
                "published": published,
                "last-modified": last_modified,
                "version": version,
                "oscal-version": "1.1.2",
            },
            "groups": groups,
        }
    }

    return catalog, catalog_uuid


def build_oscal_profile(
    impact_level: str,
    control_ids: List[str],
    catalog_uuid: str,
    version: str,
    existing_timestamps: Optional[Dict[str, str]] = None,
    content_changed: bool = True,
) -> Dict[str, Any]:
    """Build OSCAL profile for a specific impact level."""
    profile_uuid = str(uuid.uuid5(uuid.NAMESPACE_DNS, f"fedramp-20x-{impact_level}-profile-{version}"))
    impact_title = impact_level.capitalize()

    if existing_timestamps and "published" in existing_timestamps:
        published = existing_timestamps["published"]
    else:
        published = datetime.now().strftime("%Y-%m-%dT%H:%M:%S.000000-04:00")

    if content_changed or not existing_timestamps:
        last_modified = datetime.now().strftime("%Y-%m-%dT%H:%M:%S.000000-04:00")
    else:
        last_modified = existing_timestamps.get("last-modified", published)

    return {
        "profile": {
            "uuid": profile_uuid,
            "metadata": {
                "title": f"FedRAMP 20x {impact_title} Impact Profile",
                "published": published,
                "last-modified": last_modified,
                "version": version,
                "oscal-version": "1.1.2",
            },
            "imports": [
                {
                    "href": f"#{catalog_uuid}",
                    "include-controls": [{"with-ids": sorted(control_ids)}],
                }
            ],
        }
    }


def generate_csv(
    all_controls: List[Dict[str, Any]],
    control_following_info: Dict[str, List[str]],
    output_path: str,
):
    """Generate Requirements_Paramified.csv file."""
    with open(output_path, "w", newline="", encoding="utf-8") as csvfile:
        writer = csv.writer(csvfile, quoting=csv.QUOTE_ALL)
        writer.writerow(["Control Part", "OSCAL_ID", "ParamifiedProse"])

        for item in all_controls:
            control = item["control"]
            control_id = control["id"]

            control_part = control_id.upper()
            oscal_id = f"{control_id}_smt"

            statement_prose = ""
            if control.get("parts") and len(control["parts"]) > 0:
                statement_prose = control["parts"][0].get("prose", "")

            prose = statement_prose

            if control_id in control_following_info:
                following_info = control_following_info[control_id]
                if following_info:
                    if prose and not prose.rstrip().endswith(("\n", ":")):
                        prose += "\n"
                    elif prose and prose.rstrip().endswith(":"):
                        prose = prose.rstrip() + "\n"
                    info_items = [f"• {clean_prose(item)}" for item in following_info]
                    prose += "\n".join(info_items)

            writer.writerow([control_part, oscal_id, prose])


# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------

def main():
    """Main processing function. Supports both consolidated and legacy FRMR formats."""
    print("=" * 60)
    print("FRMR to OSCAL Processor")
    print("=" * 60)

    print("\nFetching FRMR file list...")
    frmr_files = fetch_frmr_file_list()
    if not frmr_files:
        print("No FRMR files found. Exiting.")
        return
    print(f"Found {len(frmr_files)} FRMR file(s)")

    all_controls = []
    all_control_impacts = {}
    all_control_following_info = {}
    versions = []

    for filename in frmr_files:
        print(f"\nProcessing {filename}...")
        data = fetch_frmr_file(filename)
        if not data:
            continue

        # Detect format
        fmt = detect_format_version(data)
        print(f"  Format: {fmt}")

        # Extract version
        version = extract_version_from_frmr(data)
        if version:
            versions.append(version)
            print(f"  Version: {version}")

        if fmt == "consolidated":
            # ---- Consolidated format (v0.9.0-beta+) ----
            # Parse KSI
            if "KSI" in data:
                controls, impacts, following_info = parse_ksi_consolidated(data)
                all_controls.extend(controls)
                all_control_impacts.update(impacts)
                all_control_following_info.update(following_info)
                print(f"  KSI controls: {len(controls)}")

            # Parse FRR from all top-level standard sections
            frr_controls, frr_impacts, frr_following = parse_frr_consolidated(data)
            if frr_controls:
                all_controls.extend(frr_controls)
                all_control_impacts.update(frr_impacts)
                all_control_following_info.update(frr_following)
                print(f"  FRR controls: {len(frr_controls)}")

        else:
            # ---- Legacy format (v0.4.0-alpha multi-file) ----
            if filename.startswith("FRMR.KSI."):
                controls, impacts, following_info = parse_ksi_indicators_legacy(data)
                all_controls.extend(controls)
                all_control_impacts.update(impacts)
                all_control_following_info.update(following_info)
                print(f"  KSI controls: {len(controls)}")
            elif "FRR" in data:
                controls, impacts, following_info = parse_frr_requirements_legacy(data, filename)
                all_controls.extend(controls)
                all_control_impacts.update(impacts)
                all_control_following_info.update(following_info)
                print(f"  FRR controls: {len(controls)}")

    if not all_controls:
        print("\nNo controls found. Exiting.")
        return

    # Determine version
    if versions:
        version = max(versions)
    else:
        version = datetime.now().strftime("%Y-%m-%d")

    print(f"\n{'=' * 60}")
    print(f"Version: {version}")
    print(f"Total controls: {len(all_controls)}")

    # Summarize groups
    group_counts = defaultdict(int)
    for item in all_controls:
        group_counts[item["group_id"]] += 1
    print("\nControls by group:")
    for gid in sorted(group_counts.keys()):
        print(f"  {gid}: {group_counts[gid]}")

    # Create output directory
    output_dir = os.path.join(OUTPUT_BASE_DIR, f"v{version}")
    os.makedirs(output_dir, exist_ok=True)

    # Check for existing files
    print("\nChecking for existing files...")
    existing_timestamps, existing_content = get_existing_file_data(output_dir, version)
    version_changed = not existing_timestamps

    if version_changed:
        print("  New version detected - will update timestamps")
    else:
        print("  Version unchanged - checking for content changes")

    # Build catalog
    print("\nBuilding OSCAL catalog...")
    catalog_timestamps = existing_timestamps.get("catalog") if existing_timestamps else None

    if version_changed:
        catalog_content_changed = True
        print("  Version changed - will update last-modified")
    else:
        catalog_temp, _ = build_oscal_catalog(all_controls, version, catalog_timestamps, content_changed=False)
        catalog_content_changed = content_has_changed(catalog_temp, existing_content.get("catalog"))
        if catalog_content_changed:
            print("  Catalog content changed - will update last-modified")
        else:
            print("  Catalog content unchanged - preserving last-modified")

    catalog, catalog_uuid = build_oscal_catalog(all_controls, version, catalog_timestamps, content_changed=catalog_content_changed)

    # Build profiles
    print("Building OSCAL profiles...")
    impact_controls = {"low": [], "moderate": [], "high": []}

    for item in all_controls:
        control_id = item["control"]["id"]
        impact = all_control_impacts.get(control_id, {})
        for lvl in ("low", "moderate", "high"):
            if impact.get(lvl, False):
                impact_controls[lvl].append(control_id)

    profiles = {}
    for impact_level in ["low", "moderate", "high"]:
        control_ids = impact_controls[impact_level]
        profile_timestamps = existing_timestamps.get(f"profile_{impact_level}") if existing_timestamps else None

        if version_changed:
            profile_content_changed = True
        else:
            profile_temp = build_oscal_profile(impact_level, control_ids, catalog_uuid, version, profile_timestamps, content_changed=False)
            profile_content_changed = content_has_changed(profile_temp, existing_content.get(f"profile_{impact_level}"))

        profiles[impact_level] = build_oscal_profile(impact_level, control_ids, catalog_uuid, version, profile_timestamps, content_changed=profile_content_changed)

        status = "content changed" if profile_content_changed else "unchanged"
        print(f"  {impact_level.capitalize()} profile: {len(control_ids)} controls ({status})")

    # Write files
    print(f"\nWriting files to {output_dir}/...")

    catalog_path = os.path.join(output_dir, "catalog.json")
    with open(catalog_path, "w", encoding="utf-8") as f:
        json.dump(catalog, f, indent=2, ensure_ascii=False)
    print(f"  Written: {catalog_path}")

    for impact_level, profile in profiles.items():
        profile_path = os.path.join(output_dir, f"20x_{impact_level}_profile.json")
        with open(profile_path, "w", encoding="utf-8") as f:
            json.dump(profile, f, indent=2, ensure_ascii=False)
        print(f"  Written: {profile_path}")

    csv_path = os.path.join(output_dir, "Requirements_Paramified.csv")
    generate_csv(all_controls, all_control_following_info, csv_path)
    print(f"  Written: {csv_path}")

    print(f"\n{'=' * 60}")
    print("Processing complete!")
    print(f"{'=' * 60}")


if __name__ == "__main__":
    main()
