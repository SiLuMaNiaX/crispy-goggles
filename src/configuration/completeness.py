from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any


@dataclass
class CompletenessResult:
    complete: bool
    percentage: float
    outstanding: list[str] = field(default_factory=list)
    checked: list[str] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        return {
            "complete": self.complete,
            "percentage": round(self.percentage, 1),
            "outstanding": self.outstanding,
            "checked": self.checked,
            "status": "COMPLETE" if self.complete else "INCOMPLETE",
        }


def evaluate(required: dict[str, Any]) -> CompletenessResult:
    """Binary completeness control + diagnostic percentage (Section 9.2).

    No silent defaults for operational decisions.
    """
    outstanding: list[str] = []
    checked: list[str] = []
    for name, value in required.items():
        checked.append(name)
        if value is None:
            outstanding.append(name)
        elif isinstance(value, str) and not value.strip():
            outstanding.append(name)
        elif isinstance(value, bool) and name.endswith("_required_true") and not value:
            outstanding.append(name)
    total = len(required) or 1
    pct = 100.0 * (total - len(outstanding)) / total
    return CompletenessResult(complete=not outstanding, percentage=pct, outstanding=outstanding, checked=checked)