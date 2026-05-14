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
    "Current Receiving & Pre-IQC Quantity",
    "Current Quarantine Quantity",
    "Current Week Realized Supply",
    "Total Supply Plan, next 8 weeks",
    "Average Supply Plan, next 8 weeks",
]

ALTERNATE_SUFFIX = " with alternates"
ROLLUP_COLUMN = "total rolled up quantity"
PRODUCT_SETS_COLUMN = "on hand product sets including alternates"
RECEIVING_PRE_IQC_QUANTITY_COLUMN = "Current Receiving & Pre-IQC Quantity"
RECEIVING_PRE_IQC_PRODUCT_SETS_COLUMN = "receiving & pre-iqc product sets"
PARENT_ON_HAND_COLUMN = "On Hand Quantity In Parents"
COMBINED_ON_HAND_COLUMN = "Current On Hand Quantity Including alternates and parents"
COMBINED_PRODUCT_SETS_COLUMN = "on hand product sets including alternates and parents"
ON_HAND_IN_TRANSIT_PRODUCT_SETS_COLUMN = "on hand + in transit product sets"
CURRENT_WEEK_NET_DEMAND_COLUMN = "Current Week Net Demand"
CURRENT_WEEK_NET_TOTAL_DEMAND_COLUMN = "Current Week Net Total Demand"
ZERO_FILL_COLUMNS = [
    "Gross Demand for BOM Line in past 8 weeks",
    "Net Total Demand for Part Number in past 8 weeks",
    "Current Week Total Gross Demand",
    CURRENT_WEEK_NET_DEMAND_COLUMN,
    CURRENT_WEEK_NET_TOTAL_DEMAND_COLUMN,
    "Current Week Realized Demand Consumption (each)",
    "Gross Demand for BOM Line in next 8 weeks",
    "Net Total Demand for Part Number in next 8 weeks",
    "Quantity Received, 8-Week Rolling Average (each)",
    "Quantity Received, Average Since Last Receipt (each)",
    "Current On-Hand Quantity (each)",
    "Current Receiving & Pre-IQC Quantity (each)",
    PARENT_ON_HAND_COLUMN,
    COMBINED_ON_HAND_COLUMN,
    "in-transit quantity",
    "On Hand Delta to Current Week Demand (each)",
    "Current Quarantine Quantity (each)",
    "Current Week Realized Supply (each)",
    "Total Supply Plan, next 8 weeks (each)",
    "Average Supply Plan, next 8 weeks (each)",
    "Quantity Received, 8-Week Rolling Average (each) with alternates",
    "Quantity Received, Average Since Last Receipt (each) with alternates",
    "Current On-Hand Quantity (each) with alternates",
    "Current Receiving & Pre-IQC Quantity (each) with alternates",
    "Weeks of Stock",
    "Weeks of Stock with In Transit",
    "in transit weeks of stock",
    "In Transit Weeks of Stock Of System's Minimum Weeks of Stock Part",
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

        df = self._add_on_hand_quantity_in_parents(df)
        df = self._add_on_hand_product_sets(df)
        df = self._add_receiving_pre_iqc_product_sets(df)
        df = self._add_current_on_hand_including_alternates_and_parents(df)
        df = self._add_on_hand_product_sets_including_alternates_and_parents(df)
        df = self._add_on_hand_plus_in_transit_product_sets(df)
        if (
            CURRENT_WEEK_NET_DEMAND_COLUMN not in df.columns
            and CURRENT_WEEK_NET_TOTAL_DEMAND_COLUMN in df.columns
        ):
            df[CURRENT_WEEK_NET_DEMAND_COLUMN] = df[CURRENT_WEEK_NET_TOTAL_DEMAND_COLUMN]

        for column in FINAL_COLUMN_ORDER:
            if column not in df.columns:
                df[column] = None

        for column in ZERO_FILL_COLUMNS:
            if column in df.columns:
                df[column] = pd.to_numeric(df[column], errors="coerce").fillna(0)

        if ROLLUP_COLUMN in df.columns:
            df[ROLLUP_COLUMN] = pd.to_numeric(df[ROLLUP_COLUMN], errors="coerce").astype("float64")
        if PRODUCT_SETS_COLUMN in df.columns:
            df[PRODUCT_SETS_COLUMN] = pd.to_numeric(df[PRODUCT_SETS_COLUMN], errors="coerce").astype("float64")
        if RECEIVING_PRE_IQC_PRODUCT_SETS_COLUMN in df.columns:
            df[RECEIVING_PRE_IQC_PRODUCT_SETS_COLUMN] = pd.to_numeric(
                df[RECEIVING_PRE_IQC_PRODUCT_SETS_COLUMN], errors="coerce"
            ).astype("float64")
        if PARENT_ON_HAND_COLUMN in df.columns:
            df[PARENT_ON_HAND_COLUMN] = (
                pd.to_numeric(df[PARENT_ON_HAND_COLUMN], errors="coerce").fillna(0).astype("float64")
            )
        if COMBINED_ON_HAND_COLUMN in df.columns:
            df[COMBINED_ON_HAND_COLUMN] = (
                pd.to_numeric(df[COMBINED_ON_HAND_COLUMN], errors="coerce").fillna(0).astype("float64")
            )
        if COMBINED_PRODUCT_SETS_COLUMN in df.columns:
            df[COMBINED_PRODUCT_SETS_COLUMN] = pd.to_numeric(
                df[COMBINED_PRODUCT_SETS_COLUMN], errors="coerce"
            ).astype("float64")
        if ON_HAND_IN_TRANSIT_PRODUCT_SETS_COLUMN in df.columns:
            df[ON_HAND_IN_TRANSIT_PRODUCT_SETS_COLUMN] = pd.to_numeric(
                df[ON_HAND_IN_TRANSIT_PRODUCT_SETS_COLUMN], errors="coerce"
            ).astype("float64")

        df = df.loc[:, FINAL_COLUMN_ORDER]
        return df

    def _add_total_rollup_quantity(self, df: pd.DataFrame) -> pd.DataFrame:
        if ROLLUP_COLUMN in df.columns:
            df[ROLLUP_COLUMN] = pd.to_numeric(df[ROLLUP_COLUMN], errors="coerce").astype("float64")
            return df

        required_columns = {
            "PART_NUMBER",
            "TOP_LEVEL_BOM",
            "ADJUSTED_QUANTITY",
            "ADJUSTED_PROCUREMENT_INTENT",
        }
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
                "ADJUSTED_PROCUREMENT_INTENT": df["ADJUSTED_PROCUREMENT_INTENT"],
            }
        ).dropna(subset=["PART_NUMBER", "TOP_LEVEL_BOM"])
        rollup_input = rollup_input[rollup_input["ADJUSTED_PROCUREMENT_INTENT"].eq("zipline_buy")]

        if rollup_input.empty:
            return df

        demanded_top_levels = self._demanded_top_level_boms(df)
        if demanded_top_levels.empty:
            return df

        rollup_input = rollup_input.merge(
            demanded_top_levels,
            on=["TOP_LEVEL_BOM", "TOP_LEVEL_REVISION"],
            how="inner",
        )

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
            .max()
            .reset_index()
        )
        part_totals = part_totals.rename(columns={"ADJUSTED_QUANTITY": ROLLUP_COLUMN})

        return df.merge(part_totals[["PART_NUMBER", ROLLUP_COLUMN]], on="PART_NUMBER", how="left")

    def _add_on_hand_quantity_in_parents(self, df: pd.DataFrame) -> pd.DataFrame:
        if PARENT_ON_HAND_COLUMN in df.columns:
            df[PARENT_ON_HAND_COLUMN] = pd.to_numeric(df[PARENT_ON_HAND_COLUMN], errors="coerce").fillna(0)
            return df

        parent_metrics = self._parent_inventory_metrics(df)
        if parent_metrics.empty:
            return df

        df[PARENT_ON_HAND_COLUMN] = parent_metrics["ON_HAND_QUANTITY_IN_PARENTS"].fillna(0)
        return df

    def _add_on_hand_product_sets(self, df: pd.DataFrame) -> pd.DataFrame:
        if PRODUCT_SETS_COLUMN in df.columns:
            df[PRODUCT_SETS_COLUMN] = pd.to_numeric(df[PRODUCT_SETS_COLUMN], errors="coerce").astype("float64")
            return df

        if ROLLUP_COLUMN not in df.columns:
            return df

        on_hand_column = f"Current On-Hand Quantity (each){ALTERNATE_SUFFIX}"
        if on_hand_column not in df.columns:
            return df

        rollup_quantity = pd.to_numeric(df[ROLLUP_COLUMN], errors="coerce")
        on_hand_quantity = pd.to_numeric(df[on_hand_column], errors="coerce").fillna(0)
        valid_rollup = rollup_quantity.notna() & rollup_quantity.ne(0)

        df[PRODUCT_SETS_COLUMN] = pd.Series(pd.NA, index=df.index, dtype="Float64")
        df.loc[valid_rollup, PRODUCT_SETS_COLUMN] = (
            on_hand_quantity.loc[valid_rollup] / rollup_quantity.loc[valid_rollup]
        )
        df[PRODUCT_SETS_COLUMN] = pd.to_numeric(df[PRODUCT_SETS_COLUMN], errors="coerce")
        return df

    def _add_receiving_pre_iqc_product_sets(self, df: pd.DataFrame) -> pd.DataFrame:
        if RECEIVING_PRE_IQC_PRODUCT_SETS_COLUMN in df.columns:
            df[RECEIVING_PRE_IQC_PRODUCT_SETS_COLUMN] = pd.to_numeric(
                df[RECEIVING_PRE_IQC_PRODUCT_SETS_COLUMN], errors="coerce"
            ).astype("float64")
            return df

        if ROLLUP_COLUMN not in df.columns:
            return df

        receiving_pre_iqc_column = f"{RECEIVING_PRE_IQC_QUANTITY_COLUMN} (each){ALTERNATE_SUFFIX}"
        if receiving_pre_iqc_column not in df.columns:
            return df

        rollup_quantity = pd.to_numeric(df[ROLLUP_COLUMN], errors="coerce")
        receiving_pre_iqc_quantity = pd.to_numeric(df[receiving_pre_iqc_column], errors="coerce").fillna(0)
        valid_rollup = rollup_quantity.notna() & rollup_quantity.ne(0)

        df[RECEIVING_PRE_IQC_PRODUCT_SETS_COLUMN] = pd.Series(pd.NA, index=df.index, dtype="Float64")
        df.loc[valid_rollup, RECEIVING_PRE_IQC_PRODUCT_SETS_COLUMN] = (
            receiving_pre_iqc_quantity.loc[valid_rollup] / rollup_quantity.loc[valid_rollup]
        )
        df[RECEIVING_PRE_IQC_PRODUCT_SETS_COLUMN] = pd.to_numeric(
            df[RECEIVING_PRE_IQC_PRODUCT_SETS_COLUMN], errors="coerce"
        )
        return df

    def _add_current_on_hand_including_alternates_and_parents(self, df: pd.DataFrame) -> pd.DataFrame:
        if COMBINED_ON_HAND_COLUMN in df.columns:
            df[COMBINED_ON_HAND_COLUMN] = pd.to_numeric(df[COMBINED_ON_HAND_COLUMN], errors="coerce").fillna(0)
            return df

        on_hand_with_alternates_column = f"Current On-Hand Quantity (each){ALTERNATE_SUFFIX}"
        if on_hand_with_alternates_column not in df.columns or PARENT_ON_HAND_COLUMN not in df.columns:
            return df

        on_hand_with_alternates = pd.to_numeric(df[on_hand_with_alternates_column], errors="coerce").fillna(0)
        on_hand_in_parents = pd.to_numeric(df[PARENT_ON_HAND_COLUMN], errors="coerce").fillna(0)
        df[COMBINED_ON_HAND_COLUMN] = on_hand_with_alternates + on_hand_in_parents
        return df

    def _add_on_hand_product_sets_including_alternates_and_parents(self, df: pd.DataFrame) -> pd.DataFrame:
        if COMBINED_PRODUCT_SETS_COLUMN in df.columns:
            df[COMBINED_PRODUCT_SETS_COLUMN] = pd.to_numeric(
                df[COMBINED_PRODUCT_SETS_COLUMN], errors="coerce"
            ).astype("float64")
            return df

        own_product_sets = (
            pd.to_numeric(df[PRODUCT_SETS_COLUMN], errors="coerce")
            if PRODUCT_SETS_COLUMN in df.columns
            else pd.Series(pd.NA, index=df.index, dtype="Float64")
        )
        parent_product_sets = self._parent_product_sets(df)

        valid_own_sets = own_product_sets.notna()
        valid_parent_sets = parent_product_sets.notna()
        valid_combined_sets = valid_own_sets | valid_parent_sets

        df[COMBINED_PRODUCT_SETS_COLUMN] = pd.Series(pd.NA, index=df.index, dtype="Float64")
        df.loc[valid_combined_sets, COMBINED_PRODUCT_SETS_COLUMN] = (
            own_product_sets.fillna(0).loc[valid_combined_sets]
            + parent_product_sets.fillna(0).loc[valid_combined_sets]
        )
        df[COMBINED_PRODUCT_SETS_COLUMN] = pd.to_numeric(df[COMBINED_PRODUCT_SETS_COLUMN], errors="coerce")
        return df

    def _add_on_hand_plus_in_transit_product_sets(self, df: pd.DataFrame) -> pd.DataFrame:
        if ON_HAND_IN_TRANSIT_PRODUCT_SETS_COLUMN in df.columns:
            df[ON_HAND_IN_TRANSIT_PRODUCT_SETS_COLUMN] = pd.to_numeric(
                df[ON_HAND_IN_TRANSIT_PRODUCT_SETS_COLUMN], errors="coerce"
            ).astype("float64")
            return df

        if ROLLUP_COLUMN not in df.columns:
            return df

        on_hand_column = f"Current On-Hand Quantity (each){ALTERNATE_SUFFIX}"
        has_on_hand = on_hand_column in df.columns
        has_in_transit = "in-transit quantity" in df.columns
        if not has_on_hand and not has_in_transit:
            return df

        rollup_quantity = pd.to_numeric(df[ROLLUP_COLUMN], errors="coerce")
        on_hand_quantity = (
            pd.to_numeric(df[on_hand_column], errors="coerce").fillna(0)
            if has_on_hand
            else pd.Series(0.0, index=df.index)
        )
        in_transit_quantity = (
            pd.to_numeric(df["in-transit quantity"], errors="coerce").fillna(0)
            if has_in_transit
            else pd.Series(0.0, index=df.index)
        )
        valid_rollup = rollup_quantity.notna() & rollup_quantity.ne(0)

        direct_product_sets = pd.Series(pd.NA, index=df.index, dtype="Float64")
        direct_product_sets.loc[valid_rollup] = (
            (on_hand_quantity.loc[valid_rollup] + in_transit_quantity.loc[valid_rollup])
            / rollup_quantity.loc[valid_rollup]
        )
        parent_product_sets = self._parent_product_sets(df)

        valid_direct_sets = direct_product_sets.notna()
        valid_parent_sets = parent_product_sets.notna()
        valid_combined_sets = valid_direct_sets | valid_parent_sets

        df[ON_HAND_IN_TRANSIT_PRODUCT_SETS_COLUMN] = pd.Series(pd.NA, index=df.index, dtype="Float64")
        df.loc[valid_combined_sets, ON_HAND_IN_TRANSIT_PRODUCT_SETS_COLUMN] = (
            direct_product_sets.fillna(0).loc[valid_combined_sets]
            + parent_product_sets.fillna(0).loc[valid_combined_sets]
        )
        df[ON_HAND_IN_TRANSIT_PRODUCT_SETS_COLUMN] = pd.to_numeric(
            df[ON_HAND_IN_TRANSIT_PRODUCT_SETS_COLUMN], errors="coerce"
        )
        return df

    def _parent_product_sets(self, df: pd.DataFrame) -> pd.Series:
        parent_sets = pd.Series(pd.NA, index=df.index, dtype="Float64")
        parent_metrics = self._parent_inventory_metrics(df)
        if parent_metrics.empty:
            return parent_sets

        valid_parent_sets = parent_metrics["VALID_PARENT_PRODUCT_SET_COUNT"].fillna(0).gt(0)
        parent_sets.loc[valid_parent_sets] = parent_metrics.loc[
            valid_parent_sets,
            "ON_HAND_PRODUCT_SETS_IN_PARENTS",
        ]
        return parent_sets

    def _parent_inventory_metrics(self, df: pd.DataFrame) -> pd.DataFrame:
        empty_metrics = pd.DataFrame(
            {
                "ON_HAND_QUANTITY_IN_PARENTS": pd.Series(0.0, index=df.index, dtype="float64"),
                "ON_HAND_PRODUCT_SETS_IN_PARENTS": pd.Series(0.0, index=df.index, dtype="float64"),
                "VALID_PARENT_PRODUCT_SET_COUNT": pd.Series(0, index=df.index, dtype="int64"),
            }
        )
        required_columns = {
            "PATH_WITHOUT_REVISION",
            "PART_NUMBER",
            "TOP_LEVEL_BOM",
            "ADJUSTED_QUANTITY",
        }
        on_hand_column = "Current On-Hand Quantity (each)"
        if on_hand_column not in df.columns:
            on_hand_column = "Current On-Hand Quantity"
        required_columns.add(on_hand_column)
        if not required_columns.issubset(df.columns):
            return empty_metrics

        top_level_revision = (
            df["TOP_LEVEL_REVISION"].fillna("")
            if "TOP_LEVEL_REVISION" in df.columns
            else pd.Series("", index=df.index)
        )
        non_top_level_assemblies = self._non_top_level_assemblies(df)
        if not non_top_level_assemblies:
            return empty_metrics

        child_rows = pd.DataFrame(
            {
                "_row_index": df.index,
                "PATH_WITHOUT_REVISION": df["PATH_WITHOUT_REVISION"],
                "TOP_LEVEL_BOM": df["TOP_LEVEL_BOM"],
                "TOP_LEVEL_REVISION": top_level_revision,
                "CHILD_ADJUSTED_QUANTITY": pd.to_numeric(
                    df["ADJUSTED_QUANTITY"], errors="coerce"
                ).fillna(0),
            }
        ).dropna(subset=["PATH_WITHOUT_REVISION", "TOP_LEVEL_BOM"])
        ancestor_rows = pd.DataFrame(
            {
                "ANCESTOR_PATH_WITHOUT_REVISION": df["PATH_WITHOUT_REVISION"],
                "PARENT_PART_NUMBER": df["PART_NUMBER"],
                "TOP_LEVEL_BOM": df["TOP_LEVEL_BOM"],
                "TOP_LEVEL_REVISION": top_level_revision,
                "PARENT_ADJUSTED_QUANTITY": pd.to_numeric(
                    df["ADJUSTED_QUANTITY"], errors="coerce"
                ).fillna(0),
                "PARENT_ON_HAND_QUANTITY": pd.to_numeric(df[on_hand_column], errors="coerce").fillna(0),
            }
        ).dropna(subset=["ANCESTOR_PATH_WITHOUT_REVISION", "PARENT_PART_NUMBER", "TOP_LEVEL_BOM"])
        ancestor_rows = ancestor_rows[ancestor_rows["PARENT_PART_NUMBER"].isin(non_top_level_assemblies)]

        if child_rows.empty or ancestor_rows.empty:
            return empty_metrics

        parent_usage = child_rows.merge(
            ancestor_rows,
            on=["TOP_LEVEL_BOM", "TOP_LEVEL_REVISION"],
            how="inner",
        )
        ancestor_match = [
            child_path != ancestor_path and str(child_path).startswith(str(ancestor_path))
            for child_path, ancestor_path in zip(
                parent_usage["PATH_WITHOUT_REVISION"],
                parent_usage["ANCESTOR_PATH_WITHOUT_REVISION"],
                strict=False,
            )
        ]
        parent_usage = parent_usage.loc[ancestor_match].copy()
        if parent_usage.empty:
            return empty_metrics

        parent_usage["CHILD_QUANTITY_IN_PARENT"] = (
            parent_usage["CHILD_ADJUSTED_QUANTITY"]
            / parent_usage["PARENT_ADJUSTED_QUANTITY"].replace(0, pd.NA)
        )
        parent_usage["ON_HAND_QUANTITY_IN_PARENT"] = (
            parent_usage["PARENT_ON_HAND_QUANTITY"]
            * parent_usage["CHILD_QUANTITY_IN_PARENT"].fillna(0)
        )

        parent_rollup = self._parent_top_level_rollup(df)
        if parent_rollup.empty:
            parent_usage["PARENT_ROLLED_UP_QUANTITY"] = pd.NA
        else:
            parent_usage = parent_usage.merge(
                parent_rollup,
                on=["PARENT_PART_NUMBER", "TOP_LEVEL_BOM", "TOP_LEVEL_REVISION"],
                how="left",
            )

        valid_parent_sets = (
            parent_usage["PARENT_ROLLED_UP_QUANTITY"].notna()
            & parent_usage["PARENT_ROLLED_UP_QUANTITY"].ne(0)
        )
        parent_usage["ON_HAND_PRODUCT_SETS_IN_PARENT"] = 0.0
        parent_usage.loc[valid_parent_sets, "ON_HAND_PRODUCT_SETS_IN_PARENT"] = (
            parent_usage.loc[valid_parent_sets, "PARENT_ON_HAND_QUANTITY"]
            / parent_usage.loc[valid_parent_sets, "PARENT_ROLLED_UP_QUANTITY"]
        )
        parent_usage["VALID_PARENT_PRODUCT_SET_COUNT"] = valid_parent_sets.astype(int)

        parent_metrics = (
            parent_usage.groupby("_row_index")
            .agg(
                ON_HAND_QUANTITY_IN_PARENTS=("ON_HAND_QUANTITY_IN_PARENT", "sum"),
                ON_HAND_PRODUCT_SETS_IN_PARENTS=("ON_HAND_PRODUCT_SETS_IN_PARENT", "sum"),
                VALID_PARENT_PRODUCT_SET_COUNT=("VALID_PARENT_PRODUCT_SET_COUNT", "sum"),
            )
            .reindex(df.index)
        )

        parent_metrics["ON_HAND_QUANTITY_IN_PARENTS"] = parent_metrics[
            "ON_HAND_QUANTITY_IN_PARENTS"
        ].fillna(0)
        parent_metrics["ON_HAND_PRODUCT_SETS_IN_PARENTS"] = parent_metrics[
            "ON_HAND_PRODUCT_SETS_IN_PARENTS"
        ].fillna(0)
        parent_metrics["VALID_PARENT_PRODUCT_SET_COUNT"] = parent_metrics[
            "VALID_PARENT_PRODUCT_SET_COUNT"
        ].fillna(0)
        return parent_metrics

    def _parent_top_level_rollup(self, df: pd.DataFrame) -> pd.DataFrame:
        required_columns = {"PART_NUMBER", "TOP_LEVEL_BOM", "ADJUSTED_QUANTITY"}
        if not required_columns.issubset(df.columns):
            return pd.DataFrame(
                columns=[
                    "PARENT_PART_NUMBER",
                    "TOP_LEVEL_BOM",
                    "TOP_LEVEL_REVISION",
                    "PARENT_ROLLED_UP_QUANTITY",
                ]
            )

        top_level_revision = (
            df["TOP_LEVEL_REVISION"].fillna("")
            if "TOP_LEVEL_REVISION" in df.columns
            else pd.Series("", index=df.index)
        )
        rollup_input = pd.DataFrame(
            {
                "PARENT_PART_NUMBER": df["PART_NUMBER"],
                "TOP_LEVEL_BOM": df["TOP_LEVEL_BOM"],
                "TOP_LEVEL_REVISION": top_level_revision,
                "ADJUSTED_QUANTITY": pd.to_numeric(df["ADJUSTED_QUANTITY"], errors="coerce").fillna(0),
            }
        ).dropna(subset=["PARENT_PART_NUMBER", "TOP_LEVEL_BOM"])

        non_top_level_assemblies = self._non_top_level_assemblies(df)
        rollup_input = rollup_input[rollup_input["PARENT_PART_NUMBER"].isin(non_top_level_assemblies)]
        if rollup_input.empty:
            return rollup_input.rename(columns={"ADJUSTED_QUANTITY": "PARENT_ROLLED_UP_QUANTITY"})

        demanded_top_levels = self._demanded_top_level_boms(df)
        if demanded_top_levels.empty:
            return pd.DataFrame(
                columns=[
                    "PARENT_PART_NUMBER",
                    "TOP_LEVEL_BOM",
                    "TOP_LEVEL_REVISION",
                    "PARENT_ROLLED_UP_QUANTITY",
                ]
            )

        rollup_input = rollup_input.merge(
            demanded_top_levels,
            on=["TOP_LEVEL_BOM", "TOP_LEVEL_REVISION"],
            how="inner",
        )
        if rollup_input.empty:
            return rollup_input.rename(columns={"ADJUSTED_QUANTITY": "PARENT_ROLLED_UP_QUANTITY"})

        return (
            rollup_input.groupby(
                ["PARENT_PART_NUMBER", "TOP_LEVEL_BOM", "TOP_LEVEL_REVISION"],
                dropna=False,
            )["ADJUSTED_QUANTITY"]
            .sum()
            .reset_index()
            .rename(columns={"ADJUSTED_QUANTITY": "PARENT_ROLLED_UP_QUANTITY"})
        )

    @staticmethod
    def _non_top_level_assemblies(df: pd.DataFrame) -> set:
        if "PART_NUMBER" not in df.columns:
            return set()

        child_mask = pd.Series(False, index=df.index)
        if "PARENT_BOM" in df.columns:
            child_mask |= df["PARENT_BOM"].fillna("").astype(str).str.strip().ne("")
        if "INDENT_LEVEL" in df.columns:
            child_mask |= pd.to_numeric(df["INDENT_LEVEL"], errors="coerce").fillna(0).gt(0)

        return set(df.loc[child_mask, "PART_NUMBER"].dropna())

    @staticmethod
    def _demanded_top_level_boms(df: pd.DataFrame) -> pd.DataFrame:
        top_level_revision = (
            df["TOP_LEVEL_REVISION"].fillna("")
            if "TOP_LEVEL_REVISION" in df.columns
            else pd.Series("", index=df.index)
        )
        demanded_top_levels = pd.DataFrame(
            {
                "TOP_LEVEL_BOM": df["TOP_LEVEL_BOM"],
                "TOP_LEVEL_REVISION": top_level_revision,
            }
        ).dropna(subset=["TOP_LEVEL_BOM"])

        if demanded_top_levels.empty:
            return demanded_top_levels.drop_duplicates()

        child_part_numbers = BomCapacityReportService._non_top_level_assemblies(df)
        if child_part_numbers:
            demanded_top_levels = demanded_top_levels[
                ~demanded_top_levels["TOP_LEVEL_BOM"].isin(child_part_numbers)
            ]

        return demanded_top_levels.drop_duplicates()
