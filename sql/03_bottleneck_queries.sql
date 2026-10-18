-- ==============================================================================
-- Warehouse Management System (WMS) - Operational Bottleneck Analysis
-- Dialect: SQLite 3
-- (Notes: SQLite datetime functions 'strftime' are used here. For PostgreSQL,
--  use 'to_char()', 'EXTRACT(EPOCH FROM ...)', and 'INTERVAL' syntax.)
-- Author: Aryan Chintaman Manjhi (github.com/KiskuAryan)
-- ==============================================================================

-- ------------------------------------------------------------------------------
-- QUERY 1: Pareto ABC Velocity vs. Physical Storage Slotting
-- Objective: Identify high-velocity Class-A SKUs stored in deep bulk storage (Zone C)
-- SQL Techniques: CTEs, Window Functions (SUM OVER), Conditional CASE expressions
-- Methodology:
--   Pareto 80/20 Classification:
--   - Class A (Fast Movers): Top 75% of cumulative warehouse pick events
--   - Class B (Medium Movers): Next 15% (75% to 90% cumulative share)
--   - Class C (Slow Movers): Remaining 10% (90% to 100% cumulative share)
-- ------------------------------------------------------------------------------
WITH sku_pick_metrics AS (
    SELECT 
        oi.sku_id,
        p.sku_code,
        p.product_name,
        p.target_abc_class AS catalog_abc,
        z.zone_code,
        z.zone_name,
        z.distance_to_dock_meters,
        COUNT(oi.item_id) AS total_pick_events,
        SUM(oi.requested_qty) AS total_units_picked
    FROM order_items oi
    JOIN orders o ON oi.order_id = o.order_id
    JOIN products_sku p ON oi.sku_id = p.sku_id
    JOIN inventory_bins b ON oi.allocated_bin_id = b.bin_id
    JOIN warehouse_zones z ON b.zone_id = z.zone_id
    WHERE o.order_timestamp >= datetime((SELECT max(order_timestamp) FROM orders), '-30 days')
    GROUP BY oi.sku_id, p.sku_code, p.product_name, p.target_abc_class, z.zone_code, z.zone_name, z.distance_to_dock_meters
),
pareto_ranking AS (
    SELECT 
        sku_id,
        sku_code,
        product_name,
        catalog_abc,
        zone_code,
        distance_to_dock_meters,
        total_pick_events,
        total_units_picked,
        ROUND(100.0 * total_pick_events / SUM(total_pick_events) OVER (), 2) AS pick_share_pct,
        ROUND(100.0 * SUM(total_pick_events) OVER (ORDER BY total_pick_events DESC ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) 
              / SUM(total_pick_events) OVER (), 2) AS cumulative_share_pct
    FROM sku_pick_metrics
)
SELECT 
    sku_code,
    product_name,
    catalog_abc,
    zone_code,
    distance_to_dock_meters,
    total_pick_events,
    pick_share_pct,
    cumulative_share_pct,
    CASE 
        WHEN cumulative_share_pct <= 80.0 THEN 'CLASS_A_FAST_MOVER'
        WHEN cumulative_share_pct <= 95.0 THEN 'CLASS_B_MEDIUM_MOVER'
        ELSE 'CLASS_C_SLOW_MOVER'
    END AS actual_velocity_class,
    CASE 
        WHEN cumulative_share_pct <= 80.0 AND zone_code = 'ZONE_C_BULK' 
            THEN 'SUB-OPTIMAL: High-frequency SKU in Deep Bulk Storage'
        WHEN cumulative_share_pct > 95.0 AND zone_code = 'ZONE_A_FASTPICK' 
            THEN 'SUB-OPTIMAL: Low-frequency SKU blocking Mezzanine Fast-Pick'
        ELSE 'OPTIMALLY_SLOTTED'
    END AS slotting_audit_flag
FROM pareto_ranking
ORDER BY total_pick_events DESC;


