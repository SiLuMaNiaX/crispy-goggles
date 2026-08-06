from __future__ import annotations

from datetime import datetime

from sqlalchemy.orm import Session

from src.audit.service import record_audit
from src.configuration.db import model_to_dict, utc_now
from src.configuration.errors import WorkflowError
from src.configuration.models import Action, Case
from src.identity_access.service import AuthUser


def _next_action_id(db: Session, prefix: str) -> str:
    count = db.query(Action).count() + 1
    return f"{prefix}-{utc_now().year}-{count:06d}"


def create_directed_action(
    db: Session,
    *,
    case: Case,
    actor: AuthUser,
    action_type: str,
    owner_user_id: int,
    due_at: datetime | None,
    priority: str,
    description: str | None,
    hod_review_id: int | None,
) -> Action:
    """Generic task engine — one accountable owner (BR-006)."""
    if not owner_user_id:
        raise WorkflowError("Directed action requires an accountable owner", rule_ids=["BR-006"], requirement_ids=["FR-HOD-003"])

    action = Action(
        action_id=_next_action_id(db, action_type),
        case_id=case.id,
        action_type=action_type,
        status="OPEN",
        owner_user_id=owner_user_id,
        priority=priority,
        due_at=due_at,
        description=description,
        hod_review_id=hod_review_id,
    )
    db.add(action)
    db.flush()

    # Create subtype records
    if action_type in {"RFV", "RFI"}:
        from src.rfv_rfi.service import create_rfv_rfi_from_action

        create_rfv_rfi_from_action(db, action=action, case=case, request_type=action_type, actor=actor)
    elif action_type == "FREEZE":
        from src.freeze.service import create_freeze_from_action

        create_freeze_from_action(db, action=action, case=case, actor=actor)
    elif action_type == "STR":
        from src.str_workflow.service import create_str_from_action

        create_str_from_action(db, action=action, case=case, actor=actor)

    record_audit(
        db,
        event_category="Action",
        entity_type="Action",
        entity_id=action.action_id,
        action="created",
        actor_user_id=actor.id,
        actor_username=actor.username,
        after=model_to_dict(action),
        rule_ids=["BR-006", "FR-HOD-003"],
    )
    return action


def complete_action(
    db: Session,
    action: Action,
    actor: AuthUser,
    *,
    outcome_summary: str,
) -> Action:
    if action.owner_user_id != actor.id and not actor.has_role("HOD", "SYSTEM_ADMIN"):
        raise WorkflowError("Only the action owner can complete this action", status_code=403)
    if not outcome_summary or not outcome_summary.strip():
        raise WorkflowError("Outcome summary required", rule_ids=["BR-007"])

    # Subtype-specific mandatory fields (BR-007)
    if action.action_type in {"RFV", "RFI"} and action.rfv_rfi and action.rfv_rfi.status != "COMPLETED":
        raise WorkflowError(
            "RFV/RFI must be completed before action completion",
            rule_ids=["BR-007"],
            requirement_ids=["FR-RFV-004"],
        )
    if action.action_type == "FREEZE" and action.freeze_action and action.freeze_action.status not in {
        "EFFECTIVE",
        "UNSUCCESSFUL",
        "REJECTED",
        "LIFTED",
        "COMPLETED",
    }:
        raise WorkflowError("Freeze outcome must be recorded", rule_ids=["BR-007"], requirement_ids=["FR-FRZ-001"])
    if action.action_type == "STR" and action.str_case and action.str_case.status not in {
        "SUBMITTED",
        "ACKNOWLEDGED",
        "NOT_PROCEEDED",
        "WITHDRAWN",
    }:
        raise WorkflowError("STR must reach a terminal status", rule_ids=["BR-007"], requirement_ids=["FR-STR-003"])

    before = model_to_dict(action)
    action.status = "COMPLETED"
    action.outcome_summary = outcome_summary
    action.completed_at = utc_now()
    action.completed_by = actor.id
    db.flush()
    record_audit(
        db,
        event_category="Action",
        entity_type="Action",
        entity_id=action.action_id,
        action="completed",
        actor_user_id=actor.id,
        actor_username=actor.username,
        before=before,
        after=model_to_dict(action),
        rule_ids=["BR-007"],
    )
    return action


def get_action(db: Session, action_id: str) -> Action:
    action = db.query(Action).filter(Action.action_id == action_id).one_or_none()
    if not action:
        raise WorkflowError(f"Action not found: {action_id}", status_code=404)
    return action


def list_actions_for_user(db: Session, user: AuthUser, open_only: bool = True) -> list[Action]:
    q = db.query(Action)
    if not user.has_role("HOD", "SYSTEM_ADMIN", "AUDITOR"):
        q = q.filter(Action.owner_user_id == user.id)
    if open_only:
        q = q.filter(Action.status.notin_(["COMPLETED", "CANCELLED", "CLOSED"]))
    return q.order_by(Action.due_at.asc().nullslast(), Action.created_at.desc()).all()