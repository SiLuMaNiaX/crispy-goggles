from __future__ import annotations

import re
from typing import Any


NBSP = "\u00a0"


def normalize_identifier(value: Any) -> str:
    """Normalize for matching without destroying the raw source value.

    Preserves leading zeroes by treating input as text. Collapses whitespace /
    non-breaking spaces. Does not silently invent values.
    """
    if value is None:
        return ""
    text = str(value).replace(NBSP, " ").strip()
    text = re.sub(r"\s+", " ", text)
    return text


def as_text(value: Any) -> str:
    """Preserve identifiers as text including leading zeroes (FR-IMP-005)."""
    if value is None:
        return ""
    if isinstance(value, float) and value.is_integer():
        return str(int(value))
    if isinstance(value, int):
        return str(value)
    return str(value).replace(NBSP, " ")


def mask_identifier(value: str | None, visible: bool = False) -> str | None:
    if value is None:
        return None
    if visible or len(value) <= 4:
        return value
    return ("*" * (len(value) - 4)) + value[-4:]


def parse_excel_cell(value: Any) -> str:
    """Convert Excel cell values to stable text without silent date coercion loss."""
    if value is None:
        return ""
    return as_text(value).strip()