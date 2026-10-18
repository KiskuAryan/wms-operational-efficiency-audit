-- ==============================================================================
-- Warehouse Management System (WMS) - Operational Optimization Logic
-- Views, Stored Routines & Dynamic Re-Slotting Logic
-- Dialect: SQLite 3 (PostgreSQL equivalents noted where applicable)
-- Author: Aryan Chintaman Manjhi (github.com/KiskuAryan)
-- ==============================================================================

-- ------------------------------------------------------------------------------
-- 1. VIEW: Automated SKU Velocity Recalculation (Rolling 30-Day Window)
-- Dynamically calculates SKU velocity from recent orders with explicit date filtering.
-- ------------------------------------------------------------------------------
DROP VIEW IF EXISTS v_sku_rolling_velocity;
CREATE VIEW v_sku_rolling_velocity AS
WITH pick_summary AS (
    SELECT 
        oi.sku_id,
        p.sku_code,
        p.product_name,
        COUNT(oi.item_id) AS total_picks_30d,
        SUM(oi.requested_qty) AS units_demanded_30d
    FROM order_items oi
    JOIN orders o ON oi.order_id = o.order_id
    JOIN products_sku p ON oi.sku_id = p.sku_id
    WHERE o.order_timestamp >= datetime((SELECT max(order_timestamp) FROM orders), '-30 days')
    GROUP BY oi.sku_id, p.sku_code, p.product_name
),
cumulative_calc AS (
    SELECT 
        sku_id,
        sku_code,
        product_name,
        total_picks_30d,
        units_demanded_30d,
        ROUND(100.0 * total_picks_30d / SUM(total_picks_30d) OVER (), 2) AS pick_share_pct,
        ROUND(100.0 * SUM(total_picks_30d) OVER (ORDER BY total_picks_30d DESC) 
              / SUM(total_picks_30d) OVER (), 2) AS cumulative_share_pct
    FROM pick_summary
)
SELECT 
    sku_id,
    sku_code,
    product_name,
    total_picks_30d,
    units_demanded_30d,
    pick_share_pct,
    cumulative_share_pct,
    CASE 
        WHEN cumulative_share_pct <= 75.0 THEN 'A'
        WHEN cumulative_share_pct <= 90.0 THEN 'B'
        ELSE 'C'
    END AS dynamic_abc_class
FROM cumulative_calc;


-- ------------------------------------------------------------------------------
-- 2. VIEW: Dynamic Re-Slotting Swap Recommendations
-- Pairs high-velocity Class-A SKUs trapped in Zone C with 
-- low-velocity Class-C SKUs occupying prime Zone A mezzanine slots.
-- ------------------------------------------------------------------------------
DROP VIEW IF EXISTS v_slotting_swap_proposals;
CREATE VIEW v_slotting_swap_proposals AS
WITH misallocated_fast_movers AS (
    SELECT 
        v.sku_id AS fast_sku_id,
        v.sku_code AS fast_sku_code,
        v.product_name AS fast_product_name,
        v.total_picks_30d AS fast_picks,
        b.bin_id AS current_deep_bin_id,
        b.bin_code AS current_deep_bin_code,
        ROW_NUMBER() OVER (ORDER BY v.total_picks_30d DESC) AS priority_rank
    FROM v_sku_rolling_velocity v
    JOIN inventory_bins b ON v.sku_id = b.current_sku_id
    JOIN warehouse_zones z ON b.zone_id = z.zone_id
    WHERE v.dynamic_abc_class = 'A' AND z.zone_code = 'ZONE_C_BULK'
),
misallocated_slow_movers AS (
    SELECT 
        v.sku_id AS slow_sku_id,
        v.sku_code AS slow_sku_code,
        v.product_name AS slow_product_name,
        v.total_picks_30d AS slow_picks,
        b.bin_id AS prime_bin_id,
        b.bin_code AS prime_bin_code,
        ROW_NUMBER() OVER (ORDER BY v.total_picks_30d ASC) AS priority_rank
    FROM v_sku_rolling_velocity v
    JOIN inventory_bins b ON v.sku_id = b.current_sku_id
    JOIN warehouse_zones z ON b.zone_id = z.zone_id
    WHERE v.dynamic_abc_class = 'C' AND z.zone_code = 'ZONE_A_FASTPICK'
)
SELECT 
    f.priority_rank,
    f.fast_sku_code AS relocate_sku_code,
    f.fast_product_name AS relocate_product,
    f.fast_picks AS monthly_picks,
    f.current_deep_bin_code AS source_bin_zone_c,
    s.prime_bin_code AS target_bin_zone_a,
    s.slow_sku_code AS demoted_sku_code,
    s.slow_product_name AS demoted_product,
    'ESTIMATED TRAVEL SAVINGS: ~260m roundtrip per pick event' AS projected_impact_note
FROM misallocated_fast_movers f
JOIN misallocated_slow_movers s ON f.priority_rank = s.priority_rank;


-- ------------------------------------------------------------------------------
-- 3. VIEW: Batch Wave-Picking Aggregation
-- Aggregates discrete pending orders into unified picking waves
-- (Note: In PostgreSQL, replace GROUP_CONCAT with STRING_AGG(o.order_number, ', '))
-- ------------------------------------------------------------------------------
DROP VIEW IF EXISTS v_wave_picking_batches;
CREATE VIEW v_wave_picking_batches AS
SELECT 
    b.zone_id,
    z.zone_name,
    b.aisle_num,
    p.sku_code,
    p.product_name,
    COUNT(DISTINCT oi.order_id) AS orders_consolidated_in_wave,
    SUM(oi.requested_qty) AS total_batch_quantity_to_pick,
    GROUP_CONCAT(o.order_number, ', ') AS order_manifest_list
FROM order_items oi
JOIN orders o ON oi.order_id = o.order_id
JOIN products_sku p ON oi.sku_id = p.sku_id
JOIN inventory_bins b ON oi.allocated_bin_id = b.bin_id
JOIN warehouse_zones z ON b.zone_id = z.zone_id
WHERE o.status = 'PENDING'
GROUP BY b.zone_id, z.zone_name, b.aisle_num, p.sku_code, p.product_name
HAVING COUNT(DISTINCT oi.order_id) > 1
ORDER BY b.zone_id, b.aisle_num;
