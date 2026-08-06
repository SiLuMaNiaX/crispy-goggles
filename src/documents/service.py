from __future__ import annotations

import shutil
from pathlib import Path

from sqlalchemy.orm import Session

from src.audit.service import record_audit
from src.configuration.db import model_to_dict, utc_now
from src.configuration.errors import WorkflowError
from src.configuration.models import Case, Document
from src.configuration.settings import DOC_STORE_DIR
from src.identity_access.service import AuthUser


def register_document(
    db: Session,
    *,
    case: Case,
    actor: AuthUser,
    source_path: Path,
    original_filename: str,
    action_id: int | None = None,
    content_type: str | None = None,
    notes: str | None = None,
) -> Document:
    case_dir = DOC_STORE_DIR / case.case_id
    case_dir.mkdir(parents=True, exist_ok=True)
    dest = case_dir / f"{utc_now().strftime('%Y%m%d%H%M%S')}_{original_filename}"
    shutil.copy2(source_path, dest)
    doc = Document(
        case_id=case.id,
        action_id=action_id,
        filename=original_filename,
        storage_uri=str(dest),
        content_type=content_type,
        verification_status="NOT_REVIEWED",
        uploaded_by=actor.id,
        notes=notes,
    )
    db.add(doc)
    db.flush()
    record_audit(
        db,
        event_category="Document",
        entity_type="Document",
        entity_id=str(doc.id),
        action="added",
        actor_user_id=actor.id,
        actor_username=actor.username,
        after=model_to_dict(doc),
        rule_ids=["FR-DOC-001"],
    )
    db.commit()
    db.refresh(doc)
    return doc


def verify_document(db: Session, doc: Document, actor: AuthUser, status: str) -> Document:
    status = status.upper().strip()
    if status not in {"VERIFIED", "REJECTED", "NOT_APPLICABLE", "NOT_REVIEWED"}:
        raise WorkflowError("Invalid verification status")
    before = model_to_dict(doc)
    doc.verification_status = status
    db.flush()
    record_audit(
        db,
        event_category="Document",
        entity_type="Document",
        entity_id=str(doc.id),
        action="verified",
        actor_user_id=actor.id,
        actor_username=actor.username,
        before=before,
        after=model_to_dict(doc),
    )
    db.commit()
    db.refresh(doc)
    return doc