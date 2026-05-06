from __future__ import annotations

import pandas as pd

from ctb_report.config.models import ReportConfig
from ctb_report.data_access.repository import ReportRepository
from ctb_report.domain.models import FINAL_COLUMN_ORDER
from ctb_report.domain.pathing import normalize_path_without_revision

EACH_TO_SETS_COLUMNS = [
    "Current Week Realized Demand Consumption",
    "Quantity Received, 8-Week Rolling Average",
    "Quantity Received, Average Since Last Receipt",
    "Current On-Hand Quantity",
    "Current Quarantine Quantity",
    "Current Week Realized Supply",
    "Total Supply Plan, next 8 weeks",
    "Average Supply Plan, next 8 weeks",
]

ALTERNATE_SUFFIX = " with alternates"
ROLLUP_COLUMN = "total rolled up quantity"
PRODUCT_SETS_COLUMN = "on hand product sets including alternates"
MULTIPLE_ROLLUP_VALUE = "mutliple"
ZERO_FILL_COLUMNS = [
    "Gross Demand for BOM Line in past 8 weeks",
    "Net Total Demand for Part Number in past 8 weeks",
    "Current Week Realized Demand Consumption (each)",
    "Gross Demand for BOM Line in next 8 weeks",
    "Net Total Demand for Part Number in next 8 weeks",
    "Quantity Received, 8-Week Rolling Average (each)",
    "Quantity Received, Average Since Last Receipt (each)",
    "Current On-Hand Quantity (each)",
    "On Hand Delta to Current Week Demand (each)",
    "Current Quarantine Quantity (each)",
    "Current Week Realized Supply (each)",
    "Total Supply Plan, next 8 weeks (each)",
    "Average Supply Plan, next 8 weeks (each)",
    "Quantity Received, 8-Week Rolling Average (each) with alternates",
    "Quantity Received, Average Since Last Receipt (each) with alternates",
    "Current On-Hand Quantity (each) with alternates",
    "Current Quarantine Quantity (each) with alternates",
    "Current Week Realized Supply (each) with alternates",
    "Total Supply Plan, next 8 weeks (each) with alternates",
    "Average Supply Plan, next 8 weeks (each) with alternates",
]


