from datetime import date

import pandas as pd
import pytest

from ctb_report.config.models import ReportConfig, SnowflakeConfig
from ctb_report.services.report_service import BomCapacityReportService


class FakeRepository:
    def __init__(self, rows=None) -> None:
        self.rows = rows or [
            {
                "PATH": "ABC:REV1|DEF:REV2",
                "PART_NUMBER": "DEF",
                "REVISION": "REV2",
            }
        ]

    def fetch_report(self, config: ReportConfig) -> pd.DataFrame:
        return pd.DataFrame(self.rows)


def test_report_service_shapes_final_columns() -> None:
    service = BomCapacityReportService(FakeRepository())
    config = ReportConfig(
        snowflake=SnowflakeConfig(account="acct", user="user"),
        as_of_date=date(2026, 4, 23),
    )

    df = service.run(config)

    assert df.loc[0, "PATH"] == "ABC:REV1|DEF:REV2"
    assert df.loc[0, "PATH_WITHOUT_REVISION"] == "ABC|DEF"
    assert "Current On-Hand Quantity (each)" in df.columns
    assert "Current Receiving & Pre-IQC Quantity (each)" in df.columns
    assert "Current Receiving & Pre-IQC Quantity (each) with alternates" in df.columns
    assert "total rolled up quantity" in df.columns
    assert "on hand product sets including alternates" in df.columns
    assert "receiving & pre-iqc product sets" in df.columns
    assert "On Hand Quantity In Parents" in df.columns
    assert "On Hand Quantity In Alternates Of Parents" in df.columns
    assert "In-Transit Quantity In Alternates Of Parents" in df.columns
    assert "in-transit quantity including alternates" in df.columns
    assert "in-transit inventory value including alternates" in df.columns
    assert "Current On Hand Quantity Including alternates and parents" in df.columns
    assert "Current On Hand Inventory Value Including alternates and parents" in df.columns
    assert "on hand product sets of alternates of parents" in df.columns
    assert "on hand + in transit product sets of alternates of parents" in df.columns
    assert "on hand product sets including alternates and parents" in df.columns
    assert "on hand + in transit product sets" in df.columns
    assert "Weeks of Stock" in df.columns
    assert "Weeks of Stock with In Transit" in df.columns
    assert "in transit weeks of stock" in df.columns
    assert "In Transit Weeks of Stock Of System's Minimum Weeks of Stock Part" in df.columns
    assert "Current Week Net Demand" in df.columns
    assert "Current Week Net Total Demand" in df.columns
    assert "Unit Cost Used" in df.columns
    assert "Unit Cost Source" in df.columns


def test_report_service_backfills_current_week_net_demand_from_existing_total_column() -> None:
    service = BomCapacityReportService(
        FakeRepository(
            [
                {
                    "PATH": "ABC:REV1|DEF:REV2",
                    "PART_NUMBER": "DEF",
                    "REVISION": "REV2",
                    "Current Week Net Total Demand": 12,
                }
            ]
        )
    )
    config = ReportConfig(
        snowflake=SnowflakeConfig(account="acct", user="user"),
        as_of_date=date(2026, 4, 23),
    )

    df = service.run(config)

    assert df.loc[0, "Current Week Net Demand"] == 12


