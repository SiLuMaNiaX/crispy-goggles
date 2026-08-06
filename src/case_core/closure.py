from __future__ import annotations

from sqlalchemy.orm import Session

from src.audit.service import record_audit
from src.case_core.service import open_required_actions, transition_case
from src.configuration.completeness import CompletenessResult, evaluate
from src.configuration.db import model_to_dict, utc_now
from src.configuration.errors import WorkflowError
from src.configuration.models import Case, FreezeAction, Investigation
from src.identity_access.service import AuthUser, require_permission


def closure_completeness(db: Session, case: Case) -> CompletenessResult:
    """Binary control + diagnostic percentage for case closure (FR-CLS-001, BR-012)."""
    open_actions = open_required_actions(db, case)
    inv = (
        db.query(Investigation)
        .filter(Investigation.case_id == case.id)
        .order_by(Investigation.created_at.desc())
        .first()
    )

    required: dict = {
        "final_outcome": case.final_outcome,
        "closure_rationale": case.closure_rationale,
        "no_open_required_actions": "ok" if not open_actions else None,
    }

    if inv and inv.officer_outcome == "NON_SUSPICIOUS":
        required["predator_disposition_confirmed"] = (
            "yes" if inv.predator_disposition_confirmed else None
        )

    # Freeze with STR obligation open blocks closure (AT-008)
    freezes = db.query(FreezeAction).filter(FreezeAction.case_id == case.id).all()
    for fr in freezes:
        if fr.creates_str_obligation and fr.status in {"EFFECTIVE", "COMPLETED"}:
            # Check if related STR action exists and is terminal
            str_open = any(
                a.action_type == "STR" and a.status not in {"COMPLETED", "CANCELLED", "CLOSED", "NOT_PROCEEDED"}
                for a in open_actions
            )
            # Also block if obligation flagged and no completed STR on case
            from src.configuration.models import STRCase

            str_done = (
                db.query(STRCase)
                .filter(
                    STRCase.case_id == case.id,
                    STRCase.status.in_(["SUBMITTED", "ACKNOWLEDGED", "NOT_PROCEEDED"]),
                )
                .count()
            )
            if fr.creates_str_obligation and str_done == 0:
                required["freeze_str_obligation_satisfied"] = None

    result = evaluate(required)
    for a in open_actions:
        result.outstanding.append(f"open_action:{a.action_id}:{a.action_type}:{a.status}")
        result.complete = False
    if result.outstanding:
        result.complete = False
        total = max(len(result.checked) + len(open_actions), 1)
        result.percentage = 100.0 * (total - len(result.outstanding)) / total
    return result


def close_case(
    db: Session,
    case: Case,
    actor: AuthUser,
    *,
    final_outcome: str,
    closure_rationale: str,
) -> Case:
    require_permission(actor, "case.close")
    if case.current_stage not in {"CLOSURE_REVIEW", "NON_SUSPICIOUS_REVIEW"}:
        # Allow closure review path only
        if case.current_stage != "CLOSURE_REVIEW":
            raise WorkflowError(
                f"Case must be in CLOSURE_REVIEW to close (current: {case.current_stage})",
                requirement_ids=["FR-CLS-001"],
            )

    case.final_outcome = final_outcome
    case.closure_rationale = closure_rationale
    gate = closure_completeness(db, case)
    if not gate.complete:
        raise WorkflowError(
            "Case closure blocked by outstanding items",
            requirement_ids=["FR-CLS-001"],
            rule_ids=["BR-012", "AT-012"],
            outstanding=gate.outstanding,
            fields={item: "outstanding" for item in gate.outstanding},
        )

    before = model_to_dict(case)
    case.closed_by = actor.id
    case.closed_at = utc_now()
    case.current_status = "CLOSED"
    transition_case(db, case, "CLOSED", actor, reason=closure_rationale)
    record_audit(
        db,
        event_category="Case",
        entity_type="Case",
        entity_id=case.case_id,
        action="closed",
        actor_user_id=actor.id,
        actor_username=actor.username,
        before=before,
        after=model_to_dict(case),
        reason=closure_rationale,
        rule_ids=["BR-012", "FR-CLS-001"],
    )
    db.commit()
    db.refresh(case)
    return case