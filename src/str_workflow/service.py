from __future__ import annotations

from sqlalchemy.orm import Session

from src.audit.service import record_audit
from src.case_core.service import transition_case
from src.configuration.completeness import evaluate
from src.configuration.db import model_to_dict, utc_now
from src.configuration.errors import WorkflowError
from src.configuration.models import Action, Case, Investigation, STRAmendment, STRCase
from src.identity_access.service import AuthUser, require_permission


def _next_id(db: Session) -> str:
    count = db.query(STRCase).count() + 1
    return f"STR-{utc_now().year}-{count:06d}"


def create_str_from_action(db: Session, *, action: Action, case: Case, actor: AuthUser) -> STRCase:
    """Generate STR case from approved HOD direction and inherit linked context (FR-STR-001)."""
    inv = (
        db.query(Investigation)
        .filter(Investigation.case_id == case.id)
        .order_by(Investigation.created_at.desc())
        .first()
    )
    rec = STRCase(
        str_case_id=_next_id(db),
        action_id=action.id,
        case_id=case.id,
        status="PENDING_DRAFT",
        primary_offence_code=inv.suspected_offence_code if inv else None,
        grounds_for_suspicion=inv.grounds_for_suspicion if inv else None,
        referral_source="HOD_DIRECTION",
        duplicate_status="NOT_DUPLICATE",
        str_pic_user_id=action.owner_user_id,
        reporting_type="INITIAL",
    )
    db.add(rec)
    db.flush()
    record_audit(
        db,
        event_category="Action",
        entity_type="STRCase",
        entity_id=rec.str_case_id,
        action="created",
        actor_user_id=actor.id,
        actor_username=actor.username,
        after=model_to_dict(rec),
        rule_ids=["FR-STR-001", "BR-010"],
    )
    return rec


def update_draft(
    db: Session,
    rec: STRCase,
    actor: AuthUser,
    *,
    narrative: str | None = None,
    grounds_for_suspicion: str | None = None,
    primary_offence_code: str | None = None,
    reporting_type: str | None = None,
    duplicate_status: str | None = None,
    review_period_from: str | None = None,
    review_period_to: str | None = None,
    mark_draft_completed: bool = False,
) -> STRCase:
    if rec.locked:
        raise WorkflowError(
            "Submitted STR content is locked; use amendment route",
            requirement_ids=["FR-STR-004"],
            rule_ids=["BR-011", "AT-010"],
        )
    before = model_to_dict(rec)
    if narrative is not None:
        rec.narrative = narrative
    if grounds_for_suspicion is not None:
        rec.grounds_for_suspicion = grounds_for_suspicion
    if primary_offence_code is not None:
        rec.primary_offence_code = primary_offence_code
    if reporting_type is not None:
        rec.reporting_type = reporting_type
    if duplicate_status is not None:
        rec.duplicate_status = duplicate_status
    if review_period_from is not None:
        rec.review_period_from = review_period_from
    if review_period_to is not None:
        rec.review_period_to = review_period_to
    rec.status = "DRAFTING" if not mark_draft_completed else "DRAFT_COMPLETED"
    if mark_draft_completed:
        rec.status = "PENDING_REVIEW"
    db.flush()
    record_audit(
        db,
        event_category="Action",
        entity_type="STRCase",
        entity_id=rec.str_case_id,
        action="draft_updated",
        actor_user_id=actor.id,
        actor_username=actor.username,
        before=before,
        after=model_to_dict(rec),
        rule_ids=["BR-010"],
    )
    db.commit()
    db.refresh(rec)
    return rec


def review_str(
    db: Session,
    rec: STRCase,
    actor: AuthUser,
    *,
    decision: str,
    remarks: str | None = None,
) -> STRCase:
    require_permission(actor, "str.review")
    if rec.locked:
        raise WorkflowError("Submitted STR is locked", rule_ids=["BR-011"])
    decision = decision.upper().strip()
    before = model_to_dict(rec)
    rec.reviewed_by = actor.id
    rec.reviewed_at = utc_now()
    if decision == "RETURN":
        rec.status = "RETURNED_AMENDMENT"
        rec.amendment_notes = remarks
    elif decision == "APPROVE":
        require_permission(actor, "str.approve")
        rec.status = "APPROVED"
        rec.approved_by = actor.id
        rec.approved_at = utc_now()
        rec.status = "PENDING_SUBMISSION"
    else:
        raise WorkflowError("decision must be RETURN or APPROVE")
    db.flush()
    record_audit(
        db,
        event_category="Decision",
        entity_type="STRCase",
        entity_id=rec.str_case_id,
        action=f"review_{decision.lower()}",
        actor_user_id=actor.id,
        actor_username=actor.username,
        before=before,
        after=model_to_dict(rec),
        reason=remarks,
        rule_ids=["FR-STR-003"],
    )
    db.commit()
    db.refresh(rec)
    return rec


