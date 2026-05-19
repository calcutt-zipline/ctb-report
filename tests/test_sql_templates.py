import json
from pathlib import Path


SQL_FILES = [
    Path("sql/final_report.sql"),
    Path("sql/mode_bom_capacity_raw.sql"),
]


def test_coop_quality_locations_are_quarantine() -> None:
    for sql_file in SQL_FILES:
        sql = sql_file.read_text()

        so_parts_pick_rule = "WHEN sl.COMPLETE_NAME LIKE 'COOP/WH/Stock/SO Parts Pick%' THEN 'Nest'"
        rework_production_rule = "WHEN sl.COMPLETE_NAME LIKE 'COOP/Quarantine/Rework/Production%' THEN 'Warehouse'"
        rework_zipping_point_rule = (
            "WHEN sl.COMPLETE_NAME LIKE 'COOP/Quarantine/Rework/Zipping Point%' THEN 'Warehouse'"
        )
        quarantine_rule = "WHEN sl.COMPLETE_NAME LIKE 'COOP/Quarantine%' THEN 'Quarantine'"
        broad_coop_wh_rule = "WHEN sl.COMPLETE_NAME LIKE 'COOP/WH%' THEN 'Warehouse'"
        coop_inspection_rule = "WHEN sl.COMPLETE_NAME LIKE 'COOP/Inspection%' THEN 'Warehouse'"
        fai_pre_inspection_rule = (
            "WHEN sl.COMPLETE_NAME LIKE 'COOP/FAI Pre-Inspection%' THEN 'Receiving & Pre-IQC'"
        )
        coop_input_rule = "WHEN sl.COMPLETE_NAME LIKE 'COOP/Input%' THEN 'Receiving & Pre-IQC'"
        coop_iqc_inspection_rule = (
            "WHEN sl.COMPLETE_NAME LIKE 'COOP/Inspection/IQC%' THEN 'Receiving & Pre-IQC'"
        )
        customer_drop_off_rule = "WHEN sl.COMPLETE_NAME LIKE 'COOP/Outbound/Pack/Customers Drop Off%' THEN 'R&D'"

        assert so_parts_pick_rule in sql
        assert sql.index(so_parts_pick_rule) < sql.index(broad_coop_wh_rule)
        assert fai_pre_inspection_rule in sql
        assert coop_input_rule in sql
        assert coop_iqc_inspection_rule in sql
        assert sql.index(coop_iqc_inspection_rule) < sql.index(coop_inspection_rule)
        assert rework_production_rule in sql
        assert sql.index(rework_production_rule) < sql.index(quarantine_rule)
        assert rework_zipping_point_rule in sql
        assert sql.index(rework_zipping_point_rule) < sql.index(quarantine_rule)
        assert "WHEN sl.COMPLETE_NAME LIKE 'COOP/Quarantine%' THEN 'Quarantine'" in sql
        assert "WHEN sl.COMPLETE_NAME LIKE 'COOP/MRB%' THEN 'Quarantine'" in sql
        assert "WHEN sl.COMPLETE_NAME LIKE 'COOP/IQC%' THEN 'Quarantine'" in sql
        assert "WHEN sl.COMPLETE_NAME LIKE 'COOP/P2/OQC Inspection/Feeder (WIP)%' THEN 'Warehouse'" in sql
        assert "WHEN sl.COMPLETE_NAME LIKE 'COOP/P2/Post-Inspection/Feeder (WIP)%' THEN 'Warehouse'" in sql
        assert customer_drop_off_rule in sql
        assert "WHEN sl.COMPLETE_NAME LIKE 'COOP/FAI Pre-Inspection%' THEN 'Warehouse'" not in sql
        assert "WHEN sl.COMPLETE_NAME LIKE 'COOP/Input%' THEN 'Warehouse'" not in sql
        assert "LIKE 'OOP/P2/OQC Inspection" not in sql


def test_on_hand_product_sets_sql_stays_numeric() -> None:
    for sql_file in SQL_FILES:
        sql = sql_file.read_text()

        assert "OR prq.TOTAL_ROLLED_UP_QUANTITY_NUMERIC = 0 THEN NULL" in sql
        assert 'CAST(\n        CASE' in sql
        assert "TO_VARCHAR(COALESCE(aim.\"Current On-Hand Quantity with alternates\", 0)" not in sql


