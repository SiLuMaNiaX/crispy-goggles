from __future__ import annotations

from datetime import datetime, timedelta

from sqlalchemy.orm import Session

from src.actions.service import create_directed_action
from src.audit.service import record_audit
from src.case_core.service import get_case_by_id, link_cases, transition_case
from src.configuration.completeness import evaluate
from src.configuration.db import model_to_dict, utc_now
from src.configuration.errors import (
    DIRECTIONS_REQUIRING_ACTION_OWNER,
    DIRECTIONS_REQUIRING_REMARKS,
    WorkflowError,
)
from src.configuration.models import Case, HODReview, Investigation
from src.configuration.settings import get_settings
from src.identity_access.service import AuthUser, require_permission
from src.reporting.notifications import notify_user


def list_pending_hod_queue(db: Session) -> list[Case]:
    return (
        db.query(Case)
        .filter(Case.current_stage == "PENDING_HOD_REVIEW")
        .order_by(Case.priority.desc(), Case.updated_at.asc())
        .all()
    )


def record_hod_direction(
    db: Session,
    case: Case,
    actor: AuthUser,
    *,
    direction_code: str,
    direction_remarks: str | None = None,
    action_owner_id: int | None = None,
    action_due_at: datetime | None = None,
    priority: str = "NORMAL",
    link_target_case_id: str | None = None,
    description: str | None = None,
) -> HODReview:
    """HOD direction stored separately from officer recommendation (FR-HOD-002, BR-004)."""
    require_permission(actor, "hod.direct")
    if case.current_stage != "PENDING_HOD_REVIEW":
        raise WorkflowError(
            f"Case is not pending HOD review (current: {case.current_stage})",
            requirement_ids=["FR-HOD-001"],
            rule_ids=["BR-003"],
        )

    direction_code = direction_code.upper().strip()
    settings = get_settings()

    required = {
        "direction_code": direction_code,
        "reviewer": actor.id,
    }
    if direction_code in DIRECTIONS_REQUIRING_REMARKS:
        required["direction_remarks"] = direction_remarks
    if direction_code in DIRECTIONS_REQUIRING_ACTION_OWNER:
        required["action_owner_id"] = action_owner_id
    if direction_code == "LINK":
        required["link_target_case_id"] = link_target_case_id
        required["direction_remarks"] = direction_remarks or description
    if direction_code == "OTHER":
        required["description"] = description or direction_remarks

    gate = evaluate(required)
    if not gate.complete:
        raise WorkflowError(
            "HOD direction incomplete",
            requirement_ids=["FR-HOD-002", "FR-HOD-003", "FR-HOD-004"],
            fields={f: "required" for f in gate.outstanding},
            outstanding=gate.outstanding,
        )

    if direction_code in DIRECTIONS_REQUIRING_ACTION_OWNER and action_due_at is None:
        days = settings.monitoring_default_days if direction_code == "MONITOR" else settings.hod_review_due_days
        if direction_code in {"RFV"}:
            days = settings.rfv_response_days
        elif direction_code in {"RFI"}:
            days = settings.rfi_response_days
        action_due_at = utc_now() + timedelta(days=days)

    inv = (
        db.query(Investigation)
        .filter(Investigation.case_id == case.id)
        .order_by(Investigation.created_at.desc())
        .first()
    )

    review = HODReview(
        case_id=case.id,
        investigation_id=inv.id if inv else None,
        reviewer_user_id=actor.id,
        review_date=utc_now(),
        direction_code=direction_code,
        direction_remarks=direction_remarks,
        action_owner_id=action_owner_id,
        action_due_at=action_due_at,
        priority=priority,
        link_target_case_id=link_target_case_id,
    )
    db.add(review)
    db.flush()

    # Route by direction catalogue (Section 5.4)
    if direction_code == "RETURN":
        transition_case(db, case, "RETURNED_TO_OFFICER", actor, reason=direction_remarks)
        if case.current_owner_user_id:
            notify_user(
                db,
                user_id=case.current_owner_user_id,
                event_type="case_returned",
                title="Case returned for revision",
                message=f"{case.case_id} returned by HOD: {direction_remarks}",
                case_id=case.case_id,
            )
    elif direction_code == "NFA":
        transition_case(db, case, "CLOSURE_REVIEW", actor, reason="HOD: no further action")
        action = create_directed_action(
            db,
            case=case,
            actor=actor,
            action_type="NFA",
            owner_user_id=action_owner_id or case.current_owner_user_id or actor.id,
            due_at=action_due_at,
            priority=priority,
            description=direction_remarks or "No further action — confirm disposition and close",
            hod_review_id=review.id,
        )
        review.created_action_id = action.id
    elif direction_code == "LINK":
        link_cases(db, case, link_target_case_id, direction_remarks or description or "HOD link", actor)
        transition_case(db, case, "CLOSURE_REVIEW", actor, reason=f"Linked to {link_target_case_id}")
    else:
        # Create directed action and move to ACTION_OPEN
        action = create_directed_action(
            db,
            case=case,
            actor=actor,
            action_type=direction_code,
            owner_user_id=action_owner_id,
            due_at=action_due_at,
            priority=priority,
            description=description or direction_remarks,
            hod_review_id=review.id,
        )
        review.created_action_id = action.id
        transition_case(db, case, "ACTION_OPEN", actor, reason=f"HOD directed {direction_code}")
        case.priority = priority
        if action_owner_id:
            case.current_owner_user_id = action_owner_id
        notify_user(
            db,
            user_id=action_owner_id,
            event_type="action_assigned",
            title=f"Directed action {direction_code}",
            message=f"{case.case_id}: {direction_code} assigned to you",
            case_id=case.case_id,
        )

    record_audit(
        db,
        event_category="Decision",
        entity_type="HODReview",
        entity_id=str(review.id),
        action="hod_direction",
        actor_user_id=actor.id,
        actor_username=actor.username,
        after={
            **model_to_dict(review),
            "officer_recommendation": inv.recommendation if inv else None,
            "separated_from_officer_recommendation": True,
        },
        reason=direction_remarks,
        rule_ids=["BR-003", "BR-004", "FR-HOD-001", "FR-HOD-002", "AT-005"],
    )
    db.commit()
    db.refresh(review)
    return review


def return_to_hod(db: Session, case: Case, actor: AuthUser, reason: str) -> Case:
    """After action outcome requires reconsideration — return to HOD, not officer self-route (5.3)."""
    if case.current_stage not in {"ACTION_OPEN", "CLOSURE_REVIEW"}:
        raise WorkflowError(f"Cannot return to HOD from {case.current_stage}")
    transition_case(db, case, "PENDING_HOD_REVIEW", actor, reason=reason)
    db.commit()
    return case