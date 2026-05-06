from datetime import date

import pandas as pd

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
    assert "total rolled up quantity" in df.columns
    assert "on hand product sets including alternates" in df.columns


def test_report_service_rolls_up_quantities_by_part_across_top_level_boms() -> None:
    service = BomCapacityReportService(
        FakeRepository(
            [
                {
                    "PATH": "TL1:R1|P1:R1|A:R1",
                    "PART_NUMBER": "P1",
                    "TOP_LEVEL_BOM": "TL1",
                    "TOP_LEVEL_REVISION": "R1",
                    "ADJUSTED_QUANTITY": 2,
                    "Current On-Hand Quantity with alternates": 20,
                },
                {
                    "PATH": "TL1:R1|P1:R1|B:R1",
                    "PART_NUMBER": "P1",
                    "TOP_LEVEL_BOM": "TL1",
                    "TOP_LEVEL_REVISION": "R1",
                    "ADJUSTED_QUANTITY": 3,
                    "Current On-Hand Quantity with alternates": 20,
                },
                {
                    "PATH": "TL2:R1|P1:R1",
                    "PART_NUMBER": "P1",
                    "TOP_LEVEL_BOM": "TL2",
                    "TOP_LEVEL_REVISION": "R1",
                    "ADJUSTED_QUANTITY": 5,
                    "Current On-Hand Quantity with alternates": 20,
                },
                {
                    "PATH": "TL1:R1|P2:R1",
                    "PART_NUMBER": "P2",
                    "TOP_LEVEL_BOM": "TL1",
                    "TOP_LEVEL_REVISION": "R1",
                    "ADJUSTED_QUANTITY": 2,
                    "Current On-Hand Quantity with alternates": 12,
                },
                {
                    "PATH": "TL2:R1|P2:R1",
                    "PART_NUMBER": "P2",
                    "TOP_LEVEL_BOM": "TL2",
                    "TOP_LEVEL_REVISION": "R1",
                    "ADJUSTED_QUANTITY": 3,
                    "Current On-Hand Quantity with alternates": 12,
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
    assert p1_rows["total rolled up quantity"].tolist() == ["5", "5", "5"]
    assert p1_rows["on hand product sets including alternates"].tolist() == [4.0, 4.0, 4.0]
    assert p2_rows["total rolled up quantity"].tolist() == ["mutliple", "mutliple"]
    assert p2_rows["on hand product sets including alternates"].isna().all()
    assert pd.api.types.is_string_dtype(df["total rolled up quantity"])
    assert pd.api.types.is_numeric_dtype(df["on hand product sets including alternates"])