def test_total_rollup_uses_max_zipline_buy_on_demanded_top_level_boms() -> None:
    for sql_file in SQL_FILES:
        sql = sql_file.read_text()

        assert "demanded_top_level_boms AS" in sql
        assert "WHERE child_bom.PART_NUMBER = et.PART_NUMBER" in sql
        assert "NULLIF(TRIM(child_bom.PARENT_BOM), '') IS NOT NULL" in sql
        assert "OR COALESCE(child_bom.INDENT_LEVEL, 0) > 0" in sql
        assert "INNER JOIN demanded_top_level_boms dtlb" in sql
        assert "AND bpn.ADJUSTED_PROCUREMENT_INTENT = 'zipline_buy'" in sql
        assert 'CAST(MAX(TOTAL_ROLLED_UP_QUANTITY) AS FLOAT) AS "total rolled up quantity"' in sql
        assert "CAST(MAX(TOTAL_ROLLED_UP_QUANTITY) AS FLOAT) AS TOTAL_ROLLED_UP_QUANTITY_NUMERIC" in sql
        assert 'CAST(prq."total rolled up quantity" AS FLOAT) AS "total rolled up quantity"' in sql
        assert "TO_VARCHAR(MAX(TOTAL_ROLLED_UP_QUANTITY))" not in sql
        assert "mutliple" not in sql


def test_report_only_expands_current_or_future_demanded_top_levels() -> None:
    for sql_file in SQL_FILES:
        sql = sql_file.read_text()

        assert "eligible_top_levels AS" in sql
        assert "AND COALESCE(QUANTITY, 0) > 0" in sql
        if sql_file == Path("sql/final_report.sql"):
            assert (
                "AND DATE_TRUNC('week', TRY_TO_DATE(DATE, 'MM/DD/YYYY')) "
                ">= DATE_TRUNC('week', TO_DATE('${as_of_date}'))"
                in sql
            )
        else:
            assert (
                "AND DATE_TRUNC('week', TRY_TO_DATE(DATE, 'MM/DD/YYYY')) "
                ">= DATE_TRUNC('week', (SELECT as_of_date FROM params))"
                in sql
            )


def test_average_since_last_receipt_is_each_per_week() -> None:
    expected_by_file = {
        Path("sql/final_report.sql"): [
            "MAX_BY(TRANSACTION_QUANTITY_2, DATE) / NULLIF(DATEDIFF(day, MAX(DATE), TO_DATE('${as_of_date}')) / 7.0, 0)",
            "arl.TRANSACTION_QUANTITY_2 / NULLIF(DATEDIFF(day, arl.DATE, TO_DATE('${as_of_date}')) / 7.0, 0)",
            "DATEDIFF(day, MAX(DATE), TO_DATE('${as_of_date}')) / 7.0 / NULLIF(MAX_BY",
            "DATEDIFF(day, arl.DATE, TO_DATE('${as_of_date}')) / 7.0 / NULLIF(arl.TRANSACTION_QUANTITY_2",
        ],
        Path("sql/mode_bom_capacity_raw.sql"): [
            "MAX_BY(TRANSACTION_QUANTITY_2, DATE) / NULLIF(DATEDIFF(day, MAX(DATE), (SELECT as_of_date FROM params)) / 7.0, 0)",
            "arl.TRANSACTION_QUANTITY_2 / NULLIF(DATEDIFF(day, arl.DATE, (SELECT as_of_date FROM params)) / 7.0, 0)",
            "DATEDIFF(day, MAX(DATE), (SELECT as_of_date FROM params)) / 7.0 / NULLIF(MAX_BY",
            "DATEDIFF(day, arl.DATE, (SELECT as_of_date FROM params)) / 7.0 / NULLIF(arl.TRANSACTION_QUANTITY_2",
        ],
    }

    for sql_file, snippets in expected_by_file.items():
        sql = sql_file.read_text()
        base_formula, alternate_formula, old_base_formula, old_alternate_formula = snippets

        assert base_formula in sql
        assert alternate_formula in sql
        assert old_base_formula not in sql
        assert old_alternate_formula not in sql


