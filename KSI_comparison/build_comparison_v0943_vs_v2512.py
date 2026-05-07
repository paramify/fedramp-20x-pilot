#!/usr/bin/env python3
"""
Build ksiData for KSI_comparison HTML by matching the **full** Phase Two catalog ``OSCAL/v25.12A``
to **all** comparable FedRAMP catalog (**FRMR**) 0.9.43-beta prose in this repo bundle:

  LEFT  (columns oldId / oldDesc after swap):  every control group in Phase Two catalog (ADS, CCM, …)
  RIGHT (columns newId / newDesc):             top-level ``KSI`` indicators **plus** ``FRR.*`` leaf
                                               requirements under ``both`` / ``20x`` (``rev5`` omitted);
                                               ``following_information`` / bullets inlined into prose.

The OSCAL ``v0.9.43-beta/catalog.json`` 60-row file is intentionally not used — FR distributes granular
requirements in ``KSI`` + ``FRR``.

Cohort aliases: ``SCR`` thematic → Phase Two ``TPR``; ``FRR.SCG`` → ``RSC``; nested ``FRR.KSI`` process
→ cohort ``AFR`` (pairs ``afr-02`` rollup / KSI summaries).

Greedy prose/title match within cohort. **Added** = FR-side orphan; **removed** = Phase Two-only orphan.
"""

from __future__ import annotations

import json
import re
from collections import defaultdict
from difflib import SequenceMatcher
from pathlib import Path

REPO = Path(__file__).resolve().parents[1] / "OSCAL"
SCRIPT_DIR = Path(__file__).resolve().parent

# Phase Two granular catalog (left column after swap).
NEW_VER_PATH = REPO / "v25.12A" / "catalog.json"

# Full KSI indicator statements (right column): FedRAMP catalog JSON, not OSCAL thematic.
FRMR_KSI_JSON = SCRIPT_DIR / "FRMR.documentation_0.9.43-beta.json"

# Top-level KSI thematic family → Phase Two group id where labels differ.
KSI_THEME_COHORT_ALIAS = {"SCR": "TPR"}

# FRMR FRR short process acronym → Phase Two catalog group id.
FRR_PROC_COHORT_ALIAS = {"SCG": "RSC", "KSI": "AFR"}

# FRR tracks included for comparisons focused on Phase Two FedRAMP 20x participants.
FRR_TWENTYX_TRACKS_ONLY = frozenset({"both", "20x"})


def norm(s: str) -> str:
    s = (s or "").strip().replace("\u2019", "'").lower()
    return " ".join(s.split())


def norm_title(s: str) -> str:
    return norm(re.sub(r"[^a-z0-9]+", " ", s or ""))


def extract_controls(cat_json: dict) -> list[dict]:
    rows = []

    def walk(controls: list, group_id: str, group_title: str):
        for c in controls:
            cid = c.get("id")
            title = (c.get("title") or "").strip()
            stmt_parts: list[str] = []
            for p in c.get("parts") or []:
                pid = p.get("id") or ""
                if pid.endswith("_smt") or p.get("name") == "statement":
                    chunks = []
                    if p.get("prose"):
                        chunks.append(p["prose"].strip())
                    for sp in p.get("parts") or []:
                        if sp.get("prose"):
                            chunks.append(sp["prose"].strip())
                    stmt_parts.extend(chunks if chunks else [])
                    break
            stmt = "\n".join(stmt_parts).strip() if stmt_parts else ""
            rows.append(
                {
                    "group_id": group_id,
                    "group_title": group_title,
                    "id": cid,
                    "title": title,
                    "stmt": stmt,
                    "norm": norm(stmt),
                }
            )
            walk(c.get("controls") or [], group_id, group_title)

    for grp in cat_json.get("groups", []):
        walk(grp.get("controls") or [], grp.get("id", ""), grp.get("title", ""))

    return rows


def frmr_augment_kv_statement(kv: dict) -> str:
    """Append bullet / list fields FedRAMP uses beside ``statement`` for matching fidelity."""
    parts: list[str] = []
    st = kv.get("statement")
    if isinstance(st, str) and st.strip():
        parts.append(st.strip())
    for key in ("following_information", "following_information_bullets"):
        block = kv.get(key)
        if isinstance(block, list):
            for item in block:
                if isinstance(item, str) and item.strip():
                    parts.append(item.strip())
    return "\n".join(parts).strip()


