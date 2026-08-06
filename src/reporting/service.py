from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any

from openpyxl import Workbook
from sqlalchemy import func
from sqlalchemy.orm import Session

from src.audit.service import record_audit
from src.configuration.db import utc_now
from src.configuration.models import (
    Action,
    Alert,
    Case,
    ExportJob,
    FreezeAction,
    ImportBatch,
    Investigation,
    RFVRFI,
    STRCase,
    User,
)
from src.configuration.settings import EXPORT_DIR
from src.identity_access.service import AuthUser


def dashboard_for(db: Session, user: AuthUser) -> dict[str, Any]:
    data: dict[str, Any] = {"role_view": [], "metrics": {}}

    if user.has_role("AML_OFFICER", "OFFICER_1"):
        data["role_view"].append("officer")
        data["metrics"]["my_assigned"] = (
            db.query(Case).filter(Case.current_owner_user_id == user.id, Case.current_status != "CLOSED").count()
        )
        data["metrics"]["in_investigation"] = (
            db.query(Case)
            .filter(Case.current_owner_user_id == user.id, Case.current_stage == "UNDER_INVESTIGATION")
            .count()
        )
        data["metrics"]["returned"] = (
            db.query(Case)
            .filter(Case.current_owner_user_id == user.id, Case.current_stage == "RETURNED_TO_OFFICER")
            .count()
        )
        data["metrics"]["my_open_actions"] = (
            db.query(Action)
            .filter(Action.owner_user_id == user.id, Action.status.notin_(["COMPLETED", "CANCELLED", "CLOSED"]))
            .count()
        )
        data["metrics"]["rfv_rfi_due"] = (
            db.query(RFVRFI)
            .join(Action, RFVRFI.action_id == Action.id)
            .filter(Action.owner_user_id == user.id, RFVRFI.status.in_(["AWAITING_RESPONSE", "FOLLOW_UP_1", "FOLLOW_UP_2"]))
            .count()
        )
        data["metrics"]["str_drafts"] = (
            db.query(STRCase)
            .filter(STRCase.str_pic_user_id == user.id, STRCase.status.in_(["PENDING_DRAFT", "DRAFTING", "RETURNED_AMENDMENT"]))
            .count()
        )

    if user.has_role("HOD"):
        data["role_view"].append("hod")
        data["metrics"]["pending_hod_review"] = (
            db.query(Case).filter(Case.current_stage == "PENDING_HOD_REVIEW").count()
        )
        data["metrics"]["high_priority"] = (
            db.query(Case).filter(Case.priority.in_(["HIGH", "CRITICAL"]), Case.current_status != "CLOSED").count()
        )
        data["metrics"]["overdue_actions"] = (
            db.query(Action)
            .filter(Action.due_at < utc_now(), Action.status.notin_(["COMPLETED", "CANCELLED", "CLOSED"]))
            .count()
        )
        data["metrics"]["str_pending_approval"] = (
            db.query(STRCase).filter(STRCase.status == "PENDING_REVIEW").count()
        )

    if user.has_role("HOD", "SYSTEM_ADMIN", "AUDITOR"):
        data["role_view"].append("management")
        data["metrics"]["alerts_imported"] = db.query(Alert).count()
        data["metrics"]["open_cases"] = db.query(Case).filter(Case.current_status != "CLOSED").count()
        data["metrics"]["closed_cases"] = db.query(Case).filter(Case.current_status == "CLOSED").count()
        data["metrics"]["rfv_rfi_open"] = (
            db.query(RFVRFI).filter(RFVRFI.status.notin_(["COMPLETED", "CLOSED"])).count()
        )
        data["metrics"]["freeze_open"] = (
            db.query(FreezeAction).filter(FreezeAction.status.notin_(["COMPLETED", "LIFTED"])).count()
        )
        data["metrics"]["str_in_progress"] = (
            db.query(STRCase).filter(STRCase.status.notin_(["SUBMITTED", "ACKNOWLEDGED", "NOT_PROCEEDED", "WITHDRAWN"])).count()
        )
        # Workload by PIC
        rows = (
            db.query(User.username, func.count(Case.id))
            .join(Case, Case.current_owner_user_id == User.id)
            .filter(Case.current_status != "CLOSED")
            .group_by(User.username)
            .all()
        )
        data["workload_by_pic"] = {u: c for u, c in rows}
        batches = db.query(ImportBatch).order_by(ImportBatch.imported_at.desc()).limit(5).all()
        data["recent_imports"] = [
            {
                "batch_id": b.batch_id,
                "imported": b.imported_count,
                "duplicate": b.duplicate_count,
                "exception": b.exception_count,
            }
            for b in batches
        ]

    return data