def test_current_week_total_gross_demand_is_selected() -> None:
    for sql_file in SQL_FILES:
        sql = sql_file.read_text()

        assert "part_number_current_week_gross_demand AS" in sql
        assert ') AS "Current Week Total Gross Demand"\n    FROM bom_path_normalized bpn' in sql
        assert 'MAX(COALESCE(cwg."Current Week Total Gross Demand", 0)) AS "Current Week Total Gross Demand"' in sql
        assert "LEFT JOIN part_number_current_week_gross_demand cwg" in sql
        assert 'pdm."Current Week Total Gross Demand"' in sql
        assert (
            'pdm."Net Total Demand for Part Number in current week" AS "Current Week Net Demand"'
            in sql
        )
        assert (
            'pdm."Net Total Demand for Part Number in current week" AS "Current Week Net Total Demand"'
            in sql
        )


def test_weeks_of_stock_uses_alternate_and_parent_on_hand_with_weekly_remaining_demand() -> None:
    for sql_file in SQL_FILES:
        sql = sql_file.read_text()

        assert "part_number_weekly_demand_by_type AS" in sql
        assert "part_number_weekly_remaining_demand AS" in sql
        assert "bom_line_demand_horizon AS" in sql
        assert "bom_line_weeks_of_stock AS" in sql
        assert "system_alternate_bom_lines AS" in sql
        assert "system_min_weeks_of_stock AS" in sql
        assert "pwd.DEMAND_WEEK = DATE_TRUNC('week'," in sql
        assert "COALESCE(cwd.PRODUCTION_CONSUMPTION_THIS_WEEK, 0)" in sql
        assert "COALESCE(cwd.NEST_CONSUMPTION_THIS_WEEK, 0)" in sql
        assert 'COALESCE(aim."Current On-Hand Quantity with alternates", 0)' in sql
        assert 'COALESCE(blpm."On Hand Quantity In Parents", 0)' in sql
        assert 'COALESCE(aitm."in-transit quantity including alternates", 0)' in sql
        assert "AS ON_HAND_QUANTITY_INCLUDING_ALTERNATES_AND_PARENTS" in sql
        assert "AS ON_HAND_QUANTITY_INCLUDING_ALTERNATES_PARENTS_AND_IN_TRANSIT" in sql
        assert "AS IN_TRANSIT_QUANTITY" in sql
        assert "PARTITION BY PATH" in sql
        assert "WHEN WEEK_DEMAND <= 0 THEN 1" in sql
        assert (
            "GREATEST(ON_HAND_QUANTITY_INCLUDING_ALTERNATES_AND_PARENTS - PRIOR_WEEK_DEMAND, 0) / WEEK_DEMAND"
            in sql
        )
        assert "WEEK_STOCK_COVERAGE_WITH_IN_TRANSIT" in sql
        assert "WEEK_STOCK_COVERAGE_IN_TRANSIT" in sql
        assert "WHEN IN_TRANSIT_QUANTITY <= 0 THEN 0" in sql
        assert (
            "GREATEST(\n                ON_HAND_QUANTITY_INCLUDING_ALTERNATES_PARENTS_AND_IN_TRANSIT - PRIOR_WEEK_DEMAND,\n                0\n            ) / WEEK_DEMAND"
            in sql
        )
        assert "GREATEST(IN_TRANSIT_QUANTITY - PRIOR_WEEK_DEMAND, 0) / WEEK_DEMAND" in sql
        assert 'CAST(SUM(WEEK_STOCK_COVERAGE) AS FLOAT) AS "Weeks of Stock"' in sql
        assert (
            'CAST(SUM(WEEK_STOCK_COVERAGE_WITH_IN_TRANSIT) AS FLOAT) AS "Weeks of Stock with In Transit"'
            in sql
        )
        assert 'CAST(SUM(WEEK_STOCK_COVERAGE_IN_TRANSIT) AS FLOAT) AS "in transit weeks of stock"' in sql
        assert 'COALESCE(pwos."Weeks of Stock", 0) AS "Weeks of Stock"' in sql
        assert (
            'COALESCE(pwos."Weeks of Stock with In Transit", 0) AS "Weeks of Stock with In Transit"'
            in sql
        )
        assert (
            'COALESCE(pwos."in transit weeks of stock", 0) AS "in transit weeks of stock"'
            in sql
        )
        assert (
            'AS "In Transit Weeks of Stock Of System\'s Minimum Weeks of Stock Part"'
            in sql
        )
        assert (
            'PARTITION BY fpl.TOP_LEVEL_BOM, COALESCE(fpl.TOP_LEVEL_REVISION, \'\'), COALESCE(fpl."System", \'\')'
            in sql
        )
        assert 'ORDER BY COALESCE(pwos."Weeks of Stock", 0), fpl.PART_NUMBER, fpl.PATH' in sql
        assert "LEFT JOIN system_min_weeks_of_stock smwos" in sql
        assert "AND COALESCE(fpl.\"System\", '') = smwos.SYSTEM_GROUP" in sql
        assert "LEFT JOIN bom_line_parent_metrics blpm" in sql
        assert "LEFT JOIN alternate_in_transit_metrics aitm" in sql
        assert "LEFT JOIN bom_line_weeks_of_stock pwos" in sql
        assert "ON fpl.PATH = pwos.PATH" in sql
        assert "LEFT JOIN system_alternate_bom_lines sabl" in sql
        assert "AND sabl.PATH IS NULL" in sql
        assert "AND fpl.ADJUSTED_PROCUREMENT_INTENT = 'zipline_buy'" in sql
        assert "AND NOT COALESCE(TRY_TO_BOOLEAN(TO_VARCHAR(fpl.IS_CONSUMABLE_STORABLE)), FALSE)" in sql
        assert "INNER JOIN original_alternate_part_bridge ab" in sql
        assert "AND ab.RELATED_PART_NUMBER <> ab.BASE_PART_NUMBER" in sql
        assert 'AND COALESCE(original_fpl."System", \'\') = COALESCE(alternate_fpl."System", \'\')' in sql


