from __future__ import annotations

import argparse
from datetime import date
import os
from pathlib import Path
from typing import Sequence

from ctb_report.adapters.notebook.run_report import run_report_to_csv
from ctb_report.config.models import ReportConfig, SnowflakeConfig


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Run the BOM capacity report and export a CSV.")
    parser.add_argument(
        "--env-file",
        type=Path,
        default=Path(".env"),
        help="Path to an env file to load before reading Snowflake settings. Defaults to .env.",
    )
    parser.add_argument(
        "--as-of-date",
        type=date.fromisoformat,
        default=date.today(),
        help="Report as-of date in YYYY-MM-DD format. Defaults to today.",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=None,
        help="Output CSV path. Defaults to bom_capacity_report_YYYYMMDD.csv in the current directory.",
    )
    parser.add_argument(
        "--overwrite",
        action="store_true",
        help="Overwrite the output file if it already exists.",
    )
    parser.add_argument(
        "--delimiter",
        default=",",
        help="CSV delimiter. Defaults to ','.",
    )
    parser.add_argument(
        "--no-header",
        action="store_true",
        help="Write the CSV without a header row.",
    )
    return parser


def load_env_file(path: Path) -> None:
    if not path.exists():
        return

    for raw_line in path.read_text().splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue

        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip("'").strip('"')
        os.environ.setdefault(key, value)


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    load_env_file(args.env_file)

    config = ReportConfig(
        snowflake=SnowflakeConfig.from_env(),
        as_of_date=args.as_of_date,
        csv_output_path=args.output,
        csv_overwrite=args.overwrite,
        csv_delimiter=args.delimiter,
        csv_include_header=not args.no_header,
    )

    _, output_path = run_report_to_csv(config)
    print(output_path)
    return 0
