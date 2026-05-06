from pathlib import Path


SQL_FILES = [
    Path("sql/final_report.sql"),
    Path("sql/mode_bom_capacity_raw.sql"),
]


def test_coop_quality_locations_are_quarantine() -> None:
    for sql_file in SQL_FILES:
        sql = sql_file.read_text()

        assert "WHEN sl.COMPLETE_NAME LIKE 'COOP/Quarantine%' THEN 'Quarantine'" in sql
        assert "WHEN sl.COMPLETE_NAME LIKE 'COOP/MRB%' THEN 'Quarantine'" in sql
        assert "WHEN sl.COMPLETE_NAME LIKE 'COOP/IQC%' THEN 'Quarantine'" in sql


def test_on_hand_product_sets_sql_stays_numeric() -> None:
    for sql_file in SQL_FILES:
        sql = sql_file.read_text()

        assert "OR prq.TOTAL_ROLLED_UP_QUANTITY_NUMERIC = 0 THEN NULL" in sql
        assert "TO_VARCHAR(COALESCE(aim.\"Current On-Hand Quantity with alternates\", 0)" not in sql