class BomCapacityReportService:
    def __init__(self, repository: ReportRepository) -> None:
        self.repository = repository

    def run(self, config: ReportConfig) -> pd.DataFrame:
        df = self.repository.fetch_report(config)

        if "PATH_WITHOUT_REVISION" not in df.columns and "PATH" in df.columns:
            df["PATH_WITHOUT_REVISION"] = df["PATH"].map(
                lambda value: normalize_path_without_revision(value, config.path_revision_pattern)
            )

        df = self._add_total_rollup_quantity(df)

        for column in EACH_TO_SETS_COLUMNS:
            each_column = f"{column} (each)"
            source_series = pd.to_numeric(df.get(column), errors="coerce")
            df[each_column] = source_series
            if column in df.columns:
                df = df.drop(columns=[column])

            alternate_source = pd.to_numeric(df.get(f"{column}{ALTERNATE_SUFFIX}"), errors="coerce")
            alternate_each_column = f"{each_column}{ALTERNATE_SUFFIX}"
            df[alternate_each_column] = alternate_source
            if f"{column}{ALTERNATE_SUFFIX}" in df.columns:
                df = df.drop(columns=[f"{column}{ALTERNATE_SUFFIX}"])

        df = self._add_on_hand_product_sets(df)

        for column in FINAL_COLUMN_ORDER:
            if column not in df.columns:
                df[column] = None

        for column in ZERO_FILL_COLUMNS:
            if column in df.columns:
                df[column] = pd.to_numeric(df[column], errors="coerce").fillna(0)

        df = df.loc[:, FINAL_COLUMN_ORDER]
        return self._coerce_mixed_output_columns_to_string(df)

    def _add_total_rollup_quantity(self, df: pd.DataFrame) -> pd.DataFrame:
        if ROLLUP_COLUMN in df.columns:
            return df

        required_columns = {"PART_NUMBER", "TOP_LEVEL_BOM", "ADJUSTED_QUANTITY"}
        if not required_columns.issubset(df.columns):
            return df

        top_level_revision = (
            df["TOP_LEVEL_REVISION"].fillna("")
            if "TOP_LEVEL_REVISION" in df.columns
            else pd.Series("", index=df.index)
        )
        rollup_input = pd.DataFrame(
            {
                "PART_NUMBER": df["PART_NUMBER"],
                "TOP_LEVEL_BOM": df["TOP_LEVEL_BOM"],
                "TOP_LEVEL_REVISION": top_level_revision,
                "ADJUSTED_QUANTITY": pd.to_numeric(df["ADJUSTED_QUANTITY"], errors="coerce").fillna(0),
            }
        ).dropna(subset=["PART_NUMBER", "TOP_LEVEL_BOM"])

        if rollup_input.empty:
            return df

        top_level_totals = (
            rollup_input.groupby(["PART_NUMBER", "TOP_LEVEL_BOM", "TOP_LEVEL_REVISION"], dropna=False)[
                "ADJUSTED_QUANTITY"
            ]
            .sum()
            .reset_index()
        )
        part_totals = (
            top_level_totals.groupby("PART_NUMBER")["ADJUSTED_QUANTITY"]
            .agg(unique_total_count="nunique", rolled_up_quantity="max")
            .reset_index()
        )
        part_totals[ROLLUP_COLUMN] = part_totals.apply(
            lambda row: MULTIPLE_ROLLUP_VALUE
            if row["unique_total_count"] > 1
            else row["rolled_up_quantity"],
            axis=1,
        )

        return df.merge(part_totals[["PART_NUMBER", ROLLUP_COLUMN]], on="PART_NUMBER", how="left")

    def _add_on_hand_product_sets(self, df: pd.DataFrame) -> pd.DataFrame:
        if PRODUCT_SETS_COLUMN in df.columns or ROLLUP_COLUMN not in df.columns:
            return df

        on_hand_column = f"Current On-Hand Quantity (each){ALTERNATE_SUFFIX}"
        if on_hand_column not in df.columns:
            return df

        rollup_quantity = pd.to_numeric(df[ROLLUP_COLUMN], errors="coerce")
        on_hand_quantity = pd.to_numeric(df[on_hand_column], errors="coerce").fillna(0)
        valid_rollup = (
            df[ROLLUP_COLUMN].ne(MULTIPLE_ROLLUP_VALUE)
            & rollup_quantity.notna()
            & rollup_quantity.ne(0)
        )

        df[PRODUCT_SETS_COLUMN] = pd.Series(pd.NA, index=df.index, dtype="Float64")
        df.loc[valid_rollup, PRODUCT_SETS_COLUMN] = (
            on_hand_quantity.loc[valid_rollup] / rollup_quantity.loc[valid_rollup]
        )
        df[PRODUCT_SETS_COLUMN] = pd.to_numeric(df[PRODUCT_SETS_COLUMN], errors="coerce")
        return df

    def _coerce_mixed_output_columns_to_string(self, df: pd.DataFrame) -> pd.DataFrame:
        output_columns = []
        for position, column in enumerate(df.columns):
            series = df.iloc[:, position]
            if column == ROLLUP_COLUMN:
                series = series.map(self._format_mixed_string_value).astype("string")
            output_columns.append(series)

        coerced = pd.concat(output_columns, axis=1)
        coerced.columns = df.columns
        coerced.index = df.index
        return coerced

    @staticmethod
    def _format_mixed_string_value(value) -> str | None:
        if pd.isna(value):
            return None

        numeric_value = pd.to_numeric(value, errors="coerce")
        if pd.notna(numeric_value) and float(numeric_value).is_integer():
            return str(int(numeric_value))

        return str(value)
