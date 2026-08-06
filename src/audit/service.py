from __future__ import annotations

import json
from typing import Any

from sqlalchemy.orm import Session

from src.configuration.models import AuditEvent


def record_audit(
    db: Session,
    *,
    event_category: str,
    entity_type: str,
    entity_id: str,
    action: str,
    actor_user_id: int | None = None,
    actor_username: str | None = None,
    before: dict[str, Any] | None = None,
    after: dict[str, Any] | None = None,
    reason: str | None = None,
    rule_ids: list[str] | None = None,
) -> AuditEvent:
    event = AuditEvent(
        event_category=event_category,
        entity_type=entity_type,
        entity_id=str(entity_id),
        action=action,
        actor_user_id=actor_user_id,
        actor_username=actor_username,
        before_json=json.dumps(before, default=str) if before is not None else None,
        after_json=json.dumps(after, default=str) if after is not None else "{}",
        reason=reason,
        rule_ids=",".join(rule_ids) if rule_ids else None,
    )
    db.add(event)
    db.flush()
    return event


def list_audit_for_entity(db: Session, entity_type: str, entity_id: str) -> list[AuditEvent]:
    return (
        db.query(AuditEvent)
        .filter(AuditEvent.entity_type == entity_type, AuditEvent.entity_id == str(entity_id))
        .order_by(AuditEvent.created_at.asc())
        .all()
    )


def list_case_history(db: Session, case_id: str) -> list[AuditEvent]:
    return (
        db.query(AuditEvent)
        .filter(
            ((AuditEvent.entity_type == "Case") & (AuditEvent.entity_id == case_id))
            | (AuditEvent.after_json.contains(f'"case_id": "{case_id}"'))
            | (AuditEvent.after_json.contains(f'"case_id":"{case_id}"'))
        )
        .order_by(AuditEvent.created_at.asc())
        .all()
    )