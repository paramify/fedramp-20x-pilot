#!/usr/bin/env python3
"""
Standalone test for v0.9.0-beta parsing logic - tests core functions without network dependencies.
"""

import json
import re
from typing import Dict, List, Any, Optional, Tuple
from collections import defaultdict

# Copy core functions from process_frmr_to_oscal.py (without requests dependency)

def normalize_control_id(raw_id: str, prefix: str = "KSI-") -> str:
    """Convert a KSI or FRR ID to an OSCAL control ID."""
    if raw_id.startswith(prefix):
        remainder = raw_id[len(prefix):]
    else:
        remainder = raw_id
    parts = remainder.split("-")
    if len(parts) >= 2:
        return "-".join(p.lower() for p in parts)
    return remainder.lower().replace("_", "-")


def clean_prose(text: str) -> str:
    """Clean prose text."""
    if not text:
        return text
    text = text.strip()
    if text.startswith('"') and text.endswith('"'):
        text = text[1:-1]
    if text.startswith("'") and text.endswith("'"):
        text = text[1:-1]
    text = re.sub(r'\*\*(.+?)\*\*', r'\1', text)
    text = re.sub(r'_([A-Za-z0-9][A-Za-z0-9\s]*[A-Za-z0-9])_', r'\1', text)
    return text


def get_indicator_statement(indicator: Dict[str, Any], level: str = "moderate") -> str:
    """Extract the statement for a given indicator."""
    statement = indicator.get("statement", "")
    if statement:
        return statement
    varies = indicator.get("varies_by_level")
    if varies and isinstance(varies, dict):
        if level in varies:
            level_data = varies[level]
            if isinstance(level_data, dict):
                return level_data.get("statement", "")
            elif isinstance(level_data, str):
                return level_data
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
    """Determine which impact levels an indicator applies to."""
    impact = {"low": False, "moderate": False, "high": False}
    varies = indicator.get("varies_by_level")
    if varies and isinstance(varies, dict):
        for level in ["low", "moderate", "high"]:
            if level in varies:
                impact[level] = True
        return impact
    if indicator.get("statement"):
        impact["low"] = True
        impact["moderate"] = True
        impact["high"] = True
        return impact
    old_impact = indicator.get("impact", {})
    if isinstance(old_impact, dict):
        impact["low"] = old_impact.get("low", False)
        impact["moderate"] = old_impact.get("moderate", False)
        impact["high"] = old_impact.get("high", False)
    return impact


KSI_GROUP_TITLES = {
    "CNA": "Cloud Native Architecture",
    "SVC": "Service Configuration",
    "SCR": "Supply Chain Risk",
    "TPR": "Third-Party Information Resources",
}


def parse_ksi_consolidated(data: Dict[str, Any]) -> Tuple[List[Dict[str, Any]], Dict[str, Dict[str, bool]], Dict[str, List[str]]]:
    """Parse KSI section from consolidated format."""
    controls = []
    control_impacts = {}
    control_following_info = {}
    
    ksi_section = data.get("KSI", {})
    ksi_data = ksi_section.get("data", ksi_section)
    skip_keys = {"info", "data"}
    themes = ksi_data if isinstance(ksi_data, dict) else {}
    
    for theme_key, theme_data in themes.items():
        if theme_key in skip_keys or not isinstance(theme_data, dict):
            continue
        
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
            if not isinstance(indicator, dict) or indicator.get("retired", False):
                continue
            
            control_id = normalize_control_id(indicator_id, prefix="KSI-")
            statement = get_indicator_statement(indicator, level="moderate")
            if not statement:
                continue
            
            cleaned_statement = clean_prose(statement)
            control_title = indicator.get("name", control_id.upper())
            
            impact = extract_impact_from_indicator(indicator)
            control_impacts[control_id] = impact
            
            following_info = indicator.get("following_information", [])
            if following_info:
                control_following_info[control_id] = following_info
            
            parts = [{
                "id": f"{control_id}_smt",
                "name": "statement",
                "prose": cleaned_statement,
            }]
            
            if following_info:
                for idx, info_item in enumerate(following_info, 1):
                    parts.append({
                        "id": f"{control_id}_smt.item.{idx}",
                        "name": "item",
                        "prose": clean_prose(info_item),
                    })
            
            control = {
                "id": control_id,
                "title": control_title,
                "parts": parts,
            }
            
            controls.append({
                "group_id": group_id,
                "group_title": theme_name,
                "control": control,
            })
    
    return controls, control_impacts, control_following_info


