from __future__ import annotations

import argparse
import sys
from pathlib import Path

import pandas as pd

from ctb_report.config.models import ReportConfig, SnowflakeConfig
from ctb_report.data_access.snowflake import SnowflakeClient


def _read_sql_inputs(files: list[Path], inline_sql: list[str]) -> list[tuple[str, str]]:
    statements = [(str(path), path.read_text().strip().rstrip(";")) for path in files]
    statements.extend((f"--sql #{index}", sql.strip().rstrip(";")) for index, sql in enumerate(inline_sql, 1))
    return [(label, sql) for label, sql in statements if sql]


def _format_dataframe(df: pd.DataFrame, output_format: str) -> str:
    if output_format == "csv":
        return df.to_csv(index=False).rstrip("\n")
    if output_format == "json":
        return df.to_json(orient="records")
    return df.to_string(index=False)


def run_sql_files(
    config: SnowflakeConfig,
    statements: list[tuple[str, str]],
    *,
    output_format: str = "table",
) -> int:
    client = SnowflakeClient(config)
    try:
        connection = client.connect()
        cursor = connection.cursor()
        try:
            for index, (label, sql) in enumerate(statements, 1):
                cursor.execute(sql)
                if cursor.description is None:
                    continue

                df = cursor.fetch_pandas_all()
                if len(statements) > 1:
                    print(f"-- {index}: {label}")
                print(_format_dataframe(df, output_format))
        finally:
            cursor.close()
    finally:
        client.close()
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Run one or more Snowflake SQL files using a single connection. "
            "Temporary credential caching is disabled by default, so this avoids "
            "macOS Keychain/Apple Passwords while still batching work behind one login."
        )
    )
    parser.add_argument("--file", "-f", action="append", type=Path, default=[], help="SQL file to execute.")
    parser.add_argument("--sql", action="append", default=[], help="Inline SQL to execute.")
    parser.add_argument(
        "--output-format",
        choices=["table", "csv", "json"],
        default="table",
        help="Result rendering format.",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    statements = _read_sql_inputs(args.file, args.sql)
    if not statements:
        parser.error("Provide at least one --file or --sql argument.")

    config = ReportConfig(snowflake=SnowflakeConfig.from_env()).snowflake
    return run_sql_files(config, statements, output_format=args.output_format)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
