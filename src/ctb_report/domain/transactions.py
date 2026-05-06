from __future__ import annotations

from typing import Optional, Tuple


def categorize_transaction(origin: str, destination: str, quantity: float) -> Tuple[str, Optional[float]]:
    if origin == "Vendors" and destination == "Warehouse":
        return "New Supply", quantity
    if origin == "Warehouse" and destination == "Vendors":
        return "New Supply", -quantity
    if origin == "Warehouse" and destination == "Nest":
        return "Nest Consumption", quantity
    if origin == "Nest" and destination == "Warehouse":
        return "RMA Supply", quantity
    if origin == "Warehouse" and destination == "Production":
        return "Production Consumption", quantity
    if origin == "Production" and destination == "Warehouse":
        return "Production Consumption", -quantity
    if origin == "Warehouse" and destination == "Scrap":
        return "QC Loss Consumption", quantity
    if origin == "Warehouse" and destination == "Quarantine":
        return "QC Loss Consumption", quantity
    if origin == "Quarantine" and destination == "Warehouse":
        return "QC Loss Consumption", -quantity
    if origin == "Scrap" and destination == "Warehouse":
        return "QC Loss Consumption", -quantity
    if origin == "Warehouse" and destination == "R&D":
        return "R&D Consumption", quantity
    if origin == "R&D" and destination == "Warehouse":
        return "R&D Supply", quantity
    return "Unknown", None