def test_receiving_pre_iqc_is_counted_with_warehouse_stock_and_reported_separately() -> None:
    for sql_file in SQL_FILES:
        sql = sql_file.read_text()

        assert "MRP_CATEGORY IN ('Warehouse', 'Receiving & Pre-IQC')" in sql
        assert (
            'AS "Current Receiving & Pre-IQC Quantity"'
            in sql
        )
        assert (
            'AS "Current Receiving & Pre-IQC Quantity with alternates"'
            in sql
        )
        assert 'im."Current Receiving & Pre-IQC Quantity"' in sql
        assert 'aim."Current Receiving & Pre-IQC Quantity with alternates"' in sql
        assert 'AS "receiving & pre-iqc product sets"' in sql
        assert (
            'COALESCE(aim."Current Receiving & Pre-IQC Quantity with alternates", 0)\n'
            '                / prq.TOTAL_ROLLED_UP_QUANTITY_NUMERIC'
            in sql
        )


def test_on_hand_inventory_status_uses_weeks_of_stock_thresholds() -> None:
    for sql_file in SQL_FILES:
        sql = sql_file.read_text()

        assert 'WHEN COALESCE(pwos."Weeks of Stock", 0) <= 1 THEN \'0-1 weeks of supply\'' in sql
        assert 'WHEN COALESCE(pwos."Weeks of Stock", 0) <= 3 THEN \'1-3 weeks of supply\'' in sql
        assert "ELSE '>3 weeks of supply'" in sql
        assert "'>= 3 weeks of demand'" not in sql
        assert "'>= 2 weeks and < 3 weeks of demand'" not in sql
        assert "'>= 1 week and < 2 weeks of demand'" not in sql
        assert "'< 1 week of demand'" not in sql


