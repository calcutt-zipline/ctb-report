from __future__ import annotations

from dataclasses import asdict
from typing import Any

import pandas as pd

from ctb_report.config.models import SnowflakeConfig


class SnowflakeClient:
    def __init__(self, config: SnowflakeConfig) -> None:
        self.config = config
        self._connection = None

    def connect(self) -> Any:
        if self._connection is None:
            import snowflake.connector

            connect_kwargs = {k: v for k, v in asdict(self.config).items() if v is not None}
            # Prefer explicit account/user auth when provided; otherwise fall back to a named connection.
            if self.config.connection_name and not (self.config.account and self.config.user):
                connect_kwargs.pop("account", None)
                connect_kwargs.pop("user", None)
                connect_kwargs.pop("password", None)
            self._connection = snowflake.connector.connect(**connect_kwargs)
        return self._connection

    def query(self, sql: str) -> pd.DataFrame:
        connection = self.connect()
        return pd.read_sql(sql, connection)

    def close(self) -> None:
        if self._connection is not None:
            self._connection.close()
            self._connection = None
