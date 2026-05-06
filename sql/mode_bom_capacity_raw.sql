WITH params AS (
    SELECT CURRENT_DATE() AS as_of_date
),
eligible_top_levels AS (
    SELECT DISTINCT
        PART_NUMBER,
        REVISION
    FROM fivetran_google_sheets.supply_chain_capacity_demand_by_part_number
    WHERE PART_NUMBER IS NOT NULL
),
bom_base AS (
    SELECT DISTINCT
        bh.PATH,
        bh.PART_NUMBER,
        bh.REVISION,
        bh.PRODUCT_NAME,
        bh.PRODUCTION_STATE,
        bh.INDENT_LEVEL,
        bh.UOM,
        bh.TRACKING,
        bh.IS_CONSUMABLE_STORABLE,
        bh.PARENT_BOM,
        bh.PARENT_REVISION,
        bh.TOP_LEVEL_BOM,
        bh.TOP_LEVEL_REVISION,
        bh.QUANTITY,
        bh.PROCUREMENT_INTENT,
        bh.ADJUSTED_QUANTITY,
        bh.ADJUSTED_PROCUREMENT_INTENT,
        bh.GLOBAL_ALTERNATE_PART_NUMBERS,
        bh.SUBSTITUTE_PART_NUMBERS
    FROM BIZ.DBT.DIM_BOM_HIERARCHY bh
    INNER JOIN eligible_top_levels et
        ON bh.TOP_LEVEL_BOM = et.PART_NUMBER
       AND COALESCE(bh.TOP_LEVEL_REVISION, '') = COALESCE(et.REVISION, '')
),
bom_path_normalized AS (
    SELECT
        bb.*,
        REGEXP_REPLACE(bb.PATH, '[|][A-Za-z][A-Za-z0-9]{0,2}[|]', '|') AS PATH_WITHOUT_REVISION
    FROM bom_base bb
),
part_top_level_rollup AS (
    SELECT
        PART_NUMBER,
        TOP_LEVEL_BOM,
        COALESCE(TOP_LEVEL_REVISION, '') AS TOP_LEVEL_REVISION,
        SUM(COALESCE(ADJUSTED_QUANTITY, 0)) AS TOTAL_ROLLED_UP_QUANTITY
    FROM bom_path_normalized
    WHERE PART_NUMBER IS NOT NULL
      AND TOP_LEVEL_BOM IS NOT NULL
    GROUP BY PART_NUMBER, TOP_LEVEL_BOM, COALESCE(TOP_LEVEL_REVISION, '')
),
part_rollup_quantity AS (
    SELECT
        PART_NUMBER,
        CASE
            WHEN COUNT(DISTINCT TOTAL_ROLLED_UP_QUANTITY) > 1 THEN 'mutliple'
            ELSE TO_VARCHAR(MAX(TOTAL_ROLLED_UP_QUANTITY))
        END AS "total rolled up quantity",
        CASE
            WHEN COUNT(DISTINCT TOTAL_ROLLED_UP_QUANTITY) > 1 THEN NULL
            ELSE MAX(TOTAL_ROLLED_UP_QUANTITY)
        END AS TOTAL_ROLLED_UP_QUANTITY_NUMERIC
    FROM part_top_level_rollup
    GROUP BY PART_NUMBER
),
demand_base AS (
    SELECT
        cd.PART_NUMBER AS TOP_LEVEL_BOM,
        cd.REVISION AS TOP_LEVEL_REVISION,
        cd.QUANTITY AS DEMAND_QUANTITY,
        cd.DEMAND_TYPE,
        TRY_TO_DATE(cd.DATE, 'MM/DD/YYYY') AS DEMAND_DATE,
        DATE_TRUNC('week', TRY_TO_DATE(cd.DATE, 'MM/DD/YYYY')) AS DEMAND_WEEK
    FROM fivetran_google_sheets.supply_chain_capacity_demand_by_part_number cd
    WHERE cd.PART_NUMBER IS NOT NULL
),
demand_metrics AS (
    SELECT
        bpn.PATH,
        bpn.PART_NUMBER,
        bpn.REVISION,
        SUM(
            CASE
                WHEN db.DEMAND_WEEK >= DATEADD(week, -7, DATE_TRUNC('week', (SELECT as_of_date FROM params)))
                 AND db.DEMAND_WEEK <= DATE_TRUNC('week', (SELECT as_of_date FROM params))
                THEN db.DEMAND_QUANTITY * COALESCE(bpn.ADJUSTED_QUANTITY, 0)
                ELSE 0
            END
        ) AS "Gross Demand for BOM Line in past 8 weeks",
        SUM(
            CASE
                WHEN db.DEMAND_WEEK >= DATE_TRUNC('week', (SELECT as_of_date FROM params))
                 AND db.DEMAND_WEEK < DATEADD(week, 4, DATE_TRUNC('week', (SELECT as_of_date FROM params)))
                THEN db.DEMAND_QUANTITY * COALESCE(bpn.ADJUSTED_QUANTITY, 0)
                ELSE 0
            END
        ) AS "Demand for BOM Line in next 4 weeks",
        SUM(
            CASE
                WHEN db.DEMAND_WEEK >= DATE_TRUNC('week', (SELECT as_of_date FROM params))
                 AND db.DEMAND_WEEK < DATEADD(week, 8, DATE_TRUNC('week', (SELECT as_of_date FROM params)))
                THEN db.DEMAND_QUANTITY * COALESCE(bpn.ADJUSTED_QUANTITY, 0)
                ELSE 0
            END
        ) AS "Gross Demand for BOM Line in next 8 weeks"
    FROM bom_path_normalized bpn
    LEFT JOIN demand_base db
        ON bpn.TOP_LEVEL_BOM = db.TOP_LEVEL_BOM
       AND COALESCE(bpn.TOP_LEVEL_REVISION, '') = COALESCE(db.TOP_LEVEL_REVISION, '')
    GROUP BY bpn.PATH, bpn.PART_NUMBER, bpn.REVISION
),
part_number_demand_by_type AS (
    SELECT
        bpn.PART_NUMBER,
        bpn.REVISION,
        db.DEMAND_TYPE,
        SUM(
            CASE
                WHEN db.DEMAND_WEEK >= DATEADD(week, -7, DATE_TRUNC('week', (SELECT as_of_date FROM params)))
                 AND db.DEMAND_WEEK <= DATE_TRUNC('week', (SELECT as_of_date FROM params))
                THEN db.DEMAND_QUANTITY * COALESCE(bpn.ADJUSTED_QUANTITY, 0)
                ELSE 0
            END
        ) AS GROSS_PAST_8_WEEKS_DEMAND,
        SUM(
            CASE
                WHEN db.DEMAND_WEEK >= DATE_TRUNC('week', (SELECT as_of_date FROM params))
                 AND db.DEMAND_WEEK < DATEADD(week, 8, DATE_TRUNC('week', (SELECT as_of_date FROM params)))
                THEN db.DEMAND_QUANTITY * COALESCE(bpn.ADJUSTED_QUANTITY, 0)
                ELSE 0
            END
        ) AS GROSS_NEXT_8_WEEKS_DEMAND,
        SUM(
            CASE
                WHEN db.DEMAND_WEEK = DATE_TRUNC('week', (SELECT as_of_date FROM params))
                THEN db.DEMAND_QUANTITY * COALESCE(bpn.ADJUSTED_QUANTITY, 0)
                ELSE 0
            END
        ) AS GROSS_CURRENT_WEEK_DEMAND
    FROM bom_path_normalized bpn
    LEFT JOIN demand_base db
        ON bpn.TOP_LEVEL_BOM = db.TOP_LEVEL_BOM
       AND COALESCE(bpn.TOP_LEVEL_REVISION, '') = COALESCE(db.TOP_LEVEL_REVISION, '')
    GROUP BY bpn.PART_NUMBER, bpn.REVISION, db.DEMAND_TYPE
),
structured_bom_lookup AS (
    SELECT
        bpn.*,
        sbsd.PRODUCT AS "Product",
        sbsd.VARIANT AS "Variant",
        sbsd.SYSTEM AS "System",
        sbsd.SUBSYSTEM AS "Subsystem"
    FROM bom_path_normalized bpn
    LEFT JOIN fivetran_google_sheets.supply_chain_structured_bom_data sbsd
        ON bpn.PATH_WITHOUT_REVISION = sbsd.PATH_WITHOUT_REV
),
flat_parts_lookup AS (
    SELECT
        sbl.*,
        fpl.NEW_COMMODITY AS Commodity
    FROM structured_bom_lookup sbl
    LEFT JOIN fivetran_google_sheets.supply_chain_flat_parts_list fpl
        ON sbl.PART_NUMBER = fpl.PART_NUMBER
),
report_parts AS (
    SELECT DISTINCT PART_NUMBER
    FROM flat_parts_lookup
    WHERE PART_NUMBER IS NOT NULL
),
alternate_part_groups AS (
    SELECT DISTINCT
        alt._ROW AS GROUP_ID,
        TRIM(f.value::string) AS PART_NUMBER
    FROM fivetran_google_sheets.supply_chain_alternate_part_numbers alt,
         LATERAL FLATTEN(input => SPLIT(alt."_0109025_000_0109025_999_0109025_001", ',')) f
    WHERE TRIM(f.value::string) <> ''
),
alternate_part_bridge AS (
    SELECT DISTINCT
        rp.PART_NUMBER AS BASE_PART_NUMBER,
        COALESCE(apg2.PART_NUMBER, rp.PART_NUMBER) AS RELATED_PART_NUMBER
    FROM report_parts rp
    LEFT JOIN alternate_part_groups apg1
        ON apg1.PART_NUMBER = rp.PART_NUMBER
    LEFT JOIN alternate_part_groups apg2
        ON apg1.GROUP_ID = apg2.GROUP_ID
),
planning_alternates AS (
    SELECT
        rp.PART_NUMBER,
        LISTAGG(related.RELATED_PART_NUMBER, ', ') WITHIN GROUP (ORDER BY related.RELATED_PART_NUMBER) AS "Supply Plan and On-Hand Alternates"
    FROM report_parts rp
    LEFT JOIN (
        SELECT DISTINCT
            ab.BASE_PART_NUMBER,
            ab.RELATED_PART_NUMBER
        FROM alternate_part_bridge ab
        WHERE ab.RELATED_PART_NUMBER <> ab.BASE_PART_NUMBER
    ) related
        ON rp.PART_NUMBER = related.BASE_PART_NUMBER
    GROUP BY rp.PART_NUMBER
),
latest_issued_po_candidates AS (
    SELECT
        pol.ODOO_PART_CODE AS PART_NUMBER,
        pol.MAJOR_REVISION AS REVISION,
        po.PO_NUMBER,
        po.SUPPLIER_NAME,
        po.VERSION_CREATED_AT_LOCAL AS PO_CREATED_AT_LOCAL,
        ROW_NUMBER() OVER (
            PARTITION BY pol.ODOO_PART_CODE, COALESCE(pol.MAJOR_REVISION, '')
            ORDER BY po.VERSION_CREATED_AT_LOCAL DESC, po.PO_VERSION_ID DESC, pol.LINE_ID DESC
        ) AS RN
    FROM BIZ.DBT.FCT_ZERP_PURCHASING_PURCHASE_ORDER_LINES pol
    INNER JOIN BIZ.DBT.FCT_ZERP_PURCHASING_PURCHASE_ORDERS po
        ON pol.PO_VERSION_ID = po.PO_VERSION_ID
    WHERE po.PO_STATUS = 'ISSUED'
      AND pol.ODOO_PART_CODE IS NOT NULL
),
latest_issued_po AS (
    SELECT
        PART_NUMBER,
        REVISION,
        PO_NUMBER AS "Latest PO",
        SUPPLIER_NAME AS "Latest Supplier",
        PO_CREATED_AT_LOCAL AS "Latest PO Creation Date"
    FROM latest_issued_po_candidates
    WHERE RN = 1
),
location_category_map AS (
    SELECT
        sl.ID,
        sl.COMPLETE_NAME,
        CASE
            WHEN sl.COMPLETE_NAME LIKE 'Vendors%' THEN 'Vendors'
            WHEN sl.COMPLETE_NAME LIKE 'Zipline%' THEN 'Production'
            WHEN sl.COMPLETE_NAME LIKE 'COOP/Quarantine%' THEN 'Quarantine'
            WHEN sl.COMPLETE_NAME LIKE 'COOP/MRB%' THEN 'Quarantine'
            WHEN sl.COMPLETE_NAME LIKE 'COOP/IQC%' THEN 'Quarantine'
            WHEN sl.COMPLETE_NAME LIKE '%Quarantine%' THEN 'Quarantine'
            WHEN sl.COMPLETE_NAME LIKE '%Scrap%' THEN 'Scrap'
            WHEN sl.COMPLETE_NAME LIKE '%Inventory adjustment%' THEN 'Scrap'
            WHEN sl.COMPLETE_NAME LIKE '%RTV%' THEN 'Scrap'
            WHEN sl.COMPLETE_NAME LIKE '%QRNT%' THEN 'Quarantine'
            WHEN sl.COMPLETE_NAME LIKE '%AGSF%' THEN 'Nest'
            WHEN sl.COMPLETE_NAME LIKE '%AR-1%' THEN 'Nest'
            WHEN sl.COMPLETE_NAME LIKE '%BOLVN%' THEN 'Nest'
            WHEN sl.COMPLETE_NAME LIKE '%CI_3%' THEN 'Nest'
            WHEN sl.COMPLETE_NAME LIKE '%CI-1%' THEN 'Nest'
            WHEN sl.COMPLETE_NAME LIKE '%CI-2%' THEN 'Nest'
            WHEN sl.COMPLETE_NAME LIKE '%CI-3%' THEN 'Nest'
            WHEN sl.COMPLETE_NAME LIKE '%CI-4%' THEN 'Nest'
            WHEN sl.COMPLETE_NAME LIKE '%CR-1%' THEN 'Nest'
            WHEN sl.COMPLETE_NAME LIKE '%CR-2%' THEN 'Nest'
            WHEN sl.COMPLETE_NAME LIKE '%CTR2%' THEN 'Nest'
            WHEN sl.COMPLETE_NAME LIKE '%DFW%' THEN 'Nest'
            WHEN sl.COMPLETE_NAME LIKE '%GB-1%' THEN 'Nest'
            WHEN sl.COMPLETE_NAME LIKE '%GH-1%' THEN 'Nest'
            WHEN sl.COMPLETE_NAME LIKE '%GH-2%' THEN 'Nest'
            WHEN sl.COMPLETE_NAME LIKE '%GH-3%' THEN 'Nest'
            WHEN sl.COMPLETE_NAME LIKE '%GH-4%' THEN 'Nest'
            WHEN sl.COMPLETE_NAME LIKE '%GH-5%' THEN 'Nest'
            WHEN sl.COMPLETE_NAME LIKE '%GH-6%' THEN 'Nest'
            WHEN sl.COMPLETE_NAME LIKE '%Gh-6%' THEN 'Nest'
            WHEN sl.COMPLETE_NAME LIKE '%GH-7%' THEN 'Nest'
            WHEN sl.COMPLETE_NAME LIKE '%GH-8%' THEN 'Nest'
            WHEN sl.COMPLETE_NAME LIKE '%JP-1%' THEN 'Nest'
            WHEN sl.COMPLETE_NAME LIKE '%KD-1%' THEN 'Nest'
            WHEN sl.COMPLETE_NAME LIKE '%KD-2%' THEN 'Nest'
            WHEN sl.COMPLETE_NAME LIKE '%KD-3%' THEN 'Nest'
            WHEN sl.COMPLETE_NAME LIKE '%KE-1%' THEN 'Nest'
            WHEN sl.COMPLETE_NAME LIKE '%NC-1%' THEN 'Nest'
            WHEN sl.COMPLETE_NAME LIKE '%ND-1%' THEN 'Nest'
            WHEN sl.COMPLETE_NAME LIKE '%Nest%' THEN 'Nest'
            WHEN sl.COMPLETE_NAME LIKE '%Nest0%' THEN 'Nest'
            WHEN sl.COMPLETE_NAME LIKE '%NestD%' THEN 'Nest'
            WHEN sl.COMPLETE_NAME LIKE '%NestW%' THEN 'Nest'
            WHEN sl.COMPLETE_NAME LIKE '%NestX%' THEN 'Nest'
            WHEN sl.COMPLETE_NAME LIKE '%NestY%' THEN 'Nest'
            WHEN sl.COMPLETE_NAME LIKE '%NestZ%' THEN 'Nest'
            WHEN sl.COMPLETE_NAME LIKE '%NextX%' THEN 'Nest'
            WHEN sl.COMPLETE_NAME LIKE '%NGBS-1%' THEN 'Nest'
            WHEN sl.COMPLETE_NAME LIKE '%OCS%' THEN 'Nest'
            WHEN sl.COMPLETE_NAME LIKE '%Pea Ridge%' THEN 'Nest'
            WHEN sl.COMPLETE_NAME LIKE '%ROHMY%' THEN 'Nest'
            WHEN sl.COMPLETE_NAME LIKE '%RW-1%' THEN 'Nest'
            WHEN sl.COMPLETE_NAME LIKE '%RW-2%' THEN 'Nest'
            WHEN sl.COMPLETE_NAME LIKE '%RWKGL%' THEN 'Nest'
            WHEN sl.COMPLETE_NAME LIKE '%TZLLA%' THEN 'Nest'
            WHEN sl.COMPLETE_NAME LIKE '%UA-1%' THEN 'Nest'
            WHEN sl.COMPLETE_NAME LIKE '%UA-2%' THEN 'Nest'
            WHEN sl.COMPLETE_NAME LIKE '%UA-3%' THEN 'Nest'
            WHEN sl.COMPLETE_NAME LIKE '%UA-4%' THEN 'Nest'
            WHEN sl.COMPLETE_NAME LIKE '%UA-5%' THEN 'Nest'
            WHEN sl.COMPLETE_NAME LIKE '%US %' THEN 'Nest'
            WHEN sl.COMPLETE_NAME LIKE '%UT-1%' THEN 'Nest'
            WHEN sl.COMPLETE_NAME LIKE '%Global Nest Transit%' THEN 'Nest'
            WHEN sl.COMPLETE_NAME LIKE '%Global RMA Transit%' THEN 'Nest'
            WHEN sl.COMPLETE_NAME LIKE '%Maintenance%' THEN 'Nest'
            WHEN sl.COMPLETE_NAME LIKE '%maintenance%' THEN 'Nest'
            WHEN sl.COMPLETE_NAME LIKE '%NEST: Defective Material%' THEN 'Nest'
            WHEN sl.COMPLETE_NAME LIKE '%ROCC (North Carolina)%' THEN 'Nest'
            WHEN sl.COMPLETE_NAME LIKE '%Truckzilla In Transit%' THEN 'Nest'
            WHEN sl.COMPLETE_NAME LIKE 'AVRY/Outbound%' THEN 'Nest'
            WHEN sl.COMPLETE_NAME LIKE 'AVRY/Output%' THEN 'Nest'
            WHEN sl.COMPLETE_NAME LIKE 'COOP/Output%' THEN 'Warehouse'
            WHEN sl.COMPLETE_NAME LIKE 'AVRY/FG%' THEN 'Warehouse'
            WHEN sl.COMPLETE_NAME LIKE 'AVRY/Input%' THEN 'Warehouse'
            WHEN sl.COMPLETE_NAME LIKE 'AVRY/Inspection%' THEN 'Warehouse'
            WHEN sl.COMPLETE_NAME LIKE 'AVRY/WH%' THEN 'Warehouse'
            WHEN sl.COMPLETE_NAME LIKE 'AVRY/Zip%' THEN 'Warehouse'
            WHEN sl.COMPLETE_NAME LIKE 'COOP/Input%' THEN 'Warehouse'
            WHEN sl.COMPLETE_NAME LIKE 'COOP/Inspected%' THEN 'Warehouse'
            WHEN sl.COMPLETE_NAME LIKE 'COOP/Inspection%' THEN 'Warehouse'
            WHEN sl.COMPLETE_NAME LIKE 'COOP/Manufacturing%' THEN 'Warehouse'
            WHEN sl.COMPLETE_NAME LIKE 'COOP/OQC%' THEN 'Warehouse'
            WHEN sl.COMPLETE_NAME LIKE 'COOP/P2/Inspected%' THEN 'Warehouse'
            WHEN sl.COMPLETE_NAME LIKE 'COOP/P1 Manufacturing%' THEN 'Warehouse'
            WHEN sl.COMPLETE_NAME LIKE 'COOP/P2/WH%' THEN 'Warehouse'
            WHEN sl.COMPLETE_NAME LIKE 'COOP/Packout%' THEN 'Warehouse'
            WHEN sl.COMPLETE_NAME LIKE 'COOP/FAI Pre-Inspection%' THEN 'Warehouse'
            WHEN sl.COMPLETE_NAME LIKE 'COOP/Post-Inspection%' THEN 'Warehouse'
            WHEN sl.COMPLETE_NAME LIKE 'COOP/Post-Production%' THEN 'Warehouse'
            WHEN sl.COMPLETE_NAME LIKE 'COOP/Pre-Production%' THEN 'Warehouse'
            WHEN sl.COMPLETE_NAME LIKE 'COOP/WH%' THEN 'Warehouse'
            WHEN sl.COMPLETE_NAME LIKE 'COOP/P2/Manufacturing%' THEN 'Warehouse'
            WHEN sl.COMPLETE_NAME LIKE '%AVRY%' THEN 'Nest'
            WHEN sl.COMPLETE_NAME LIKE 'AVRY/AVRY/HIL%' THEN 'R&D'
            WHEN sl.COMPLETE_NAME LIKE 'AVRY/Employee Location%' THEN 'R&D'
            WHEN sl.COMPLETE_NAME LIKE 'AVRY/HIL%' THEN 'R&D'
            WHEN sl.COMPLETE_NAME LIKE 'AVRY/NPI%' THEN 'R&D'
            WHEN sl.COMPLETE_NAME LIKE 'AVRY/R&D%' THEN 'R&D'
            WHEN sl.COMPLETE_NAME LIKE 'COOP/Buck Builds%' THEN 'R&D'
            WHEN sl.COMPLETE_NAME LIKE 'COOP/DVP&R%' THEN 'R&D'
            WHEN sl.COMPLETE_NAME LIKE 'COOP/Employee Location%' THEN 'R&D'
            WHEN sl.COMPLETE_NAME LIKE 'COOP/OPS Fab Lab%' THEN 'R&D'
            WHEN sl.COMPLETE_NAME LIKE 'COOP/R&D%' THEN 'R&D'
            WHEN sl.COMPLETE_NAME LIKE 'R&D%' THEN 'R&D'
            WHEN sl.COMPLETE_NAME LIKE 'ROST%' THEN 'R&D'
            WHEN sl.COMPLETE_NAME LIKE '%RMA%' THEN 'Nest'
            ELSE 'Unknown'
        END AS MRP_CATEGORY
    FROM BIZ.DBT_STG.STG_ODOO_PROD__STOCK_LOCATION sl
),
stock_moves_enriched AS (
    SELECT
        sm.DATE,
        pt.DEFAULT_CODE AS PART_NUMBER,
        pt.NAME,
        sm.PRODUCT_QTY,
        origin.MRP_CATEGORY AS MRP_CATEGORY_ORIGIN,
        destination.MRP_CATEGORY AS MRP_CATEGORY_DESTINATION,
        CASE
            WHEN origin.MRP_CATEGORY = 'Vendors' AND destination.MRP_CATEGORY = 'Warehouse' THEN 'New Supply'
            WHEN origin.MRP_CATEGORY = 'Warehouse' AND destination.MRP_CATEGORY = 'Vendors' THEN 'New Supply'
            WHEN origin.MRP_CATEGORY = 'Warehouse' AND destination.MRP_CATEGORY = 'Nest' THEN 'Nest Consumption'
            WHEN origin.MRP_CATEGORY = 'Nest' AND destination.MRP_CATEGORY = 'Warehouse' THEN 'RMA Supply'
            WHEN origin.MRP_CATEGORY = 'Warehouse' AND destination.MRP_CATEGORY = 'Production' THEN 'Production Consumption'
            WHEN origin.MRP_CATEGORY = 'Production' AND destination.MRP_CATEGORY = 'Warehouse' THEN 'Production Consumption'
            WHEN origin.MRP_CATEGORY = 'Warehouse' AND destination.MRP_CATEGORY = 'Scrap' THEN 'QC Loss Consumption'
            WHEN origin.MRP_CATEGORY = 'Warehouse' AND destination.MRP_CATEGORY = 'Quarantine' THEN 'QC Loss Consumption'
            WHEN origin.MRP_CATEGORY = 'Quarantine' AND destination.MRP_CATEGORY = 'Warehouse' THEN 'QC Loss Consumption'
            WHEN origin.MRP_CATEGORY = 'Scrap' AND destination.MRP_CATEGORY = 'Warehouse' THEN 'QC Loss Consumption'
            WHEN origin.MRP_CATEGORY = 'Warehouse' AND destination.MRP_CATEGORY = 'R&D' THEN 'R&D Consumption'
            WHEN origin.MRP_CATEGORY = 'R&D' AND destination.MRP_CATEGORY = 'Warehouse' THEN 'R&D Supply'
            ELSE 'Unknown'
        END AS TRANSACTION_CATEGORY_2,
        CASE
            WHEN origin.MRP_CATEGORY = 'Vendors' AND destination.MRP_CATEGORY = 'Warehouse' THEN sm.PRODUCT_QTY
            WHEN origin.MRP_CATEGORY = 'Warehouse' AND destination.MRP_CATEGORY = 'Vendors' THEN -sm.PRODUCT_QTY
            WHEN origin.MRP_CATEGORY = 'Warehouse' AND destination.MRP_CATEGORY = 'Nest' THEN sm.PRODUCT_QTY
            WHEN origin.MRP_CATEGORY = 'Nest' AND destination.MRP_CATEGORY = 'Warehouse' THEN sm.PRODUCT_QTY
            WHEN origin.MRP_CATEGORY = 'Warehouse' AND destination.MRP_CATEGORY = 'Production' THEN sm.PRODUCT_QTY
            WHEN origin.MRP_CATEGORY = 'Production' AND destination.MRP_CATEGORY = 'Warehouse' THEN -sm.PRODUCT_QTY
            WHEN origin.MRP_CATEGORY = 'Warehouse' AND destination.MRP_CATEGORY = 'Scrap' THEN sm.PRODUCT_QTY
            WHEN origin.MRP_CATEGORY = 'Warehouse' AND destination.MRP_CATEGORY = 'Quarantine' THEN sm.PRODUCT_QTY
            WHEN origin.MRP_CATEGORY = 'Quarantine' AND destination.MRP_CATEGORY = 'Warehouse' THEN -sm.PRODUCT_QTY
            WHEN origin.MRP_CATEGORY = 'Scrap' AND destination.MRP_CATEGORY = 'Warehouse' THEN -sm.PRODUCT_QTY
            WHEN origin.MRP_CATEGORY = 'Warehouse' AND destination.MRP_CATEGORY = 'R&D' THEN sm.PRODUCT_QTY
            WHEN origin.MRP_CATEGORY = 'R&D' AND destination.MRP_CATEGORY = 'Warehouse' THEN sm.PRODUCT_QTY
            ELSE NULL
        END AS TRANSACTION_QUANTITY_2
    FROM BIZ.DBT_STG.STG_ODOO_PROD__STOCK_MOVE sm
    LEFT JOIN BIZ.DBT_STG.STG_ODOO_PROD__PRODUCT_PRODUCT p
        ON p.ID = sm.PRODUCT_ID
    LEFT JOIN BIZ.DBT_STG.STG_ODOO_PROD__PRODUCT_TEMPLATE pt
        ON pt.ID = p.PRODUCT_TMPL_ID
    LEFT JOIN location_category_map origin
        ON origin.ID = sm.LOCATION_ID
    LEFT JOIN location_category_map destination
        ON destination.ID = sm.LOCATION_DEST_ID
    WHERE sm.STATE = 'done'
      AND sm.DATE >= '2025-01-01'
),
receipt_moves AS (
    SELECT
        PART_NUMBER,
        DATE,
        DATE_TRUNC('week', DATE) AS RECEIPT_WEEK,
        TRANSACTION_QUANTITY_2
    FROM stock_moves_enriched
    WHERE TRANSACTION_CATEGORY_2 IN ('New Supply', 'R&D Supply')
      AND TRANSACTION_QUANTITY_2 IS NOT NULL
),
current_week_supply_realized AS (
    SELECT
        PART_NUMBER,
        SUM(
            CASE
                WHEN RECEIPT_WEEK = DATE_TRUNC('week', (SELECT as_of_date FROM params))
                THEN TRANSACTION_QUANTITY_2
                ELSE 0
            END
        ) AS "Current Week Realized Supply"
    FROM receipt_moves
    GROUP BY PART_NUMBER
),
current_week_demand_consumption AS (
    SELECT
        PART_NUMBER,
        SUM(
            CASE
                WHEN DATE_TRUNC('week', DATE) = DATE_TRUNC('week', (SELECT as_of_date FROM params))
                 AND TRANSACTION_CATEGORY_2 = 'Production Consumption'
                THEN TRANSACTION_QUANTITY_2
                ELSE 0
            END
        ) AS PRODUCTION_CONSUMPTION_THIS_WEEK,
        SUM(
            CASE
                WHEN DATE_TRUNC('week', DATE) = DATE_TRUNC('week', (SELECT as_of_date FROM params))
                 AND TRANSACTION_CATEGORY_2 = 'Nest Consumption'
                THEN TRANSACTION_QUANTITY_2
                ELSE 0
            END
        ) AS NEST_CONSUMPTION_THIS_WEEK
    FROM stock_moves_enriched
    GROUP BY PART_NUMBER
),
part_number_demand_metrics AS (
    SELECT
        pd.PART_NUMBER,
        pd.REVISION,
        SUM(pd.GROSS_PAST_8_WEEKS_DEMAND)
            - SUM(
                CASE
                    WHEN pd.DEMAND_TYPE = 'Production' THEN COALESCE(cwd.PRODUCTION_CONSUMPTION_THIS_WEEK, 0)
                    WHEN pd.DEMAND_TYPE = 'Spares' THEN COALESCE(cwd.NEST_CONSUMPTION_THIS_WEEK, 0)
                    ELSE 0
                END
            ) AS "Net Total Demand for Part Number in past 8 weeks",
        SUM(pd.GROSS_NEXT_8_WEEKS_DEMAND)
            - SUM(
                CASE
                    WHEN pd.DEMAND_TYPE = 'Production' THEN COALESCE(cwd.PRODUCTION_CONSUMPTION_THIS_WEEK, 0)
                    WHEN pd.DEMAND_TYPE = 'Spares' THEN COALESCE(cwd.NEST_CONSUMPTION_THIS_WEEK, 0)
                    ELSE 0
                END
            ) AS "Net Total Demand for Part Number in next 8 weeks",
        SUM(pd.GROSS_CURRENT_WEEK_DEMAND)
            - SUM(
                CASE
                    WHEN pd.DEMAND_TYPE = 'Production' THEN COALESCE(cwd.PRODUCTION_CONSUMPTION_THIS_WEEK, 0)
                    WHEN pd.DEMAND_TYPE = 'Spares' THEN COALESCE(cwd.NEST_CONSUMPTION_THIS_WEEK, 0)
                    ELSE 0
                END
            ) AS "Net Total Demand for Part Number in current week",
        SUM(
            CASE
                WHEN pd.DEMAND_TYPE = 'Production' THEN COALESCE(cwd.PRODUCTION_CONSUMPTION_THIS_WEEK, 0)
                WHEN pd.DEMAND_TYPE = 'Spares' THEN COALESCE(cwd.NEST_CONSUMPTION_THIS_WEEK, 0)
                ELSE 0
            END
        ) AS "Current Week Realized Demand Consumption"
    FROM part_number_demand_by_type pd
    LEFT JOIN current_week_demand_consumption cwd
        ON pd.PART_NUMBER = cwd.PART_NUMBER
    GROUP BY pd.PART_NUMBER, pd.REVISION
),
receipt_metrics AS (
    SELECT
        PART_NUMBER,
        SUM(
            CASE
                WHEN RECEIPT_WEEK >= DATEADD(week, -3, DATE_TRUNC('week', (SELECT as_of_date FROM params)))
                 AND RECEIPT_WEEK <= DATE_TRUNC('week', (SELECT as_of_date FROM params))
                THEN TRANSACTION_QUANTITY_2
                ELSE 0
            END
        ) / 4.0 AS "Quantity Received, 4-Week Rolling Average",
        SUM(
            CASE
                WHEN RECEIPT_WEEK >= DATEADD(week, -7, DATE_TRUNC('week', (SELECT as_of_date FROM params)))
                 AND RECEIPT_WEEK <= DATE_TRUNC('week', (SELECT as_of_date FROM params))
                THEN TRANSACTION_QUANTITY_2
                ELSE 0
            END
        ) / 8.0 AS "Quantity Received, 8-Week Rolling Average",
        DATEDIFF(day, MAX(DATE), (SELECT as_of_date FROM params)) / 7.0 / NULLIF(MAX_BY(TRANSACTION_QUANTITY_2, DATE), 0) AS "Quantity Received, Average Since Last Receipt"
    FROM receipt_moves
    GROUP BY PART_NUMBER
),
alternate_receipt_latest AS (
    SELECT
        ab.BASE_PART_NUMBER AS PART_NUMBER,
        rm.DATE,
        rm.TRANSACTION_QUANTITY_2,
        ROW_NUMBER() OVER (
            PARTITION BY ab.BASE_PART_NUMBER
            ORDER BY rm.DATE DESC
        ) AS RN
    FROM alternate_part_bridge ab
    JOIN receipt_moves rm
        ON rm.PART_NUMBER = ab.RELATED_PART_NUMBER
),
alternate_receipt_metrics AS (
    SELECT
        ab.BASE_PART_NUMBER AS PART_NUMBER,
        SUM(
            CASE
                WHEN rm.RECEIPT_WEEK >= DATEADD(week, -3, DATE_TRUNC('week', (SELECT as_of_date FROM params)))
                 AND rm.RECEIPT_WEEK <= DATE_TRUNC('week', (SELECT as_of_date FROM params))
                THEN rm.TRANSACTION_QUANTITY_2
                ELSE 0
            END
        ) / 4.0 AS "Quantity Received, 4-Week Rolling Average with alternates",
        SUM(
            CASE
                WHEN rm.RECEIPT_WEEK >= DATEADD(week, -7, DATE_TRUNC('week', (SELECT as_of_date FROM params)))
                 AND rm.RECEIPT_WEEK <= DATE_TRUNC('week', (SELECT as_of_date FROM params))
                THEN rm.TRANSACTION_QUANTITY_2
                ELSE 0
            END
        ) / 8.0 AS "Quantity Received, 8-Week Rolling Average with alternates",
        DATEDIFF(day, arl.DATE, (SELECT as_of_date FROM params)) / 7.0 / NULLIF(arl.TRANSACTION_QUANTITY_2, 0) AS "Quantity Received, Average Since Last Receipt with alternates"
    FROM alternate_part_bridge ab
    LEFT JOIN receipt_moves rm
        ON rm.PART_NUMBER = ab.RELATED_PART_NUMBER
    LEFT JOIN alternate_receipt_latest arl
        ON arl.PART_NUMBER = ab.BASE_PART_NUMBER
       AND arl.RN = 1
    GROUP BY
        ab.BASE_PART_NUMBER,
        arl.DATE,
        arl.TRANSACTION_QUANTITY_2
),
alternate_current_week_supply_realized AS (
    SELECT
        ab.BASE_PART_NUMBER AS PART_NUMBER,
        SUM(COALESCE(cws."Current Week Realized Supply", 0)) AS "Current Week Realized Supply with alternates"
    FROM alternate_part_bridge ab
    LEFT JOIN current_week_supply_realized cws
        ON cws.PART_NUMBER = ab.RELATED_PART_NUMBER
    GROUP BY ab.BASE_PART_NUMBER
),
inventory_metrics AS (
    SELECT
        inv.DEFAULT_CODE AS PART_NUMBER,
        SUM(CASE WHEN lcm.MRP_CATEGORY = 'Warehouse' THEN inv.QUANTITY ELSE 0 END) AS "Current On-Hand Quantity",
        SUM(CASE WHEN lcm.MRP_CATEGORY = 'Quarantine' THEN inv.QUANTITY ELSE 0 END) AS "Current Quarantine Quantity"
    FROM BIZ.DBT_ODOO.INVENTORY inv
    LEFT JOIN location_category_map lcm
        ON lcm.ID = inv.STOCK_LOCATION_ID
    GROUP BY inv.DEFAULT_CODE
),
alternate_inventory_metrics AS (
    SELECT
        ab.BASE_PART_NUMBER AS PART_NUMBER,
        SUM(COALESCE(im."Current On-Hand Quantity", 0)) AS "Current On-Hand Quantity with alternates",
        SUM(COALESCE(im."Current Quarantine Quantity", 0)) AS "Current Quarantine Quantity with alternates"
    FROM alternate_part_bridge ab
    LEFT JOIN inventory_metrics im
        ON im.PART_NUMBER = ab.RELATED_PART_NUMBER
    GROUP BY ab.BASE_PART_NUMBER
),
supply_plan_base AS (
    SELECT
        sp.PART_NUMBER AS PART_NUMBER,
        sp.QUANTITY AS QUANTITY,
        DATE_TRUNC(
            'week',
            TRY_TO_DATE(
                TRIM(sp.DATE) || '/' || EXTRACT(year FROM (SELECT as_of_date FROM params)),
                'MM/DD/YYYY'
            )
        ) AS PLAN_WEEK,
        TRY_TO_DATE(
            TRIM(sp.DATE) || '/' || EXTRACT(year FROM (SELECT as_of_date FROM params)),
            'MM/DD/YYYY'
        ) AS PLAN_DATE
    FROM fivetran_google_sheets.supply_chain_supply_plans sp
),
supply_plan_metrics AS (
    SELECT
        sp.PART_NUMBER,
        COALESCE(cws."Current Week Realized Supply", 0) AS "Current Week Realized Supply",
        SUM(CASE WHEN sp.PLAN_WEEK >= DATE_TRUNC('week', (SELECT as_of_date FROM params))
                  AND sp.PLAN_WEEK < DATEADD(week, 4, DATE_TRUNC('week', (SELECT as_of_date FROM params)))
             THEN sp.QUANTITY ELSE 0 END) - COALESCE(cws."Current Week Realized Supply", 0) AS "Total Supply Plan, next 4 weeks",
        SUM(CASE WHEN sp.PLAN_WEEK >= DATE_TRUNC('week', (SELECT as_of_date FROM params))
                  AND sp.PLAN_WEEK < DATEADD(week, 8, DATE_TRUNC('week', (SELECT as_of_date FROM params)))
             THEN sp.QUANTITY ELSE 0 END) - COALESCE(cws."Current Week Realized Supply", 0) AS "Total Supply Plan, next 8 weeks",
        (
            SUM(CASE WHEN sp.PLAN_WEEK >= DATE_TRUNC('week', (SELECT as_of_date FROM params))
                      AND sp.PLAN_WEEK < DATEADD(week, 4, DATE_TRUNC('week', (SELECT as_of_date FROM params)))
                 THEN sp.QUANTITY ELSE 0 END) - COALESCE(cws."Current Week Realized Supply", 0)
        ) / 4.0 AS "Average Supply Plan, next 4 weeks",
        (
            SUM(CASE WHEN sp.PLAN_WEEK >= DATE_TRUNC('week', (SELECT as_of_date FROM params))
                      AND sp.PLAN_WEEK < DATEADD(week, 8, DATE_TRUNC('week', (SELECT as_of_date FROM params)))
                 THEN sp.QUANTITY ELSE 0 END) - COALESCE(cws."Current Week Realized Supply", 0)
        ) / 8.0 AS "Average Supply Plan, next 8 weeks"
    FROM supply_plan_base sp
    LEFT JOIN current_week_supply_realized cws
        ON sp.PART_NUMBER = cws.PART_NUMBER
    WHERE sp.PLAN_DATE IS NOT NULL
    GROUP BY sp.PART_NUMBER, cws."Current Week Realized Supply"
),
alternate_supply_plan_metrics AS (
    SELECT
        ab.BASE_PART_NUMBER AS PART_NUMBER,
        COALESCE(acws."Current Week Realized Supply with alternates", 0) AS "Current Week Realized Supply with alternates",
        SUM(CASE WHEN sp.PLAN_WEEK >= DATE_TRUNC('week', (SELECT as_of_date FROM params))
                  AND sp.PLAN_WEEK < DATEADD(week, 4, DATE_TRUNC('week', (SELECT as_of_date FROM params)))
             THEN sp.QUANTITY ELSE 0 END) - COALESCE(acws."Current Week Realized Supply with alternates", 0) AS "Total Supply Plan, next 4 weeks with alternates",
        SUM(CASE WHEN sp.PLAN_WEEK >= DATE_TRUNC('week', (SELECT as_of_date FROM params))
                  AND sp.PLAN_WEEK < DATEADD(week, 8, DATE_TRUNC('week', (SELECT as_of_date FROM params)))
             THEN sp.QUANTITY ELSE 0 END) - COALESCE(acws."Current Week Realized Supply with alternates", 0) AS "Total Supply Plan, next 8 weeks with alternates",
        (
            SUM(CASE WHEN sp.PLAN_WEEK >= DATE_TRUNC('week', (SELECT as_of_date FROM params))
                      AND sp.PLAN_WEEK < DATEADD(week, 4, DATE_TRUNC('week', (SELECT as_of_date FROM params)))
                 THEN sp.QUANTITY ELSE 0 END) - COALESCE(acws."Current Week Realized Supply with alternates", 0)
        ) / 4.0 AS "Average Supply Plan, next 4 weeks with alternates",
        (
            SUM(CASE WHEN sp.PLAN_WEEK >= DATE_TRUNC('week', (SELECT as_of_date FROM params))
                      AND sp.PLAN_WEEK < DATEADD(week, 8, DATE_TRUNC('week', (SELECT as_of_date FROM params)))
                 THEN sp.QUANTITY ELSE 0 END) - COALESCE(acws."Current Week Realized Supply with alternates", 0)
        ) / 8.0 AS "Average Supply Plan, next 8 weeks with alternates"
    FROM alternate_part_bridge ab
    LEFT JOIN supply_plan_base sp
        ON sp.PART_NUMBER = ab.RELATED_PART_NUMBER
       AND sp.PLAN_DATE IS NOT NULL
    LEFT JOIN alternate_current_week_supply_realized acws
        ON ab.BASE_PART_NUMBER = acws.PART_NUMBER
    GROUP BY ab.BASE_PART_NUMBER, acws."Current Week Realized Supply with alternates"
)
SELECT
    fpl.PATH,
    fpl.PATH_WITHOUT_REVISION,
    fpl.PART_NUMBER,
    fpl.REVISION,
    fpl.PRODUCT_NAME,
    fpl.PRODUCTION_STATE,
    fpl.INDENT_LEVEL,
    fpl.UOM,
    fpl.TRACKING,
    fpl.IS_CONSUMABLE_STORABLE,
    fpl.PARENT_BOM,
    fpl.PARENT_REVISION,
    fpl.TOP_LEVEL_BOM,
    fpl.TOP_LEVEL_REVISION,
    fpl.QUANTITY,
    fpl.PROCUREMENT_INTENT,
    fpl.ADJUSTED_QUANTITY,
    prq."total rolled up quantity",
    fpl.ADJUSTED_PROCUREMENT_INTENT,
    fpl.GLOBAL_ALTERNATE_PART_NUMBERS,
    fpl.SUBSTITUTE_PART_NUMBERS,
    pa."Supply Plan and On-Hand Alternates",
    lpo."Latest PO",
    lpo."Latest Supplier",
    lpo."Latest PO Creation Date",
    fpl."Product",
    fpl."Variant",
    fpl."System",
    fpl."Subsystem",
    fpl.Commodity,
    dm."Gross Demand for BOM Line in past 8 weeks",
    pdm."Net Total Demand for Part Number in past 8 weeks",
    pdm."Current Week Realized Demand Consumption",
    dm."Gross Demand for BOM Line in next 8 weeks",
    pdm."Net Total Demand for Part Number in next 8 weeks",
    rm."Quantity Received, 4-Week Rolling Average",
    rm."Quantity Received, 8-Week Rolling Average",
    rm."Quantity Received, Average Since Last Receipt",
    arm."Quantity Received, 4-Week Rolling Average with alternates",
    arm."Quantity Received, 8-Week Rolling Average with alternates",
    arm."Quantity Received, Average Since Last Receipt with alternates",
    im."Current On-Hand Quantity",
    COALESCE(im."Current On-Hand Quantity", 0)
        - COALESCE(pdm."Net Total Demand for Part Number in current week", 0) AS "On Hand Delta to Current Week Demand (each)",
    im."Current Quarantine Quantity",
    aim."Current On-Hand Quantity with alternates",
    CASE
        WHEN prq."total rolled up quantity" = 'mutliple'
          OR prq.TOTAL_ROLLED_UP_QUANTITY_NUMERIC IS NULL
          OR prq.TOTAL_ROLLED_UP_QUANTITY_NUMERIC = 0 THEN NULL
        ELSE COALESCE(aim."Current On-Hand Quantity with alternates", 0) / prq.TOTAL_ROLLED_UP_QUANTITY_NUMERIC
    END AS "on hand product sets including alternates",
    aim."Current Quarantine Quantity with alternates",
    spm."Current Week Realized Supply",
    spm."Total Supply Plan, next 4 weeks",
    spm."Total Supply Plan, next 8 weeks",
    spm."Average Supply Plan, next 4 weeks",
    spm."Average Supply Plan, next 8 weeks",
    aspm."Current Week Realized Supply with alternates",
    aspm."Total Supply Plan, next 4 weeks with alternates",
    aspm."Total Supply Plan, next 8 weeks with alternates",
    aspm."Average Supply Plan, next 4 weeks with alternates",
    aspm."Average Supply Plan, next 8 weeks with alternates",
    CASE
        WHEN COALESCE(pdm."Net Total Demand for Part Number in next 8 weeks", 0) = 0 THEN '>= 3 weeks of demand'
        WHEN COALESCE(aim."Current On-Hand Quantity with alternates", 0) >= COALESCE(pdm."Net Total Demand for Part Number in next 8 weeks", 0) * 3.0 / 8.0 THEN '>= 3 weeks of demand'
        WHEN COALESCE(aim."Current On-Hand Quantity with alternates", 0) >= COALESCE(pdm."Net Total Demand for Part Number in next 8 weeks", 0) / 4.0 THEN '>= 2 weeks and < 3 weeks of demand'
        WHEN COALESCE(aim."Current On-Hand Quantity with alternates", 0) >= COALESCE(pdm."Net Total Demand for Part Number in next 8 weeks", 0) / 8.0 THEN '>= 1 week and < 2 weeks of demand'
        ELSE '< 1 week of demand'
    END AS "On Hand Inventory Status",
    CASE
        WHEN COALESCE(pdm."Net Total Demand for Part Number in next 8 weeks", 0) = 0 THEN '>= 100% of total demand next 8 weeks'
        WHEN COALESCE(aspm."Total Supply Plan, next 8 weeks with alternates", 0) >= COALESCE(pdm."Net Total Demand for Part Number in next 8 weeks", 0) THEN '>= 100% of total demand next 8 weeks'
        WHEN COALESCE(aspm."Total Supply Plan, next 8 weeks with alternates", 0) >= COALESCE(pdm."Net Total Demand for Part Number in next 8 weeks", 0) * 0.9 THEN '>= 90% and < 100% of total demand next 8 weeks'
        WHEN COALESCE(aspm."Total Supply Plan, next 8 weeks with alternates", 0) >= COALESCE(pdm."Net Total Demand for Part Number in next 8 weeks", 0) * 0.5 THEN '>= 50% and < 90% of total demand next 8 weeks'
        ELSE '< 50% of total demand next 8 weeks'
    END AS "Supply Plan Status",
    CASE
        WHEN COALESCE(pdm."Net Total Demand for Part Number in past 8 weeks", 0) = 0 THEN '>= 100% of total demand past 8 weeks'
        WHEN COALESCE(arm."Quantity Received, 8-Week Rolling Average with alternates", 0) * 8 >= COALESCE(pdm."Net Total Demand for Part Number in past 8 weeks", 0) THEN '>= 100% of total demand past 8 weeks'
        WHEN COALESCE(arm."Quantity Received, 8-Week Rolling Average with alternates", 0) * 8 >= COALESCE(pdm."Net Total Demand for Part Number in past 8 weeks", 0) * 0.9 THEN '>= 90% and < 100% of total demand past 8 weeks'
        WHEN COALESCE(arm."Quantity Received, 8-Week Rolling Average with alternates", 0) * 8 >= COALESCE(pdm."Net Total Demand for Part Number in past 8 weeks", 0) * 0.5 THEN '>= 50% and < 90% of total demand past 8 weeks'
        ELSE '< 50% of total demand past 8 weeks'
    END AS "Avg Shipments Status"
