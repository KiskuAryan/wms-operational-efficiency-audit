-- ==============================================================================
-- Warehouse Management System (WMS) - Core Relational Schema
-- Dialect: SQLite 3
-- Author: Aryan Chintaman Manjhi (github.com/KiskuAryan)
--
-- Notes on portability:
-- - Uses SQLite PRAGMA, AUTOINCREMENT, and strftime datetime conventions.
-- - For PostgreSQL: replace AUTOINCREMENT with SERIAL/BIGSERIAL, and PRAGMA with
--   standard DDL alter table constraints.
-- ==============================================================================

PRAGMA foreign_keys = ON;

-- 1. Warehouses Master
CREATE TABLE IF NOT EXISTS warehouses (
    warehouse_id INTEGER PRIMARY KEY AUTOINCREMENT,
    warehouse_code VARCHAR(20) NOT NULL UNIQUE,
    name VARCHAR(100) NOT NULL,
    location_city VARCHAR(100) NOT NULL,
    total_capacity_sqm DECIMAL(10,2) NOT NULL CHECK (total_capacity_sqm > 0),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- 2. Physical Warehouse Storage Zones
CREATE TABLE IF NOT EXISTS warehouse_zones (
    zone_id INTEGER PRIMARY KEY AUTOINCREMENT,
    warehouse_id INTEGER NOT NULL,
    zone_code VARCHAR(30) NOT NULL UNIQUE,
    zone_name VARCHAR(100) NOT NULL,
    distance_to_dock_meters INTEGER NOT NULL CHECK (distance_to_dock_meters >= 0),
    handling_type VARCHAR(50) DEFAULT 'STANDARD',
    FOREIGN KEY (warehouse_id) REFERENCES warehouses(warehouse_id)
);

-- 3. SKU / Product Catalog
CREATE TABLE IF NOT EXISTS products_sku (
    sku_id INTEGER PRIMARY KEY AUTOINCREMENT,
    sku_code VARCHAR(30) NOT NULL UNIQUE,
    product_name VARCHAR(150) NOT NULL,
    category VARCHAR(50) NOT NULL,
    unit_weight_kg DECIMAL(6,2) NOT NULL CHECK (unit_weight_kg > 0),
    target_abc_class CHAR(1) NOT NULL CHECK (target_abc_class IN ('A', 'B', 'C')),
    unit_price_jpy INTEGER NOT NULL CHECK (unit_price_jpy >= 0),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- 4. Storage Bins & Current Stock Levels
CREATE TABLE IF NOT EXISTS inventory_bins (
    bin_id INTEGER PRIMARY KEY AUTOINCREMENT,
    warehouse_id INTEGER NOT NULL,
    zone_id INTEGER NOT NULL,
    bin_code VARCHAR(30) NOT NULL UNIQUE,
    aisle_num INTEGER NOT NULL CHECK (aisle_num > 0),
    rack_num INTEGER NOT NULL CHECK (rack_num > 0),
    shelf_level INTEGER NOT NULL CHECK (shelf_level > 0),
    current_sku_id INTEGER,
    current_qty INTEGER NOT NULL DEFAULT 0 CHECK (current_qty >= 0),
    max_capacity_qty INTEGER NOT NULL CHECK (max_capacity_qty > 0),
    safety_stock_qty INTEGER NOT NULL DEFAULT 10 CHECK (safety_stock_qty >= 0),
    last_replenished_at TIMESTAMP,
    CHECK (current_qty <= max_capacity_qty),
    FOREIGN KEY (warehouse_id) REFERENCES warehouses(warehouse_id),
    FOREIGN KEY (zone_id) REFERENCES warehouse_zones(zone_id),
    FOREIGN KEY (current_sku_id) REFERENCES products_sku(sku_id)
);

-- 5. Customer Fulfillment Orders
CREATE TABLE IF NOT EXISTS orders (
    order_id INTEGER PRIMARY KEY AUTOINCREMENT,
    order_number VARCHAR(50) NOT NULL UNIQUE,
    customer_id VARCHAR(50) NOT NULL,
    order_timestamp TIMESTAMP NOT NULL,
    priority_level VARCHAR(20) NOT NULL CHECK (priority_level IN ('STANDARD', 'EXPRESS', 'SAME_DAY')),
    status VARCHAR(30) NOT NULL CHECK (status IN ('PENDING', 'ALLOCATED', 'PICKING', 'PACKED', 'SHIPPED', 'CANCELLED')),
    destination_prefecture VARCHAR(50) NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- 6. Order Line Items
CREATE TABLE IF NOT EXISTS order_items (
    item_id INTEGER PRIMARY KEY AUTOINCREMENT,
    order_id INTEGER NOT NULL,
    sku_id INTEGER NOT NULL,
    requested_qty INTEGER NOT NULL CHECK (requested_qty > 0),
    allocated_bin_id INTEGER,
    fulfilled_qty INTEGER DEFAULT 0 CHECK (fulfilled_qty >= 0),
    unit_price_jpy INTEGER NOT NULL CHECK (unit_price_jpy >= 0),
    CHECK (fulfilled_qty <= requested_qty),
    FOREIGN KEY (order_id) REFERENCES orders(order_id),
    FOREIGN KEY (sku_id) REFERENCES products_sku(sku_id),
    FOREIGN KEY (allocated_bin_id) REFERENCES inventory_bins(bin_id)
);

-- 7. Fulfillment Execution & Timing Logs
CREATE TABLE IF NOT EXISTS fulfillment_tasks (
    task_id INTEGER PRIMARY KEY AUTOINCREMENT,
    order_id INTEGER NOT NULL UNIQUE,
    assigned_picker_id VARCHAR(30) NOT NULL,
    order_received_at TIMESTAMP NOT NULL,
    pick_allocated_at TIMESTAMP NOT NULL,
    pick_started_at TIMESTAMP NOT NULL,
    pick_completed_at TIMESTAMP NOT NULL,
    pack_completed_at TIMESTAMP NOT NULL,
    shipped_at TIMESTAMP NOT NULL,
    picker_travel_meters INTEGER NOT NULL CHECK (picker_travel_meters >= 0),
    picking_method VARCHAR(30) DEFAULT 'SINGLE_ORDER_DISCRETE',
    exception_flag INTEGER DEFAULT 0 CHECK (exception_flag IN (0, 1)),
    FOREIGN KEY (order_id) REFERENCES orders(order_id)
);

-- ==============================================================================
-- Performance Indexes for Operational Queries
-- ==============================================================================
CREATE INDEX IF NOT EXISTS idx_inventory_sku ON inventory_bins(current_sku_id);
CREATE INDEX IF NOT EXISTS idx_inventory_zone ON inventory_bins(zone_id);
CREATE INDEX IF NOT EXISTS idx_orders_status_timestamp ON orders(status, order_timestamp);
CREATE INDEX IF NOT EXISTS idx_order_items_sku ON order_items(sku_id);
CREATE INDEX IF NOT EXISTS idx_order_items_order ON order_items(order_id);
CREATE INDEX IF NOT EXISTS idx_fulfillment_order ON fulfillment_tasks(order_id);
CREATE INDEX IF NOT EXISTS idx_fulfillment_timestamps ON fulfillment_tasks(order_received_at, shipped_at);