def extract_ksi_indicators_frmr(frmr: dict) -> list[dict]:
    """Flatten top-level ``KSI`` into control-shaped dicts matching ``extract_controls`` fields."""
    rows: list[dict] = []
    ksi_root = frmr.get("KSI") or {}
    if not isinstance(ksi_root, dict):
        return rows

    def push(family_code: str, kid: str, title: str, stmt: str) -> None:
        st = (stmt or "").strip()
        if not st:
            return
        rows.append(
            {
                "group_id": family_code,
                "group_title": family_code,
                "id": kid,
                "title": (title or "").strip(),
                "stmt": st,
                "norm": norm(st),
            }
        )

    for family_code, block in sorted(ksi_root.items()):
        if not isinstance(block, dict):
            continue
        indicators = block.get("indicators") or {}
        if not isinstance(indicators, dict):
            continue
        for kid, kv in sorted(indicators.items()):
            if not isinstance(kv, dict):
                continue
            title = kv.get("name") or ""
            stmt = frmr_augment_kv_statement(kv)
            push(family_code, kid, title, stmt if stmt else "")
            vb = kv.get("varies_by_level")
            if isinstance(vb, dict):
                for lvl, lv in sorted(vb.items()):
                    if not isinstance(lv, dict):
                        continue
                    if not isinstance(lv, dict):
                        continue
                    lv_joined = frmr_augment_kv_statement(lv)
                    if lv_joined.strip():
                        nid = f"{kid}[{lvl}]"
                        push(family_code, nid, title, lv_joined.strip())

    return rows


def frr_twentyx_id_suffix(track_key: str) -> str:
    """Right-hand display: only annotate ``20x`` bucket IDs; omit ``both`` suffix noise."""
    return " (20x)" if track_key == "20x" else ""


def extract_frr_requirements_frmr(frmr: dict) -> list[dict]:
    """All ``FRR.<process>.data`` leaves under ``both`` and ``20x`` only (exclude ``rev5``)."""
    rows: list[dict] = []
    frr_root = frmr.get("FRR") or {}
    if not isinstance(frr_root, dict):
        return rows

    for proc_short, pdata in sorted(frr_root.items()):
        if not isinstance(pdata, dict):
            continue
        cohort_raw = (proc_short or "").strip().upper()
        cohort = FRR_PROC_COHORT_ALIAS.get(cohort_raw, cohort_raw)
        data = pdata.get("data") or {}
        if not isinstance(data, dict):
            continue

        for track_key in sorted(FRR_TWENTYX_TRACKS_ONLY):
            track_val = data.get(track_key)
            if not isinstance(track_val, dict):
                continue
            suf = frr_twentyx_id_suffix(track_key)
            for _label_key, label_val in sorted(track_val.items()):
                if not isinstance(label_val, dict):
                    continue
                for req_id, req in sorted(label_val.items()):
                    if not isinstance(req, dict):
                        continue
                    title = (req.get("name") or "").strip()
                    vb = req.get("varies_by_level")
                    pushed_levels = False
                    if isinstance(vb, dict) and vb:
                        for lvl, lv in sorted(vb.items()):
                            if not isinstance(lv, dict):
                                continue
                            joined = frmr_augment_kv_statement(lv)
                            if not joined.strip():
                                continue
                            rid = f"{req_id}[{lvl}]{suf}"
                            rows.append(
                                {
                                    "group_id": cohort,
                                    "group_title": cohort,
                                    "id": rid,
                                    "title": title,
                                    "stmt": joined.strip(),
                                    "norm": norm(joined),
                                }
                            )
                            pushed_levels = True
                    st_main = frmr_augment_kv_statement(req)
                    if pushed_levels:
                        continue
                    if not st_main.strip():
                        continue
                    rid = f"{req_id}{suf}"
                    rows.append(
                        {
                            "group_id": cohort,
                            "group_title": cohort,
                            "id": rid,
                            "title": title,
                            "stmt": st_main.strip(),
                            "norm": norm(st_main),
                        }
                    )
    return rows


def extract_fr_mr_rhs_controls(frmr: dict) -> list[dict]:
    """Right-hand catalog union: thematic ``KSI`` + granular ``FRR`` requirements."""
    ksi_rows = extract_ksi_indicators_frmr(frmr)
    frr_rows = extract_frr_requirements_frmr(frmr)
    merged = [*ksi_rows, *frr_rows]
    if not merged:
        return merged
    # Deterministic cohort then id ordering for stable greedy tie-break behaviour
    merged.sort(key=lambda r: ((r["group_id"] or "").upper(), str(r["id"]), r["stmt"][:120]))
    return merged


