# Mode Transfer Guide

This project can be moved into Mode with one SQL query and one Python notebook.

Artifacts prepared in this repo:
- SQL to paste into Mode: [sql/mode_bom_capacity_raw.sql](/Users/brian.calcutt/code/work/ctb-report/sql/mode_bom_capacity_raw.sql:1)
- Notebook to import into Mode: [notebooks/mode_bom_capacity_publish.ipynb](/Users/brian.calcutt/code/work/ctb-report/notebooks/mode_bom_capacity_publish.ipynb:1)

## What the Mode version does
- SQL query produces the raw report dataset directly from Snowflake.
- Python notebook applies the same final shaping this project currently does:
  - renames numeric metrics to `(... each)`
  - drops `Commodity`
  - fills missing numeric metrics with `0`
  - enforces the final column order
- The notebook’s final output cell is `final_df`, so that dataframe can be published from the notebook.

## Mode Setup
1. Create a new Mode report connected to the same Snowflake data source.
2. Add a SQL query and name it exactly `BOM Capacity Raw`.
3. Paste the contents of [sql/mode_bom_capacity_raw.sql](/Users/brian.calcutt/code/work/ctb-report/sql/mode_bom_capacity_raw.sql:1) into that query.
4. Run the SQL query once and confirm it returns rows.
5. Add a notebook to the report and import [notebooks/mode_bom_capacity_publish.ipynb](/Users/brian.calcutt/code/work/ctb-report/notebooks/mode_bom_capacity_publish.ipynb:1).
6. Run the notebook.
7. In the last notebook cell, publish `final_df`:
   - use `Add to Report` if you want the dataframe output visible in the report
   - or use `Use output -> Create a dataset` if you want a local Python dataset inside Mode for downstream tables/charts

## SQL Notes
The Mode SQL file is already adapted from this project’s local SQL:
- all relation placeholders are inlined
- `CURRENT_DATE()` is used as the report as-of date
- the query returns the raw metrics used by the notebook

If you need a fixed as-of date instead of `CURRENT_DATE()`, edit the first CTE in [sql/mode_bom_capacity_raw.sql](/Users/brian.calcutt/code/work/ctb-report/sql/mode_bom_capacity_raw.sql:1):

```sql
WITH params AS (
    SELECT CURRENT_DATE() AS as_of_date
),
```

Replace it with:

```sql
WITH params AS (
    SELECT TO_DATE('2026-04-27') AS as_of_date
),
```

## Notebook Notes
The imported notebook expects the SQL query to be named `BOM Capacity Raw`. If you rename the query, update this line in the notebook:

```python
raw_df = datasets["BOM Capacity Raw"].copy()
```

The notebook also has a fallback to `datasets[0]`, but keeping the SQL query name stable is cleaner.

## Publish the final dataframe
To make the final output usable inside Mode:
- keep the last notebook cell as just `final_df`
- run the notebook
- from the output cell, publish it to the report or create a local dataset

That final dataframe is the Mode equivalent of this project’s exported CSV.

## Validation Checklist
After import, check these before sharing:
- SQL query runs successfully in Mode
- notebook runs without edits
- final output cell contains a pandas dataframe
- column order matches the CSV from this repo
- numeric blanks are `0`, not `NULL`
- `Supply Plan and On-Hand Alternates` is present
- demand columns use:
  - `Gross Demand for BOM Line ...`
  - `Net Total Demand for Part Number ...`

## Current Caveats
- The SQL still emits a few intermediate raw columns internally; the notebook trims the output to the final published schema.
- Week logic is driven by Snowflake SQL date functions, not Python.
- The query uses `CURRENT_DATE()` by default, so rerunning in Mode on a different day will change the week windows.

## Relevant Mode docs
- Mode notebooks can be imported from `.ipynb`, and SQL query results are available to the notebook through `datasets`: https://mode.com/help/articles/notebook/
- Notebook output can be added to the report, and pandas dataframe output can be turned into a local dataset: https://mode.com/help/articles/notebook/
- Mode reports combine SQL and notebooks in one report workflow: https://mode.com/help/articles/getting-started-with-mode/
