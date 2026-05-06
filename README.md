# ctb-report

Portable BOM capacity reporting with:

- a reusable Python core package
- Snowflake SQL pushed down for heavy computation
- thin notebook and CSV output adapters

## Quick start

1. Create a virtual environment.
2. Install dependencies with `pip install -e .[dev]`.
3. Set Snowflake environment variables or pass values into `ReportConfig`.
4. Put Snowflake settings in `.env`, then run `ctb-report --overwrite --output outputs/bom_capacity_report.csv`, `python -m ctb_report --overwrite`, or use the notebook in `notebooks/bom_capacity_report.ipynb`.

## Package layout

- `src/ctb_report/domain`: pure business logic and models
- `src/ctb_report/data_access`: Snowflake client and SQL loading
- `src/ctb_report/services`: report orchestration
- `src/ctb_report/adapters/output`: CSV export
- `src/ctb_report/adapters/notebook`: notebook helpers
- `sql`: query assets