def test_in_transit_quantity_filters_terminal_shipments() -> None:
    for sql_file in SQL_FILES:
        sql = sql_file.read_text()

        assert "shipment_lines_normalized AS" in sql
        assert "shipments_normalized AS" in sql
        assert "in_transit_metrics AS" in sql
        assert "original_alternate_part_bridge AS" in sql
        assert "alternate_in_transit_metrics AS" in sql
        assert "AS IN_TRANSIT_QUANTITY" in sql
        assert 'AS "in-transit quantity including alternates"' in sql
        assert "f.index AS PART_INDEX" in sql
        assert "WHERE original_part.PART_INDEX = 0" in sql
        assert "OBJECT_CONSTRUCT(*) AS shipment_line" in sql
        assert "OBJECT_CONSTRUCT(*) AS shipment" in sql
        assert "ROW_NUMBER() OVER (\n                PARTITION BY SHIPMENT_ID" in sql
        assert "WHERE RN = 1" in sql
        assert "TRY_TO_DOUBLE(TO_VARCHAR(shipment_line:" in sql
        assert "TO_VARCHAR(shipment_line:DEFAULT_CODE)" in sql
        assert "TO_VARCHAR(shipment_line:QUANTITY_IN_SHIPMENT)" in sql
        assert "TO_VARCHAR(shipment:STATE)" in sql
        assert "TO_VARCHAR(shipment:SHIPMENT_STATUS)" in sql
        assert "INNER JOIN shipments_normalized s" in sql
        assert "ON s.SHIPMENT_ID = TO_VARCHAR(shipment_line:SHIPMENT_ID)" in sql
        assert "REGEXP_REPLACE(\n                UPPER(TRIM(RAW_SHIPMENT_STATUS))" in sql
        assert "SHIPMENT_STATUS NOT IN" in sql
        assert "'DRAFT'" in sql
        assert "'CANCELED'" in sql
        assert "'CANCELLED'" in sql
        assert "'DELIVERED'" in sql
        assert "'DELIVERED_COMPLETED'" in sql
        assert "'COMPLETED'" in sql
        assert "'PENDING_DELIVERY'" not in sql
        assert "FCT_ZERP_LOGISTICS_SHIPMENT_LINES" not in sql
        assert (
            'COALESCE(aitm."in-transit quantity including alternates", 0) '
            'AS "in-transit quantity including alternates"'
            in sql
        )
        assert "LEFT JOIN in_transit_metrics base_itm" in sql
        assert "LEFT JOIN in_transit_metrics alternate_itm" in sql
        assert "alternate_itm.IN_TRANSIT_QUANTITY > 0" in sql
        assert "LEFT JOIN alternate_in_transit_metrics aitm" in sql

    mode_sql = Path("sql/mode_bom_capacity_raw.sql").read_text()
    assert "FROM BIZ.DBT_ODOO.SHIPMENTS" in mode_sql
    assert "FROM BIZ.DBT_ODOO.SHIPMENT_PACKING_LIST" in mode_sql