-- ------------------------------------------------------------------------------
-- QUERY 2: Fulfillment Lifecycle Dwell-Time & Hourly Congestion Analysis
-- Objective: Pinpoint stage latency spikes across shift operating hours
-- Date Filter: Explicit 30-day simulation window
-- ------------------------------------------------------------------------------
SELECT 
    strftime('%H:00', order_received_at) AS shift_hour_bucket,
    COUNT(task_id) AS orders_processed,
    ROUND(AVG((strftime('%s', pick_allocated_at) - strftime('%s', order_received_at)) / 60.0), 1) AS avg_allocation_dwell_min,
    ROUND(AVG((strftime('%s', pick_completed_at) - strftime('%s', pick_started_at)) / 60.0), 1) AS avg_pick_transit_duration_min,
    ROUND(AVG((strftime('%s', pack_completed_at) - strftime('%s', pick_completed_at)) / 60.0), 1) AS avg_packing_duration_min,
    ROUND(AVG((strftime('%s', shipped_at) - strftime('%s', pack_completed_at)) / 60.0), 1) AS avg_dock_staging_duration_min,
    ROUND(AVG((strftime('%s', shipped_at) - strftime('%s', order_received_at)) / 60.0), 1) AS avg_total_cycle_time_min
FROM fulfillment_tasks
WHERE order_received_at >= datetime((SELECT max(order_received_at) FROM fulfillment_tasks), '-30 days')
GROUP BY strftime('%H:00', order_received_at)
ORDER BY shift_hour_bucket ASC;


-- ------------------------------------------------------------------------------
-- QUERY 3: Picker Travel Workload & Exception Rates
-- Objective: Quantify picker transit load and verify exception frequencies
-- ------------------------------------------------------------------------------
SELECT 
    assigned_picker_id,
    COUNT(task_id) AS completed_tasks,
    SUM(picker_travel_meters) AS total_travel_meters,
    ROUND(AVG(picker_travel_meters), 1) AS avg_meters_per_order,
    ROUND(SUM(picker_travel_meters) / 1000.0, 2) AS total_travel_kilometers,
    SUM(exception_flag) AS recorded_exceptions,
    ROUND(100.0 * SUM(exception_flag) / COUNT(task_id), 2) AS exception_rate_pct
FROM fulfillment_tasks
WHERE order_received_at >= datetime((SELECT max(order_received_at) FROM fulfillment_tasks), '-30 days')
GROUP BY assigned_picker_id
ORDER BY total_travel_meters DESC;


-- ------------------------------------------------------------------------------
-- QUERY 4: Zone Routing Variance Analysis (Relational Join Classification)
-- Objective: Compare orders requiring Deep Storage (Zone C) vs Proximity (Zone A/B)
-- Rigorous Relational Logic: Classifies orders via joined inventory bins, not travel distance
-- ------------------------------------------------------------------------------
SELECT 
    CASE 
        WHEN EXISTS (
            SELECT 1 
            FROM order_items oi
            JOIN inventory_bins b ON oi.allocated_bin_id = b.bin_id
            JOIN warehouse_zones z ON b.zone_id = z.zone_id
            WHERE oi.order_id = ft.order_id 
              AND z.zone_code = 'ZONE_C_BULK'
        ) THEN 'DEEP_STORAGE_ACCESS (Zone C Involved)'
        ELSE 'PROXIMITY_PICK (Zone A/B Only)'
    END AS pick_routing_category,
    COUNT(ft.task_id) AS order_count,
    ROUND(AVG(ft.picker_travel_meters), 1) AS avg_travel_meters,
    ROUND(AVG((strftime('%s', ft.pick_completed_at) - strftime('%s', ft.pick_started_at)) / 60.0), 1) AS avg_pick_duration_min,
    ROUND(AVG((strftime('%s', ft.shipped_at) - strftime('%s', ft.order_received_at)) / 60.0), 1) AS avg_total_cycle_time_min,
    SUM(ft.exception_flag) AS total_stockout_exceptions
FROM fulfillment_tasks ft
WHERE ft.order_received_at >= datetime((SELECT max(order_received_at) FROM fulfillment_tasks), '-30 days')
GROUP BY pick_routing_category;