def cohort_key_rhs(rhs_ctrl: dict) -> str:
    g = (rhs_ctrl["group_id"] or "").upper()
    return KSI_THEME_COHORT_ALIAS.get(g, g)


def cohort_key_v25(ctrl: dict) -> str:
    """Phase Two catalog group id (already uppercase in OSCAL extracts)."""
    return (ctrl["group_id"] or "").upper()


def pair_score(oc: dict, nc: dict) -> float:
    if not oc["norm"] or not nc["norm"]:
        return 0.0
    pr = SequenceMatcher(None, oc["norm"], nc["norm"]).ratio()
    tit_o, tit_n = norm_title(oc["title"]), norm_title(nc["title"])
    if tit_o and tit_o == tit_n:
        pr = min(1.0, pr + 0.08)
    elif tit_o and tit_n and (tit_o in tit_n or tit_n in tit_o):
        pr = min(1.0, pr + 0.03)
    return pr


def greedy_match(old_list: list[dict], new_list: list[dict], score_floor: float = 0.35):
    cand: list[tuple[float, int, int]] = []
    for i, oc in enumerate(old_list):
        for j, nc in enumerate(new_list):
            cand.append((pair_score(oc, nc), i, j))
    cand.sort(reverse=True)
    matched_o: set[int] = set()
    matched_n: set[int] = set()
    out_pairs: list[tuple[dict, dict]] = []
    for sc, i, j in cand:
        if sc < score_floor:
            break
        if i in matched_o or j in matched_n:
            continue
        matched_o.add(i)
        matched_n.add(j)
        out_pairs.append((old_list[i], new_list[j]))
    return out_pairs, matched_o, matched_n


def prose_similarity_ratio(oc: dict, nc: dict) -> float:
    a, b = oc.get("norm") or "", nc.get("norm") or ""
    if not a or not b:
        return 0.0
    return SequenceMatcher(None, a, b).ratio()


# Treat high prose overlap + title disagreement as “same”: catalog labels changed but body is unchanged.
TITLE_DIFF_NEAR_MATCH_MIN = 0.991


def classify(oc: dict, nc: dict) -> str:
    """Normalized prose equality → same. Else, if titles differ and prose overlap is extremely high → same."""
    if oc["norm"] == nc["norm"]:
        return "same"
    ot = (oc.get("title") or "").strip()
    nt = (nc.get("title") or "").strip()
    if ot != nt and prose_similarity_ratio(oc, nc) >= TITLE_DIFF_NEAR_MATCH_MIN:
        return "same"
    return "modified"


def make_row(
    oc: dict | None,
    nc: dict | None,
    status: str,
    cohort: str,
):
    oid = oc["id"] if oc else ""
    nid = nc["id"] if nc else ""
    od = oc["stmt"] if oc else ""
    nd = nc["stmt"] if nc else ""

    notes_parts: list[str] = []

    # Orphan meanings (after row swap): left=v25.12A, right=FRMR 0.9.43-beta union (`KSI` + `FRR`).
    if status == "added":
        notes_parts.append(
            "Appears in FedRAMP catalog 0.9.43-beta (`KSI` and/or `FRR`) but has no paired Phase Two v25.12A control in this cohort"
        )
    elif status == "removed":
        notes_parts.append(
            "Appears in Phase Two v25.12A catalog but has no paired 0.9.43-beta FR `KSI`/`FRR` row in this cohort"
        )
    elif status == "same" and oc and nc:
        oid_l = (oc["id"] or "").lower()
        nid_l = (nc["id"] or "").lower()
        ot = (oc.get("title") or "").strip()
        nt = (nc.get("title") or "").strip()
        exact_body = oc.get("norm") == nc.get("norm")
        ids_differ = oid_l != nid_l
        titles_differ = ot != nt

        if exact_body:
            if titles_differ and ids_differ:
                notes_parts.append(
                    "Same requirement — statement text is identical; titles differ "
                    f"(FR {ot!r} vs Phase Two {nt!r}). "
                    f"Updated ID: Phase Two `{nc['id']}` ↔ FR `{oc['id']}`."
                )
            elif titles_differ:
                notes_parts.append(
                    "Same requirement — statement text is identical; titles differ "
                    f"(FR {ot!r} vs Phase Two {nt!r})."
                )
            elif ids_differ:
                notes_parts.append(
                    "Same requirement — statement text is identical; "
                    f"updated ID: Phase Two `{nc['id']}` ↔ FR `{oc['id']}`."
                )
        else:
            pct = prose_similarity_ratio(oc, nc) * 100.0
            sub_parts: list[str] = []
            if ids_differ:
                sub_parts.append(
                    f"updated ID — Phase Two `{nc['id']}` ↔ FR `{oc['id']}`"
                )
            if titles_differ:
                sub_parts.append(f"titles differ — FR: {ot!r} · Phase Two: {nt!r}")
            lead = (
                f"Treat as same — statement wording ~{pct:.1f}% similar (titles differ;"
                " not an exact normalized match)"
            )
            if sub_parts:
                notes_parts.append(lead + "; " + "; ".join(sub_parts) + ".")
            else:
                notes_parts.append(lead + ".")
    elif (
        status == "modified"
        and oc
        and nc
        and (oc.get("title") or "").strip() != (nc.get("title") or "").strip()
    ):
        notes_parts.append(
            f"titles differ — FR: {(oc.get('title') or '')!r} · Phase Two: {(nc.get('title') or '')!r}"
        )

    return {
        "family": cohort,
        "oldId": oid,
        "newId": nid,
        "status": status,
        "oldDesc": od,
        "newDesc": nd,
        "notes": "; ".join(notes_parts),
    }


