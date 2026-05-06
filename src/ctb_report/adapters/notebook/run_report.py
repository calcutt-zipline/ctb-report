from __future__ import annotations

from pathlib import Path
from typing import Tuple

import pandas as pd

from ctb_report.adapters.output.csv_exporter import CsvExporter
from ctb_report.config.models import ReportConfig, SnowflakeConfig
from ctb_report.data_access.repository import ReportRepository
from ctb_report.data_access.snowflake import SnowflakeClient
from ctb_report.services.report_service import BomCapacityReportService


def build_service(config: ReportConfig) -> BomCapacityReportService:
    client = SnowflakeClient(config.snowflake)
    repository = ReportRepository(client)
    return BomCapacityReportService(repository)


def run_report_to_csv(config: ReportConfig) -> Tuple[pd.DataFrame, Path]:
    service = build_service(config)
    df = service.run(config)
    output_path = CsvExporter().export(df, config)
    return df, output_path


def report_config_from_env(**overrides: object) -> ReportConfig:
    config = ReportConfig(snowflake=SnowflakeConfig.from_env())
    if not overrides:
        return config
    return ReportConfig(**{**config.__dict__, **overrides})
