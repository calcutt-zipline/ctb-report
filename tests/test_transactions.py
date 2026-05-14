from ctb_report.domain.transactions import categorize_transaction


def test_vendor_to_warehouse_is_new_supply() -> None:
    assert categorize_transaction("Vendors", "Warehouse", 5) == ("New Supply", 5)


def test_production_return_is_negative_consumption() -> None:
    assert categorize_transaction("Production", "Warehouse", 3) == ("Production Consumption", -3)


def test_receiving_pre_iqc_is_warehouse_like() -> None:
    assert categorize_transaction("Vendors", "Receiving & Pre-IQC", 5) == ("New Supply", 5)
    assert categorize_transaction("Receiving & Pre-IQC", "Production", 3) == (
        "Production Consumption",
        3,
    )
    assert categorize_transaction("Production", "Receiving & Pre-IQC", 2) == (
        "Production Consumption",
        -2,
    )


def test_unknown_pair_returns_unknown() -> None:
    assert categorize_transaction("Unknown", "Unknown", 7) == ("Unknown", None)