def main(
    *,
    frmr_json: Path | None = None,
    v25_catalog_path: Path | None = None,
) -> list[dict]:
    frmr_path = Path(frmr_json or FRMR_KSI_JSON)
    v25_path = Path(v25_catalog_path or NEW_VER_PATH)
    with open(frmr_path, encoding="utf-8") as f:
        rhs_controls = extract_fr_mr_rhs_controls(json.load(f))
    if not rhs_controls:
        raise SystemExit(f"No FRMR `KSI`/`FRR` content extracted from {frmr_path}")

    with open(v25_path, encoding="utf-8") as f:
        v25_controls = extract_controls(json.load(f)["catalog"])

    by_rhs: dict[str, list[dict]] = defaultdict(list)
    by_cohort_v25: dict[str, list[dict]] = defaultdict(list)
    for rhs in rhs_controls:
        by_rhs[cohort_key_rhs(rhs)].append(rhs)
    for vc in v25_controls:
        by_cohort_v25[cohort_key_v25(vc)].append(vc)

    cohorts = sorted(set(by_rhs.keys()) | set(by_cohort_v25.keys()))

    rows: list[dict] = []

    for cohort in cohorts:
        rhs_side = by_rhs.get(cohort, [])
        v25_side = by_cohort_v25.get(cohort, [])
        mx = max(len(rhs_side), len(v25_side), 1)
        score_floor = 0.34 if mx < 14 else (0.28 if mx < 42 else 0.24)

        if rhs_side and v25_side:
            pairs_mt, matched_o, matched_n = greedy_match(rhs_side, v25_side, score_floor)

            matched_rhs_ids = set(id(x[0]) for x in pairs_mt)
            matched_v25_ids_set = set(id(x[1]) for x in pairs_mt)

            for rhs_r, vc in pairs_mt:
                sts = classify(rhs_r, vc)
                rows.append(make_row(rhs_r, vc, sts, cohort))

            for rhs_r in rhs_side:
                if id(rhs_r) not in matched_rhs_ids:
                    rows.append(make_row(rhs_r, None, "added", cohort))

            for vc in v25_side:
                if id(vc) not in matched_v25_ids_set:
                    rows.append(make_row(None, vc, "removed", cohort))

        elif not rhs_side and v25_side:
            for vc in v25_side:
                rows.append(make_row(None, vc, "removed", cohort))
        elif rhs_side and not v25_side:
            for rhs_r in rhs_side:
                rows.append(make_row(rhs_r, None, "added", cohort))

    # Emit left → right as Phase Two → v0.9.43 (stored column keys remain old/new for shared JS UX)
    for r in rows:
        r["oldId"], r["newId"] = r["newId"], r["oldId"]
        r["oldDesc"], r["newDesc"] = r["newDesc"], r["oldDesc"]

    # Preserve stable-ish display order: cohort, then paired rows before singles
    prio = {"same": 0, "modified": 1, "added": 2, "removed": 3}
    rows.sort(
        key=lambda r: (
            r["family"],
            prio[r["status"]],
            r.get("oldId") or "",
            r.get("newId") or "",
        )
    )

    return rows


