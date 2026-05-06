from datetime import date

import pandas as pd

from ctb_report.adapters.output.csv_exporter import CsvExporter
from ctb_report.config.models import ReportConfig, SnowflakeConfig


def make_config(tmp_path, overwrite: bool = False) -> ReportConfig:
    return ReportConfig(
        snowflake=SnowflakeConfig(account="acct", user="user"),
        as_of_date=date(2026, 4, 23),
        csv_output_path=tmp_path / "report.csv",
        csv_overwrite=overwrite,
    )


def test_csv_exporter_writes_expected_file(tmp_path) -> None:
    config = make_config(tmp_path)
    df = pd.DataFrame([{"PATH": "A"}])

    output_path = CsvExporter().export(df, config)

    assert output_path.exists()
    assert output_path.read_text().startswith("PATH\nA\n")


def test_csv_exporter_refuses_overwrite(tmp_path) -> None:
    config = make_config(tmp_path)
    path = config.resolved_output_path()
    path.write_text("existing")

    try:
        CsvExporter().export(pd.DataFrame([{"PATH": "A"}]), config)
    except FileExistsError:
        pass
    else:
        raise AssertionError("Expected FileExistsError")
