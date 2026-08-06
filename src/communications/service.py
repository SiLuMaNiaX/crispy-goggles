from __future__ import annotations

from sqlalchemy.orm import Session

from src.audit.service import record_audit
from src.configuration.db import model_to_dict
from src.configuration.models import Case, Communication
from src.identity_access.service import AuthUser


def record_communication(
    db: Session,
    *,
    case: Case,
    actor: AuthUser,
    communication_type: str,
    subject: str | None = None,
    body: str | None = None,
    direction: str = "OUTBOUND",
    action_id: int | None = None,
    attachment_ref: str | None = None,
) -> Communication:
    # Automatic external email sending is out of scope (Section 3.3)
    rec = Communication(
        case_id=case.id,
        action_id=action_id,
        communication_type=communication_type,
        subject=subject,
        body=body,
        direction=direction,
        recorded_by=actor.id,
        attachment_ref=attachment_ref,
    )
    db.add(rec)
    db.flush()
    record_audit(
        db,
        event_category="Data",
        entity_type="Communication",
        entity_id=str(rec.id),
        action="recorded",
        actor_user_id=actor.id,
        actor_username=actor.username,
        after={**model_to_dict(rec), "auto_email_sent": False},
        rule_ids=["FR-COM-001"],
    )
    db.commit()
    db.refresh(rec)
    return rec