def test_report_service_uses_max_zipline_buy_rollup_across_demanded_top_level_boms() -> None:
    service = BomCapacityReportService(
        FakeRepository(
            [
                {
                    "PATH": "TL1:R1|P1:R1|A:R1",
                    "PART_NUMBER": "P1",
                    "PARENT_BOM": "TL1",
                    "TOP_LEVEL_BOM": "TL1",
                    "TOP_LEVEL_REVISION": "R1",
                    "INDENT_LEVEL": 1,
                    "ADJUSTED_QUANTITY": 2,
                    "ADJUSTED_PROCUREMENT_INTENT": "zipline_buy",
                    "Current On-Hand Quantity with alternates": 21,
                    "Current Receiving & Pre-IQC Quantity with alternates": 14,
                },
                {
                    "PATH": "TL1:R1|P1:R1|B:R1",
                    "PART_NUMBER": "P1",
                    "PARENT_BOM": "TL1",
                    "TOP_LEVEL_BOM": "TL1",
                    "TOP_LEVEL_REVISION": "R1",
                    "INDENT_LEVEL": 1,
                    "ADJUSTED_QUANTITY": 3,
                    "ADJUSTED_PROCUREMENT_INTENT": "zipline_buy",
                    "Current On-Hand Quantity with alternates": 21,
                    "Current Receiving & Pre-IQC Quantity with alternates": 14,
                },
                {
                    "PATH": "TL2:R1|P1:R1",
                    "PART_NUMBER": "P1",
                    "PARENT_BOM": "TL2",
                    "TOP_LEVEL_BOM": "TL2",
                    "TOP_LEVEL_REVISION": "R1",
                    "INDENT_LEVEL": 1,
                    "ADJUSTED_QUANTITY": 7,
                    "ADJUSTED_PROCUREMENT_INTENT": "zipline_buy",
                    "Current On-Hand Quantity with alternates": 21,
                    "Current Receiving & Pre-IQC Quantity with alternates": 14,
                },
                {
                    "PATH": "TL2:R1|P1:R1|SUPPLIER:R1",
                    "PART_NUMBER": "P1",
                    "PARENT_BOM": "TL2",
                    "TOP_LEVEL_BOM": "TL2",
                    "TOP_LEVEL_REVISION": "R1",
                    "INDENT_LEVEL": 1,
                    "ADJUSTED_QUANTITY": 100,
                    "ADJUSTED_PROCUREMENT_INTENT": "supplier_buy",
                    "Current On-Hand Quantity with alternates": 21,
                    "Current Receiving & Pre-IQC Quantity with alternates": 14,
                },
                {
                    "PATH": "TL1:R1|P2:R1",
                    "PART_NUMBER": "P2",
                    "PARENT_BOM": "TL1",
                    "TOP_LEVEL_BOM": "TL1",
                    "TOP_LEVEL_REVISION": "R1",
                    "INDENT_LEVEL": 1,
                    "ADJUSTED_QUANTITY": 2,
                    "ADJUSTED_PROCUREMENT_INTENT": "supplier_buy",
                    "Current On-Hand Quantity with alternates": 12,
                },
                {
                    "PATH": "TL2:R1|P2:R1",
                    "PART_NUMBER": "P2",
                    "PARENT_BOM": "TL2",
                    "TOP_LEVEL_BOM": "TL2",
                    "TOP_LEVEL_REVISION": "R1",
                    "INDENT_LEVEL": 1,
                    "ADJUSTED_QUANTITY": 3,
                    "ADJUSTED_PROCUREMENT_INTENT": "supplier_buy",
                    "Current On-Hand Quantity with alternates": 12,
                },
                {
                    "PATH": "TL3:R1|P3:R1",
                    "PART_NUMBER": "P3",
                    "PARENT_BOM": "TL3",
                    "TOP_LEVEL_BOM": "TL3",
                    "TOP_LEVEL_REVISION": "R1",
                    "INDENT_LEVEL": 1,
                    "ADJUSTED_QUANTITY": 0,
                    "ADJUSTED_PROCUREMENT_INTENT": "zipline_buy",
                    "Current On-Hand Quantity with alternates": 10,
                },
                {
                    "PATH": "TL_TOP:R1|TL_CHILD:R1",
                    "PART_NUMBER": "TL_CHILD",
                    "PARENT_BOM": "TL_TOP",
                    "TOP_LEVEL_BOM": "TL_TOP",
                    "TOP_LEVEL_REVISION": "R1",
                    "INDENT_LEVEL": 1,
                    "ADJUSTED_QUANTITY": 1,
                    "ADJUSTED_PROCUREMENT_INTENT": "make",
                    "Current On-Hand Quantity with alternates": 0,
                },
                {
                    "PATH": "TL_CHILD:R1|P4:R1",
                    "PART_NUMBER": "P4",
                    "PARENT_BOM": "TL_CHILD",
                    "TOP_LEVEL_BOM": "TL_CHILD",
                    "TOP_LEVEL_REVISION": "R1",
                    "INDENT_LEVEL": 1,
                    "ADJUSTED_QUANTITY": 9,
                    "ADJUSTED_PROCUREMENT_INTENT": "zipline_buy",
                    "Current On-Hand Quantity with alternates": 40,
                    "Current Receiving & Pre-IQC Quantity with alternates": 8,
                },
                {
                    "PATH": "TL_TOP:R1|P4:R1",
                    "PART_NUMBER": "P4",
                    "PARENT_BOM": "TL_TOP",
                    "TOP_LEVEL_BOM": "TL_TOP",
                    "TOP_LEVEL_REVISION": "R1",
                    "INDENT_LEVEL": 1,
                    "ADJUSTED_QUANTITY": 4,
                    "ADJUSTED_PROCUREMENT_INTENT": "zipline_buy",
                    "Current On-Hand Quantity with alternates": 40,
                    "Current Receiving & Pre-IQC Quantity with alternates": 8,
                },
            ]
        )
    )
    config = ReportConfig(
        snowflake=SnowflakeConfig(account="acct", user="user"),
        as_of_date=date(2026, 4, 23),
    )

    df = service.run(config)

    p1_rows = df[df["PART_NUMBER"] == "P1"]
    p2_rows = df[df["PART_NUMBER"] == "P2"]
    p3_rows = df[df["PART_NUMBER"] == "P3"]
    p4_rows = df[df["PART_NUMBER"] == "P4"]
    assert p1_rows["total rolled up quantity"].tolist() == [7.0, 7.0, 7.0, 7.0]
    assert p1_rows["on hand product sets including alternates"].tolist() == [3.0, 3.0, 3.0, 3.0]
    assert p1_rows["receiving & pre-iqc product sets"].tolist() == [2.0, 2.0, 2.0, 2.0]
    assert p2_rows["on hand product sets including alternates"].isna().all()
    assert p2_rows["total rolled up quantity"].isna().all()
    assert p3_rows["total rolled up quantity"].tolist() == [0.0]
    assert p3_rows["on hand product sets including alternates"].isna().all()
    assert p4_rows["total rolled up quantity"].tolist() == [4.0, 4.0]
    assert p4_rows["on hand product sets including alternates"].tolist() == [10.0, 10.0]
    assert p4_rows["receiving & pre-iqc product sets"].tolist() == [2.0, 2.0]
    assert pd.api.types.is_numeric_dtype(df["total rolled up quantity"])
    assert pd.api.types.is_numeric_dtype(df["on hand product sets including alternates"])
    assert pd.api.types.is_numeric_dtype(df["receiving & pre-iqc product sets"])


