from __future__ import annotations

import pandas as pd

from ctb_report.config.models import ReportConfig
from ctb_report.data_access.snowflake import SnowflakeClient
from ctb_report.data_access.sql_loader import SqlLoader


class ReportRepository:
    def __init__(self, client: SnowflakeClient, sql_loader: SqlLoader | None = None) -> None:
        self.client = client
        self.sql_loader = sql_loader or SqlLoader()

    def fetch_report(self, config: ReportConfig) -> pd.DataFrame:
        sql = self.sql_loader.render(
            "final_report",
            as_of_date=config.as_of_date.isoformat(),
            path_revision_pattern=config.path_revision_pattern,
            bom_hierarchy=config.relations.bom_hierarchy,
            capacity_demand=config.relations.capacity_demand,
            structured_bom_data=config.relations.structured_bom_data,
            flat_parts_list=config.relations.flat_parts_list,
            alternate_part_numbers=config.relations.alternate_part_numbers,
            alternate_part_numbers_column=config.relations.alternate_part_numbers_column,
            supply_plans=config.relations.supply_plans,
            stock_move=config.relations.stock_move,
            product_product=config.relations.product_product,
            product_template=config.relations.product_template,
            stock_location=config.relations.stock_location,
            inventory=config.relations.inventory,
            inventory_part_number_column=config.inventory.part_number_column,
            inventory_quantity_column=config.inventory.quantity_column,
            inventory_location_id_column=config.inventory.location_id_column,
            supply_plan_part_number_column=config.supply_plan.part_number_column,
            supply_plan_quantity_column=config.supply_plan.quantity_column,
            supply_plan_date_column=config.supply_plan.date_column,
        )
        return self.client.query(sql)
