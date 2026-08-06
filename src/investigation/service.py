from __future__ import annotations

from sqlalchemy.orm import Session

from src.audit.service import record_audit
from src.case_core.service import transition_case
from src.configuration.completeness import evaluate
from src.configuration.db import model_to_dict, utc_now
from src.configuration.errors import WorkflowError
from src.configuration.models import Case, Investigation
from src.identity_access.service import AuthUser, require_permission


def start_investigation(db: Session, case: Case, actor: AuthUser) -> Investigation:
    require_permission(actor, "investigation.update_own")
    if case.current_owner_user_id != actor.id and not actor.has_role("HOD", "SYSTEM_ADMIN"):
        raise WorkflowError("Case is not in your queue", status_code=403)
    if case.current_stage not in {"ASSIGNED", "RETURNED_TO_OFFICER", "REASSIGNED", "UNDER_INVESTIGATION"}:
        raise WorkflowError(f"Cannot start investigation from stage {case.current_stage}")

    inv = (
        db.query(Investigation)
        .filter(Investigation.case_id == case.id, Investigation.status == "IN_PROGRESS")
        .one_or_none()
    )
    if inv is None:
        inv = Investigation(
            case_id=case.id,
            officer_user_id=actor.id,
            started_at=utc_now(),
            status="IN_PROGRESS",
        )
        db.add(inv)
        db.flush()

    if case.current_stage != "UNDER_INVESTIGATION":
        transition_case(db, case, "UNDER_INVESTIGATION", actor, reason="Investigation started")
    record_audit(
        db,
        event_category="Decision",
        entity_type="Investigation",
        entity_id=str(inv.id),
        action="started",
        actor_user_id=actor.id,
        actor_username=actor.username,
        after=model_to_dict(inv),
        rule_ids=["FR-INV-001"],
    )
    db.commit()
    db.refresh(inv)
    return inv


def save_investigation_draft(
    db: Session,
    case: Case,
    actor: AuthUser,
    *,
    assessment_summary: str | None = None,
    predator_reference: str | None = None,
    grounds_for_suspicion: str | None = None,
    suspected_offence_code: str | None = None,
    recommendation: str | None = None,
) -> Investigation:
    """Save draft without stage transition when incomplete (UX 10.4)."""
    require_permission(actor, "investigation.update_own")
    inv = (
        db.query(Investigation)
        .filter(Investigation.case_id == case.id, Investigation.status == "IN_PROGRESS")
        .one_or_none()
    )
    if inv is None:
        inv = start_investigation(db, case, actor)

    before = model_to_dict(inv)
    if assessment_summary is not None:
        inv.assessment_summary = assessment_summary
    if predator_reference is not None:
        inv.predator_reference = predator_reference
    if grounds_for_suspicion is not None:
        inv.grounds_for_suspicion = grounds_for_suspicion
    if suspected_offence_code is not None:
        inv.suspected_offence_code = suspected_offence_code
    if recommendation is not None:
        inv.recommendation = recommendation
    inv.updated_at = utc_now()
    db.flush()
    record_audit(
        db,
        event_category="Decision",
        entity_type="Investigation",
        entity_id=str(inv.id),
        action="draft_saved",
        actor_user_id=actor.id,
        actor_username=actor.username,
        before=before,
        after=model_to_dict(inv),
        rule_ids=["FR-INV-001", "BR-005"],
    )
    db.commit()
    db.refresh(inv)
    return inv


def complete_non_suspicious(
    db: Session,
    case: Case,
    actor: AuthUser,
    *,
    assessment_summary: str,
    predator_disposition_confirmed: bool,
    predator_reference: str | None = None,
) -> Investigation:
    require_permission(actor, "investigation.update_own")
    if not assessment_summary or not assessment_summary.strip():
        raise WorkflowError(
            "Assessment summary is required",
            requirement_ids=["FR-INV-001", "FR-INV-004"],
            fields={"assessment_summary": "required"},
        )
    if not predator_disposition_confirmed:
        raise WorkflowError(
            "Predator disposition confirmation is required for non-suspicious route",
            requirement_ids=["FR-INV-004"],
            rule_ids=["BR-001"],
            fields={"predator_disposition_confirmed": "required"},
        )

    inv = save_investigation_draft(
        db,
        case,
        actor,
        assessment_summary=assessment_summary,
        predator_reference=predator_reference,
    )
    inv.officer_outcome = "NON_SUSPICIOUS"
    inv.predator_disposition_confirmed = True
    inv.predator_disposition_date = utc_now()
    inv.completed_at = utc_now()
    inv.status = "COMPLETED"
    transition_case(db, case, "NON_SUSPICIOUS_REVIEW", actor, reason="Officer non-suspicious outcome")
    transition_case(db, case, "CLOSURE_REVIEW", actor, reason="Ready for closure controls")
    record_audit(
        db,
        event_category="Decision",
        entity_type="Investigation",
        entity_id=str(inv.id),
        action="officer_outcome_non_suspicious",
        actor_user_id=actor.id,
        actor_username=actor.username,
        after=model_to_dict(inv),
        rule_ids=["BR-001", "FR-INV-004"],
    )
    db.commit()
    db.refresh(inv)
    return inv


def refer_suspicious(
    db: Session,
    case: Case,
    actor: AuthUser,
    *,
    assessment_summary: str,
    grounds_for_suspicion: str,
    suspected_offence_code: str,
    recommendation: str | None = None,
    predator_reference: str | None = None,
) -> Investigation:
    """Officer suspicious referral — cannot record HOD direction (BR-003/004, FR-HOD-001)."""
    require_permission(actor, "investigation.refer_suspicious")
    # BR-005: system must not make or recommend an AML suspicious decision using AI
    gate = evaluate(
        {
            "assessment_summary": assessment_summary,
            "grounds_for_suspicion": grounds_for_suspicion,
            "suspected_offence_code": suspected_offence_code,
        }
    )
    if not gate.complete:
        raise WorkflowError(
            "Suspicious referral incomplete",
            requirement_ids=["FR-INV-002", "FR-HOD-001"],
            rule_ids=["BR-003"],
            fields={f: "required" for f in gate.outstanding},
            outstanding=gate.outstanding,
        )

    inv = save_investigation_draft(
        db,
        case,
        actor,
        assessment_summary=assessment_summary,
        grounds_for_suspicion=grounds_for_suspicion,
        suspected_offence_code=suspected_offence_code,
        recommendation=recommendation,
        predator_reference=predator_reference,
    )
    inv.officer_outcome = "SUSPICIOUS"
    inv.completed_at = utc_now()
    inv.status = "REFERRED"
    transition_case(db, case, "PENDING_HOD_REVIEW", actor, reason="Suspicious referral to HOD")
    record_audit(
        db,
        event_category="Decision",
        entity_type="Investigation",
        entity_id=str(inv.id),
        action="officer_outcome_suspicious",
        actor_user_id=actor.id,
        actor_username=actor.username,
        after={
            **model_to_dict(inv),
            "note": "Officer recommendation is not HOD direction",
        },
        rule_ids=["BR-003", "BR-004", "BR-005", "FR-HOD-001", "AT-004"],
    )
    db.commit()
    db.refresh(inv)
    return inv


def latest_investigation(db: Session, case: Case) -> Investigation | None:
    return (
        db.query(Investigation)
        .filter(Investigation.case_id == case.id)
        .order_by(Investigation.created_at.desc())
        .first()
    )