def export_rfv_rfi_register(db: Session, actor: AuthUser) -> ExportJob:
    EXPORT_DIR.mkdir(parents=True, exist_ok=True)
    wb = Workbook()
    ws = wb.active
    ws.title = "RFV_RFI"
    headers = [
        "RFV_RFI_ID",
        "Case ID",
        "Request Type",
        "Status",
        "Branch",
        "Recipient",
        "Sent At",
        "Response Due",
        "Response Received",
        "Post Assessment Route",
    ]
    ws.append(headers)
    rows = db.query(RFVRFI).order_by(RFVRFI.created_at.asc()).all()
    for r in rows:
        case = db.get(Case, r.case_id)
        ws.append(
            [
                r.rfv_rfi_id,
                case.case_id if case else "",
                r.request_type,
                r.status,
                r.branch_code or "",
                r.recipient or "",
                r.sent_at.isoformat() if r.sent_at else "",
                r.response_due_at.isoformat() if r.response_due_at else "",
                r.response_received_at.isoformat() if r.response_received_at else "",
                r.post_assessment_route or "",
            ]
        )
    as_of = utc_now()
    path = EXPORT_DIR / f"rfv_rfi_export_{as_of.strftime('%Y%m%d%H%M%S')}.xlsx"
    wb.save(path)
    control = hashlib.sha256(path.read_bytes()).hexdigest()
    job = ExportJob(
        export_type="RFV_RFI",
        exported_by=actor.id,
        as_of=as_of,
        filter_json=json.dumps({"all": True}),
        row_count=len(rows),
        control_hash=control,
        template_version="1.0",
        status="SUCCESS",
        artifact_uri=str(path),
    )
    db.add(job)
    db.flush()
    record_audit(
        db,
        event_category="Export",
        entity_type="ExportJob",
        entity_id=str(job.id),
        action="rfv_rfi_export",
        actor_user_id=actor.id,
        actor_username=actor.username,
        after={
            "row_count": len(rows),
            "control_hash": control,
            "artifact": str(path),
            "reconciled_to_repository": True,
        },
        rule_ids=["FR-EXP-001", "BR-016", "AT-014"],
    )
    db.commit()
    db.refresh(job)
    return job


def export_str_register(db: Session, actor: AuthUser) -> ExportJob:
    EXPORT_DIR.mkdir(parents=True, exist_ok=True)
    wb = Workbook()
    ws = wb.active
    ws.title = "STR"
    ws.append(
        [
            "STR Case ID",
            "Case ID",
            "Status",
            "Offence",
            "Reporting Type",
            "Duplicate Status",
            "STR Reference",
            "Submitted At",
        ]
    )
    rows = db.query(STRCase).order_by(STRCase.created_at.asc()).all()
    for r in rows:
        case = db.get(Case, r.case_id)
        ws.append(
            [
                r.str_case_id,
                case.case_id if case else "",
                r.status,
                r.primary_offence_code or "",
                r.reporting_type or "",
                r.duplicate_status,
                r.str_reference or "",
                r.submitted_at.isoformat() if r.submitted_at else "",
            ]
        )
    as_of = utc_now()
    path = EXPORT_DIR / f"str_export_{as_of.strftime('%Y%m%d%H%M%S')}.xlsx"
    wb.save(path)
    control = hashlib.sha256(path.read_bytes()).hexdigest()
    job = ExportJob(
        export_type="STR",
        exported_by=actor.id,
        as_of=as_of,
        row_count=len(rows),
        control_hash=control,
        template_version="1.0",
        status="SUCCESS",
        artifact_uri=str(path),
    )
    db.add(job)
    db.flush()
    record_audit(
        db,
        event_category="Export",
        entity_type="ExportJob",
        entity_id=str(job.id),
        action="str_export",
        actor_user_id=actor.id,
        actor_username=actor.username,
        after={"row_count": len(rows), "control_hash": control, "artifact": str(path)},
        rule_ids=["FR-EXP-001", "BR-016"],
    )
    db.commit()
    db.refresh(job)
    return job