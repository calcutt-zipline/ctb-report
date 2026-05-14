# Reproduction Prompt

Structure this project as a portable, layered system:

- isolate core logic (data access, transformations, modeling) in a pure, reusable Python package with no UI or platform dependencies
- use development interfaces such as notebooks only as thin orchestration layers
- handle environment differences through configuration
- implement separate, lightweight output adapters such as dashboards, reports, apps, and CLI entrypoints that call the same core logic
- the project should be deployable across different platforms with minimal rework

Implement it as a Python project that:

- runs from the command line
- authenticates to Snowflake using browser-based auth
- auto-loads a local `.env`
- exports a CSV

Use this default env shape:

```env
SNOWFLAKE_ACCOUNT=oya50208
SNOWFLAKE_USER=brian.calcutt@flyzipline.com
SNOWFLAKE_AUTHENTICATOR=externalbrowser
SNOWFLAKE_WAREHOUSE=COMPUTE_WH
SNOWFLAKE_DATABASE=BIZ
SNOWFLAKE_SCHEMA=DBT
# optional:
# SNOWFLAKE_ROLE=ZIPLINE_READ_ONLY
# SNOWFLAKE_PASSWORD=...
# SNOWFLAKE_CONNECTION_NAME=OYA50208
```

The output should be a table with rows corresponding to each unique `PATH` on the BOM hierarchy table `BIZ.DBT.DIM_BOM_HIERARCHY`, where the top-level part number and revision for that `PATH` also appears on `fivetran_google_sheets.supply_chain_capacity_demand_by_part_number`.

The output table should include:

- `PATH`
- `PATH_WITHOUT_REVISION`
- the following BOM fields from `BIZ.DBT.DIM_BOM_HIERARCHY`:
  - `PART_NUMBER`
  - `REVISION`
  - `PRODUCT_NAME`
  - `PRODUCTION_STATE`
  - `INDENT_LEVEL`
  - `UOM`
  - `TRACKING`
  - `IS_CONSUMABLE_STORABLE`
  - `PARENT_BOM`
  - `PARENT_REVISION`
  - `TOP_LEVEL_BOM`
  - `TOP_LEVEL_REVISION`
  - `QUANTITY`
  - `PROCUREMENT_INTENT`
  - `ADJUSTED_QUANTITY`
  - `ADJUSTED_PROCUREMENT_INTENT`
  - `GLOBAL_ALTERNATE_PART_NUMBERS`
  - `SUBSTITUTE_PART_NUMBERS`
- fields looked up from `fivetran_google_sheets.supply_chain_structured_bom_data` using `PATH_WITHOUT_REVISION`:
  - `Product`
  - `Variant`
  - `System`
  - `Subsystem`
- fields looked up from `fivetran_google_sheets.supply_chain_flat_parts_list` using part number:
  - `Commodity`

`PATH_WITHOUT_REVISION` should be derived from the live pipe-delimited BOM path format by removing standalone revision segments such as `|A|`, `|B01|`, `|M|` while preserving the leading/trailing pipe structure. For example:

- `|20000-007|E|` -> `|20000-007|`
- `|20000-007|E|0109350-000|A|` -> `|20000-007|0109350-000|`

Use `fivetran_google_sheets.supply_chain_structured_bom_data.PATH_WITHOUT_REV` as the join target for structured BOM metadata.

Use `fivetran_google_sheets.supply_chain_flat_parts_list.NEW_COMMODITY` as `Commodity`.

For current inventory, use `BIZ.DBT_ODOO.INVENTORY` with these actual columns:

- part number: `DEFAULT_CODE`
- quantity: `QUANTITY`
- location id: `STOCK_LOCATION_ID`

For supply plans, use `fivetran_google_sheets.supply_chain_supply_plans` with these actual columns:

- part number: `PART_NUMBER`
- quantity: `QUANTITY`
- date: `DATE`

The supply plan `DATE` field is stored as `MM/DD` text without a year. Parse it by attaching the report year and using a safe date parse.

For alternate aggregation, use `fivetran_google_sheets.supply_chain_alternate_part_numbers`, which is a single-column Google Sheet of comma-separated alternate groups. The actual alternate-group column name is:

- `"PART_NUMBERS"`

Treat all part numbers listed in the same comma-separated row as one alternate group. For a given base part number, alternate-aware metrics should aggregate that part plus all related parts in its group.

## Stock move source query

Use this stock-move source logic:

```sql
SELECT
    sm.DATE,
    pt.DEFAULT_CODE,
    pt.NAME,
    sm.PRODUCT_QTY,
    slo.COMPLETE_NAME origin_name,
    sld.COMPLETE_NAME destination_name
FROM BIZ.DBT_STG.STG_ODOO_PROD__STOCK_MOVE sm
LEFT JOIN BIZ.DBT_STG.STG_ODOO_PROD__PRODUCT_PRODUCT p on p.ID = sm.PRODUCT_ID
LEFT JOIN BIZ.DBT_STG.STG_ODOO_PROD__PRODUCT_TEMPLATE pt on pt.ID = p.PRODUCT_TMPL_ID
LEFT JOIN BIZ.DBT_STG.STG_ODOO_PROD__STOCK_LOCATION slo on slo.ID = sm.LOCATION_ID
LEFT JOIN BIZ.DBT_STG.STG_ODOO_PROD__STOCK_LOCATION sld on sld.ID = sm.LOCATION_DEST_ID
WHERE sm.STATE = 'done'
AND sm.DATE >= '2025-01-01'
ORDER BY sm.DATE ASC
```