def test_inventory_value_columns_use_latest_zerp_po_unit_costs_with_q2_forecast_fallback() -> None:
    for sql_file in SQL_FILES:
        sql = sql_file.read_text()

        assert "latest_zerp_po_line_versions AS" in sql
        assert "latest_zerp_po_lines AS" in sql
        assert "latest_zerp_part_unit_costs AS" in sql
        assert "forecast_part_unit_costs AS" in sql
        assert "part_unit_costs AS" in sql
        assert "FROM BIZ.DBT_STG.STG_ZERP_PURCHASING__PURCHASE_ORDER_LINE pol" in sql
        assert "LEFT JOIN BIZ.DBT_STG.STG_ZERP_PURCHASING__PURCHASE_ORDER_VERSION pov" in sql
        assert "LEFT JOIN BIZ.DBT_STG.STG_ZERP_PURCHASING__PURCHASE_ORDER po" in sql
        assert "LEFT JOIN BIZ.DBT_STG.STG_ODOO_PROD__PRODUCT_TEMPLATE op" in sql
        assert "LEFT JOIN BIZ.DBT_STG.STG_ZERP_PURCHASING__UOM zuom" in sql
        assert "LEFT JOIN BIZ.DBT_STG.STG_ODOO_PROD__UOM_UOM ouom" in sql
        assert "WHERE pov.STATUS = 'ISSUED'" in sql
        assert "pol.UNIT_PRICE_UCENTS / 100000000.0 AS UNIT_PRICE" in sql
        assert "ouom.FACTOR AS UOM_FACTOR" in sql
        assert "WHEN ouom.FACTOR IS NULL THEN pol.UNIT_PRICE_UCENTS / 100000000.0" in sql
        assert "ELSE pol.UNIT_PRICE_UCENTS / 100000000.0 * ouom.FACTOR" in sql
        assert "END AS UNIT_COST" in sql
        assert "V_2_26_Q_2 AS UNIT_COST" in sql
        assert "UNIT_COST_26_Q_2 AS UNIT_COST" not in sql
        if sql_file == Path("sql/final_report.sql"):
            assert "FROM ${unit_cost_forecast}" in sql
        else:
            assert "FROM fivetran_google_sheets.supply_chain_unit_cost_forecast" in sql
        assert "COALESCE(NULLIF(zp.UNIT_COST, 0), fuc.UNIT_COST) AS UNIT_COST" in sql
        assert "WHEN NULLIF(zp.UNIT_COST, 0) IS NOT NULL THEN 'latest_zerp_po'" in sql
        assert "WHEN fuc.UNIT_COST IS NOT NULL THEN 'q2_unit_cost_forecast'" in sql
        assert 'puc.UNIT_COST AS "Unit Cost Used"' in sql
        assert 'puc.UNIT_COST_SOURCE AS "Unit Cost Source"' in sql
        assert "WHERE LINE_VERSION_RN = 1" in sql
        assert "PURCHASE_ORDER_NUMBER AS \"Latest PO\"" in sql
        assert 'AS "Current On-Hand Inventory Value"' in sql
        assert 'AS "Current On-Hand Inventory Value with alternates"' in sql
        assert 'AS "in-transit inventory value including alternates"' in sql
        assert 'AS "Current On Hand Inventory Value Including alternates and parents"' in sql
        assert "inv.QUANTITY * COALESCE(puc.UNIT_COST, 0)" in sql or (
            "inv.${inventory_quantity_column} * COALESCE(puc.UNIT_COST, 0)" in sql
        )
        assert "PRODUCT_VALUE" not in sql
        assert "product_values AS" not in sql
        assert "BIZ.DBT_ODOO.PRODUCTS" not in sql
        assert "${products}" not in sql
        assert "AS IN_TRANSIT_VALUE" not in sql
        assert (
            'COALESCE(aitm."in-transit quantity including alternates", 0)\n'
            "        * COALESCE(puc.UNIT_COST, 0)"
            in sql
        )
        assert 'COALESCE(aim."Current On-Hand Inventory Value with alternates", 0)' in sql
        assert 'COALESCE(blpm."On Hand Quantity In Parents", 0) * COALESCE(puc.UNIT_COST, 0)' in sql
        assert "LEFT JOIN part_unit_costs puc" in sql


def test_mode_publish_notebook_includes_unit_cost_source() -> None:
    notebook = json.loads(Path("notebooks/mode_bom_capacity_publish.ipynb").read_text())
    source = "".join(notebook["cells"][1]["source"])

    assert '"Unit Cost Source"' in source
    assert '"Unit Cost Used"' in source
    assert source.index('"Latest PO Creation Date"') < source.index('"Unit Cost Used"')
    assert source.index('"Unit Cost Used"') < source.index('"Unit Cost Source"')
    assert source.index('"Unit Cost Source"') < source.index('"Product"')