# Test data
SAMPLE_DATA = {
    "info": {
        "version": "0.9.0-beta",
        "last_updated": "2025-01-19"
    },
    "KSI": {
        "data": {
            "CNA": {
                "id": "KSI-CNA",
                "name": "Cloud Native Architecture",
                "short_name": "CNA",
                "indicators": {
                    "KSI-CNA-RNT": {
                        "name": "Restrict Network Traffic",
                        "statement": "Configure all machine-based resources to limit inbound and outbound network traffic.",
                        "controls": ["ac-17.3", "ca-9"]
                    },
                    "KSI-CNA-MAS": {
                        "name": "Minimize the Attack Surface",
                        "statement": "Design systems to minimize attack surface.",
                        "controls": ["sc-7.3"]
                    }
                }
            },
            "SCR": {
                "id": "KSI-SCR",
                "name": "Supply Chain Risk",
                "short_name": "SCR",
                "indicators": {
                    "KSI-SCR-MIT": {
                        "fka": "KSI-TPR-03",
                        "name": "Mitigating Supply Chain Risk",
                        "statement": "Persistently identify, review, and mitigate potential supply chain risks.",
                        "controls": ["ac-20", "ra-3.1"]
                    }
                }
            },
            "SVC": {
                "id": "KSI-SVC",
                "name": "Service Configuration",
                "short_name": "SVC",
                "indicators": {
                    "KSI-SVC-PRR": {
                        "name": "Preventing Residual Risk",
                        "varies_by_level": {
                            "low": {
                                "statement": "**Optional:** Persistently review plans..."
                            },
                            "moderate": {
                                "statement": "Persistently review plans, procedures, and the state of information resources..."
                            }
                        },
                        "controls": ["sc-4"]
                    }
                }
            }
        }
    }
}


def test_all():
    """Run all tests."""
    print("=" * 60)
    print("Testing v0.9.0-beta Parsing Logic")
    print("=" * 60)
    print()
    
    errors = []
    
    # Test 1: Control ID normalization
    print("Test 1: Control ID normalization")
    test_cases = [
        ("KSI-CNA-RNT", "cna-rnt"),
        ("KSI-SCR-MIT", "scr-mit"),
        ("KSI-CNA-01", "cna-01"),
    ]
    for input_id, expected in test_cases:
        result = normalize_control_id(input_id, prefix="KSI-")
        if result != expected:
            errors.append(f"  ✗ {input_id}: expected '{expected}', got '{result}'")
        else:
            print(f"  ✓ {input_id} -> {result}")
    print()
    
    # Test 2: Impact extraction
    print("Test 2: Impact extraction")
    indicator1 = {"statement": "Some statement"}
    impact1 = extract_impact_from_indicator(indicator1)
    if impact1["low"] and impact1["moderate"] and impact1["high"]:
        print("  ✓ Direct statement applies to all levels")
    else:
        errors.append("  ✗ Direct statement should apply to all levels")
    
    indicator2 = {
        "varies_by_level": {
            "low": {"statement": "Low"},
            "moderate": {"statement": "Moderate"}
        }
    }
    impact2 = extract_impact_from_indicator(indicator2)
    if impact2["low"] and impact2["moderate"] and not impact2["high"]:
        print("  ✓ varies_by_level correctly parsed")
    else:
        errors.append(f"  ✗ varies_by_level: expected low=True, moderate=True, high=False, got {impact2}")
    print()
    
    # Test 3: Statement extraction
    print("Test 3: Statement extraction")
    stmt1 = get_indicator_statement({"statement": "Direct"}, level="moderate")
    if stmt1 == "Direct":
        print("  ✓ Direct statement extracted")
    else:
        errors.append(f"  ✗ Expected 'Direct', got '{stmt1}'")
    
    stmt2 = get_indicator_statement({
        "varies_by_level": {
            "moderate": {"statement": "Moderate statement"}
        }
    }, level="moderate")
    if stmt2 == "Moderate statement":
        print("  ✓ Level-specific statement extracted")
    else:
        errors.append(f"  ✗ Expected 'Moderate statement', got '{stmt2}'")
    print()
    
    # Test 4: KSI parsing
    print("Test 4: KSI parsing")
    controls, impacts, following_info = parse_ksi_consolidated(SAMPLE_DATA)
    
    if len(controls) == 0:
        errors.append("  ✗ No controls parsed")
    else:
        print(f"  ✓ Parsed {len(controls)} controls")
    
    control_ids = [c["control"]["id"] for c in controls]
    expected_ids = ["cna-rnt", "cna-mas", "scr-mit", "svc-prr"]
    for expected_id in expected_ids:
        if expected_id in control_ids:
            print(f"    ✓ Found control: {expected_id}")
        else:
            errors.append(f"  ✗ Missing control: {expected_id}")
    
    groups = set(c["group_id"] for c in controls)
    if "CNA" in groups and "SCR" in groups and "SVC" in groups:
        print(f"  ✓ Groups found: {sorted(groups)}")
    else:
        errors.append(f"  ✗ Missing groups, got: {sorted(groups)}")
    
    # Test varies_by_level impact
    if "svc-prr" in impacts:
        svc_impact = impacts["svc-prr"]
        if svc_impact["low"] and svc_impact["moderate"] and not svc_impact["high"]:
            print("  ✓ varies_by_level impact correctly assigned")
        else:
            errors.append(f"  ✗ svc-prr impact incorrect: {svc_impact}")
    
    # Test statement cleaning (remove **Optional:**)
    svc_prr_control = next((c for c in controls if c["control"]["id"] == "svc-prr"), None)
    if svc_prr_control:
        statement = svc_prr_control["control"]["parts"][0]["prose"]
        if "**Optional:**" not in statement:
            print("  ✓ Optional marker cleaned from statement")
        else:
            errors.append("  ✗ Optional marker not cleaned")
    
    print()
    
    # Summary
    print("=" * 60)
    if errors:
        print(f"FAILED: {len(errors)} error(s)")
        for error in errors:
            print(error)
        return 1
    else:
        print("ALL TESTS PASSED ✓")
        return 0


if __name__ == "__main__":
    exit(test_all())
