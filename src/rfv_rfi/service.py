from __future__ import annotations

from datetime import datetime, timedelta

from sqlalchemy.orm import Session

from src.audit.service import record_audit
from src.case_core.service import transition_case
from src.configuration.completeness import evaluate
from src.configuration.db import model_to_dict, utc_now
from src.configuration.errors import WorkflowError
from src.configuration.models import Action, Case, RFVRFI
from src.configuration.settings import get_settings
from src.identity_access.service import AuthUser


def _next_id(db: Session, prefix: str) -> str:
    count = db.query(RFVRFI).count() + 1
    return f"{prefix}-{utc_now().year}-{count:06d}"


def create_rfv_rfi_from_action(
    db: Session,
    *,
    action: Action,
    case: Case,
    request_type: str,
    actor: AuthUser,
) -> RFVRFI:
    """Create RFV/RFI from case without re-keying shared fields (FR-RFV-001)."""
    settings = get_settings()
    days = settings.rfv_response_days if request_type == "RFV" else settings.rfi_response_days
    record = RFVRFI(
        rfv_rfi_id=_next_id(db, request_type),
        action_id=action.id,
        case_id=case.id,
        request_type=request_type,
        status="DRAFT",
        requested_information=action.description,
        response_due_at=utc_now() + timedelta(days=days),
    )
    db.add(record)
    db.flush()
    record_audit(
        db,
        event_category="Action",
        entity_type="RFVRFI",
        entity_id=record.rfv_rfi_id,
        action="created",
        actor_user_id=actor.id,
        actor_username=actor.username,
        after=model_to_dict(record),
        rule_ids=["FR-RFV-001"],
    )
    return record


def mark_sent(
    db: Session,
    record: RFVRFI,
    actor: AuthUser,
    *,
    branch_code: str,
    recipient: str,
    requested_information: str,
    response_due_at: datetime | None = None,
) -> RFVRFI:
    gate = evaluate(
        {
            "request_type": record.request_type,
            "branch_code": branch_code,
            "recipient": recipient,
            "requested_information": requested_information,
        }
    )
    if not gate.complete:
        raise WorkflowError(
            "RFV/RFI send incomplete",
            requirement_ids=["FR-RFV-002"],
            fields={f: "required" for f in gate.outstanding},
            outstanding=gate.outstanding,
        )
    before = model_to_dict(record)
    record.branch_code = branch_code
    record.recipient = recipient
    record.requested_information = requested_information
    record.sent_at = utc_now()
    record.response_due_at = response_due_at or record.response_due_at
    record.status = "AWAITING_RESPONSE"
    record.action.status = "IN_PROGRESS"
    db.flush()
    record_audit(
        db,
        event_category="Action",
        entity_type="RFVRFI",
        entity_id=record.rfv_rfi_id,
        action="sent",
        actor_user_id=actor.id,
        actor_username=actor.username,
        before=before,
        after=model_to_dict(record),
        rule_ids=["FR-RFV-002"],
    )
    db.commit()
    db.refresh(record)
    return record


def record_follow_up(db: Session, record: RFVRFI, actor: AuthUser, which: int = 1) -> RFVRFI:
    before = model_to_dict(record)
    now = utc_now()
    if which == 1:
        record.follow_up_1_at = now
        record.status = "FOLLOW_UP_1"
    else:
        record.follow_up_2_at = now
        record.status = "FOLLOW_UP_2"
    db.flush()
    record_audit(
        db,
        event_category="Action",
        entity_type="RFVRFI",
        entity_id=record.rfv_rfi_id,
        action=f"follow_up_{which}",
        actor_user_id=actor.id,
        actor_username=actor.username,
        before=before,
        after=model_to_dict(record),
        rule_ids=["FR-RFV-003"],
    )
    db.commit()
    db.refresh(record)
    return record


def record_response(db: Session, record: RFVRFI, actor: AuthUser, response_status: str) -> RFVRFI:
    before = model_to_dict(record)
    record.response_received_at = utc_now()
    record.response_status = response_status
    record.status = "RESPONSE_RECEIVED"
    db.flush()
    record_audit(
        db,
        event_category="Action",
        entity_type="RFVRFI",
        entity_id=record.rfv_rfi_id,
        action="response_received",
        actor_user_id=actor.id,
        actor_username=actor.username,
        before=before,
        after=model_to_dict(record),
    )
    db.commit()
    db.refresh(record)
    return record


def complete_assessment(
    db: Session,
    record: RFVRFI,
    actor: AuthUser,
    *,
    evidence_assessment: str,
    final_conclusion: str,
    post_assessment_route: str,
) -> RFVRFI:
    """Completion requires response, evidence assessment, conclusion and next route (FR-RFV-004).

    BR-008: RFV/RFI completion does not automatically resolve suspicion.
    """
    gate = evaluate(
        {
            "response_status": record.response_status,
            "response_received_at": record.response_received_at,
            "evidence_assessment": evidence_assessment,
            "final_conclusion": final_conclusion,
            "post_assessment_route": post_assessment_route,
        }
    )
    if not gate.complete:
        raise WorkflowError(
            "RFV/RFI completion blocked — missing mandatory fields",
            requirement_ids=["FR-RFV-004"],
            rule_ids=["BR-007", "BR-008", "AT-006"],
            fields={f: "required" for f in gate.outstanding},
            outstanding=gate.outstanding,
        )

    route = post_assessment_route.upper().strip()
    if route not in {"CLOSURE", "RETURN_HOD"}:
        raise WorkflowError("post_assessment_route must be CLOSURE or RETURN_HOD", rule_ids=["BR-008"])

    before = model_to_dict(record)
    record.evidence_assessment = evidence_assessment
    record.final_conclusion = final_conclusion
    record.post_assessment_route = route
    record.status = "COMPLETED"
    record.action.status = "COMPLETED"
    record.action.outcome_summary = final_conclusion
    record.action.completed_at = utc_now()
    record.action.completed_by = actor.id

    case = db.get(Case, record.case_id)
    assert case is not None
    if route == "RETURN_HOD":
        transition_case(db, case, "PENDING_HOD_REVIEW", actor, reason="RFV/RFI concern remains — return to HOD")
    else:
        transition_case(db, case, "CLOSURE_REVIEW", actor, reason="RFV/RFI concern resolved — closure review")

    record_audit(
        db,
        event_category="Action",
        entity_type="RFVRFI",
        entity_id=record.rfv_rfi_id,
        action="completed",
        actor_user_id=actor.id,
        actor_username=actor.username,
        before=before,
        after={**model_to_dict(record), "auto_resolved_suspicion": False},
        rule_ids=["BR-008", "FR-RFV-004", "AT-007"],
    )
    db.commit()
    db.refresh(record)
    return record


def get_rfv_rfi(db: Session, rfv_rfi_id: str) -> RFVRFI:
    rec = db.query(RFVRFI).filter(RFVRFI.rfv_rfi_id == rfv_rfi_id).one_or_none()
    if not rec:
        raise WorkflowError(f"RFV/RFI not found: {rfv_rfi_id}", status_code=404)
    return rec


def is_overdue(record: RFVRFI) -> bool:
    if not record.response_due_at or record.status in {"COMPLETED", "CLOSED"}:
        return False
    due = record.response_due_at
    if due.tzinfo is None:
        from datetime import timezone

        due = due.replace(tzinfo=timezone.utc)
    return utc_now() > due and record.response_received_at is None