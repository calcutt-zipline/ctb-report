from __future__ import annotations

from dataclasses import dataclass, field
from datetime import date
from pathlib import Path
from typing import Optional
import os
import re


def _env_bool(name: str, default: bool = False) -> bool:
    value = os.environ.get(name)
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "y", "on"}


def _default_snowflake_connection_name() -> Optional[str]:
    for path in (Path.home() / ".snowflake" / "connections.toml", Path.home() / ".snowflake" / "config.toml"):
        if not path.exists():
            continue

        match = re.search(
            r"(?m)^\s*default_connection_name\s*=\s*[\"']?([^\"'\s#]+)",
            path.read_text(),
        )
        if match:
            return match.group(1)

    return None


@dataclass(frozen=True)
class SnowflakeConfig:
    account: Optional[str] = None
    user: Optional[str] = None
    password: Optional[str] = None
    connection_name: Optional[str] = None
    authenticator: str = "externalbrowser"
    warehouse: Optional[str] = None
    database: Optional[str] = None
    schema: Optional[str] = None
    role: Optional[str] = None
    client_store_temporary_credential: bool = False

    @classmethod
    def from_env(cls) -> "SnowflakeConfig":
        connection_name = os.environ.get("SNOWFLAKE_CONNECTION_NAME") or _default_snowflake_connection_name()
        user = os.environ.get("SNOWFLAKE_USER")
        account = os.environ.get("SNOWFLAKE_ACCOUNT")

        if not (account and user) and not connection_name:
            raise ValueError(
                "Missing Snowflake credentials. Set SNOWFLAKE_CONNECTION_NAME, configure a default "
                "Snowflake connection, or set both SNOWFLAKE_ACCOUNT and SNOWFLAKE_USER."
            )

        return cls(
            account=account,
            user=user,
            password=os.environ.get("SNOWFLAKE_PASSWORD"),
            connection_name=connection_name,
            authenticator=os.environ.get("SNOWFLAKE_AUTHENTICATOR", "externalbrowser"),
            warehouse=os.environ.get("SNOWFLAKE_WAREHOUSE"),
            database=os.environ.get("SNOWFLAKE_DATABASE"),
            schema=os.environ.get("SNOWFLAKE_SCHEMA"),
            role=os.environ.get("SNOWFLAKE_ROLE"),
            client_store_temporary_credential=_env_bool(
                "SNOWFLAKE_CLIENT_STORE_TEMPORARY_CREDENTIAL",
                False,
            ),
        )


@dataclass(frozen=True)
class RelationsConfig:
    bom_hierarchy: str = "BIZ.DBT.DIM_BOM_HIERARCHY"
    capacity_demand: str = "fivetran_google_sheets.supply_chain_capacity_demand_by_part_number"
    structured_bom_data: str = "fivetran_google_sheets.supply_chain_structured_bom_data"
    flat_parts_list: str = "fivetran_google_sheets.supply_chain_flat_parts_list"
    alternate_part_numbers: str = "fivetran_google_sheets.supply_chain_alternate_part_numbers"
    alternate_part_numbers_column: str = '"PART_NUMBERS"'
    supply_plans: str = "fivetran_google_sheets.supply_chain_supply_plans"
    stock_move: str = "BIZ.DBT_STG.STG_ODOO_PROD__STOCK_MOVE"
    product_product: str = "BIZ.DBT_STG.STG_ODOO_PROD__PRODUCT_PRODUCT"
    product_template: str = "BIZ.DBT_STG.STG_ODOO_PROD__PRODUCT_TEMPLATE"
    stock_location: str = "BIZ.DBT_STG.STG_ODOO_PROD__STOCK_LOCATION"
    inventory: str = "BIZ.DBT_ODOO.INVENTORY"
    shipments: str = "BIZ.DBT_ODOO.SHIPMENTS"
    shipment_lines: str = "BIZ.DBT_ODOO.SHIPMENT_PACKING_LIST"


@dataclass(frozen=True)
class InventoryConfig:
    part_number_column: str = "DEFAULT_CODE"
    quantity_column: str = "QUANTITY"
    location_id_column: str = "STOCK_LOCATION_ID"


@dataclass(frozen=True)
class SupplyPlanConfig:
    part_number_column: str = "PART_NUMBER"
    quantity_column: str = "QUANTITY"
    date_column: str = "DATE"


@dataclass(frozen=True)
class ShipmentLineConfig:
    part_number_column: str = "DEFAULT_CODE"
    quantity_column: str = "QUANTITY_IN_SHIPMENT"
    status_column: str = "STATE"


@dataclass(frozen=True)
class ReportConfig:
    snowflake: SnowflakeConfig
    relations: RelationsConfig = field(default_factory=RelationsConfig)
    inventory: InventoryConfig = field(default_factory=InventoryConfig)
    supply_plan: SupplyPlanConfig = field(default_factory=SupplyPlanConfig)
    shipment_line: ShipmentLineConfig = field(default_factory=ShipmentLineConfig)
    as_of_date: date = field(default_factory=date.today)
    timezone: str = "America/Los_Angeles"
    path_revision_pattern: str = r"\|[A-Za-z][A-Za-z0-9]{0,2}\|"
    csv_output_path: Optional[Path] = None
    csv_delimiter: str = ","
    csv_include_header: bool = True
    csv_overwrite: bool = False

    def resolved_output_path(self) -> Path:
        if self.csv_output_path:
            return self.csv_output_path
        return Path(f"bom_capacity_report_{self.as_of_date.strftime('%Y%m%d')}.csv")
