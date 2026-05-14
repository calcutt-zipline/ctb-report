from __future__ import annotations

from typing import Optional, Tuple


WAREHOUSE_LIKE_CATEGORIES = {"Warehouse", "Receiving & Pre-IQC"}


def _is_warehouse_like(category: str) -> bool:
    return category in WAREHOUSE_LIKE_CATEGORIES


def categorize_transaction(origin: str, destination: str, quantity: float) -> Tuple[str, Optional[float]]:
    origin_is_warehouse_like = _is_warehouse_like(origin)
    destination_is_warehouse_like = _is_warehouse_like(destination)

    if origin == "Vendors" and destination_is_warehouse_like:
        return "New Supply", quantity
    if origin_is_warehouse_like and destination == "Vendors":
        return "New Supply", -quantity
    if origin_is_warehouse_like and destination == "Nest":
        return "Nest Consumption", quantity
    if origin == "Nest" and destination_is_warehouse_like:
        return "RMA Supply", quantity
    if origin_is_warehouse_like and destination == "Production":
        return "Production Consumption", quantity
    if origin == "Production" and destination_is_warehouse_like:
        return "Production Consumption", -quantity
    if origin_is_warehouse_like and destination == "Scrap":
        return "QC Loss Consumption", quantity
    if origin_is_warehouse_like and destination == "Quarantine":
        return "QC Loss Consumption", quantity
    if origin == "Quarantine" and destination_is_warehouse_like:
        return "QC Loss Consumption", -quantity
    if origin == "Scrap" and destination_is_warehouse_like:
        return "QC Loss Consumption", -quantity
    if origin_is_warehouse_like and destination == "R&D":
        return "R&D Consumption", quantity
    if origin == "R&D" and destination_is_warehouse_like:
        return "R&D Supply", quantity
    return "Unknown", None
