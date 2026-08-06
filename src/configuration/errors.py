from __future__ import annotations

from typing import Any


class WorkflowError(Exception):
    """Structured workflow validation / business-rule failure."""

    def __init__(
        self,
        message: str,
        *,
        rule_ids: list[str] | None = None,
        requirement_ids: list[str] | None = None,
        fields: dict[str, str] | None = None,
        outstanding: list[str] | None = None,
        status_code: int = 400,
    ):
        super().__init__(message)
        self.message = message
        self.rule_ids = rule_ids or []
        self.requirement_ids = requirement_ids or []
        self.fields = fields or {}
        self.outstanding = outstanding or []
        self.status_code = status_code

    def to_dict(self) -> dict[str, Any]:
        return {
            "error": self.message,
            "rule_ids": self.rule_ids,
            "requirement_ids": self.requirement_ids,
            "fields": self.fields,
            "outstanding": self.outstanding,
        }


ALLOWED_CASE_TRANSITIONS: dict[str, set[str]] = {
    "IMPORTED": {"ASSIGNED", "IMPORT_EXCEPTION"},
    "ASSIGNED": {"UNDER_INVESTIGATION", "REASSIGNED"},
    "REASSIGNED": {"ASSIGNED", "UNDER_INVESTIGATION"},
    "UNDER_INVESTIGATION": {"NON_SUSPICIOUS_REVIEW", "PENDING_HOD_REVIEW", "RETURNED_TO_OFFICER"},
    "NON_SUSPICIOUS_REVIEW": {"CLOSURE_REVIEW", "UNDER_INVESTIGATION"},
    "PENDING_HOD_REVIEW": {"RETURNED_TO_OFFICER", "ACTION_OPEN", "CLOSURE_REVIEW"},
    "RETURNED_TO_OFFICER": {"UNDER_INVESTIGATION", "PENDING_HOD_REVIEW"},
    "ACTION_OPEN": {"PENDING_HOD_REVIEW", "CLOSURE_REVIEW", "ACTION_OPEN"},
    "CLOSURE_REVIEW": {"CLOSED", "ACTION_OPEN", "RETURNED_TO_OFFICER"},
    "CLOSED": {"AMENDMENT_OPEN"},
    "IMPORT_EXCEPTION": {"IMPORTED", "REJECTED"},
    "AMENDMENT_OPEN": {"CLOSED"},
    "REJECTED": set(),
}


def assert_transition(current: str, nxt: str) -> None:
    allowed = ALLOWED_CASE_TRANSITIONS.get(current, set())
    if nxt not in allowed and nxt != current:
        raise WorkflowError(
            f"Invalid case state transition: {current} → {nxt}",
            rule_ids=["BR-state-machine"],
            fields={"current_stage": current, "requested_stage": nxt},
        )


DIRECTIONS_REQUIRING_REMARKS = {"RETURN", "OTHER"}
DIRECTIONS_REQUIRING_ACTION_OWNER = {
    "ASSESS",
    "RFV",
    "RFI",
    "FREEZE",
    "STR",
    "MONITOR",
    "OTHER",
    "RETURN",
}