## Location categorization

Use this exact categorization logic for both stock moves and current inventory:

```sql
SELECT
  DISTINCT sl.COMPLETE_NAME,
  CASE
    WHEN sl.COMPLETE_NAME LIKE 'Vendors%' THEN 'Vendors'
    WHEN sl.COMPLETE_NAME LIKE 'Zipline%' THEN 'Production'
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
    WHEN sl.COMPLETE_NAME LIKE '%TZLLA%' THEN 'Nest'
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
    WHEN sl.COMPLETE_NAME LIKE 'COOP/P1 Manufacturing%' THEN 'Warehouse'
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
  END AS MRP_Category
FROM BIZ.DBT_STG.STG_ODOO_PROD__STOCK_LOCATION sl
ORDER BY COMPLETE_NAME
```

## Transaction categorization

Use this logic:

```python
def categorize_transaction_v2(row):
    origin = row["MRP_CATEGORY_ORIGIN"]
    dest = row["MRP_CATEGORY_DESTINATION"]
    qty = row["PRODUCT_QTY"]

    if origin == "Vendors" and dest == "Warehouse":
        return "New Supply", qty
    elif origin == "Warehouse" and dest == "Vendors":
        return "New Supply", -qty
    elif origin == "Warehouse" and dest == "Nest":
        return "Nest Consumption", qty
    elif origin == "Nest" and dest == "Warehouse":
        return "RMA Supply", qty
    elif origin == "Warehouse" and dest == "Production":
        return "Production Consumption", qty
    elif origin == "Production" and dest == "Warehouse":
        return "Production Consumption", -qty
    elif origin == "Warehouse" and dest == "Nest":
        return "Nest Consumption", qty
    elif origin == "Warehouse" and dest == "Scrap":
        return "QC Loss Consumption", qty
    elif origin == "Warehouse" and dest == "Quarantine":
        return "QC Loss Consumption", qty
    elif origin == "Quarantine" and dest == "Warehouse":
        return "QC Loss Consumption", -qty
    elif origin == "Scrap" and dest == "Warehouse":
        return "QC Loss Consumption", -qty
    elif origin == "Warehouse" and dest == "R&D":
        return "R&D Consumption", qty
    elif origin == "R&D" and dest == "Warehouse":
        return "R&D Supply", qty
    else:
        return "Unknown", None
```

## Metrics

Compute:

- `Quantity Received, 4-Week Rolling Average`
- `Quantity Received, 8-Week Rolling Average`
- `Quantity Received, Average Since Last Receipt`
- `Current On-Hand Quantity`
- `Current Quarantine Quantity`
- `Total Supply Plan, next 4 weeks`
- `Total Supply Plan, next 8 weeks`
- `Average Supply Plan, next 4 weeks`
- `Average Supply Plan, next 8 weeks`

Historical receipts:

- use `New Supply` and `R&D Supply`
- use calendar weeks
- include the current calendar week in historical 4-week and 8-week rolling averages
- include zero weeks in the denominator
- if 10 units were received across the last 4 calendar weeks, the 4-week rolling average must be `2.5`

Historical receipt average since last receipt:

- use the most recent qualifying receipt
- compute the receipt quantity divided by elapsed weeks since that receipt

Current inventory:

- on-hand = sum of inventory in `Warehouse`
- quarantine = sum of inventory in `Quarantine`

Future supply plan:

- totals for `next 4 weeks` and `next 8 weeks` should use calendar weeks and include the current week
- rolling averages should use calendar weeks, include zero weeks, and start with the next calendar week
  - `Average Supply Plan, next 4 weeks` = weeks `+1` through `+4`, divided by `4`
  - `Average Supply Plan, next 8 weeks` = weeks `+1` through `+8`, divided by `8`

## Numeric output columns

For all numeric metrics above:

1. create base `(... each)` columns
2. create base `(... sets)` columns by dividing the `each` value by `ADJUSTED_QUANTITY`
3. duplicate all of those metrics as `with alternates`, aggregating across the part number plus all alternates from `supply_chain_alternate_part_numbers`

If `ADJUSTED_QUANTITY` is blank or zero, leave the corresponding `(sets)` value blank.

Order the metric columns in this exact grouping:

1. all base `each`
2. all base `sets`
3. all `each with alternates`
4. all `sets with alternates`

## Project shape

Build the project as a layered Python package with:

- `src/ctb_report/config`
- `src/ctb_report/domain`
- `src/ctb_report/data_access`
- `src/ctb_report/services`
- `src/ctb_report/adapters/output`
- `src/ctb_report/adapters/notebook`
- `sql`
- `notebooks`

Requirements:

- CLI entrypoint via `python -m ctb_report`
- thin notebook adapter
- CSV exporter
- `.env` auto-loading in the CLI
- browser-auth Snowflake connection

The CLI should support:

- `--env-file`
- `--as-of-date`
- `--output`
- `--overwrite`
- `--delimiter`
- `--no-header`

The main command should be:

```bash
PYTHONPATH=src python3 -m ctb_report --overwrite --output outputs/bom_capacity_report.csv
```

The output of this implementation should match the current project state, including:

- SQL-heavy transformations in Snowflake
- Python service-layer post-processing for `(each)`, `(sets)`, and `with alternates`
- current live schema adaptations for the source tables above
- the generated CSV at `outputs/bom_capacity_report.csv`