HTML_TEMPLATE = r"""<!DOCTYPE html>
<html lang="en">

<!--
  Phase Two vs **FedRAMP catalog (FRMR JSON)**: unions top-level **`KSI`** + **`FRR`** requirement leaves (**`both`** and **`20x`** only;
  **`rev5`** omitted); list fields folded into prose. Matching: greedy prose/title per cohort alias. **Added** = FR orphan;
  **Removed** = Phase Two orphan.
-->

<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>v25.12A vs FedRAMP catalog 0.9.43‑beta</title>
    <style>
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            margin: 0;
            padding: 20px;
            background-color: #f5f7fa;
            line-height: 1.4;
            font-size: 14px;
        }

        .container {
            max-width: 100%;
            margin: 0 auto;
            background: white;
            padding: 20px;
            border-radius: 12px;
            box-shadow: 0 4px 20px rgba(0,0,0,0.1);
        }

        h1 {
            text-align: center;
            color: #2c3e50;
            margin-bottom: 16px;
        }

        .controls {
            display: flex;
            flex-wrap: wrap;
            gap: 15px;
            margin-bottom: 20px;
            padding: 15px;
            background: #ecf0f1;
            border-radius: 8px;
            align-items: center;
        }

        .filter-group {
            display: flex;
            flex-direction: column;
            gap: 5px;
        }

        .filter-group label {
            font-weight: 600;
            font-size: 12px;
            color: #2c3e50;
        }

        select, input {
            padding: 8px;
            border: 1px solid #bdc3c7;
            border-radius: 4px;
            font-size: 12px;
        }

        .table-container {
            overflow: auto;
            max-height: 70vh;
            border: 1px solid #ddd;
            border-radius: 8px;
        }

        table {
            width: 100%;
            border-collapse: collapse;
            font-size: 14px;
        }

        th {
            background: #34495e;
            color: white;
            padding: 10px 6px;
            text-align: left;
            font-weight: 600;
            position: sticky;
            top: 0;
            z-index: 10;
            cursor: pointer;
            user-select: none;
        }

        th:hover {
            background: #2c3e50;
        }

        td {
            padding: 8px 6px;
            border-bottom: 1px solid #ecf0f1;
            vertical-align: top;
        }

        td:nth-child(1), td:nth-child(2), td:nth-child(3), td:nth-child(4) {
            width: 7%;
            min-width: 60px;
            max-width: 90px;
        }

        .description-cell, .notes-cell {
            font-size: 13px;
        }

        tr:hover {
            background-color: #f8f9fa;
        }

        tr.hidden {
            display: none;
        }

        .status {
            font-weight: 600;
            padding: 3px 6px;
            border-radius: 3px;
            font-size: 10px;
            text-align: center;
            white-space: nowrap;
        }

        .same { background-color: #d5f4e6; color: #0f5132; }
        .modified { background-color: #cff4fc; color: #055160; }
        /* added = only in FR 0.9.43-beta; removed = only in Phase Two v25.12A */
        .added { background-color: #d1ecf1; color: #055160; }
        .removed { background-color: #e2e3e5; color: #41464b; }

        .id-cell {
            font-family: 'Courier New', monospace;
            font-weight: 600;
            min-width: 70px;
        }

        .notes-cell {
            font-style: italic;
            color: #6c757d;
            max-width: 220px;
        }

        .export-btn {
            background: #3498db;
            color: white;
            border: none;
            padding: 8px 16px;
            border-radius: 4px;
            cursor: pointer;
            font-size: 12px;
        }

        .export-btn:hover {
            background: #2980b9;
        }

        .summary {
            display: flex;
            flex-wrap: wrap;
            gap: 14px;
            margin-bottom: 15px;
            font-size: 12px;
        }

        .summary-item {
            padding: 8px 12px;
            border-radius: 4px;
            font-weight: 600;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>Phase Two catalog v25.12A ↔ FedRAMP catalog 0.9.43‑beta</h1>

        <div class="controls">
            <div class="filter-group">
                <label>Filter by family:</label>
                <select id="familyFilter"><option value="">All families</option></select>
            </div>

            <div class="filter-group">
                <label>Filter by Status:</label>
                <select id="statusFilter">
                    <option value="">All Status</option>
                    <option value="same">Same</option>
                    <option value="modified">Modified</option>
                    <option value="added">Added (FR 0.9.43-beta only)</option>
                    <option value="removed">Removed (Phase Two only)</option>
                </select>
            </div>

            <div class="filter-group">
                <label>Search:</label>
                <input type="text" id="searchInput" placeholder="Search IDs or descriptions…">
            </div>

            <button class="export-btn" onclick="exportToCsv()" type="button">Export to CSV</button>
        </div>

        <div class="summary" id="summary"></div>

        <div class="table-container">
            <table id="ksiTable">
                <thead>
                    <tr>
                        <th onclick="sortTable(0)">Family</th>
                        <th onclick="sortTable(1)">Phase Two<br>v25.12A ID</th>
                        <th onclick="sortTable(2)">v0.9.43-beta<br>ID</th>
                        <th onclick="sortTable(3)">Status</th>
                        <th onclick="sortTable(4)">v25.12A<br>statement</th>
                        <th onclick="sortTable(5)">v0.9.43-beta<br>statement</th>
                        <th onclick="sortTable(6)">Notes</th>
                    </tr>
                </thead>
                <tbody id="tableBody"></tbody>
            </table>
        </div>
    </div>

    <script>
        const ksiData = __DATA__;

        let currentSort = { column: -1, ascending: true };

        function populateFamilyFilter() {
            const sel = document.getElementById('familyFilter');
            const families = [...new Set(ksiData.map(r => r.family))].sort();
            families.forEach(f => {
                const o = document.createElement('option');
                o.value = f;
                o.textContent = f;
                sel.appendChild(o);
            });
        }

        document.addEventListener('DOMContentLoaded', () => {
            populateFamilyFilter();
            populateTable();
            setupEventListeners();
        });

        function setupEventListeners() {
            document.getElementById('familyFilter').addEventListener('change', filterTable);
            document.getElementById('statusFilter').addEventListener('change', filterTable);
            document.getElementById('searchInput').addEventListener('input', filterTable);
        }

        function populateTable() {
            const tbody = document.getElementById('tableBody');
            tbody.innerHTML = '';

            ksiData.forEach(row => {
                const tr = document.createElement('tr');
                const oid = escapeHtml(displayOldId(row.oldId));
                tr.innerHTML = `
                    <td>${escapeHtml(row.family)}</td>
                    <td class="id-cell">${oid}</td>
                    <td class="id-cell">${escapeHtml(row.newId)}</td>
                    <td><span class="status ${row.status}">${row.status.charAt(0).toUpperCase() + row.status.slice(1)}</span></td>
                    <td class="description-cell">${escapeHtml(row.oldDesc)}</td>
                    <td class="description-cell">${escapeHtml(row.newDesc)}</td>
                    <td class="notes-cell">${escapeHtml(row.notes)}</td>`;
                tbody.appendChild(tr);
            });

            updateSummary();
        }

        function displayOldId(id) {
            if (!id) return '';
            // Left column uses Phase Two slugs (e.g. iam-01); preserve as-is.
            return id;
        }

        function escapeHtml(text) {
            if (!text) return '';
            return String(text)
                .replace(/&/g, '&amp;')
                .replace(/</g, '&lt;')
                .replace(/>/g, '&gt;')
                .replace(/"/g, '&quot;')
                .replace(/'/g, '&#039;');
        }

        function updateSummary() {
            const counts = {};
            ksiData.forEach(row => { counts[row.status] = (counts[row.status] || 0) + 1; });
            document.getElementById('summary').innerHTML =
                Object.entries(counts).map(([s, n]) =>
                    `<div class="summary-item ${s}">${s.charAt(0).toUpperCase() + s.slice(1)}: ${n}</div>`
                ).join('');
        }

        function filterTable() {
            const familyFilter = document.getElementById('familyFilter').value;
            const statusFilter = document.getElementById('statusFilter').value;
            const q = document.getElementById('searchInput').value.toLowerCase();

            document.querySelectorAll('#tableBody tr').forEach(row => {
                const cells = row.getElementsByTagName('td');
                const blob = [...cells].map(c => c.textContent.toLowerCase()).join('|');
                const familyOk = !familyFilter || cells[0].textContent === familyFilter;
                const statusTxt = cells[3].textContent.toLowerCase();
                const statusOk = !statusFilter || statusTxt.includes(statusFilter);
                const searchOk = !q || blob.includes(q);
                row.style.display = (familyOk && statusOk && searchOk) ? '' : 'none';
            });
        }

        function sortTable(columnIndex) {
            const tbody = document.getElementById('tableBody');
            let rows = Array.from(tbody.getElementsByTagName('tr'));
            const ascending = currentSort.column === columnIndex ? !currentSort.ascending : true;
            currentSort = { column: columnIndex, ascending };

            rows.sort((a, b) => {
                const av = a.getElementsByTagName('td')[columnIndex].textContent.trim();
                const bv = b.getElementsByTagName('td')[columnIndex].textContent.trim();

                if (columnIndex === 3) {
                    const order = { same: 0, modified: 1, added: 2, removed: 3 };
                    const ao = order[av.toLowerCase()] ?? 99;
                    const bo = order[bv.toLowerCase()] ?? 99;
                    return ascending ? ao - bo : bo - ao;
                }
                return ascending ? av.localeCompare(bv) : bv.localeCompare(av);
            });

            tbody.innerHTML = '';
            rows.forEach(r => tbody.appendChild(r));
        }

        function exportToCsv() {
            const escapeCsvField = field => {
                if (field == null) return '';
                const s = String(field);
                if (/[,"\n]/.test(s)) return `"${s.replace(/"/g, '""')}"`;
                return s;
            };

            const lines = [['Cohort','Phase Two v25.12A ID','v0.9.43-beta ID','Status','Phase Two v25.12A statement','v0.9.43-beta statement','Notes'].join(',')]
                .concat(ksiData.map(row => [
                    escapeCsvField(row.family),
                    escapeCsvField(displayOldId(row.oldId)),
                    escapeCsvField(row.newId),
                    escapeCsvField(row.status),
                    escapeCsvField(row.oldDesc),
                    escapeCsvField(row.newDesc),
                    escapeCsvField(row.notes),
                ].join(',')));

            const blob = new Blob([lines.join('\n')], { type: 'text/csv;charset=utf-8;' });
            const url = URL.createObjectURL(blob);
            const a = document.createElement('a');
            a.href = url;
            a.download = 'v25_12A_to_frmr_KSI_and_FRR_comparison.csv';
            a.click();
            URL.revokeObjectURL(url);
        }
    </script>
</body>
</html>
"""


