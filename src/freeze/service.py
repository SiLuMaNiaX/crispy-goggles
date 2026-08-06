from __future__ import annotations

from datetime import datetime

from sqlalchemy.orm import Session

from src.audit.service import record_audit
from src.case_core.service import transition_case
from src.configuration.completeness import evaluate
from src.configuration.db import model_to_dict, utc_now
from src.configuration.errors import WorkflowError
from src.configuration.models import Action, Case, FreezeAction
from src.identity_access.service import AuthUser


def _next_id(db: Session) -> str:
    count = db.query(FreezeAction).count() + 1
    return f"FRZ-{utc_now().year}-{count:06d}"


def create_freeze_from_action(db: Session, *, action: Action, case: Case, actor: AuthUser) -> FreezeAction:
    """Track freeze direction without executing the freeze (FR-FRZ-002, BR-009)."""
    # Inherit account from first alert if available
    account_raw = None
    if case.alerts:
        account_raw = case.alerts[0].account_number_raw

    rec = FreezeAction(
        freeze_id=_next_id(db),
        action_id=action.id,
        case_id=case.id,
        status="DIRECTED",
        affected_account_raw=account_raw,
        notes="Tracking only — actual freeze executed outside this system (BR-009)",
    )
    db.add(rec)
    db.flush()
    record_audit(
        db,
        event_category="Action",
        entity_type="FreezeAction",
        entity_id=rec.freeze_id,
        action="created",
        actor_user_id=actor.id,
        actor_username=actor.username,
        after={**model_to_dict(rec), "executes_freeze": False},
        rule_ids=["FR-FRZ-002", "BR-009"],
    )
    return rec


def update_freeze_status(
    db: Session,
    rec: FreezeAction,
    actor: AuthUser,
    *,
    status: str,
    external_reference: str | None = None,
    affected_account_raw: str | None = None,
    outcome: str | None = None,
    effective_at: datetime | None = None,
    creates_str_obligation: bool | None = None,
    creates_followup_obligation: bool | None = None,
    notes: str | None = None,
) -> FreezeAction:
    status = status.upper().strip()
    before = model_to_dict(rec)

    if status in {"INITIATED", "PENDING_CONFIRMATION"}:
        rec.initiated_at = rec.initiated_at or utc_now()
    if status == "PENDING_CONFIRMATION":
        pass
    if status in {"EFFECTIVE", "UNSUCCESSFUL", "REJECTED", "LIFTED", "COMPLETED"}:
        gate_fields = {
            "affected_account": affected_account_raw or rec.affected_account_raw,
            "status": status,
            "outcome": outcome or status,
        }
        if status == "EFFECTIVE":
            gate_fields["external_reference_or_reason"] = external_reference or notes or rec.external_reference
        gate = evaluate(gate_fields)
        if not gate.complete:
            raise WorkflowError(
                "Freeze completion incomplete",
                requirement_ids=["FR-FRZ-001"],
                fields={f: "required" for f in gate.outstanding},
                outstanding=gate.outstanding,
            )
        rec.confirmed_at = utc_now()
        if status == "EFFECTIVE":
            rec.effective_at = effective_at or utc_now()
        rec.outcome = outcome or status
        if creates_str_obligation is not None:
            rec.creates_str_obligation = creates_str_obligation
        if creates_followup_obligation is not None:
            rec.creates_followup_obligation = creates_followup_obligation

    if external_reference is not None:
        rec.external_reference = external_reference
    if affected_account_raw is not None:
        rec.affected_account_raw = affected_account_raw
    if notes is not None:
        rec.notes = notes
    rec.status = status
    rec.action.status = "IN_PROGRESS" if status not in {"COMPLETED", "EFFECTIVE", "UNSUCCESSFUL", "REJECTED", "LIFTED"} else "COMPLETED"
    if rec.action.status == "COMPLETED":
        rec.action.completed_at = utc_now()
        rec.action.completed_by = actor.id
        rec.action.outcome_summary = rec.outcome or status

    case = db.get(Case, rec.case_id)
    assert case is not None
    # Open obligations / return to HOD when freeze creates STR obligation or follow-up
    if status in {"EFFECTIVE", "COMPLETED"} and (rec.creates_str_obligation or rec.creates_followup_obligation):
        transition_case(
            db,
            case,
            "PENDING_HOD_REVIEW",
            actor,
            reason="Freeze effective with open STR/follow-up obligations",
        )
    elif status in {"EFFECTIVE", "UNSUCCESSFUL", "REJECTED", "LIFTED", "COMPLETED"}:
        transition_case(db, case, "CLOSURE_REVIEW", actor, reason=f"Freeze {status}")

    record_audit(
        db,
        event_category="Action",
        entity_type="FreezeAction",
        entity_id=rec.freeze_id,
        action="status_updated",
        actor_user_id=actor.id,
        actor_username=actor.username,
        before=before,
        after={**model_to_dict(rec), "executes_freeze": False},
        rule_ids=["FR-FRZ-001", "FR-FRZ-002", "FR-FRZ-003", "BR-009", "AT-008"],
    )
    db.commit()
    db.refresh(rec)
    return rec


def get_freeze(db: Session, freeze_id: str) -> FreezeAction:
    rec = db.query(FreezeAction).filter(FreezeAction.freeze_id == freeze_id).one_or_none()
    if not rec:
        raise WorkflowError(f"Freeze action not found: {freeze_id}", status_code=404)
    return rec