FROM flat_parts_lookup fpl
LEFT JOIN part_rollup_quantity prq
    ON fpl.PART_NUMBER = prq.PART_NUMBER
LEFT JOIN planning_alternates pa
    ON fpl.PART_NUMBER = pa.PART_NUMBER
LEFT JOIN latest_issued_po lpo
    ON fpl.PART_NUMBER = lpo.PART_NUMBER
   AND COALESCE(fpl.REVISION, '') = COALESCE(lpo.REVISION, '')
LEFT JOIN demand_metrics dm
    ON fpl.PATH = dm.PATH
LEFT JOIN part_number_demand_metrics pdm
    ON fpl.PART_NUMBER = pdm.PART_NUMBER
   AND COALESCE(fpl.REVISION, '') = COALESCE(pdm.REVISION, '')
LEFT JOIN receipt_metrics rm
    ON fpl.PART_NUMBER = rm.PART_NUMBER
LEFT JOIN alternate_receipt_metrics arm
    ON fpl.PART_NUMBER = arm.PART_NUMBER
LEFT JOIN inventory_metrics im
    ON fpl.PART_NUMBER = im.PART_NUMBER
LEFT JOIN alternate_inventory_metrics aim
    ON fpl.PART_NUMBER = aim.PART_NUMBER
LEFT JOIN supply_plan_metrics spm
    ON fpl.PART_NUMBER = spm.PART_NUMBER
LEFT JOIN alternate_supply_plan_metrics aspm
    ON fpl.PART_NUMBER = aspm.PART_NUMBER
ORDER BY fpl.PATH