def write_standalone_html(
    path: Path | None = None,
    data: list[dict] | None = None,
    *,
    frmr_json: Path | None = None,
    v25_catalog_path: Path | None = None,
) -> Path:
    path = path or Path(__file__).resolve().parent / (
        "v25.12A vs v0.9.43-beta KSI comparison.html"
    )
    rows = (
        data
        if data is not None
        else main(frmr_json=frmr_json, v25_catalog_path=v25_catalog_path)
    )
    json_payload = json.dumps(rows, indent=12, ensure_ascii=False)
    out = HTML_TEMPLATE.replace("__DATA__", json_payload, 1)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(out, encoding="utf-8")
    return path


if __name__ == "__main__":
    import argparse
    from collections import Counter

    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--html",
        action="store_true",
        help=(
            "Write standalone HTML beside this script (default filename includes "
            "v25.12A vs v0.9.43-beta)."
        ),
    )
    ap.add_argument(
        "--html-out",
        type=Path,
        default=None,
        help="Override output HTML path",
    )
    ap.add_argument(
        "--frmr",
        type=Path,
        default=None,
        help=(
            "FedRAMP catalog JSON with `KSI` and `FRR` roots "
            "(default: FRMR.documentation_0.9.43-beta.json beside this script)."
        ),
    )
    ap.add_argument(
        "--v25-catalog",
        type=Path,
        default=None,
        help="Phase Two catalog.json path (default: OSCAL/v25.12A/catalog.json).",
    )

    args = ap.parse_args()
    data = main(frmr_json=args.frmr, v25_catalog_path=args.v25_catalog)
    print("Total rows:", len(data))
    print("By status:", dict(Counter(r["status"] for r in data)))
    print("FedRAMP catalog JSON:", Path(args.frmr or FRMR_KSI_JSON))

    if args.html:
        outp = write_standalone_html(
            args.html_out,
            data=data,
            frmr_json=args.frmr,
            v25_catalog_path=args.v25_catalog,
        )
        print("Wrote", outp)