def test_report_service_calculates_on_hand_quantity_in_non_top_level_parents() -> None:
    service = BomCapacityReportService(
        FakeRepository(
            [
                {
                    "PATH": "|10000-000|",
                    "PART_NUMBER": "10000-000",
                    "PARENT_BOM": None,
                    "TOP_LEVEL_BOM": "10000-000",
                    "TOP_LEVEL_REVISION": "R1",
                    "INDENT_LEVEL": 0,
                    "QUANTITY": 1,
                    "ADJUSTED_QUANTITY": 1,
                    "ADJUSTED_PROCUREMENT_INTENT": "zipline_buy",
                    "Current On-Hand Quantity": 5,
                    "Current On-Hand Quantity with alternates": 5,
                },
                {
                    "PATH": "|10000-000|20000-000|",
                    "PART_NUMBER": "20000-000",
                    "PARENT_BOM": "10000-000",
                    "TOP_LEVEL_BOM": "10000-000",
                    "TOP_LEVEL_REVISION": "R1",
                    "INDENT_LEVEL": 1,
                    "QUANTITY": 2,
                    "ADJUSTED_QUANTITY": 2,
                    "ADJUSTED_PROCUREMENT_INTENT": "zipline_buy",
                    "Current On-Hand Quantity": 6,
                    "Current On-Hand Quantity with alternates": 6,
                },
                {
                    "PATH": "|10000-000|20000-000|25000-000|",
                    "PART_NUMBER": "25000-000",
                    "PARENT_BOM": "20000-000",
                    "TOP_LEVEL_BOM": "10000-000",
                    "TOP_LEVEL_REVISION": "R1",
                    "INDENT_LEVEL": 2,
                    "QUANTITY": 3,
                    "ADJUSTED_QUANTITY": 6,
                    "ADJUSTED_PROCUREMENT_INTENT": "zipline_buy",
                    "Current On-Hand Quantity": 4,
                    "Current On-Hand Quantity with alternates": 4,
                },
                {
                    "PATH": "|10000-000|20000-000|25000-000|30000-000|",
                    "PART_NUMBER": "30000-000",
                    "PARENT_BOM": "25000-000",
                    "TOP_LEVEL_BOM": "10000-000",
                    "TOP_LEVEL_REVISION": "R1",
                    "INDENT_LEVEL": 3,
                    "QUANTITY": 5,
                    "ADJUSTED_QUANTITY": 30,
                    "ADJUSTED_PROCUREMENT_INTENT": "zipline_buy",
                    "Current On-Hand Quantity": 10,
                    "Current On-Hand Quantity with alternates": 10,
                    "in-transit quantity including alternates": 20,
                },
                {
                    "PATH": "|10000-000|40000-000|",
                    "PART_NUMBER": "40000-000",
                    "PARENT_BOM": "10000-000",
                    "TOP_LEVEL_BOM": "10000-000",
                    "TOP_LEVEL_REVISION": "R1",
                    "INDENT_LEVEL": 1,
                    "QUANTITY": 4,
                    "ADJUSTED_QUANTITY": 4,
                    "ADJUSTED_PROCUREMENT_INTENT": "zipline_buy",
                    "Current On-Hand Quantity": 7,
                    "Current On-Hand Quantity with alternates": 7,
                    "in-transit quantity including alternates": 1,
                },
            ]
        )
    )
    config = ReportConfig(
        snowflake=SnowflakeConfig(account="acct", user="user"),
        as_of_date=date(2026, 4, 23),
    )

    df = service.run(config)

    assert df.loc[df["PART_NUMBER"] == "30000-000", "On Hand Quantity In Parents"].tolist() == [110.0]
    assert df.loc[df["PART_NUMBER"] == "20000-000", "On Hand Quantity In Parents"].tolist() == [0.0]
    assert df.loc[df["PART_NUMBER"] == "40000-000", "On Hand Quantity In Parents"].tolist() == [0.0]
    assert df.loc[
        df["PART_NUMBER"] == "30000-000",
        "Current On Hand Quantity Including alternates and parents",
    ].tolist() == [120.0]
    c1_combined_sets = df.loc[
        df["PART_NUMBER"] == "30000-000",
        "on hand product sets including alternates and parents",
    ].iloc[0]
    assert c1_combined_sets == pytest.approx((10 / 30) + (4 / 6) + (6 / 2))
    c1_on_hand_in_transit_sets = df.loc[
        df["PART_NUMBER"] == "30000-000",
        "on hand + in transit product sets",
    ].iloc[0]
    assert c1_on_hand_in_transit_sets == pytest.approx(((10 + 20) / 30) + (4 / 6) + (6 / 2))
    assert df.loc[
        df["PART_NUMBER"] == "20000-000",
        "on hand product sets including alternates and parents",
    ].tolist() == [3.0]
    assert df.loc[
        df["PART_NUMBER"] == "40000-000",
        "on hand product sets including alternates and parents",
    ].tolist() == [1.75]
    assert df.loc[
        df["PART_NUMBER"] == "40000-000",
        "on hand + in transit product sets",
    ].tolist() == [2.0]
    assert pd.api.types.is_numeric_dtype(df["On Hand Quantity In Parents"])
    assert pd.api.types.is_numeric_dtype(df["On Hand Quantity In Alternates Of Parents"])
    assert pd.api.types.is_numeric_dtype(df["In-Transit Quantity In Alternates Of Parents"])
    assert pd.api.types.is_numeric_dtype(df["Current On Hand Quantity Including alternates and parents"])
    assert pd.api.types.is_numeric_dtype(df["on hand product sets of alternates of parents"])
    assert pd.api.types.is_numeric_dtype(df["on hand + in transit product sets of alternates of parents"])
    assert pd.api.types.is_numeric_dtype(df["on hand product sets including alternates and parents"])
    assert pd.api.types.is_numeric_dtype(df["on hand + in transit product sets"])


