-- ==============================================================================
-- Warehouse Management System (WMS) - Operational Bottleneck Analysis
-- Dialect: ANSI SQL / SQLite / PostgreSQL compatible
-- Author: Aryan Chintaman Manjhi (github.com/KiskuAryan)
-- ==============================================================================

-- ------------------------------------------------------------------------------
-- QUERY 1: Pareto ABC Velocity vs. Physical Slotting Mismatch
-- Objective: Identify high-velocity Class-A SKUs stored in deep bulk storage (Zone C)
-- Key SQL concepts: CTEs, Window Functions (SUM OVER), Conditional CASE expressions
-- ------------------------------------------------------------------------------
WITH sku_pick_metrics AS (
    SELECT 
        oi.sku_id,
        p.sku_code,
        p.product_name,
        p.target_abc_class AS nominal_abc,
        z.zone_code,
        z.zone_name,
        z.distance_to_dock_meters,
        COUNT(oi.item_id) AS total_pick_events,
        SUM(oi.requested_qty) AS total_units_picked
    FROM order_items oi
    JOIN products_sku p ON oi.sku_id = p.sku_id
    JOIN inventory_bins b ON oi.allocated_bin_id = b.bin_id
    JOIN warehouse_zones z ON b.zone_id = z.zone_id
    GROUP BY oi.sku_id, p.sku_code, p.product_name, p.target_abc_class, z.zone_code, z.zone_name, z.distance_to_dock_meters
),
pareto_ranking AS (
    SELECT 
        sku_id,
        sku_code,
        product_name,
        nominal_abc,
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
    nominal_abc,
    zone_code,
    distance_to_dock_meters,
    total_pick_events,
    pick_share_pct,
    cumulative_share_pct,
    CASE 
        WHEN cumulative_share_pct <= 70.0 THEN 'CLASS_A_FAST_MOVER'
        WHEN cumulative_share_pct <= 90.0 THEN 'CLASS_B_MEDIUM_MOVER'
        ELSE 'CLASS_C_SLOW_MOVER'
    END AS actual_velocity_class,
    CASE 
        WHEN cumulative_share_pct <= 70.0 AND zone_code = 'ZONE_C_BULK' 
            THEN 'CRITICAL BOTTLENECK: Move to Zone A (Mezzanine)'
        WHEN cumulative_share_pct > 90.0 AND zone_code = 'ZONE_A_FASTPICK' 
            THEN 'INEFFICIENT: Demote to Zone C (Frees prime space)'
        ELSE 'OPTIMALLY_SLOTTED'
    END AS slotting_recommendation
FROM pareto_ranking
ORDER BY total_pick_events DESC;


-- ------------------------------------------------------------------------------
-- QUERY 2: Order Fulfillment Stage Dwell-Time & Hourly Congestion Analysis
-- Objective: Pinpoint which fulfillment phase creates the primary delay
-- Key SQL concepts: Timestamp arithmetic, Hourly bucketing, Multi-stage latency breakdown
-- ------------------------------------------------------------------------------
SELECT 
    strftime('%H:00', order_received_at) AS order_hour_bucket,
    COUNT(task_id) AS total_orders,
    ROUND(AVG((strftime('%s', pick_allocated_at) - strftime('%s', order_received_at)) / 60.0), 1) AS avg_allocation_dwell_min,
    ROUND(AVG((strftime('%s', pick_completed_at) - strftime('%s', pick_started_at)) / 60.0), 1) AS avg_pick_transit_duration_min,
    ROUND(AVG((strftime('%s', pack_completed_at) - strftime('%s', pick_completed_at)) / 60.0), 1) AS avg_packing_duration_min,
    ROUND(AVG((strftime('%s', shipped_at) - strftime('%s', pack_completed_at)) / 60.0), 1) AS avg_dock_staging_duration_min,
    ROUND(AVG((strftime('%s', shipped_at) - strftime('%s', order_received_at)) / 60.0), 1) AS avg_total_cycle_time_min
FROM fulfillment_tasks
GROUP BY strftime('%H:00', order_received_at)
ORDER BY order_hour_bucket ASC;


-- ------------------------------------------------------------------------------
-- QUERY 3: Picker Travel Distance & Ergonomic Workload Impact
-- Objective: Calculate the travel penalty of Zone C picks vs Zone A picks
-- Key SQL concepts: Conditional Aggregation, Efficiency Indexing
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
GROUP BY assigned_picker_id
ORDER BY total_travel_meters DESC;


-- ------------------------------------------------------------------------------
-- QUERY 4: Zone Congestion and Travel Distance Variance Analysis
-- Objective: Quantify travel and time penalty specifically attributable to Zone C
-- ------------------------------------------------------------------------------
SELECT 
    CASE 
        WHEN picker_travel_meters > 250 THEN 'DEEP_STORAGE_ACCESS (Zone C Involved)'
        ELSE 'PROXIMITY_PICK (Zone A/B Only)'
    END AS pick_routing_category,
    COUNT(task_id) AS order_count,
    ROUND(AVG(picker_travel_meters), 1) AS avg_travel_meters,
    ROUND(AVG((strftime('%s', pick_completed_at) - strftime('%s', pick_started_at)) / 60.0), 1) AS avg_pick_duration_min,
    ROUND(AVG((strftime('%s', shipped_at) - strftime('%s', order_received_at)) / 60.0), 1) AS avg_total_cycle_time_min,
    SUM(exception_flag) AS total_stockout_exceptions
FROM fulfillment_tasks
GROUP BY 
    CASE 
        WHEN picker_travel_meters > 250 THEN 'DEEP_STORAGE_ACCESS (Zone C Involved)'
        ELSE 'PROXIMITY_PICK (Zone A/B Only)'
    END;
