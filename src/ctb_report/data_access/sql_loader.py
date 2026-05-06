from __future__ import annotations

from pathlib import Path
from string import Template
from typing import Any


class SqlLoader:
    def __init__(self, sql_dir: Path | None = None) -> None:
        self.sql_dir = sql_dir or Path(__file__).resolve().parents[3] / "sql"

    def load(self, name: str) -> str:
        return (self.sql_dir / f"{name}.sql").read_text()

    def render(self, name: str, **params: Any) -> str:
        template = Template(self.load(name))
        return template.safe_substitute(**params)
