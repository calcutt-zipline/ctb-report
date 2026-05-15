import os
import sys
import types

from ctb_report.config.models import SnowflakeConfig
from ctb_report.data_access.snowflake import SnowflakeClient


def test_snowflake_config_disables_temporary_credential_storage_by_default(monkeypatch) -> None:
    monkeypatch.setenv("SNOWFLAKE_ACCOUNT", "acct")
    monkeypatch.setenv("SNOWFLAKE_USER", "user")
    monkeypatch.delenv("SNOWFLAKE_CLIENT_STORE_TEMPORARY_CREDENTIAL", raising=False)

    config = SnowflakeConfig.from_env()

    assert config.client_store_temporary_credential is False


def test_snowflake_config_allows_explicit_temporary_credential_storage(monkeypatch) -> None:
    monkeypatch.setenv("SNOWFLAKE_ACCOUNT", "acct")
    monkeypatch.setenv("SNOWFLAKE_USER", "user")
    monkeypatch.setenv("SNOWFLAKE_CLIENT_STORE_TEMPORARY_CREDENTIAL", "true")

    config = SnowflakeConfig.from_env()

    assert config.client_store_temporary_credential is True


def test_snowflake_config_uses_default_connection_from_connections_toml(monkeypatch, tmp_path) -> None:
    snowflake_dir = tmp_path / ".snowflake"
    snowflake_dir.mkdir()
    (snowflake_dir / "connections.toml").write_text(
        'default_connection_name = "OYA50208"\n\n[OYA50208]\naccount = "acct"\nuser = "user"\n'
    )
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.delenv("SNOWFLAKE_ACCOUNT", raising=False)
    monkeypatch.delenv("SNOWFLAKE_USER", raising=False)
    monkeypatch.delenv("SNOWFLAKE_CONNECTION_NAME", raising=False)

    config = SnowflakeConfig.from_env()

    assert config.connection_name == "OYA50208"
    assert config.client_store_temporary_credential is False


def test_snowflake_client_passes_temporary_credential_setting(monkeypatch) -> None:
    captured_kwargs = {}

    class FakeConnector:
        @staticmethod
        def connect(**kwargs):
            captured_kwargs.update(kwargs)
            return object()

    fake_snowflake = types.SimpleNamespace(connector=FakeConnector)
    monkeypatch.setitem(sys.modules, "snowflake", fake_snowflake)
    monkeypatch.setitem(sys.modules, "snowflake.connector", FakeConnector)

    SnowflakeClient(SnowflakeConfig(account="acct", user="user")).connect()

    assert captured_kwargs["client_store_temporary_credential"] is False
