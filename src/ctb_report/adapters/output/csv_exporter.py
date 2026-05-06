from __future__ import annotations

from pathlib import Path

import pandas as pd

from ctb_report.config.models import ReportConfig


class CsvExporter:
    def export(self, df: pd.DataFrame, config: ReportConfig) -> Path:
        output_path = config.resolved_output_path()
        if output_path.exists() and not config.csv_overwrite:
            raise FileExistsError(f"Refusing to overwrite existing file: {output_path}")

        output_path.parent.mkdir(parents=True, exist_ok=True)
        df.to_csv(output_path, index=False, sep=config.csv_delimiter, header=config.csv_include_header)
        return output_path