def submit_str(
    db: Session,
    rec: STRCase,
    actor: AuthUser,
    *,
    str_reference: str,
) -> STRCase:
    """Submitted requires reference, date and submitter (FR-STR-003). Does not auto-submit to regulator."""
    require_permission(actor, "str.submit")
    if rec.status not in {"APPROVED", "PENDING_SUBMISSION"}:
        raise WorkflowError(
            f"STR must be approved before submission (current: {rec.status})",
            requirement_ids=["FR-STR-003"],
        )
    gate = evaluate(
        {
            "str_reference": str_reference,
            "primary_offence_code": rec.primary_offence_code,
            "grounds_for_suspicion": rec.grounds_for_suspicion,
            "approved_by": rec.approved_by,
            "reporting_type": rec.reporting_type,
            "duplicate_status": rec.duplicate_status,
        }
    )
    if not gate.complete:
        raise WorkflowError(
            "STR submission blocked",
            requirement_ids=["FR-STR-003"],
            rule_ids=["BR-010", "AT-009"],
            fields={f: "required" for f in gate.outstanding},
            outstanding=gate.outstanding,
        )

    before = model_to_dict(rec)
    rec.str_reference = str_reference
    rec.submitted_at = utc_now()
    rec.submitted_by = actor.id
    rec.status = "SUBMITTED"
    rec.locked = True
    rec.action.status = "COMPLETED"
    rec.action.completed_at = utc_now()
    rec.action.completed_by = actor.id
    rec.action.outcome_summary = f"STR submitted: {str_reference}"

    case = db.get(Case, rec.case_id)
    assert case is not None
    transition_case(db, case, "CLOSURE_REVIEW", actor, reason=f"STR submitted {str_reference}")

    record_audit(
        db,
        event_category="Decision",
        entity_type="STRCase",
        entity_id=rec.str_case_id,
        action="submitted",
        actor_user_id=actor.id,
        actor_username=actor.username,
        before=before,
        after={**model_to_dict(rec), "auto_submitted_to_regulator": False},
        rule_ids=["FR-STR-003", "FR-STR-004", "BR-011"],
    )
    db.commit()
    db.refresh(rec)
    return rec


def add_amendment(db: Session, rec: STRCase, actor: AuthUser, amendment_text: str) -> STRAmendment:
    """Submitted content immutable; corrections are additive amendments (FR-STR-004, BR-011)."""
    if not rec.locked and rec.status != "SUBMITTED":
        raise WorkflowError("Amendments apply to submitted STRs", rule_ids=["BR-011"])
    if not amendment_text or not amendment_text.strip():
        raise WorkflowError("Amendment text required")
    amd = STRAmendment(str_case_pk=rec.id, amendment_text=amendment_text, created_by=actor.id)
    db.add(amd)
    db.flush()
    record_audit(
        db,
        event_category="Data",
        entity_type="STRCase",
        entity_id=rec.str_case_id,
        action="amendment_added",
        actor_user_id=actor.id,
        actor_username=actor.username,
        after={"amendment": amendment_text},
        reason="Additive amendment to locked STR",
        rule_ids=["BR-011", "FR-STR-004", "AT-010"],
    )
    db.commit()
    db.refresh(amd)
    return amd


def get_str(db: Session, str_case_id: str) -> STRCase:
    rec = db.query(STRCase).filter(STRCase.str_case_id == str_case_id).one_or_none()
    if not rec:
        raise WorkflowError(f"STR case not found: {str_case_id}", status_code=404)
    return rec


def attempt_edit_submitted(db: Session, rec: STRCase, actor: AuthUser, narrative: str) -> None:
    """Explicitly blocked path for AT-010."""
    if rec.locked or rec.status == "SUBMITTED":
        raise WorkflowError(
            "Edit blocked: submitted STR is immutable. Use amendment route.",
            requirement_ids=["FR-STR-004"],
            rule_ids=["BR-011", "AT-010"],
        )
    update_draft(db, rec, actor, narrative=narrative)