def test_parent_alternate_stock_and_set_columns_are_standalone() -> None:
    for sql_file in SQL_FILES:
        sql = sql_file.read_text()

        assert "parent_alternate_candidates AS" in sql
        assert "latest_alternate_parent_revisions AS" in sql
        assert "alternate_parent_bom_requirements AS" in sql
        assert "alternate_parent_component_related_parts AS" in sql
        assert "part_current_week_net_demand AS" in sql
        assert "alternate_parent_component_supply AS" in sql
        assert "alternate_parent_buildable_sets AS" in sql
        assert "bom_line_parent_alternate_metrics AS" in sql
        assert "ab.BASE_PART_NUMBER = blpu.PARENT_PART_NUMBER" in sql
        assert "ab.RELATED_PART_NUMBER <> blpu.PARENT_PART_NUMBER" in sql
        assert "MAX(COALESCE(bh.TOP_LEVEL_REVISION, '')) AS TOP_LEVEL_REVISION" in sql
        assert "bh.ADJUSTED_PROCUREMENT_INTENT = 'zipline_buy'" in sql
        assert "NOT COALESCE(TRY_TO_BOOLEAN(TO_VARCHAR(bh.IS_CONSUMABLE_STORABLE)), FALSE)" in sql
        assert (
            "SUM(COALESCE(im.\"Current On-Hand Quantity\", 0))\n"
            "                - SUM(COALESCE(pcwnd.CURRENT_WEEK_NET_DEMAND, 0))"
            in sql
        )
        assert "SUM(COALESCE(itm.IN_TRANSIT_QUANTITY, 0))" in sql
        assert (
            "MIN(apcs.COMPONENT_AVAILABLE_ON_HAND / NULLIF(apbr.COMPONENT_REQUIRED_QUANTITY, 0))"
            in sql
        )
        assert (
            "MIN(apcs.COMPONENT_AVAILABLE_ON_HAND_IN_TRANSIT / NULLIF(apbr.COMPONENT_REQUIRED_QUANTITY, 0))"
            in sql
        )
        assert (
            'COALESCE(blpam."On Hand Quantity In Alternates Of Parents", 0) '
            'AS "On Hand Quantity In Alternates Of Parents"'
            in sql
        )
        assert (
            'COALESCE(blpam."In-Transit Quantity In Alternates Of Parents", 0) '
            'AS "In-Transit Quantity In Alternates Of Parents"'
            in sql
        )
        assert 'AS "on hand product sets of alternates of parents"' in sql
        assert 'AS "on hand + in transit product sets of alternates of parents"' in sql
        assert "LEFT JOIN bom_line_parent_alternate_metrics blpam" in sql
        assert 'COALESCE(blpm.ON_HAND_PRODUCT_SETS_IN_PARENTS, 0)' in sql


def test_mode_publish_notebook_includes_parent_alternate_columns() -> None:
    notebook = json.loads(Path("notebooks/mode_bom_capacity_publish.ipynb").read_text())
    source = "".join(notebook["cells"][1]["source"])

    assert '"On Hand Quantity In Alternates Of Parents"' in source
    assert '"In-Transit Quantity In Alternates Of Parents"' in source
    assert '"on hand product sets of alternates of parents"' in source
    assert '"on hand + in transit product sets of alternates of parents"' in source
    assert "PARENT_ALTERNATE_COLUMNS" in source


def test_on_hand_quantity_in_parents_excludes_top_level_assemblies() -> None:
    for sql_file in SQL_FILES:
        sql = sql_file.read_text()

        assert "non_top_level_assemblies AS" in sql
        assert "parent_top_level_rollup AS" in sql
        assert "bom_line_parent_usage AS" in sql
        assert "bom_line_parent_metrics AS" in sql
        assert "NULLIF(TRIM(PARENT_BOM), '') IS NOT NULL" in sql
        assert "OR COALESCE(INDENT_LEVEL, 0) > 0" in sql
        assert 'AS "On Hand Quantity In Parents"' in sql
        assert 'AS "Current On Hand Quantity Including alternates and parents"' in sql
        assert 'AS "on hand product sets including alternates and parents"' in sql
        assert 'AS "on hand + in transit product sets"' in sql
        assert (
            'COALESCE(aim."Current On-Hand Quantity with alternates", 0)\n'
            '                        + COALESCE(aitm."in-transit quantity including alternates", 0)'
            in sql
        )
        assert (
            "COALESCE(child.ADJUSTED_QUANTITY, 0) / NULLIF(COALESCE(ancestor.ADJUSTED_QUANTITY, 0), 0)"
            in sql
        )
        assert (
            "LEFT(child.PATH_WITHOUT_REVISION, LENGTH(ancestor.PATH_WITHOUT_REVISION)) = ancestor.PATH_WITHOUT_REVISION"
            in sql
        )
        assert 'COALESCE(blpm."On Hand Quantity In Parents", 0)' in sql
        assert 'COALESCE(parent_im."Current On-Hand Quantity", 0)' in sql
        assert "COALESCE(parent_im.\"Current On-Hand Quantity\", 0)\n                        / ptlr.PARENT_ROLLED_UP_QUANTITY" in sql
        assert "LEFT JOIN inventory_metrics parent_im" in sql
        assert "LEFT JOIN bom_line_parent_metrics blpm" in sql
        assert "LEFT JOIN parent_top_level_rollup ptlr" in sql
