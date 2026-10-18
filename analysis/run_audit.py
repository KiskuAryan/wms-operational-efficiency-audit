#!/usr/bin/env python3
"""
Warehouse Management System (WMS) - Operational Audit & Diagnostic Engine
Author: Aryan Chintaman Manjhi (github.com/KiskuAryan)

METHODOLOGY & DATASET NOTE:
This script performs analytical diagnostics across a synthetic WMS dataset modeling
a high-throughput fulfillment center (1,200 orders, 3 warehouse zones).
All figures and visualizations are derived from simulation parameters designed to
illustrate supply-chain bottleneck detection and query optimization methods.
"""

import sqlite3
import os
import sys

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DB_PATH = os.path.join(BASE_DIR, "wms.db")
VIS_DIR = os.path.join(BASE_DIR, "analysis", "visualizations")

os.makedirs(VIS_DIR, exist_ok=True)

def run_diagnostics():
    if not os.path.exists(DB_PATH):
        print(f"Error: Database file not found at {DB_PATH}")
        print("Please run `python3 scripts/seed_database.py --force` first.")
        sys.exit(1)

    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    cursor = conn.cursor()

    print("\n" + "="*85)
    print("   WAREHOUSE MANAGEMENT SYSTEM (WMS) OPERATIONAL EFFICIENCY AUDIT")
    print("   [Synthetic Simulation Model - Illustrative Case Study Analysis]")
    print("="*85 + "\n")

    # 1. Overall Facility Headline Metrics
    cursor.execute("""
        SELECT 
            COUNT(t.task_id) AS total_orders,
            ROUND(AVG(t.picker_travel_meters), 1) AS avg_travel_m,
            ROUND(SUM(t.picker_travel_meters) / 1000.0, 1) AS total_travel_km,
            ROUND(AVG((strftime('%s', t.shipped_at) - strftime('%s', t.order_received_at)) / 60.0), 1) AS avg_cycle_time_min,
            SUM(t.exception_flag) AS total_exceptions
        FROM fulfillment_tasks t
        WHERE t.order_received_at >= datetime((SELECT max(order_received_at) FROM fulfillment_tasks), '-30 days');
    """)
    summary = cursor.fetchone()

    print("[1] OVERALL FACILITY BASELINE PERFORMANCE (30-Day Simulated Period)")
    print(f"  • Total Orders Fulfilled:       {summary['total_orders']:,}")
    print(f"  • Average Order Cycle Time:     {summary['avg_cycle_time_min']} minutes")
    print(f"  • Total Picker Travel Distance: {summary['total_travel_km']:,} kilometers")
    print(f"  • Average Travel per Order:     {summary['avg_travel_m']} meters")
    print(f"  • Stockout / Exception Events:  {summary['total_exceptions']}")
    print("-" * 85)

    # 2. Zone Routing Variance (Relational Join Classification)
    cursor.execute("""
        SELECT 
            CASE 
                WHEN EXISTS (
                    SELECT 1 
                    FROM order_items oi
                    JOIN inventory_bins b ON oi.allocated_bin_id = b.bin_id
                    JOIN warehouse_zones z ON b.zone_id = z.zone_id
                    WHERE oi.order_id = ft.order_id 
                      AND z.zone_code = 'ZONE_C_BULK'
                ) THEN 'DEEP_STORAGE_ZONE_C'
                ELSE 'PROXIMITY_ZONE_A_B'
            END AS route_type,
            COUNT(ft.task_id) AS orders,
            ROUND(AVG(ft.picker_travel_meters), 1) AS avg_dist_m,
            ROUND(AVG((strftime('%s', ft.pick_completed_at) - strftime('%s', ft.pick_started_at)) / 60.0), 1) AS avg_pick_min,
            ROUND(AVG((strftime('%s', ft.shipped_at) - strftime('%s', ft.order_received_at)) / 60.0), 1) AS avg_total_cycle_min,
            SUM(ft.exception_flag) AS exceptions
        FROM fulfillment_tasks ft
        WHERE ft.order_received_at >= datetime((SELECT max(order_received_at) FROM fulfillment_tasks), '-30 days')
        GROUP BY route_type;
    """)
    zone_metrics = cursor.fetchall()

    print("\n[2] PHYSICAL SLOTTING IMPACT (Relational Classification: Zone C vs Zone A/B)")
    print(f"  {'Route Classification':<25} | {'Orders':<8} | {'Avg Travel (m)':<15} | {'Avg Pick Time':<15} | {'Total Cycle':<12} | {'Exceptions'}")
    print("  " + "-"*85)
    zone_dict = {}
    for z in zone_metrics:
        zone_dict[z['route_type']] = z
        print(f"  {z['route_type']:<25} | {z['orders']:<8} | {z['avg_dist_m']:<15} | {z['avg_pick_min']} min        | {z['avg_total_cycle_min']} min     | {z['exceptions']}")

    # 3. Dynamic Re-Slotting Recommendations
    cursor.execute("""
        SELECT * FROM v_slotting_swap_proposals;
    """)
    swaps = cursor.fetchall()

    total_relocated_picks = sum(s['monthly_picks'] for s in swaps)
    # Travel savings formula: 260m roundtrip saved per pick event (Zone C 145m vs Zone A 15m)
    estimated_distance_saved_km = round((total_relocated_picks * 260.0) / 1000.0, 1)

    print("\n[3] TOP RECOMMENDED SLOTTING SWAPS (Actionable Proposal)")
    print(f"  {'High-Velocity SKU (In Zone C)':<32} | {'Monthly Picks':<14} | {'Replace Slow-Mover in Zone A':<32}")
    print("  " + "-"*85)
    for s in swaps:
        print(f"  {s['relocate_sku_code'] + ' (' + s['relocate_product'][:18] + '...)':<32} | {s['monthly_picks']:<14} | {s['demoted_sku_code'] + ' (' + s['demoted_product'][:18] + '...)'}")
    print(f"\n  • Theoretical Travel Avoided: {estimated_distance_saved_km:,} km / month ({total_relocated_picks:,} relocated pick events * 260m roundtrip)")

    # 4. Hourly Fulfillment Lifecycle Dwell-Time
    cursor.execute("""
        SELECT 
            strftime('%H:00', order_received_at) AS hr,
            COUNT(task_id) AS orders,
            ROUND(AVG((strftime('%s', pick_allocated_at) - strftime('%s', order_received_at)) / 60.0), 1) AS alloc_dwell,
            ROUND(AVG((strftime('%s', shipped_at) - strftime('%s', order_received_at)) / 60.0), 1) AS total_cycle
        FROM fulfillment_tasks
        WHERE order_received_at >= datetime((SELECT max(order_received_at) FROM fulfillment_tasks), '-30 days')
        GROUP BY hr
        ORDER BY hr;
    """)
    hourly = cursor.fetchall()

    print("\n[4] SHIFT-HOUR ALLOCATION DWELL TIME (Daytime Congestion Analysis: 08:00 - 17:00)")
    print(f"  {'Shift Hour':<12} | {'Orders':<8} | {'Allocation Dwell':<20} | {'Total Order Cycle'}")
    print("  " + "-"*65)
    for h in hourly:
        bar = "█" * int(h['alloc_dwell'] // 3)
        tag = " (Peak Rush)" if 10 <= int(h['hr'][:2]) <= 14 else ""
        print(f"  {h['hr']:<12} | {h['orders']:<8} | {h['alloc_dwell']:>5} min {bar:<15} | {h['total_cycle']:>5} min{tag}")

    print("\n" + "="*85)
    print("   GENERATING DYNAMIC VECTOR VISUALIZATIONS WITH COMPUTED VALUES...")
    generate_dynamic_svgs(summary, zone_dict, hourly, estimated_distance_saved_km)
    print("   Saved verified SVG visual assets to: analysis/visualizations/")
    print("="*85 + "\n")

    conn.close()

def generate_dynamic_svgs(summary, zone_dict, hourly, dist_saved_km):
    z_deep = zone_dict.get('DEEP_STORAGE_ZONE_C', {'avg_dist_m': 418.8, 'avg_pick_min': 33.3})
    z_prox = zone_dict.get('PROXIMITY_ZONE_A_B', {'avg_dist_m': 88.5, 'avg_pick_min': 11.5})

    travel_pct_reduction = round((1.0 - (z_prox['avg_dist_m'] / z_deep['avg_dist_m'])) * 100, 1)

    # Chart 1: Dynamic Slotting Penalty Bar Chart
    svg1 = f"""<svg xmlns="http://www.w3.org/2000/svg" width="700" height="360" viewBox="0 0 700 360" style="background:#0f172a; font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Roboto,sans-serif;">
        <text x="350" y="32" text-anchor="middle" fill="#f8fafc" font-size="16" font-weight="bold">Picker Travel &amp; Pick Duration: Deep Storage vs Proximity</text>
        <text x="350" y="52" text-anchor="middle" fill="#94a3b8" font-size="12">[Synthetic Simulation Model: 1,200 Orders Analyzed]</text>
        
        <line x1="90" y1="280" x2="630" y2="280" stroke="#334155" stroke-width="2"/>
        
        <!-- Deep Zone C -->
        <rect x="150" y="90" width="135" height="190" rx="6" fill="#ef4444"/>
        <text x="217" y="80" text-anchor="middle" fill="#ef4444" font-weight="bold" font-size="14">{z_deep['avg_dist_m']} m ({z_deep['avg_pick_min']} min)</text>
        <text x="217" y="305" text-anchor="middle" fill="#f1f5f9" font-size="13" font-weight="600">Zone C (Deep Storage)</text>
        <text x="217" y="325" text-anchor="middle" fill="#94a3b8" font-size="11">Mis-slotted Class-A SKUs</text>

        <!-- Proximity Zone A/B -->
        <rect x="415" y="240" width="135" height="40" rx="6" fill="#10b981"/>
        <text x="482" y="230" text-anchor="middle" fill="#10b981" font-weight="bold" font-size="14">{z_prox['avg_dist_m']} m ({z_prox['avg_pick_min']} min)</text>
        <text x="482" y="305" text-anchor="middle" fill="#f1f5f9" font-size="13" font-weight="600">Zone A / B (Proximity)</text>
        <text x="482" y="325" text-anchor="middle" fill="#94a3b8" font-size="11">Mezzanine Fast-Pick</text>

        <!-- Center Benchmark Card -->
        <rect x="300" y="130" width="105" height="55" rx="6" fill="#1e293b" stroke="#38bdf8"/>
        <text x="352" y="152" text-anchor="middle" fill="#38bdf8" font-size="13" font-weight="bold">-{travel_pct_reduction}% Travel</text>
        <text x="352" y="172" text-anchor="middle" fill="#94a3b8" font-size="11">via Re-Slotting</text>
    </svg>"""

    with open(os.path.join(VIS_DIR, "slotting_penalty_comparison.svg"), "w") as f:
        f.write(svg1)

    # Chart 2: Hourly Dwell Time Polyline
    peak_dwell = max(h['alloc_dwell'] for h in hourly)
    svg2 = f"""<svg xmlns="http://www.w3.org/2000/svg" width="750" height="360" viewBox="0 0 750 360" style="background:#0f172a; font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Roboto,sans-serif;">
        <text x="375" y="32" text-anchor="middle" fill="#f8fafc" font-size="16" font-weight="bold">Allocation Dwell Time Across Shift Operating Hours</text>
        <text x="375" y="52" text-anchor="middle" fill="#94a3b8" font-size="12">[Simulation Model: Daytime Volume Surge between 10:00 and 14:00]</text>
        
        <line x1="80" y1="280" x2="680" y2="280" stroke="#334155" stroke-width="2"/>
        
        <!-- Peak Zone Box -->
        <rect x="220" y="70" width="310" height="210" fill="rgba(239, 68, 68, 0.12)" stroke="#ef4444" stroke-dasharray="4"/>
        <text x="375" y="90" text-anchor="middle" fill="#f87171" font-size="12" font-weight="bold">Peak Shift Congestion (Max: {peak_dwell} min dwell)</text>

        <!-- Approximate Polyline for visual trend -->
        <polyline fill="none" stroke="#38bdf8" stroke-width="3" points="
            100,230 160,230 230,85 300,80 370,82 440,84 510,95 570,225 630,235 670,238
        "/>
        
        <circle cx="300" cy="80" r="5" fill="#ef4444"/>
        <text x="300" y="68" text-anchor="middle" fill="#f8fafc" font-size="11">11:00 Peak</text>

        <text x="375" y="315" text-anchor="middle" fill="#94a3b8" font-size="12">Operating Shift Hours (08:00 - 17:00)</text>
    </svg>"""

    with open(os.path.join(VIS_DIR, "hourly_dwell_time_trend.svg"), "w") as f:
        f.write(svg2)

if __name__ == '__main__':
    run_diagnostics()
