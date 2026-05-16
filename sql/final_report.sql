WITH eligible_top_levels AS (
    SELECT DISTINCT
        PART_NUMBER,
        REVISION
    FROM ${capacity_demand}
    WHERE PART_NUMBER IS NOT NULL
),
demanded_top_level_boms AS (
    SELECT DISTINCT
        et.PART_NUMBER,
        et.REVISION
    FROM eligible_top_levels et
    WHERE NOT EXISTS (
        SELECT 1
        FROM ${bom_hierarchy} child_bom
        WHERE child_bom.PART_NUMBER = et.PART_NUMBER
          AND (
              NULLIF(TRIM(child_bom.PARENT_BOM), '') IS NOT NULL
              OR COALESCE(child_bom.INDENT_LEVEL, 0) > 0
          )
    )
),
non_top_level_assemblies AS (
    SELECT DISTINCT
        PART_NUMBER
    FROM ${bom_hierarchy}
    WHERE PART_NUMBER IS NOT NULL
      AND (
          NULLIF(TRIM(PARENT_BOM), '') IS NOT NULL
          OR COALESCE(INDENT_LEVEL, 0) > 0
      )
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
    FROM ${bom_hierarchy} bh
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
        bpn.PART_NUMBER,
        bpn.TOP_LEVEL_BOM,
        COALESCE(bpn.TOP_LEVEL_REVISION, '') AS TOP_LEVEL_REVISION,
        SUM(COALESCE(bpn.ADJUSTED_QUANTITY, 0)) AS TOTAL_ROLLED_UP_QUANTITY
    FROM bom_path_normalized bpn
    INNER JOIN demanded_top_level_boms dtlb
        ON bpn.TOP_LEVEL_BOM = dtlb.PART_NUMBER
       AND COALESCE(bpn.TOP_LEVEL_REVISION, '') = COALESCE(dtlb.REVISION, '')
    WHERE bpn.PART_NUMBER IS NOT NULL
      AND bpn.TOP_LEVEL_BOM IS NOT NULL
      AND bpn.ADJUSTED_PROCUREMENT_INTENT = 'zipline_buy'
    GROUP BY bpn.PART_NUMBER, bpn.TOP_LEVEL_BOM, COALESCE(bpn.TOP_LEVEL_REVISION, '')
),
part_rollup_quantity AS (
    SELECT
        PART_NUMBER,
        CAST(MAX(TOTAL_ROLLED_UP_QUANTITY) AS FLOAT) AS "total rolled up quantity",
        CAST(MAX(TOTAL_ROLLED_UP_QUANTITY) AS FLOAT) AS TOTAL_ROLLED_UP_QUANTITY_NUMERIC
    FROM part_top_level_rollup
    GROUP BY PART_NUMBER
),
parent_top_level_rollup AS (
    SELECT
        bpn.PART_NUMBER AS PARENT_PART_NUMBER,
        bpn.TOP_LEVEL_BOM,
        COALESCE(bpn.TOP_LEVEL_REVISION, '') AS TOP_LEVEL_REVISION,
        CAST(SUM(COALESCE(bpn.ADJUSTED_QUANTITY, 0)) AS FLOAT) AS PARENT_ROLLED_UP_QUANTITY
    FROM bom_path_normalized bpn
    INNER JOIN demanded_top_level_boms dtlb
        ON bpn.TOP_LEVEL_BOM = dtlb.PART_NUMBER
       AND COALESCE(bpn.TOP_LEVEL_REVISION, '') = COALESCE(dtlb.REVISION, '')
    INNER JOIN non_top_level_assemblies ntla
        ON bpn.PART_NUMBER = ntla.PART_NUMBER
    WHERE bpn.PART_NUMBER IS NOT NULL
      AND bpn.TOP_LEVEL_BOM IS NOT NULL
    GROUP BY bpn.PART_NUMBER, bpn.TOP_LEVEL_BOM, COALESCE(bpn.TOP_LEVEL_REVISION, '')
),
bom_line_parent_usage AS (
    SELECT
        child.PATH,
        ancestor.PART_NUMBER AS PARENT_PART_NUMBER,
        ancestor.TOP_LEVEL_BOM,
        COALESCE(ancestor.TOP_LEVEL_REVISION, '') AS TOP_LEVEL_REVISION,
        COALESCE(child.ADJUSTED_QUANTITY, 0) / NULLIF(COALESCE(ancestor.ADJUSTED_QUANTITY, 0), 0) AS CHILD_QUANTITY_IN_PARENT
    FROM bom_path_normalized child
    INNER JOIN bom_path_normalized ancestor
        ON child.TOP_LEVEL_BOM = ancestor.TOP_LEVEL_BOM
       AND COALESCE(child.TOP_LEVEL_REVISION, '') = COALESCE(ancestor.TOP_LEVEL_REVISION, '')
       AND child.PATH_WITHOUT_REVISION <> ancestor.PATH_WITHOUT_REVISION
       AND LEFT(child.PATH_WITHOUT_REVISION, LENGTH(ancestor.PATH_WITHOUT_REVISION)) = ancestor.PATH_WITHOUT_REVISION
    INNER JOIN non_top_level_assemblies ntla
        ON ancestor.PART_NUMBER = ntla.PART_NUMBER
    WHERE child.PART_NUMBER IS NOT NULL
      AND child.TOP_LEVEL_BOM IS NOT NULL
),
demand_base AS (
    SELECT
        cd.PART_NUMBER AS TOP_LEVEL_BOM,
        cd.REVISION AS TOP_LEVEL_REVISION,
        cd.QUANTITY AS DEMAND_QUANTITY,
        cd.DEMAND_TYPE,
        TRY_TO_DATE(cd.DATE, 'MM/DD/YYYY') AS DEMAND_DATE,
        DATE_TRUNC('week', TRY_TO_DATE(cd.DATE, 'MM/DD/YYYY')) AS DEMAND_WEEK
    FROM ${capacity_demand} cd
    WHERE cd.PART_NUMBER IS NOT NULL
),
demand_metrics AS (
    SELECT
        bpn.PATH,
        bpn.PART_NUMBER,
        bpn.REVISION,
        SUM(
            CASE
                WHEN db.DEMAND_WEEK >= DATEADD(week, -7, DATE_TRUNC('week', TO_DATE('${as_of_date}')))
                 AND db.DEMAND_WEEK <= DATE_TRUNC('week', TO_DATE('${as_of_date}'))
                THEN db.DEMAND_QUANTITY * COALESCE(bpn.ADJUSTED_QUANTITY, 0)
                ELSE 0
            END
        ) AS "Gross Demand for BOM Line in past 8 weeks",
        SUM(
            CASE
                WHEN db.DEMAND_WEEK >= DATE_TRUNC('week', TO_DATE('${as_of_date}'))
                 AND db.DEMAND_WEEK < DATEADD(week, 4, DATE_TRUNC('week', TO_DATE('${as_of_date}')))
                THEN db.DEMAND_QUANTITY * COALESCE(bpn.ADJUSTED_QUANTITY, 0)
                ELSE 0
            END
        ) AS "Demand for BOM Line in next 4 weeks",
        SUM(
            CASE
                WHEN db.DEMAND_WEEK >= DATE_TRUNC('week', TO_DATE('${as_of_date}'))
                 AND db.DEMAND_WEEK < DATEADD(week, 8, DATE_TRUNC('week', TO_DATE('${as_of_date}')))
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
                WHEN db.DEMAND_WEEK >= DATEADD(week, -7, DATE_TRUNC('week', TO_DATE('${as_of_date}')))
                 AND db.DEMAND_WEEK <= DATE_TRUNC('week', TO_DATE('${as_of_date}'))
                THEN db.DEMAND_QUANTITY * COALESCE(bpn.ADJUSTED_QUANTITY, 0)
                ELSE 0
            END
        ) AS GROSS_PAST_8_WEEKS_DEMAND,
        SUM(
            CASE
                WHEN db.DEMAND_WEEK >= DATE_TRUNC('week', TO_DATE('${as_of_date}'))
                 AND db.DEMAND_WEEK < DATEADD(week, 8, DATE_TRUNC('week', TO_DATE('${as_of_date}')))
                THEN db.DEMAND_QUANTITY * COALESCE(bpn.ADJUSTED_QUANTITY, 0)
                ELSE 0
            END
        ) AS GROSS_NEXT_8_WEEKS_DEMAND,
        SUM(
            CASE
                WHEN db.DEMAND_WEEK = DATE_TRUNC('week', TO_DATE('${as_of_date}'))
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
part_number_current_week_gross_demand AS (
    SELECT
        bpn.PART_NUMBER,
        bpn.REVISION,
        SUM(
            CASE
                WHEN db.DEMAND_WEEK = DATE_TRUNC('week', TO_DATE('${as_of_date}'))
                THEN db.DEMAND_QUANTITY * COALESCE(bpn.ADJUSTED_QUANTITY, 0)
                ELSE 0
            END
        ) AS "Current Week Total Gross Demand"
    FROM bom_path_normalized bpn
    LEFT JOIN demand_base db
        ON bpn.TOP_LEVEL_BOM = db.TOP_LEVEL_BOM
       AND COALESCE(bpn.TOP_LEVEL_REVISION, '') = COALESCE(db.TOP_LEVEL_REVISION, '')
    GROUP BY bpn.PART_NUMBER, bpn.REVISION
),
structured_bom_lookup AS (
    SELECT
        bpn.*,
        sbsd.PRODUCT AS "Product",
        sbsd.VARIANT AS "Variant",
        sbsd.SYSTEM AS "System",
        sbsd.SUBSYSTEM AS "Subsystem"
    FROM bom_path_normalized bpn
    LEFT JOIN ${structured_bom_data} sbsd
        ON bpn.PATH_WITHOUT_REVISION = sbsd.PATH_WITHOUT_REV
),
flat_parts_lookup AS (
    SELECT
        sbl.*,
        fpl.NEW_COMMODITY AS Commodity
    FROM structured_bom_lookup sbl
    LEFT JOIN ${flat_parts_list} fpl
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
        f.index AS PART_INDEX,
        TRIM(f.value::string) AS PART_NUMBER
    FROM ${alternate_part_numbers} alt,
         LATERAL FLATTEN(input => SPLIT(alt.${alternate_part_numbers_column}, ',')) f
    WHERE TRIM(f.value::string) <> ''
),
original_alternate_part_bridge AS (
    SELECT DISTINCT
        original_part.PART_NUMBER AS BASE_PART_NUMBER,
        alternate_part.PART_NUMBER AS RELATED_PART_NUMBER
    FROM alternate_part_groups original_part
    INNER JOIN alternate_part_groups alternate_part
        ON original_part.GROUP_ID = alternate_part.GROUP_ID
    WHERE original_part.PART_INDEX = 0
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
latest_zerp_po_line_versions AS (
    SELECT
        pol.ID,
        po.PURCHASE_ORDER_NUMBER,
        pol.LINE_NUMBER,
        pol.CREATED_AT AS PO_CREATED_AT_LOCAL,
        op.DEFAULT_CODE AS PART_NUMBER,
        suppliers.NAME AS SUPPLIER_NAME,
        pol.MAJOR_REVISION_NAME AS REVISION,
        pol.UNIT_PRICE_UCENTS / 100000000.0 AS UNIT_PRICE,
        ouom.FACTOR AS UOM_FACTOR,
        CASE
            WHEN ouom.FACTOR IS NULL THEN pol.UNIT_PRICE_UCENTS / 100000000.0
            ELSE pol.UNIT_PRICE_UCENTS / 100000000.0 * ouom.FACTOR
        END AS UNIT_COST,
        ROW_NUMBER() OVER (
            PARTITION BY po.PURCHASE_ORDER_NUMBER, pol.LINE_NUMBER, op.DEFAULT_CODE
            ORDER BY pol.CREATED_AT DESC, pol.ID DESC
        ) AS LINE_VERSION_RN
    FROM BIZ.DBT_STG.STG_ZERP_PURCHASING__PURCHASE_ORDER_LINE pol
    LEFT JOIN BIZ.DBT_STG.STG_ZERP_PURCHASING__PURCHASE_ORDER_VERSION pov
        ON pol.PURCHASE_ORDER_VERSION_ID = pov.ID
    LEFT JOIN BIZ.DBT_STG.STG_ZERP_PURCHASING__PURCHASE_ORDER po
        ON pov.PURCHASE_ORDER_ID = po.ID
    LEFT JOIN BIZ.DBT_STG.STG_ODOO_PROD__PRODUCT_TEMPLATE op
        ON pol.ODOO_PART_ID = op.ID
    LEFT JOIN BIZ.DBT_STG.STG_ZERP_PURCHASING__SUPPLIER suppliers
        ON suppliers.ID = pov.SUPPLIER_ID
    LEFT JOIN BIZ.DBT_STG.STG_ZERP_PURCHASING__UOM zuom
        ON pol.UNIT_OF_MEASURE_ID = zuom.ID
    LEFT JOIN BIZ.DBT_STG.STG_ODOO_PROD__UOM_UOM ouom
        ON zuom.ODOO_ID = ouom.ID
    WHERE pov.STATUS = 'ISSUED'
      AND op.DEFAULT_CODE IS NOT NULL
),
latest_zerp_po_lines AS (
    SELECT
        ID,
        PURCHASE_ORDER_NUMBER,
        LINE_NUMBER,
        PO_CREATED_AT_LOCAL,
        PART_NUMBER,
        SUPPLIER_NAME,
        REVISION,
        UNIT_PRICE,
        UOM_FACTOR,
        UNIT_COST
    FROM latest_zerp_po_line_versions
    WHERE LINE_VERSION_RN = 1
),
latest_issued_po_candidates AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY PART_NUMBER, COALESCE(REVISION, '')
            ORDER BY PO_CREATED_AT_LOCAL DESC, PURCHASE_ORDER_NUMBER DESC, LINE_NUMBER DESC, ID DESC
        ) AS RN
    FROM latest_zerp_po_lines
),
latest_issued_po AS (
    SELECT
        PART_NUMBER,
        REVISION,
        PURCHASE_ORDER_NUMBER AS "Latest PO",
        SUPPLIER_NAME AS "Latest Supplier",
        PO_CREATED_AT_LOCAL AS "Latest PO Creation Date",
        UNIT_COST
    FROM latest_issued_po_candidates
    WHERE RN = 1
),
part_unit_cost_candidates AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY PART_NUMBER
            ORDER BY PO_CREATED_AT_LOCAL DESC, PURCHASE_ORDER_NUMBER DESC, LINE_NUMBER DESC, ID DESC
        ) AS RN
    FROM latest_zerp_po_lines
),
part_unit_costs AS (
    SELECT
        PART_NUMBER,
        UNIT_COST
    FROM part_unit_cost_candidates
    WHERE RN = 1
),
location_category_map AS (
    SELECT
        sl.ID,
        sl.COMPLETE_NAME,
        CASE
            WHEN sl.COMPLETE_NAME LIKE 'Vendors%' THEN 'Vendors'
            WHEN sl.COMPLETE_NAME LIKE 'Zipline%' THEN 'Production'
            WHEN sl.COMPLETE_NAME LIKE 'COOP/WH/Stock/SO Parts Pick%' THEN 'Nest'
            WHEN sl.COMPLETE_NAME LIKE 'COOP/Quarantine/Rework/Production%' THEN 'Warehouse'
            WHEN sl.COMPLETE_NAME LIKE 'COOP/Quarantine/Rework/Zipping Point%' THEN 'Warehouse'
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
            WHEN sl.COMPLETE_NAME LIKE 'COOP/FAI Pre-Inspection%' THEN 'Receiving & Pre-IQC'
            WHEN sl.COMPLETE_NAME LIKE 'COOP/Input%' THEN 'Receiving & Pre-IQC'
            WHEN sl.COMPLETE_NAME LIKE 'COOP/Inspection/IQC%' THEN 'Receiving & Pre-IQC'
            WHEN sl.COMPLETE_NAME LIKE 'COOP/Inspected%' THEN 'Warehouse'
            WHEN sl.COMPLETE_NAME LIKE 'COOP/Inspection%' THEN 'Warehouse'
            WHEN sl.COMPLETE_NAME LIKE 'COOP/Manufacturing%' THEN 'Warehouse'
            WHEN sl.COMPLETE_NAME LIKE 'COOP/OQC%' THEN 'Warehouse'
            WHEN sl.COMPLETE_NAME LIKE 'COOP/P2/OQC Inspection/Feeder (WIP)%' THEN 'Warehouse'
            WHEN sl.COMPLETE_NAME LIKE 'COOP/P2/Inspected%' THEN 'Warehouse'
            WHEN sl.COMPLETE_NAME LIKE 'COOP/P1 Manufacturing%' THEN 'Warehouse'
            WHEN sl.COMPLETE_NAME LIKE 'COOP/P2/WH%' THEN 'Warehouse'
            WHEN sl.COMPLETE_NAME LIKE 'COOP/Packout%' THEN 'Warehouse'
            WHEN sl.COMPLETE_NAME LIKE 'COOP/P2/Post-Inspection/Feeder (WIP)%' THEN 'Warehouse'
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
            WHEN sl.COMPLETE_NAME LIKE 'COOP/Outbound/Pack/Customers Drop Off%' THEN 'R&D'
            WHEN sl.COMPLETE_NAME LIKE 'COOP/R&D%' THEN 'R&D'
            WHEN sl.COMPLETE_NAME LIKE 'R&D%' THEN 'R&D'
            WHEN sl.COMPLETE_NAME LIKE 'ROST%' THEN 'R&D'
            WHEN sl.COMPLETE_NAME LIKE '%RMA%' THEN 'Nest'
            ELSE 'Unknown'
        END AS MRP_CATEGORY
    FROM ${stock_location} sl
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
            WHEN origin.MRP_CATEGORY = 'Vendors' AND destination.MRP_CATEGORY IN ('Warehouse', 'Receiving & Pre-IQC') THEN 'New Supply'
            WHEN origin.MRP_CATEGORY IN ('Warehouse', 'Receiving & Pre-IQC') AND destination.MRP_CATEGORY = 'Vendors' THEN 'New Supply'
            WHEN origin.MRP_CATEGORY IN ('Warehouse', 'Receiving & Pre-IQC') AND destination.MRP_CATEGORY = 'Nest' THEN 'Nest Consumption'
            WHEN origin.MRP_CATEGORY = 'Nest' AND destination.MRP_CATEGORY IN ('Warehouse', 'Receiving & Pre-IQC') THEN 'RMA Supply'
            WHEN origin.MRP_CATEGORY IN ('Warehouse', 'Receiving & Pre-IQC') AND destination.MRP_CATEGORY = 'Production' THEN 'Production Consumption'
            WHEN origin.MRP_CATEGORY = 'Production' AND destination.MRP_CATEGORY IN ('Warehouse', 'Receiving & Pre-IQC') THEN 'Production Consumption'
            WHEN origin.MRP_CATEGORY IN ('Warehouse', 'Receiving & Pre-IQC') AND destination.MRP_CATEGORY = 'Scrap' THEN 'QC Loss Consumption'
            WHEN origin.MRP_CATEGORY IN ('Warehouse', 'Receiving & Pre-IQC') AND destination.MRP_CATEGORY = 'Quarantine' THEN 'QC Loss Consumption'
            WHEN origin.MRP_CATEGORY = 'Quarantine' AND destination.MRP_CATEGORY IN ('Warehouse', 'Receiving & Pre-IQC') THEN 'QC Loss Consumption'
            WHEN origin.MRP_CATEGORY = 'Scrap' AND destination.MRP_CATEGORY IN ('Warehouse', 'Receiving & Pre-IQC') THEN 'QC Loss Consumption'
            WHEN origin.MRP_CATEGORY IN ('Warehouse', 'Receiving & Pre-IQC') AND destination.MRP_CATEGORY = 'R&D' THEN 'R&D Consumption'
            WHEN origin.MRP_CATEGORY = 'R&D' AND destination.MRP_CATEGORY IN ('Warehouse', 'Receiving & Pre-IQC') THEN 'R&D Supply'
            ELSE 'Unknown'
        END AS TRANSACTION_CATEGORY_2,
        CASE
            WHEN origin.MRP_CATEGORY = 'Vendors' AND destination.MRP_CATEGORY IN ('Warehouse', 'Receiving & Pre-IQC') THEN sm.PRODUCT_QTY
            WHEN origin.MRP_CATEGORY IN ('Warehouse', 'Receiving & Pre-IQC') AND destination.MRP_CATEGORY = 'Vendors' THEN -sm.PRODUCT_QTY
            WHEN origin.MRP_CATEGORY IN ('Warehouse', 'Receiving & Pre-IQC') AND destination.MRP_CATEGORY = 'Nest' THEN sm.PRODUCT_QTY
            WHEN origin.MRP_CATEGORY = 'Nest' AND destination.MRP_CATEGORY IN ('Warehouse', 'Receiving & Pre-IQC') THEN sm.PRODUCT_QTY
            WHEN origin.MRP_CATEGORY IN ('Warehouse', 'Receiving & Pre-IQC') AND destination.MRP_CATEGORY = 'Production' THEN sm.PRODUCT_QTY
            WHEN origin.MRP_CATEGORY = 'Production' AND destination.MRP_CATEGORY IN ('Warehouse', 'Receiving & Pre-IQC') THEN -sm.PRODUCT_QTY
            WHEN origin.MRP_CATEGORY IN ('Warehouse', 'Receiving & Pre-IQC') AND destination.MRP_CATEGORY = 'Scrap' THEN sm.PRODUCT_QTY
            WHEN origin.MRP_CATEGORY IN ('Warehouse', 'Receiving & Pre-IQC') AND destination.MRP_CATEGORY = 'Quarantine' THEN sm.PRODUCT_QTY
            WHEN origin.MRP_CATEGORY = 'Quarantine' AND destination.MRP_CATEGORY IN ('Warehouse', 'Receiving & Pre-IQC') THEN -sm.PRODUCT_QTY
            WHEN origin.MRP_CATEGORY = 'Scrap' AND destination.MRP_CATEGORY IN ('Warehouse', 'Receiving & Pre-IQC') THEN -sm.PRODUCT_QTY
            WHEN origin.MRP_CATEGORY IN ('Warehouse', 'Receiving & Pre-IQC') AND destination.MRP_CATEGORY = 'R&D' THEN sm.PRODUCT_QTY
            WHEN origin.MRP_CATEGORY = 'R&D' AND destination.MRP_CATEGORY IN ('Warehouse', 'Receiving & Pre-IQC') THEN sm.PRODUCT_QTY
            ELSE NULL
        END AS TRANSACTION_QUANTITY_2
    FROM ${stock_move} sm
    LEFT JOIN ${product_product} p
        ON p.ID = sm.PRODUCT_ID
    LEFT JOIN ${product_template} pt
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
                WHEN RECEIPT_WEEK = DATE_TRUNC('week', TO_DATE('${as_of_date}'))
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
                WHEN DATE_TRUNC('week', DATE) = DATE_TRUNC('week', TO_DATE('${as_of_date}'))
                 AND TRANSACTION_CATEGORY_2 = 'Production Consumption'
                THEN TRANSACTION_QUANTITY_2
                ELSE 0
            END
        ) AS PRODUCTION_CONSUMPTION_THIS_WEEK,
        SUM(
            CASE
                WHEN DATE_TRUNC('week', DATE) = DATE_TRUNC('week', TO_DATE('${as_of_date}'))
                 AND TRANSACTION_CATEGORY_2 = 'Nest Consumption'
                THEN TRANSACTION_QUANTITY_2
                ELSE 0
            END
        ) AS NEST_CONSUMPTION_THIS_WEEK
    FROM stock_moves_enriched
    GROUP BY PART_NUMBER
),
part_number_weekly_demand_by_type AS (
    SELECT
        bpn.PART_NUMBER,
        bpn.REVISION,
        db.DEMAND_WEEK,
        db.DEMAND_TYPE,
        SUM(db.DEMAND_QUANTITY * COALESCE(bpn.ADJUSTED_QUANTITY, 0)) AS GROSS_WEEK_DEMAND
    FROM bom_path_normalized bpn
    INNER JOIN demand_base db
        ON bpn.TOP_LEVEL_BOM = db.TOP_LEVEL_BOM
       AND COALESCE(bpn.TOP_LEVEL_REVISION, '') = COALESCE(db.TOP_LEVEL_REVISION, '')
    WHERE db.DEMAND_WEEK >= DATE_TRUNC('week', TO_DATE('${as_of_date}'))
    GROUP BY bpn.PART_NUMBER, bpn.REVISION, db.DEMAND_WEEK, db.DEMAND_TYPE
),
part_number_weekly_remaining_demand AS (
    SELECT
        pwd.PART_NUMBER,
        pwd.REVISION,
        pwd.DEMAND_WEEK,
        CAST(
            GREATEST(
                SUM(COALESCE(pwd.GROSS_WEEK_DEMAND, 0))
                    - SUM(
                        CASE
                            WHEN pwd.DEMAND_WEEK = DATE_TRUNC('week', TO_DATE('${as_of_date}'))
                             AND pwd.DEMAND_TYPE = 'Production'
                            THEN COALESCE(cwd.PRODUCTION_CONSUMPTION_THIS_WEEK, 0)
                            WHEN pwd.DEMAND_WEEK = DATE_TRUNC('week', TO_DATE('${as_of_date}'))
                             AND pwd.DEMAND_TYPE = 'Spares'
                            THEN COALESCE(cwd.NEST_CONSUMPTION_THIS_WEEK, 0)
                            ELSE 0
                        END
                    ),
                0
            )
            AS FLOAT
        ) AS WEEK_DEMAND
    FROM part_number_weekly_demand_by_type pwd
    LEFT JOIN current_week_demand_consumption cwd
        ON pwd.PART_NUMBER = cwd.PART_NUMBER
    GROUP BY pwd.PART_NUMBER, pwd.REVISION, pwd.DEMAND_WEEK
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
        MAX(COALESCE(cwg."Current Week Total Gross Demand", 0)) AS "Current Week Total Gross Demand",
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
    LEFT JOIN part_number_current_week_gross_demand cwg
        ON pd.PART_NUMBER = cwg.PART_NUMBER
       AND COALESCE(pd.REVISION, '') = COALESCE(cwg.REVISION, '')
    GROUP BY pd.PART_NUMBER, pd.REVISION
),
receipt_metrics AS (
    SELECT
        PART_NUMBER,
        SUM(
            CASE
                WHEN RECEIPT_WEEK >= DATEADD(week, -3, DATE_TRUNC('week', TO_DATE('${as_of_date}')))
                 AND RECEIPT_WEEK <= DATE_TRUNC('week', TO_DATE('${as_of_date}'))
                THEN TRANSACTION_QUANTITY_2
                ELSE 0
            END
        ) / 4.0 AS "Quantity Received, 4-Week Rolling Average",
        SUM(
            CASE
                WHEN RECEIPT_WEEK >= DATEADD(week, -7, DATE_TRUNC('week', TO_DATE('${as_of_date}')))
                 AND RECEIPT_WEEK <= DATE_TRUNC('week', TO_DATE('${as_of_date}'))
                THEN TRANSACTION_QUANTITY_2
                ELSE 0
            END
        ) / 8.0 AS "Quantity Received, 8-Week Rolling Average",
        MAX_BY(TRANSACTION_QUANTITY_2, DATE) / NULLIF(DATEDIFF(day, MAX(DATE), TO_DATE('${as_of_date}')) / 7.0, 0) AS "Quantity Received, Average Since Last Receipt"
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
                WHEN rm.RECEIPT_WEEK >= DATEADD(week, -3, DATE_TRUNC('week', TO_DATE('${as_of_date}')))
                 AND rm.RECEIPT_WEEK <= DATE_TRUNC('week', TO_DATE('${as_of_date}'))
                THEN rm.TRANSACTION_QUANTITY_2
                ELSE 0
            END
        ) / 4.0 AS "Quantity Received, 4-Week Rolling Average with alternates",
        SUM(
            CASE
                WHEN rm.RECEIPT_WEEK >= DATEADD(week, -7, DATE_TRUNC('week', TO_DATE('${as_of_date}')))
                 AND rm.RECEIPT_WEEK <= DATE_TRUNC('week', TO_DATE('${as_of_date}'))
                THEN rm.TRANSACTION_QUANTITY_2
                ELSE 0
            END
        ) / 8.0 AS "Quantity Received, 8-Week Rolling Average with alternates",
        arl.TRANSACTION_QUANTITY_2 / NULLIF(DATEDIFF(day, arl.DATE, TO_DATE('${as_of_date}')) / 7.0, 0) AS "Quantity Received, Average Since Last Receipt with alternates"
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
        inv.${inventory_part_number_column} AS PART_NUMBER,
        SUM(CASE WHEN lcm.MRP_CATEGORY IN ('Warehouse', 'Receiving & Pre-IQC') THEN inv.${inventory_quantity_column} ELSE 0 END) AS "Current On-Hand Quantity",
        SUM(CASE WHEN lcm.MRP_CATEGORY IN ('Warehouse', 'Receiving & Pre-IQC') THEN inv.${inventory_quantity_column} * COALESCE(puc.UNIT_COST, 0) ELSE 0 END) AS "Current On-Hand Inventory Value",
        SUM(CASE WHEN lcm.MRP_CATEGORY = 'Receiving & Pre-IQC' THEN inv.${inventory_quantity_column} ELSE 0 END) AS "Current Receiving & Pre-IQC Quantity",
        SUM(CASE WHEN lcm.MRP_CATEGORY = 'Quarantine' THEN inv.${inventory_quantity_column} ELSE 0 END) AS "Current Quarantine Quantity"
    FROM ${inventory} inv
    LEFT JOIN location_category_map lcm
        ON lcm.ID = inv.${inventory_location_id_column}
    LEFT JOIN part_unit_costs puc
        ON puc.PART_NUMBER = inv.${inventory_part_number_column}
    GROUP BY inv.${inventory_part_number_column}
),
shipments_normalized AS (
    SELECT
        SHIPMENT_ID,
        COALESCE(
            REGEXP_REPLACE(
                UPPER(TRIM(RAW_SHIPMENT_STATUS)),
                '[^A-Z0-9]+',
                '_'
            ),
            ''
        ) AS SHIPMENT_STATUS
    FROM (
        SELECT
            SHIPMENT_ID,
            RAW_SHIPMENT_STATUS,
            ROW_NUMBER() OVER (
                PARTITION BY SHIPMENT_ID
                ORDER BY SHIPMENT_UPDATED_AT DESC NULLS LAST, RAW_SHIPMENT_STATUS
            ) AS RN
        FROM (
            SELECT
                COALESCE(
                    TO_VARCHAR(shipment:SHIPMENT_ID),
                    TO_VARCHAR(shipment:ID)
                ) AS SHIPMENT_ID,
                COALESCE(
                    TO_VARCHAR(shipment:${shipment_line_status_column}),
                    TO_VARCHAR(shipment:STATE),
                    TO_VARCHAR(shipment:STATUS),
                    TO_VARCHAR(shipment:SHIPMENT_STATUS)
                ) AS RAW_SHIPMENT_STATUS,
                COALESCE(
                    TRY_TO_TIMESTAMP_NTZ(TO_VARCHAR(shipment:UPDATED_AT)),
                    TRY_TO_TIMESTAMP_NTZ(TO_VARCHAR(shipment:UPDATED_DATE)),
                    TRY_TO_TIMESTAMP_NTZ(TO_VARCHAR(shipment:WRITE_DATE)),
                    TRY_TO_TIMESTAMP_NTZ(TO_VARCHAR(shipment:MODIFIED_AT)),
                    TRY_TO_TIMESTAMP_NTZ(TO_VARCHAR(shipment:_FIVETRAN_SYNCED)),
                    TRY_TO_TIMESTAMP_NTZ(TO_VARCHAR(shipment:CREATED_AT)),
                    TRY_TO_TIMESTAMP_NTZ(TO_VARCHAR(shipment:CREATE_DATE))
                ) AS SHIPMENT_UPDATED_AT
            FROM (
                SELECT OBJECT_CONSTRUCT(*) AS shipment
                FROM ${shipments}
            )
        )
        WHERE SHIPMENT_ID IS NOT NULL
    )
    WHERE RN = 1
),
shipment_lines_normalized AS (
    SELECT
        COALESCE(
            TO_VARCHAR(shipment_line:${shipment_line_part_number_column}),
            TO_VARCHAR(shipment_line:DEFAULT_CODE),
            TO_VARCHAR(shipment_line:PRODUCT_DEFAULT_CODE),
            TO_VARCHAR(shipment_line:PART_NUMBER),
            TO_VARCHAR(shipment_line:ODOO_PART_CODE)
        ) AS PART_NUMBER,
        COALESCE(
            TRY_TO_DOUBLE(TO_VARCHAR(shipment_line:${shipment_line_quantity_column})),
            TRY_TO_DOUBLE(TO_VARCHAR(shipment_line:QUANTITY_IN_SHIPMENT)),
            TRY_TO_DOUBLE(TO_VARCHAR(shipment_line:QUANTITY)),
            TRY_TO_DOUBLE(TO_VARCHAR(shipment_line:PRODUCT_QTY)),
            TRY_TO_DOUBLE(TO_VARCHAR(shipment_line:PRODUCT_UOM_QTY)),
            0
        ) AS QUANTITY,
        s.SHIPMENT_STATUS
    FROM (
        SELECT OBJECT_CONSTRUCT(*) AS shipment_line
        FROM ${shipment_lines}
    ) sl
    INNER JOIN shipments_normalized s
        ON s.SHIPMENT_ID = TO_VARCHAR(shipment_line:SHIPMENT_ID)
),
in_transit_metrics AS (
    SELECT
        sln.PART_NUMBER,
        CAST(SUM(QUANTITY) AS FLOAT) AS IN_TRANSIT_QUANTITY
    FROM shipment_lines_normalized sln
    WHERE sln.PART_NUMBER IS NOT NULL
      AND sln.SHIPMENT_STATUS NOT IN (
          'DRAFT',
          'CANCELED',
          'CANCELLED',
          'DELIVERED',
          'DELIVERED_COMPLETED',
          'COMPLETE',
          'COMPLETED',
          'DONE'
      )
    GROUP BY sln.PART_NUMBER
),
alternate_in_transit_metrics AS (
    SELECT
        rp.PART_NUMBER,
        CAST(
            COALESCE(base_itm.IN_TRANSIT_QUANTITY, 0)
            + COALESCE(SUM(COALESCE(alternate_itm.IN_TRANSIT_QUANTITY, 0)), 0)
            AS FLOAT
        ) AS "in-transit quantity including alternates"
    FROM report_parts rp
    LEFT JOIN in_transit_metrics base_itm
        ON base_itm.PART_NUMBER = rp.PART_NUMBER
    LEFT JOIN original_alternate_part_bridge ab
        ON ab.BASE_PART_NUMBER = rp.PART_NUMBER
    LEFT JOIN in_transit_metrics alternate_itm
        ON alternate_itm.PART_NUMBER = ab.RELATED_PART_NUMBER
       AND ab.RELATED_PART_NUMBER <> rp.PART_NUMBER
       AND alternate_itm.IN_TRANSIT_QUANTITY > 0
    GROUP BY rp.PART_NUMBER, base_itm.IN_TRANSIT_QUANTITY
),
bom_line_parent_metrics AS (
    SELECT
        blpu.PATH,
        CAST(
            SUM(
                COALESCE(parent_im."Current On-Hand Quantity", 0)
                * COALESCE(blpu.CHILD_QUANTITY_IN_PARENT, 0)
            )
            AS FLOAT
        ) AS "On Hand Quantity In Parents",
        CAST(
            SUM(
                CASE
                    WHEN ptlr.PARENT_ROLLED_UP_QUANTITY IS NULL
                      OR ptlr.PARENT_ROLLED_UP_QUANTITY = 0 THEN 0
                    ELSE COALESCE(parent_im."Current On-Hand Quantity", 0)
                        / ptlr.PARENT_ROLLED_UP_QUANTITY
                END
            )
            AS FLOAT
        ) AS ON_HAND_PRODUCT_SETS_IN_PARENTS,
        COUNT(
            CASE
                WHEN ptlr.PARENT_ROLLED_UP_QUANTITY IS NOT NULL
                  AND ptlr.PARENT_ROLLED_UP_QUANTITY <> 0 THEN 1
            END
        ) AS VALID_PARENT_PRODUCT_SET_COUNT
    FROM bom_line_parent_usage blpu
    LEFT JOIN inventory_metrics parent_im
        ON blpu.PARENT_PART_NUMBER = parent_im.PART_NUMBER
    LEFT JOIN parent_top_level_rollup ptlr
        ON blpu.PARENT_PART_NUMBER = ptlr.PARENT_PART_NUMBER
       AND blpu.TOP_LEVEL_BOM = ptlr.TOP_LEVEL_BOM
       AND blpu.TOP_LEVEL_REVISION = ptlr.TOP_LEVEL_REVISION
    GROUP BY blpu.PATH
),
alternate_inventory_metrics AS (
    SELECT
        ab.BASE_PART_NUMBER AS PART_NUMBER,
        SUM(COALESCE(im."Current On-Hand Quantity", 0)) AS "Current On-Hand Quantity with alternates",
        SUM(COALESCE(im."Current On-Hand Inventory Value", 0)) AS "Current On-Hand Inventory Value with alternates",
        SUM(COALESCE(im."Current Receiving & Pre-IQC Quantity", 0)) AS "Current Receiving & Pre-IQC Quantity with alternates",
        SUM(COALESCE(im."Current Quarantine Quantity", 0)) AS "Current Quarantine Quantity with alternates"
    FROM alternate_part_bridge ab
    LEFT JOIN inventory_metrics im
        ON im.PART_NUMBER = ab.RELATED_PART_NUMBER
    GROUP BY ab.BASE_PART_NUMBER
),
week_offsets AS (
    SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1 AS WEEK_OFFSET
    FROM TABLE(GENERATOR(ROWCOUNT => 104))
),
bom_line_demand_horizon AS (
    SELECT
        fpl.PATH,
        fpl.PART_NUMBER,
        fpl.REVISION,
        LEAST(
            103,
            GREATEST(
                0,
                COALESCE(
                    MAX(DATEDIFF(week, DATE_TRUNC('week', TO_DATE('${as_of_date}')), pwrd.DEMAND_WEEK)),
                    0
                )
            )
        ) AS MAX_WEEK_OFFSET
    FROM flat_parts_lookup fpl
    LEFT JOIN part_number_weekly_remaining_demand pwrd
        ON fpl.PART_NUMBER = pwrd.PART_NUMBER
       AND COALESCE(fpl.REVISION, '') = COALESCE(pwrd.REVISION, '')
    WHERE fpl.PART_NUMBER IS NOT NULL
      AND fpl.PATH IS NOT NULL
    GROUP BY fpl.PATH, fpl.PART_NUMBER, fpl.REVISION
),
bom_line_weeks_of_stock_base AS (
    SELECT
        bldh.PATH,
        bldh.PART_NUMBER,
        bldh.REVISION,
        wo.WEEK_OFFSET,
        DATEADD(week, wo.WEEK_OFFSET, DATE_TRUNC('week', TO_DATE('${as_of_date}'))) AS DEMAND_WEEK,
        COALESCE(pwrd.WEEK_DEMAND, 0) AS WEEK_DEMAND,
        COALESCE(aim."Current On-Hand Quantity with alternates", 0)
            + COALESCE(blpm."On Hand Quantity In Parents", 0)
            AS ON_HAND_QUANTITY_INCLUDING_ALTERNATES_AND_PARENTS,
        COALESCE(aim."Current On-Hand Quantity with alternates", 0)
            + COALESCE(blpm."On Hand Quantity In Parents", 0)
            + COALESCE(aitm."in-transit quantity including alternates", 0)
            AS ON_HAND_QUANTITY_INCLUDING_ALTERNATES_PARENTS_AND_IN_TRANSIT,
        COALESCE(aitm."in-transit quantity including alternates", 0) AS IN_TRANSIT_QUANTITY
    FROM bom_line_demand_horizon bldh
    INNER JOIN week_offsets wo
        ON wo.WEEK_OFFSET <= bldh.MAX_WEEK_OFFSET
    LEFT JOIN part_number_weekly_remaining_demand pwrd
        ON bldh.PART_NUMBER = pwrd.PART_NUMBER
       AND COALESCE(bldh.REVISION, '') = COALESCE(pwrd.REVISION, '')
       AND DATEADD(week, wo.WEEK_OFFSET, DATE_TRUNC('week', TO_DATE('${as_of_date}'))) = pwrd.DEMAND_WEEK
    LEFT JOIN alternate_inventory_metrics aim
        ON bldh.PART_NUMBER = aim.PART_NUMBER
    LEFT JOIN bom_line_parent_metrics blpm
        ON bldh.PATH = blpm.PATH
    LEFT JOIN alternate_in_transit_metrics aitm
        ON bldh.PART_NUMBER = aitm.PART_NUMBER
),
bom_line_weekly_stock_position AS (
    SELECT
        PATH,
        PART_NUMBER,
        REVISION,
        WEEK_OFFSET,
        DEMAND_WEEK,
        WEEK_DEMAND,
        ON_HAND_QUANTITY_INCLUDING_ALTERNATES_AND_PARENTS,
        ON_HAND_QUANTITY_INCLUDING_ALTERNATES_PARENTS_AND_IN_TRANSIT,
        IN_TRANSIT_QUANTITY,
        COALESCE(
            SUM(WEEK_DEMAND) OVER (
                PARTITION BY PATH
                ORDER BY WEEK_OFFSET
                ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
            ),
            0
        ) AS PRIOR_WEEK_DEMAND
    FROM bom_line_weeks_of_stock_base
),
bom_line_weekly_stock_coverage AS (
    SELECT
        PATH,
        PART_NUMBER,
        REVISION,
        WEEK_OFFSET,
        DEMAND_WEEK,
        WEEK_DEMAND,
        ON_HAND_QUANTITY_INCLUDING_ALTERNATES_AND_PARENTS,
        ON_HAND_QUANTITY_INCLUDING_ALTERNATES_PARENTS_AND_IN_TRANSIT,
        IN_TRANSIT_QUANTITY,
        ON_HAND_QUANTITY_INCLUDING_ALTERNATES_AND_PARENTS - PRIOR_WEEK_DEMAND AS REMAINING_ON_HAND_BEFORE_WEEK,
        ON_HAND_QUANTITY_INCLUDING_ALTERNATES_PARENTS_AND_IN_TRANSIT
            - PRIOR_WEEK_DEMAND AS REMAINING_ON_HAND_WITH_IN_TRANSIT_BEFORE_WEEK,
        IN_TRANSIT_QUANTITY - PRIOR_WEEK_DEMAND AS REMAINING_IN_TRANSIT_BEFORE_WEEK,
        CASE
            WHEN PRIOR_WEEK_DEMAND > ON_HAND_QUANTITY_INCLUDING_ALTERNATES_AND_PARENTS THEN 0
            WHEN WEEK_DEMAND <= 0 THEN 1
            WHEN ON_HAND_QUANTITY_INCLUDING_ALTERNATES_AND_PARENTS - PRIOR_WEEK_DEMAND >= WEEK_DEMAND THEN 1
            ELSE GREATEST(ON_HAND_QUANTITY_INCLUDING_ALTERNATES_AND_PARENTS - PRIOR_WEEK_DEMAND, 0) / WEEK_DEMAND
        END AS WEEK_STOCK_COVERAGE,
        CASE
            WHEN PRIOR_WEEK_DEMAND > ON_HAND_QUANTITY_INCLUDING_ALTERNATES_PARENTS_AND_IN_TRANSIT THEN 0
            WHEN WEEK_DEMAND <= 0 THEN 1
            WHEN ON_HAND_QUANTITY_INCLUDING_ALTERNATES_PARENTS_AND_IN_TRANSIT - PRIOR_WEEK_DEMAND >= WEEK_DEMAND THEN 1
            ELSE GREATEST(
                ON_HAND_QUANTITY_INCLUDING_ALTERNATES_PARENTS_AND_IN_TRANSIT - PRIOR_WEEK_DEMAND,
                0
            ) / WEEK_DEMAND
        END AS WEEK_STOCK_COVERAGE_WITH_IN_TRANSIT,
        CASE
            WHEN IN_TRANSIT_QUANTITY <= 0 THEN 0
            WHEN PRIOR_WEEK_DEMAND > IN_TRANSIT_QUANTITY THEN 0
            WHEN WEEK_DEMAND <= 0 THEN 1
            WHEN IN_TRANSIT_QUANTITY - PRIOR_WEEK_DEMAND >= WEEK_DEMAND THEN 1
            ELSE GREATEST(IN_TRANSIT_QUANTITY - PRIOR_WEEK_DEMAND, 0) / WEEK_DEMAND
        END AS WEEK_STOCK_COVERAGE_IN_TRANSIT
    FROM bom_line_weekly_stock_position
),
bom_line_weeks_of_stock AS (
    SELECT
        PATH,
        PART_NUMBER,
        REVISION,
        CAST(SUM(WEEK_STOCK_COVERAGE) AS FLOAT) AS "Weeks of Stock",
        CAST(SUM(WEEK_STOCK_COVERAGE_WITH_IN_TRANSIT) AS FLOAT) AS "Weeks of Stock with In Transit",
        CAST(SUM(WEEK_STOCK_COVERAGE_IN_TRANSIT) AS FLOAT) AS "in transit weeks of stock"
    FROM bom_line_weekly_stock_coverage
    GROUP BY PATH, PART_NUMBER, REVISION
),
system_alternate_bom_lines AS (
    SELECT DISTINCT
        alternate_fpl.PATH
    FROM flat_parts_lookup alternate_fpl
    INNER JOIN original_alternate_part_bridge ab
        ON ab.RELATED_PART_NUMBER = alternate_fpl.PART_NUMBER
       AND ab.RELATED_PART_NUMBER <> ab.BASE_PART_NUMBER
    INNER JOIN flat_parts_lookup original_fpl
        ON original_fpl.PART_NUMBER = ab.BASE_PART_NUMBER
       AND original_fpl.TOP_LEVEL_BOM = alternate_fpl.TOP_LEVEL_BOM
       AND COALESCE(original_fpl.TOP_LEVEL_REVISION, '') = COALESCE(alternate_fpl.TOP_LEVEL_REVISION, '')
       AND COALESCE(original_fpl."System", '') = COALESCE(alternate_fpl."System", '')
),
system_min_weeks_of_stock AS (
    SELECT
        TOP_LEVEL_BOM,
        TOP_LEVEL_REVISION,
        SYSTEM_GROUP,
        CAST(
            IN_TRANSIT_WEEKS_OF_STOCK
            AS FLOAT
        ) AS "In Transit Weeks of Stock Of System's Minimum Weeks of Stock Part"
    FROM (
        SELECT
            fpl.TOP_LEVEL_BOM,
            COALESCE(fpl.TOP_LEVEL_REVISION, '') AS TOP_LEVEL_REVISION,
            COALESCE(fpl."System", '') AS SYSTEM_GROUP,
            COALESCE(pwos."in transit weeks of stock", 0) AS IN_TRANSIT_WEEKS_OF_STOCK,
            ROW_NUMBER() OVER (
                PARTITION BY fpl.TOP_LEVEL_BOM, COALESCE(fpl.TOP_LEVEL_REVISION, ''), COALESCE(fpl."System", '')
                ORDER BY COALESCE(pwos."Weeks of Stock", 0), fpl.PART_NUMBER, fpl.PATH
            ) AS SYSTEM_MIN_WEEKS_RANK
        FROM flat_parts_lookup fpl
        LEFT JOIN bom_line_weeks_of_stock pwos
            ON fpl.PATH = pwos.PATH
        LEFT JOIN system_alternate_bom_lines sabl
            ON fpl.PATH = sabl.PATH
        WHERE fpl.TOP_LEVEL_BOM IS NOT NULL
          AND sabl.PATH IS NULL
          AND fpl.ADJUSTED_PROCUREMENT_INTENT = 'zipline_buy'
          AND NOT COALESCE(TRY_TO_BOOLEAN(TO_VARCHAR(fpl.IS_CONSUMABLE_STORABLE)), FALSE)
    ) ranked_system_parts
    WHERE SYSTEM_MIN_WEEKS_RANK = 1
),
supply_plan_base AS (
    SELECT
        sp.${supply_plan_part_number_column} AS PART_NUMBER,
        sp.${supply_plan_quantity_column} AS QUANTITY,
        DATE_TRUNC(
            'week',
            TRY_TO_DATE(
                TRIM(sp.${supply_plan_date_column}) || '/' || EXTRACT(year FROM TO_DATE('${as_of_date}')),
                'MM/DD/YYYY'
            )
        ) AS PLAN_WEEK,
        TRY_TO_DATE(
            TRIM(sp.${supply_plan_date_column}) || '/' || EXTRACT(year FROM TO_DATE('${as_of_date}')),
            'MM/DD/YYYY'
        ) AS PLAN_DATE
    FROM ${supply_plans} sp
),
supply_plan_metrics AS (
    SELECT
        sp.PART_NUMBER,
        COALESCE(cws."Current Week Realized Supply", 0) AS "Current Week Realized Supply",
        SUM(CASE WHEN sp.PLAN_WEEK >= DATE_TRUNC('week', TO_DATE('${as_of_date}'))
                  AND sp.PLAN_WEEK < DATEADD(week, 4, DATE_TRUNC('week', TO_DATE('${as_of_date}')))
             THEN sp.QUANTITY ELSE 0 END) - COALESCE(cws."Current Week Realized Supply", 0) AS "Total Supply Plan, next 4 weeks",
        SUM(CASE WHEN sp.PLAN_WEEK >= DATE_TRUNC('week', TO_DATE('${as_of_date}'))
                  AND sp.PLAN_WEEK < DATEADD(week, 8, DATE_TRUNC('week', TO_DATE('${as_of_date}')))
             THEN sp.QUANTITY ELSE 0 END) - COALESCE(cws."Current Week Realized Supply", 0) AS "Total Supply Plan, next 8 weeks",
        (
            SUM(CASE WHEN sp.PLAN_WEEK >= DATE_TRUNC('week', TO_DATE('${as_of_date}'))
                      AND sp.PLAN_WEEK < DATEADD(week, 4, DATE_TRUNC('week', TO_DATE('${as_of_date}')))
                 THEN sp.QUANTITY ELSE 0 END) - COALESCE(cws."Current Week Realized Supply", 0)
        ) / 4.0 AS "Average Supply Plan, next 4 weeks",
        (
            SUM(CASE WHEN sp.PLAN_WEEK >= DATE_TRUNC('week', TO_DATE('${as_of_date}'))
                      AND sp.PLAN_WEEK < DATEADD(week, 8, DATE_TRUNC('week', TO_DATE('${as_of_date}')))
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
        SUM(CASE WHEN sp.PLAN_WEEK >= DATE_TRUNC('week', TO_DATE('${as_of_date}'))
                  AND sp.PLAN_WEEK < DATEADD(week, 4, DATE_TRUNC('week', TO_DATE('${as_of_date}')))
             THEN sp.QUANTITY ELSE 0 END) - COALESCE(acws."Current Week Realized Supply with alternates", 0) AS "Total Supply Plan, next 4 weeks with alternates",
        SUM(CASE WHEN sp.PLAN_WEEK >= DATE_TRUNC('week', TO_DATE('${as_of_date}'))
                  AND sp.PLAN_WEEK < DATEADD(week, 8, DATE_TRUNC('week', TO_DATE('${as_of_date}')))
             THEN sp.QUANTITY ELSE 0 END) - COALESCE(acws."Current Week Realized Supply with alternates", 0) AS "Total Supply Plan, next 8 weeks with alternates",
        (
            SUM(CASE WHEN sp.PLAN_WEEK >= DATE_TRUNC('week', TO_DATE('${as_of_date}'))
                      AND sp.PLAN_WEEK < DATEADD(week, 4, DATE_TRUNC('week', TO_DATE('${as_of_date}')))
                 THEN sp.QUANTITY ELSE 0 END) - COALESCE(acws."Current Week Realized Supply with alternates", 0)
        ) / 4.0 AS "Average Supply Plan, next 4 weeks with alternates",
        (
            SUM(CASE WHEN sp.PLAN_WEEK >= DATE_TRUNC('week', TO_DATE('${as_of_date}'))
                      AND sp.PLAN_WEEK < DATEADD(week, 8, DATE_TRUNC('week', TO_DATE('${as_of_date}')))
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
    CAST(prq."total rolled up quantity" AS FLOAT) AS "total rolled up quantity",
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
    pdm."Current Week Total Gross Demand",
    pdm."Net Total Demand for Part Number in current week" AS "Current Week Net Demand",
    pdm."Net Total Demand for Part Number in current week" AS "Current Week Net Total Demand",
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
    im."Current Receiving & Pre-IQC Quantity",
    COALESCE(blpm."On Hand Quantity In Parents", 0) AS "On Hand Quantity In Parents",
    COALESCE(aitm."in-transit quantity including alternates", 0) AS "in-transit quantity including alternates",
    CAST(
        COALESCE(aitm."in-transit quantity including alternates", 0)
        * COALESCE(puc.UNIT_COST, 0)
        AS FLOAT
    ) AS "in-transit inventory value including alternates",
    COALESCE(im."Current On-Hand Quantity", 0)
        - COALESCE(pdm."Net Total Demand for Part Number in current week", 0) AS "On Hand Delta to Current Week Demand (each)",
    im."Current Quarantine Quantity",
    aim."Current On-Hand Quantity with alternates",
    aim."Current Receiving & Pre-IQC Quantity with alternates",
    COALESCE(pwos."Weeks of Stock", 0) AS "Weeks of Stock",
    COALESCE(pwos."Weeks of Stock with In Transit", 0) AS "Weeks of Stock with In Transit",
    COALESCE(pwos."in transit weeks of stock", 0) AS "in transit weeks of stock",
    COALESCE(
        smwos."In Transit Weeks of Stock Of System's Minimum Weeks of Stock Part",
        0
    ) AS "In Transit Weeks of Stock Of System's Minimum Weeks of Stock Part",
    CAST(
        COALESCE(aim."Current On-Hand Quantity with alternates", 0)
        + COALESCE(blpm."On Hand Quantity In Parents", 0)
        AS FLOAT
    ) AS "Current On Hand Quantity Including alternates and parents",
    CAST(
        COALESCE(aim."Current On-Hand Inventory Value with alternates", 0)
        + COALESCE(blpm."On Hand Quantity In Parents", 0) * COALESCE(puc.UNIT_COST, 0)
        AS FLOAT
    ) AS "Current On Hand Inventory Value Including alternates and parents",
    CAST(
        CASE
            WHEN prq.TOTAL_ROLLED_UP_QUANTITY_NUMERIC IS NULL
              OR prq.TOTAL_ROLLED_UP_QUANTITY_NUMERIC = 0 THEN NULL
            ELSE COALESCE(aim."Current On-Hand Quantity with alternates", 0) / prq.TOTAL_ROLLED_UP_QUANTITY_NUMERIC
        END
        AS FLOAT
    ) AS "on hand product sets including alternates",
    CAST(
        CASE
            WHEN prq.TOTAL_ROLLED_UP_QUANTITY_NUMERIC IS NULL
              OR prq.TOTAL_ROLLED_UP_QUANTITY_NUMERIC = 0 THEN NULL
            ELSE COALESCE(aim."Current Receiving & Pre-IQC Quantity with alternates", 0)
                / prq.TOTAL_ROLLED_UP_QUANTITY_NUMERIC
        END
        AS FLOAT
    ) AS "receiving & pre-iqc product sets",
    CAST(
        CASE
            WHEN (
                prq.TOTAL_ROLLED_UP_QUANTITY_NUMERIC IS NULL
                OR prq.TOTAL_ROLLED_UP_QUANTITY_NUMERIC = 0
            )
            AND (
                blpm.VALID_PARENT_PRODUCT_SET_COUNT IS NULL
                OR blpm.VALID_PARENT_PRODUCT_SET_COUNT = 0
            ) THEN NULL
            ELSE
                CASE
                    WHEN prq.TOTAL_ROLLED_UP_QUANTITY_NUMERIC IS NULL
                      OR prq.TOTAL_ROLLED_UP_QUANTITY_NUMERIC = 0 THEN 0
                    ELSE COALESCE(aim."Current On-Hand Quantity with alternates", 0)
                        / prq.TOTAL_ROLLED_UP_QUANTITY_NUMERIC
                END
                + COALESCE(blpm.ON_HAND_PRODUCT_SETS_IN_PARENTS, 0)
        END
        AS FLOAT
    ) AS "on hand product sets including alternates and parents",
    CAST(
        CASE
            WHEN (
                prq.TOTAL_ROLLED_UP_QUANTITY_NUMERIC IS NULL
                OR prq.TOTAL_ROLLED_UP_QUANTITY_NUMERIC = 0
            )
            AND (
                blpm.VALID_PARENT_PRODUCT_SET_COUNT IS NULL
                OR blpm.VALID_PARENT_PRODUCT_SET_COUNT = 0
            ) THEN NULL
            ELSE
                CASE
                    WHEN prq.TOTAL_ROLLED_UP_QUANTITY_NUMERIC IS NULL
                      OR prq.TOTAL_ROLLED_UP_QUANTITY_NUMERIC = 0 THEN 0
                    ELSE (
                        COALESCE(aim."Current On-Hand Quantity with alternates", 0)
                        + COALESCE(aitm."in-transit quantity including alternates", 0)
                    ) / prq.TOTAL_ROLLED_UP_QUANTITY_NUMERIC
                END
                + COALESCE(blpm.ON_HAND_PRODUCT_SETS_IN_PARENTS, 0)
        END
        AS FLOAT
    ) AS "on hand + in transit product sets",
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
        WHEN COALESCE(pwos."Weeks of Stock", 0) <= 1 THEN '0-1 weeks of supply'
        WHEN COALESCE(pwos."Weeks of Stock", 0) <= 3 THEN '1-3 weeks of supply'
        ELSE '>3 weeks of supply'
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
LEFT JOIN part_unit_costs puc
    ON fpl.PART_NUMBER = puc.PART_NUMBER
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
LEFT JOIN alternate_in_transit_metrics aitm
    ON fpl.PART_NUMBER = aitm.PART_NUMBER
LEFT JOIN bom_line_parent_metrics blpm
    ON fpl.PATH = blpm.PATH
LEFT JOIN alternate_inventory_metrics aim
    ON fpl.PART_NUMBER = aim.PART_NUMBER
LEFT JOIN bom_line_weeks_of_stock pwos
    ON fpl.PATH = pwos.PATH
LEFT JOIN system_min_weeks_of_stock smwos
    ON fpl.TOP_LEVEL_BOM = smwos.TOP_LEVEL_BOM
   AND COALESCE(fpl.TOP_LEVEL_REVISION, '') = smwos.TOP_LEVEL_REVISION
   AND COALESCE(fpl."System", '') = smwos.SYSTEM_GROUP
LEFT JOIN supply_plan_metrics spm
    ON fpl.PART_NUMBER = spm.PART_NUMBER
LEFT JOIN alternate_supply_plan_metrics aspm
    ON fpl.PART_NUMBER = aspm.PART_NUMBER
ORDER BY fpl.PATH
