from __future__ import annotations

from sqlalchemy.orm import Session

from src.audit.service import record_audit
from src.configuration.db import model_to_dict, utc_now
from src.configuration.errors import WorkflowError, assert_transition
from src.configuration.models import Case, CaseLink, CaseSequence, Customer
from src.configuration.normalization import normalize_identifier
from src.identity_access.service import AuthUser


def next_case_id(db: Session) -> str:
    year = utc_now().year
    seq = db.get(CaseSequence, year)
    if seq is None:
        seq = CaseSequence(year=year, last_value=0)
        db.add(seq)
        db.flush()
    seq.last_value += 1
    db.flush()
    return f"AML-{year}-{seq.last_value:06d}"


def get_or_create_customer(db: Session, customer_id_raw: str, customer_name: str) -> Customer:
    normalized = normalize_identifier(customer_id_raw)
    customer = db.query(Customer).filter(Customer.customer_id_normalized == normalized).one_or_none()
    if customer:
        return customer
    customer = Customer(customer_id_normalized=normalized, customer_name=customer_name.strip())
    db.add(customer)
    db.flush()
    return customer


def create_case(
    db: Session,
    *,
    customer: Customer | None,
    owner_user_id: int | None,
    actor: AuthUser,
    stage: str = "ASSIGNED",
    priority: str = "NORMAL",
) -> Case:
    case = Case(
        case_id=next_case_id(db),
        customer_id=customer.id if customer else None,
        current_stage=stage,
        current_status="OPEN",
        current_owner_user_id=owner_user_id,
        priority=priority,
    )
    db.add(case)
    db.flush()
    record_audit(
        db,
        event_category="Case",
        entity_type="Case",
        entity_id=case.case_id,
        action="created",
        actor_user_id=actor.id,
        actor_username=actor.username,
        after=model_to_dict(case),
        rule_ids=["FR-CASE-001"],
    )
    return case


def get_case_by_id(db: Session, case_id: str) -> Case:
    case = db.query(Case).filter(Case.case_id == case_id).one_or_none()
    if not case:
        raise WorkflowError(f"Case not found: {case_id}", status_code=404)
    return case


def transition_case(db: Session, case: Case, new_stage: str, actor: AuthUser, reason: str | None = None) -> Case:
    assert_transition(case.current_stage, new_stage)
    before = model_to_dict(case)
    case.current_stage = new_stage
    case.version += 1
    case.updated_at = utc_now()
    db.flush()
    record_audit(
        db,
        event_category="Case",
        entity_type="Case",
        entity_id=case.case_id,
        action="state_changed",
        actor_user_id=actor.id,
        actor_username=actor.username,
        before=before,
        after=model_to_dict(case),
        reason=reason,
        rule_ids=["BR-state-machine"],
    )
    return case


def reassign_case(db: Session, case: Case, new_owner_id: int, actor: AuthUser, reason: str) -> Case:
    if not reason or not reason.strip():
        raise WorkflowError("Reassignment requires a reason", rule_ids=["BR-013"], requirement_ids=["FR-AUD-001"])
    before = model_to_dict(case)
    case.current_owner_user_id = new_owner_id
    case.version += 1
    if case.current_stage == "ASSIGNED":
        pass
    elif case.current_stage in {"IMPORTED"}:
        case.current_stage = "ASSIGNED"
    db.flush()
    record_audit(
        db,
        event_category="Case",
        entity_type="Case",
        entity_id=case.case_id,
        action="reassigned",
        actor_user_id=actor.id,
        actor_username=actor.username,
        before=before,
        after=model_to_dict(case),
        reason=reason,
        rule_ids=["BR-013"],
    )
    return case


def link_cases(
    db: Session,
    from_case: Case,
    to_case_id: str,
    reason: str,
    actor: AuthUser,
) -> CaseLink:
    if not reason or not reason.strip():
        raise WorkflowError("Link requires a relationship reason", requirement_ids=["FR-CASE-005"])
    target = get_case_by_id(db, to_case_id)
    link = CaseLink(
        from_case_id=from_case.id,
        to_case_id=target.id,
        relationship_reason=reason,
        linked_by=actor.id,
    )
    db.add(link)
    db.flush()
    record_audit(
        db,
        event_category="Case",
        entity_type="Case",
        entity_id=from_case.case_id,
        action="linked",
        actor_user_id=actor.id,
        actor_username=actor.username,
        after={"to_case_id": target.case_id, "reason": reason},
        reason=reason,
        rule_ids=["FR-CASE-005", "BR-014"],
    )
    return link


def find_historical_matches(db: Session, customer_id_normalized: str, exclude_case_id: str | None = None) -> list[dict]:
    """Surface potential historical RFV/RFI/STR matches — human confirmation required (FR-CASE-003/004)."""
    from src.configuration.models import Action, RFVRFI, STRCase

    q = db.query(Case).join(Customer).filter(Customer.customer_id_normalized == customer_id_normalized)
    if exclude_case_id:
        q = q.filter(Case.case_id != exclude_case_id)
    matches = []
    for case in q.all():
        rfv_count = db.query(RFVRFI).filter(RFVRFI.case_id == case.id).count()
        str_count = db.query(STRCase).filter(STRCase.case_id == case.id).count()
        open_actions = (
            db.query(Action)
            .filter(Action.case_id == case.id, Action.status.notin_(["COMPLETED", "CANCELLED", "CLOSED"]))
            .count()
        )
        matches.append(
            {
                "case_id": case.case_id,
                "stage": case.current_stage,
                "rfv_rfi_count": rfv_count,
                "str_count": str_count,
                "open_actions": open_actions,
                "requires_human_confirmation": True,
            }
        )
    return matches


def list_cases_for_user(db: Session, user: AuthUser, stage: str | None = None) -> list[Case]:
    q = db.query(Case)
    if user.can("case.view_all") or user.has_role("HOD", "SYSTEM_ADMIN", "AUDITOR"):
        pass
    else:
        q = q.filter(Case.current_owner_user_id == user.id)
    if stage:
        q = q.filter(Case.current_stage == stage)
    return q.order_by(Case.updated_at.desc()).all()


def open_required_actions(db: Session, case: Case) -> list:
    from src.configuration.models import Action

    return (
        db.query(Action)
        .filter(
            Action.case_id == case.id,
            Action.status.notin_(["COMPLETED", "CANCELLED", "CLOSED", "NOT_PROCEEDED"]),
        )
        .all()
    )