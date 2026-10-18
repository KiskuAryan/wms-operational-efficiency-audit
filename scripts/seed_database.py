#!/usr/bin/env python3
"""
Warehouse Management System (WMS) Realistic Data Generator
Generates realistic logistics transaction logs reflecting real-world warehouse bottlenecks.
Author: Aryan Chintaman Manjhi (github.com/KiskuAryan)
"""

import sqlite3
import random
import os
from datetime import datetime, timedelta

DB_PATH = os.path.join(os.path.dirname(__file__), "..", "wms.db")
SCHEMA_PATH = os.path.join(os.path.dirname(__file__), "..", "sql", "01_schema.sql")
SQL_DUMP_PATH = os.path.join(os.path.dirname(__file__), "..", "sql", "02_seed_data.sql")

random.seed(42)

def init_db():
    if os.path.exists(DB_PATH):
        os.remove(DB_PATH)
    conn = sqlite3.connect(DB_PATH)
    with open(SCHEMA_PATH, 'r') as f:
        conn.executescript(f.read())
    return conn

def generate_data(conn):
    cursor = conn.cursor()
    sql_dump_lines = ["-- ==============================================================================\n",
                      "-- Warehouse Management System (WMS) - Synthetic Seed Data\n",
                      "-- ==============================================================================\n\n"]

    # 1. Warehouse Master
    cursor.execute("""
        INSERT INTO warehouses (warehouse_code, name, location_city, total_capacity_sqm)
        VALUES ('WH-TYO-01', 'Tokyo Bay Logistics Fulfillment Center', 'Tokyo', 45000.00)
    """)
    wh_id = cursor.lastrowid
    sql_dump_lines.append(f"INSERT INTO warehouses (warehouse_id, warehouse_code, name, location_city, total_capacity_sqm) "
                          f"VALUES ({wh_id}, 'WH-TYO-01', 'Tokyo Bay Logistics Fulfillment Center', 'Tokyo', 45000.00);\n")

    # 2. Zones
    zones = [
        ('ZONE_A_FASTPICK', 'Zone A: Mezzanine Fast-Pick', 15, 'RAPID_PICK'),
        ('ZONE_B_STANDARD', 'Zone B: Mid-Bay High Racks', 60, 'STANDARD'),
        ('ZONE_C_BULK', 'Zone C: Deep Storage & Heavy Pallets', 145, 'HEAVY_FORKLIFT')
    ]
    zone_ids = {}
    for code, name, dist, h_type in zones:
        cursor.execute("""
            INSERT INTO warehouse_zones (warehouse_id, zone_code, zone_name, distance_to_dock_meters, handling_type)
            VALUES (?, ?, ?, ?, ?)
        """, (wh_id, code, name, dist, h_type))
        zone_ids[code] = cursor.lastrowid
        sql_dump_lines.append(f"INSERT INTO warehouse_zones (zone_id, warehouse_id, zone_code, zone_name, distance_to_dock_meters, handling_type) "
                              f"VALUES ({zone_ids[code]}, {wh_id}, '{code}', '{name}', {dist}, '{h_type}');\n")

    # 3. SKUs Catalog (50 items: 10 Class A, 20 Class B, 20 Class C)
    categories = ['Industrial Tools', 'Automotive Spares', 'Consumer Electronics', 'Precision Machinery', 'Safety Equipment']
    skus = []
    
    # 10 Class A (High Velocity)
    for i in range(1, 11):
        skus.append((f"SKU-A{i:03d}", f"High-Demand Precision Component A-{i}", random.choice(categories), round(random.uniform(0.5, 4.0), 2), 'A', random.randint(3500, 25000)))
    # 20 Class B (Medium Velocity)
    for i in range(1, 21):
        skus.append((f"SKU-B{i:03d}", f"Standard Industrial Assembly B-{i}", random.choice(categories), round(random.uniform(1.0, 8.0), 2), 'B', random.randint(1500, 12000)))
    # 20 Class C (Low Velocity)
    for i in range(1, 21):
        skus.append((f"SKU-C{i:03d}", f"Specialized Replacement Spare C-{i}", random.choice(categories), round(random.uniform(2.0, 15.0), 2), 'C', random.randint(5000, 45000)))

    sku_db_ids = {}
    for code, name, cat, weight, abc, price in skus:
        cursor.execute("""
            INSERT INTO products_sku (sku_code, product_name, category, unit_weight_kg, target_abc_class, unit_price_jpy)
            VALUES (?, ?, ?, ?, ?, ?)
        """, (code, name, cat, weight, abc, price))
        sku_db_ids[code] = {
            'id': cursor.lastrowid,
            'abc': abc,
            'price': price
        }
        sql_dump_lines.append(f"INSERT INTO products_sku (sku_id, sku_code, product_name, category, unit_weight_kg, target_abc_class, unit_price_jpy) "
                              f"VALUES ({cursor.lastrowid}, '{code}', '{name}', '{cat}', {weight}, '{abc}', {price});\n")

    # 4. Storage Bins (60 Bins)
    # INTENTIONAL BOTTLENECK: Place 4 high-demand Class-A SKUs in ZONE_C_BULK (Deep Storage)
    # This demonstrates the classic WMS slotting misconfiguration.
    bin_ids = []
    bin_counter = 1
    
    sku_keys = list(sku_db_ids.keys())
    # Assign SKUs to zones
    for idx, code in enumerate(sku_keys):
        sku_info = sku_db_ids[code]
        abc = sku_info['abc']
        
        # Misallocation logic:
        if code in ['SKU-A001', 'SKU-A002', 'SKU-A003', 'SKU-A004']:
            assigned_zone = 'ZONE_C_BULK' # MISSLOTTED!
        elif abc == 'A':
            assigned_zone = 'ZONE_A_FASTPICK'
        elif abc == 'B':
            assigned_zone = 'ZONE_B_STANDARD'
        else:
            # Class C occasionally in Zone A (wasting prime space)
            if idx % 5 == 0:
                assigned_zone = 'ZONE_A_FASTPICK' # SLOW MOVER BLOCKING PRIME SPACE
            else:
                assigned_zone = 'ZONE_C_BULK'

        zone_id = zone_ids[assigned_zone]
        aisle = ((bin_counter - 1) // 10) + 1
        rack = (((bin_counter - 1) // 2) % 5) + 1
        shelf = ((bin_counter - 1) % 4) + 1
        bin_code = f"{assigned_zone[:6]}-B{bin_counter:03d}-A{aisle:02d}-R{rack:02d}-S{shelf:02d}"
        
        qty = random.randint(40, 200)
        max_cap = 250
        safety = 20

        cursor.execute("""
            INSERT INTO inventory_bins (warehouse_id, zone_id, bin_code, aisle_num, rack_num, shelf_level, current_sku_id, current_qty, max_capacity_qty, safety_stock_qty, last_replenished_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, (wh_id, zone_id, bin_code, aisle, rack, shelf, sku_info['id'], qty, max_cap, safety, '2026-09-01 08:00:00'))
        
        b_id = cursor.lastrowid
        bin_ids.append({'bin_id': b_id, 'zone_code': assigned_zone, 'sku_id': sku_info['id']})
        sql_dump_lines.append(f"INSERT INTO inventory_bins (bin_id, warehouse_id, zone_id, bin_code, aisle_num, rack_num, shelf_level, current_sku_id, current_qty, max_capacity_qty, safety_stock_qty, last_replenished_at) "
                              f"VALUES ({b_id}, {wh_id}, {zone_id}, '{bin_code}', {aisle}, {rack}, {shelf}, {sku_info['id']}, {qty}, {max_cap}, {safety}, '2026-09-01 08:00:00');\n")
        bin_counter += 1

    # 5. Generate 1,200 Orders and Fulfillment Tasks over 30 days
    start_date = datetime(2026, 9, 1, 8, 0, 0)
    prefectures = ['Tokyo', 'Kanagawa', 'Chiba', 'Saitama', 'Osaka', 'Aichi', 'Fukuoka', 'Hyogo']
    pickers = ['PK-101', 'PK-102', 'PK-103', 'PK-104', 'PK-105', 'PK-106', 'PK-107', 'PK-108']

    print("Generating 1,200 orders and fulfillment cycles...")

    # Class A weights: 75% of order probability
    a_skus = [s for s in sku_keys if sku_db_ids[s]['abc'] == 'A']
    b_skus = [s for s in sku_keys if sku_db_ids[s]['abc'] == 'B']
    c_skus = [s for s in sku_keys if sku_db_ids[s]['abc'] == 'C']

    for o_idx in range(1, 1201):
        # Time distribution: simulate rush peak between 10:00 and 14:00
        days_offset = random.randint(0, 29)
        hour = random.choices(
            population=[8, 9, 10, 11, 12, 13, 14, 15, 16, 17],
            weights=[5, 8, 18, 22, 15, 12, 10, 5, 3, 2],
            k=1
        )[0]
        minute = random.randint(0, 59)
        second = random.randint(0, 59)
        order_time = start_date + timedelta(days=days_offset, hours=hour, minutes=minute, seconds=second)

        priority = random.choices(['STANDARD', 'EXPRESS', 'SAME_DAY'], weights=[70, 20, 10])[0]
        status = 'SHIPPED'
        dest = random.choice(prefectures)
        order_num = f"ORD-202609-{o_idx:05d}"
        cust_id = f"CUST-{random.randint(1000, 9999)}"

        cursor.execute("""
            INSERT INTO orders (order_number, customer_id, order_timestamp, priority_level, status, destination_prefecture)
            VALUES (?, ?, ?, ?, ?, ?)
        """, (order_num, cust_id, order_time.strftime('%Y-%m-%d %H:%M:%S'), priority, status, dest))
        order_id = cursor.lastrowid

        # Items in this order (1 to 4 items)
        num_items = random.choices([1, 2, 3, 4], weights=[50, 30, 15, 5])[0]
        chosen_skus = set()
        
        has_deep_storage_pick = False
        total_order_weight = 0

        for _ in range(num_items):
            # Select SKU biased toward Class A
            roll = random.random()
            if roll < 0.75:
                sku_sel = random.choice(a_skus)
            elif roll < 0.93:
                sku_sel = random.choice(b_skus)
            else:
                sku_sel = random.choice(c_skus)

            if sku_sel in chosen_skus:
                continue
            chosen_skus.add(sku_sel)

            sku_meta = sku_db_ids[sku_sel]
            req_qty = random.randint(1, 6)
            
            # Find bin
            matching_bin = next(b for b in bin_ids if b['sku_id'] == sku_meta['id'])
            if matching_bin['zone_code'] == 'ZONE_C_BULK':
                has_deep_storage_pick = True

            cursor.execute("""
                INSERT INTO order_items (order_id, sku_id, requested_qty, allocated_bin_id, fulfilled_qty, unit_price_jpy)
                VALUES (?, ?, ?, ?, ?, ?)
            """, (order_id, sku_meta['id'], req_qty, matching_bin['bin_id'], req_qty, sku_meta['price']))

        # Fulfillment Lifecycle Timings:
        # BOTTLENECK 2: Peak hours (10-14) experience severe allocation dwell time due to legacy single-threaded processing
        if 10 <= hour <= 14:
            alloc_dwell_min = random.uniform(25, 65)  # severe backlog
        else:
            alloc_dwell_min = random.uniform(5, 18)

        # Picking duration: depends heavily on travel to Zone C
        if has_deep_storage_pick:
            picking_min = random.uniform(22, 45) # Long transit to deep storage
            travel_meters = random.randint(310, 520)
        else:
            picking_min = random.uniform(7, 16)  # Fast mezzanine pick
            travel_meters = random.randint(45, 130)

        packing_min = random.uniform(4, 12)
        staging_min = random.uniform(15, 45)

        t_alloc = order_time + timedelta(minutes=alloc_dwell_min)
        t_pick_start = t_alloc + timedelta(minutes=random.uniform(2, 5))
        t_pick_end = t_pick_start + timedelta(minutes=picking_min)
        t_pack_end = t_pick_end + timedelta(minutes=packing_min)
        t_shipped = t_pack_end + timedelta(minutes=staging_min)

        assigned_pk = random.choice(pickers)
        exception = 1 if (random.random() < 0.04 and has_deep_storage_pick) else 0

        cursor.execute("""
            INSERT INTO fulfillment_tasks (
                order_id, assigned_picker_id, order_received_at, pick_allocated_at,
                pick_started_at, pick_completed_at, pack_completed_at, shipped_at,
                picker_travel_meters, picking_method, exception_flag
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, (
            order_id, assigned_pk,
            order_time.strftime('%Y-%m-%d %H:%M:%S'),
            t_alloc.strftime('%Y-%m-%d %H:%M:%S'),
            t_pick_start.strftime('%Y-%m-%d %H:%M:%S'),
            t_pick_end.strftime('%Y-%m-%d %H:%M:%S'),
            t_pack_end.strftime('%Y-%m-%d %H:%M:%S'),
            t_shipped.strftime('%Y-%m-%d %H:%M:%S'),
            travel_meters,
            'SINGLE_ORDER_DISCRETE',
            exception
        ))

    conn.commit()
    conn.close()
    print("Database seeded successfully in wms.db!")

if __name__ == '__main__':
    conn = init_db()
    generate_data(conn)