def test_report_service_calculates_parent_alternate_stock_and_buildable_sets() -> None:
    service = BomCapacityReportService(
        FakeRepository(
            [
                {
                    "PATH": "|TOP|",
                    "PART_NUMBER": "TOP",
                    "PARENT_BOM": None,
                    "TOP_LEVEL_BOM": "TOP",
                    "TOP_LEVEL_REVISION": "R1",
                    "INDENT_LEVEL": 0,
                    "ADJUSTED_QUANTITY": 1,
                    "ADJUSTED_PROCUREMENT_INTENT": "make",
                    "Current On-Hand Quantity": 0,
                    "Current On-Hand Quantity with alternates": 0,
                },
                {
                    "PATH": "|TOP|PARENT|",
                    "PART_NUMBER": "PARENT",
                    "PARENT_BOM": "TOP",
                    "TOP_LEVEL_BOM": "TOP",
                    "TOP_LEVEL_REVISION": "R1",
                    "INDENT_LEVEL": 1,
                    "ADJUSTED_QUANTITY": 1,
                    "ADJUSTED_PROCUREMENT_INTENT": "make",
                    "Supply Plan and On-Hand Alternates": "ALT_PARENT",
                    "Current On-Hand Quantity": 0,
                    "Current On-Hand Quantity with alternates": 0,
                    "in-transit quantity including alternates": 0,
                },
                {
                    "PATH": "|TOP|PARENT|CHILD|",
                    "PART_NUMBER": "CHILD",
                    "PARENT_BOM": "PARENT",
                    "TOP_LEVEL_BOM": "TOP",
                    "TOP_LEVEL_REVISION": "R1",
                    "INDENT_LEVEL": 2,
                    "ADJUSTED_QUANTITY": 2,
                    "ADJUSTED_PROCUREMENT_INTENT": "zipline_buy",
                    "Current On-Hand Quantity": 10,
                    "Current On-Hand Quantity with alternates": 10,
                    "Current Week Net Demand": 0,
                    "in-transit quantity including alternates": 0,
                },
                {
                    "PATH": "|ALT_PARENT|",
                    "PART_NUMBER": "ALT_PARENT",
                    "PARENT_BOM": None,
                    "TOP_LEVEL_BOM": "ALT_PARENT",
                    "TOP_LEVEL_REVISION": "A",
                    "INDENT_LEVEL": 0,
                    "ADJUSTED_QUANTITY": 1,
                    "ADJUSTED_PROCUREMENT_INTENT": "make",
                    "Supply Plan and On-Hand Alternates": "PARENT",
                    "Current On-Hand Quantity": 5,
                    "Current On-Hand Quantity with alternates": 5,
                    "in-transit quantity including alternates": 3,
                },
                {
                    "PATH": "|ALT_PARENT|COMP_A|",
                    "PART_NUMBER": "COMP_A",
                    "PARENT_BOM": "ALT_PARENT",
                    "TOP_LEVEL_BOM": "ALT_PARENT",
                    "TOP_LEVEL_REVISION": "A",
                    "INDENT_LEVEL": 1,
                    "ADJUSTED_QUANTITY": 100,
                    "ADJUSTED_PROCUREMENT_INTENT": "zipline_buy",
                    "Supply Plan and On-Hand Alternates": "COMP_A_ALT",
                    "Current On-Hand Quantity": 5,
                    "Current Week Net Demand": 1,
                    "in-transit quantity including alternates": 0,
                },
                {
                    "PATH": "|ALT_PARENT_B|",
                    "PART_NUMBER": "ALT_PARENT",
                    "PARENT_BOM": None,
                    "TOP_LEVEL_BOM": "ALT_PARENT",
                    "TOP_LEVEL_REVISION": "B",
                    "INDENT_LEVEL": 0,
                    "ADJUSTED_QUANTITY": 1,
                    "ADJUSTED_PROCUREMENT_INTENT": "make",
                    "Supply Plan and On-Hand Alternates": "PARENT",
                    "Current On-Hand Quantity": 5,
                    "Current On-Hand Quantity with alternates": 5,
                    "in-transit quantity including alternates": 3,
                },
                {
                    "PATH": "|ALT_PARENT_B|COMP_A|",
                    "PART_NUMBER": "COMP_A",
                    "PARENT_BOM": "ALT_PARENT",
                    "TOP_LEVEL_BOM": "ALT_PARENT",
                    "TOP_LEVEL_REVISION": "B",
                    "INDENT_LEVEL": 1,
                    "ADJUSTED_QUANTITY": 2,
                    "ADJUSTED_PROCUREMENT_INTENT": "zipline_buy",
                    "IS_CONSUMABLE_STORABLE": False,
                    "Supply Plan and On-Hand Alternates": "COMP_A_ALT",
                    "Current On-Hand Quantity": 5,
                    "Current Week Net Demand": 1,
                    "in-transit quantity including alternates": 0,
                },
                {
                    "PATH": "|ALT_PARENT_B|COMP_B|",
                    "PART_NUMBER": "COMP_B",
                    "PARENT_BOM": "ALT_PARENT",
                    "TOP_LEVEL_BOM": "ALT_PARENT",
                    "TOP_LEVEL_REVISION": "B",
                    "INDENT_LEVEL": 1,
                    "ADJUSTED_QUANTITY": 4,
                    "ADJUSTED_PROCUREMENT_INTENT": "zipline_buy",
                    "IS_CONSUMABLE_STORABLE": False,
                    "Current On-Hand Quantity": 20,
                    "Current Week Net Demand": 8,
                    "in-transit quantity including alternates": 4,
                },
                {
                    "PATH": "|COMP_A_ALT|",
                    "PART_NUMBER": "COMP_A_ALT",
                    "PARENT_BOM": None,
                    "TOP_LEVEL_BOM": "COMP_A_ALT",
                    "TOP_LEVEL_REVISION": "R1",
                    "INDENT_LEVEL": 0,
                    "ADJUSTED_QUANTITY": 1,
                    "ADJUSTED_PROCUREMENT_INTENT": "make",
                    "Supply Plan and On-Hand Alternates": "COMP_A",
                    "Current On-Hand Quantity": 4,
                    "Current Week Net Demand": 0,
                    "in-transit quantity including alternates": 0,
                },
            ]
        )
    )
    config = ReportConfig(
        snowflake=SnowflakeConfig(account="acct", user="user"),
        as_of_date=date(2026, 4, 23),
    )

    df = service.run(config)
    child_row = df[df["PART_NUMBER"] == "CHILD"].iloc[0]

    assert child_row["On Hand Quantity In Alternates Of Parents"] == pytest.approx(10.0)
    assert child_row["In-Transit Quantity In Alternates Of Parents"] == pytest.approx(6.0)
    assert child_row["on hand product sets of alternates of parents"] == pytest.approx(3.0)
    assert child_row["on hand + in transit product sets of alternates of parents"] == pytest.approx(4.0)
    assert child_row["Current On Hand Quantity Including alternates and parents"] == pytest.approx(10.0)
    assert child_row["on hand product sets including alternates and parents"] == pytest.approx(5.0)
    assert child_row["on hand + in transit product sets"] == pytest.approx(5.0)
