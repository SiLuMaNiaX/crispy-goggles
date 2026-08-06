from __future__ import annotations

from sqlalchemy.orm import Session

from src.configuration.models import Notification


def notify_user(
    db: Session,
    *,
    user_id: int,
    event_type: str,
    title: str,
    message: str,
    case_id: str | None = None,
) -> Notification:
    note = Notification(
        user_id=user_id,
        event_type=event_type,
        title=title,
        message=message,
        case_id=case_id,
    )
    db.add(note)
    db.flush()
    return note


def list_notifications(db: Session, user_id: int, unread_only: bool = False) -> list[Notification]:
    q = db.query(Notification).filter(Notification.user_id == user_id)
    if unread_only:
        q = q.filter(Notification.is_read.is_(False))
    return q.order_by(Notification.created_at.desc()).limit(100).all()


def mark_read(db: Session, notification_id: int, user_id: int) -> None:
    note = db.get(Notification, notification_id)
    if note and note.user_id == user_id:
        note.is_read = True
        db.commit()