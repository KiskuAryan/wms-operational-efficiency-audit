# Warehouse Management System (WMS) Operational Efficiency Audit
### *Synthetic Case Study: Supply-Chain Bottleneck Diagnostics, SQL Optimization & Architectural Refactoring*

[![SQL](https://img.shields.io/badge/SQL-SQLite%203%20%7C%20ANSI%20Core-blue?style=flat-square&logo=sqlite)](sql/)
[![VB.NET](https://img.shields.io/badge/.NET-Conceptual%20VB.NET%20Sketch-512BD4?style=flat-square&logo=dotnet)](legacy_audit/)
[![Python](https://img.shields.io/badge/Python-3.9%2B%20Diagnostic%20Engine-3776AB?style=flat-square&logo=python)](analysis/)
[![License](https://img.shields.io/badge/License-MIT-green?style=flat-square)](LICENSE)

> **Methodology & Authenticity Disclaimer:**  
> This repository is an **illustrative, synthetic simulation study** demonstrating a quantitative audit methodology for Warehouse Management Systems (WMS). All operational transaction logs (1,200 orders, 50 SKUs, 3 warehouse zones) are synthetically generated via calibrated statistical distributions (`scripts/seed_database.py`). It is designed to illustrate how data diagnostics, SQL optimization, and backend architectural refactoring can address classic supply-chain bottlenecks. Real-world implementation requires empirical validation against live facility telemetry and operational constraints.

---

## 📌 Project Overview & Structure

In high-volume third-party logistics (3PL) fulfillment facilities, operational throughput is frequently constrained by two interrelated bottlenecks: **sub-optimal physical inventory slotting** (causing excessive floor walking) and **database dispatch queueing** (causing shift-hour order allocation delays).

This project models and analyzes these challenges through a modular, reproducible pipeline:

1. 📄 **[Comprehensive Improvement Proposal (docs/SYSTEM_IMPROVEMENT_REPORT.md)](docs/SYSTEM_IMPROVEMENT_REPORT.md):** Formal report detailing baseline simulation metrics, root-cause analyses, mathematical derivations of travel savings, and a 6-week phased rollout roadmap.
2. 🗄️ **[Relational SQL Engine (sql/)](sql/):** Schema DDL, 1,200-order synchronized seed dataset, advanced analytical diagnostic queries (Pareto CTEs, Window Functions, joined-zone routing), and automated dynamic re-slotting views.
3. 💻 **[Conceptual .NET Architecture Review (legacy_audit/)](legacy_audit/):** Code-level audit of legacy ADO.NET patterns ($N+1$ query loops, whole-table `TABLOCKX` locks), paired with a modern asynchronous sketch featuring consistent batching and full-order atomicity.
4. 📊 **[Diagnostic Engine & Dynamic Visuals (analysis/)](analysis/):** Automated CLI tool that executes diagnostic queries and dynamically generates vector charts from the database.

---

## 🎯 Observed Simulation Baseline vs. Model Projections

The figures below distinguish between **observed simulation baseline data** and **theoretical model projections**:

| Performance Metric | Observed Simulation Baseline | Theoretical Model Projection | Derivation / Assumptions |
| :--- | :--- | :--- | :--- |
| **Average Order Cycle Time** | 101.6 minutes | **~67.2 minutes (-33.8%)** | Calculated by subtracting projected travel time savings and queue wait reduction. |
| **Average Picker Travel / Order** | 247.6 meters | **149.7 meters (-39.5%)** | $\frac{\text{Baseline Travel (297.1 km)} - \text{Relocation Savings (117.5 km)}}{1,200 \text{ orders}}$ |
| **Monthly Travel Avoided** | 0 km | **117.5 km eliminated** | $452 \text{ relocated picks} \times 2 \times (145\text{m} - 15\text{m}) = 117,520\text{ m}$. |
| **Walking Time Recovered** | 0 hours | **~32.6 picker-hours / mo** | Assumes standard picker walking speed of $1.0\text{ m/s}$ ($60\text{ m/min}$). |
| **Peak Allocation Dwell Time** | 44.5 minutes (avg peak) | **< 3.0 minutes** | Estimated by eliminating sequential network roundtrips and table lock waits. |
| **Stockout Pick Exceptions** | 19 events / month | **Target: < 3 events** | Dynamic safety stock buffers mitigate deep-storage starvation. |

---

## 🔍 Key Findings from the Simulation

### 1. The Deep Storage Travel Penalty (Physical Slotting)
* **The Root Cause:** Three top-velocity Class-A SKUs (`SKU-A001`, `SKU-A002`, `SKU-A003`) accounting for 452 picks were statically assigned to **Zone C (Deep Bulk Storage)**, 145 meters from shipping docks.
* **The Simulation Impact:** Orders requiring Zone C items averaged **418.8 meters** of picker transit and **33.3 minutes** of pick duration, compared to **88.5 meters** and **11.5 minutes** for proximity orders in Zone A/B.
* **The Optimization:** An automated SQL view (`v_slotting_swap_proposals`) pairs these fast-movers with slow-moving Class-C items occupying prime mezzanine space in Zone A.

```
Zone C Access (Deep Storage) : 418.8 m travel | 33.3 min pick duration  [19 exceptions]
Zone A/B Only (Proximity)    :  88.5 m travel | 11.5 min pick duration  [ 0 exceptions]
--> Relocation Savings       : 452 picks * 260m roundtrip = 117.5 km walking eliminated / month
```

### 2. Shift-Hour Dispatch Queueing (10:00–14:00 Surge)
* **The Root Cause:** Simulating legacy ADO.NET single-threaded batching where order waves execute sequentially with $N+1$ network roundtrips and table-level locks.
* **The Simulation Impact:** Allocation dwell time jumped from an off-peak average of 11.6 minutes to **44.5 minutes** during midday volume peaks (10:00–14:00).
* **The Modernization Sketch:** Migrates to asynchronous multi-table batch retrieval and row-level concurrency (`ROWLOCK, UPDLOCK`), preventing terminal freezes on worker RF scanners.

---

## 📁 Repository Directory Structure

```text
wms-operational-efficiency-audit/
├── README.md                      # Project master documentation & methodology overview
├── LICENSE                        # MIT Open Source License
├── requirements.txt               # Runtime environment notes (zero external dependencies)
├── docs/
│   └── SYSTEM_IMPROVEMENT_REPORT.md # Comprehensive 6-page System Improvement Proposal
├── sql/
│   ├── 01_schema.sql              # Relational schema DDL (SQLite 3 with Postgres notes)
│   ├── 02_seed_data.sql           # Complete synchronized seed dataset (4,600+ lines)
│   ├── 03_bottleneck_queries.sql  # Analytical diagnostic queries (CTEs, Window Functions, Joined Zones)
│   └── 04_optimization_procedures.sql # Dynamic slotting swap views & batch wave logic
├── legacy_audit/
│   ├── legacy_wms_data_access.vb  # Conceptual ADO.NET sketch modeling anti-patterns & refactors
│   └── VB_NET_AUDIT_REPORT.md     # Code audit report with atomicity & batching analysis
├── analysis/
│   ├── run_audit.py               # Diagnostic engine executing SQL & generating dynamic SVGs
│   └── visualizations/            # Standalone vector SVG charts generated from database
└── scripts/
    └── seed_database.py           # Synthetic dataset generator with CLI controls (--force, --orders)
```

---

## 🚀 Reproduction & Setup Guide

This project is completely self-contained with **zero external dependencies** (uses native Python 3 and SQLite3).

### 1. Clone the Repository
```bash
git clone https://github.com/KiskuAryan/wms-operational-efficiency-audit.git
cd wms-operational-efficiency-audit
```

### 2. Run the Diagnostic Engine
Execute the audit engine to run all SQL queries, recalculate facility KPIs, and generate dynamic visual charts:
```bash
python3 analysis/run_audit.py
```

### 3. (Optional) Rebuild the Database from Scratch
To regenerate the synthetic database with a fresh random seed and refresh the SQL dump:
```bash
# Explicit --force flag prevents accidental database deletion
python3 scripts/seed_database.py --force --orders 1200
```

### 4. Direct SQL Inspection
Inspect diagnostic views directly using SQLite:
```bash
# Inspect automated slotting swap recommendations:
sqlite3 wms.db "SELECT * FROM v_slotting_swap_proposals;"

# Inspect joined-zone routing variance:
sqlite3 wms.db < sql/03_bottleneck_queries.sql
```

---

## 👨‍💻 Author & Contact

**Aryan Chintaman Manjhi**  
* GitHub: [@KiskuAryan](https://github.com/KiskuAryan)  
* Focus: Supply Chain Analytics, Relational Database Engineering & Query Optimization  
* Context: Developed as an illustrative WMS optimization case study demonstrating analytical audit methodology and operational improvement proposals.
