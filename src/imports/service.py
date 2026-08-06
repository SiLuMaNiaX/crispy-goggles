from __future__ import annotations

import hashlib
import json
import shutil
from pathlib import Path
from typing import Any

from openpyxl import Workbook, load_workbook
from sqlalchemy.orm import Session

from src.audit.service import record_audit
from src.case_core.service import create_case, get_or_create_customer
from src.configuration.db import utc_now
from src.configuration.errors import WorkflowError
from src.configuration.models import Alert, AlertImportRow, ImportBatch
from src.configuration.normalization import as_text, normalize_identifier, parse_excel_cell
from src.configuration.settings import UPLOAD_DIR
from src.identity_access.service import AuthUser, resolve_pic_to_user

REQUIRED_COLUMNS = ["Alert ID", "Customer ID", "Customer Name", "Assigned PIC"]
OPTIONAL_COLUMNS = ["Account Number", "Alert Date", "Alert Type", "Amount"]


def _file_hash(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def _next_batch_id(db: Session) -> str:
    count = db.query(ImportBatch).count() + 1
    stamp = utc_now().strftime("%Y%m%d")
    return f"IMP-{stamp}-{count:04d}"


def import_predator_extract(
    db: Session,
    *,
    source_path: Path,
    original_filename: str,
    actor: AuthUser,
    sheet_name: str | None = None,
) -> ImportBatch:
    """Import authorized .xlsx Predator extract without modifying the source (FR-IMP-001..006)."""
    if source_path.suffix.lower() != ".xlsx":
        raise WorkflowError("Only .xlsx Predator extracts are supported", requirement_ids=["FR-IMP-001"])

    stored = UPLOAD_DIR / f"{utc_now().strftime('%Y%m%d%H%M%S')}_{original_filename}"
    shutil.copy2(source_path, stored)
    file_hash = _file_hash(stored)

    wb = load_workbook(stored, data_only=True, read_only=True)
    ws = wb[sheet_name] if sheet_name and sheet_name in wb.sheetnames else wb[wb.sheetnames[0]]
    rows_iter = ws.iter_rows(values_only=True)
    try:
        header_row = next(rows_iter)
    except StopIteration as exc:
        raise WorkflowError("Empty worksheet", requirement_ids=["FR-IMP-003"]) from exc

    headers = [parse_excel_cell(h) for h in header_row]
    missing = [c for c in REQUIRED_COLUMNS if c not in headers]
    if missing:
        raise WorkflowError(
            f"Missing required columns: {', '.join(missing)}",
            requirement_ids=["FR-IMP-003"],
            fields={c: "required" for c in missing},
        )
    col_index = {name: headers.index(name) for name in headers if name}

    batch = ImportBatch(
        batch_id=_next_batch_id(db),
        filename=original_filename,
        file_hash=file_hash,
        sheet_name=ws.title,
        imported_by=actor.id,
        status="PROCESSING",
    )
    db.add(batch)
    db.flush()

    imported = duplicate = exception = ignored = 0
    source_rows = 0

    for row_no, row in enumerate(rows_iter, start=2):
        source_rows += 1
        values = {name: parse_excel_cell(row[idx]) if idx < len(row) else "" for name, idx in col_index.items()}

        # Ignore summary/blank rows
        if not any(values.get(c) for c in REQUIRED_COLUMNS):
            ignored += 1
            db.add(
                AlertImportRow(
                    batch_id=batch.id,
                    source_row_no=row_no,
                    alert_id_raw=None,
                    raw_json=json.dumps(values),
                    disposition="ignored",
                    disposition_reason="Blank/non-operational row",
                )
            )
            continue

        alert_id = as_text(values.get("Alert ID", "")).strip()
        customer_id_raw = as_text(values.get("Customer ID", "")).strip()
        customer_name = as_text(values.get("Customer Name", "")).strip()
        pic_raw = as_text(values.get("Assigned PIC", "")).strip()

        row_errors = []
        if not alert_id:
            row_errors.append("Alert ID required")
        if not customer_id_raw:
            row_errors.append("Customer ID required")
        if not customer_name:
            row_errors.append("Customer Name required")
        if not pic_raw:
            row_errors.append("Assigned PIC required")

        if row_errors:
            exception += 1
            db.add(
                AlertImportRow(
                    batch_id=batch.id,
                    source_row_no=row_no,
                    alert_id_raw=alert_id or None,
                    raw_json=json.dumps(values),
                    disposition="exception",
                    disposition_reason="; ".join(row_errors),
                )
            )
            continue

        existing = db.query(Alert).filter(Alert.alert_id == alert_id).one_or_none()
        if existing:
            duplicate += 1
            db.add(
                AlertImportRow(
                    batch_id=batch.id,
                    source_row_no=row_no,
                    alert_id_raw=alert_id,
                    raw_json=json.dumps(values),
                    disposition="duplicate",
                    disposition_reason=f"Alert ID already exists (case {existing.case.case_id if existing.case else 'n/a'})",
                    alert_id=existing.id,
                )
            )
            continue

        pic_user = resolve_pic_to_user(db, pic_raw)
        customer = get_or_create_customer(db, customer_id_raw, customer_name)
        case = create_case(
            db,
            customer=customer,
            owner_user_id=pic_user.id if pic_user else actor.id,
            actor=actor,
            stage="ASSIGNED" if pic_user else "IMPORT_EXCEPTION",
        )

        alert = Alert(
            alert_id=alert_id,
            case_id=case.id,
            source_batch_id=batch.id,
            source_row_no=row_no,
            customer_id_raw=customer_id_raw,
            customer_id_normalized=normalize_identifier(customer_id_raw),
            customer_name_raw=customer_name,
            account_number_raw=as_text(values.get("Account Number", "")) or None,
            assigned_pic_raw=pic_raw,
            assigned_user_id=pic_user.id if pic_user else None,
            alert_date_raw=as_text(values.get("Alert Date", "")) or None,
            alert_type_raw=as_text(values.get("Alert Type", "")) or None,
            amount_raw=as_text(values.get("Amount", "")) or None,
            raw_payload_json=json.dumps(values),
        )
        db.add(alert)
        db.flush()

        if not pic_user:
            exception += 1  # countable as exception for unmapped PIC, but alert still imported linked
            disposition = "exception"
            reason = f"PIC '{pic_raw}' could not be mapped to an internal user; case created in IMPORT_EXCEPTION"
        else:
            imported += 1
            disposition = "imported"
            reason = None

        # If PIC mapped, count as imported even though we may have already incremented exception above
        if pic_user:
            pass
        else:
            # Reclassify: alert exists but exception for mapping — still create row as exception
            # Adjust: we already incremented exception; do not also count imported
            pass

        db.add(
            AlertImportRow(
                batch_id=batch.id,
                source_row_no=row_no,
                alert_id_raw=alert_id,
                raw_json=json.dumps(values),
                disposition=disposition,
                disposition_reason=reason,
                alert_id=alert.id,
            )
        )
        if not pic_user:
            # already counted exception; ensure not double-counted as imported
            pass
        elif disposition == "imported":
            pass

    # Fix imported count for PIC-mapped rows only — recompute from rows for accuracy
    db.flush()
    imported = db.query(AlertImportRow).filter(AlertImportRow.batch_id == batch.id, AlertImportRow.disposition == "imported").count()
    duplicate = db.query(AlertImportRow).filter(AlertImportRow.batch_id == batch.id, AlertImportRow.disposition == "duplicate").count()
    exception = db.query(AlertImportRow).filter(AlertImportRow.batch_id == batch.id, AlertImportRow.disposition == "exception").count()
    ignored = db.query(AlertImportRow).filter(AlertImportRow.batch_id == batch.id, AlertImportRow.disposition == "ignored").count()

    batch.total_source_rows = source_rows
    batch.imported_count = imported
    batch.duplicate_count = duplicate
    batch.exception_count = exception
    batch.ignored_count = ignored
    batch.status = "COMPLETED"
    db.flush()

    record_audit(
        db,
        event_category="Import",
        entity_type="ImportBatch",
        entity_id=batch.batch_id,
        action="batch_imported",
        actor_user_id=actor.id,
        actor_username=actor.username,
        after={
            "batch_id": batch.batch_id,
            "filename": original_filename,
            "file_hash": file_hash,
            "sheet": batch.sheet_name,
            "total_source_rows": source_rows,
            "imported": imported,
            "duplicate": duplicate,
            "exception": exception,
            "ignored": ignored,
            "reconcile": source_rows == imported + duplicate + exception + ignored,
        },
        rule_ids=["FR-IMP-001", "FR-IMP-002", "FR-IMP-004", "BR-002"],
    )
    db.commit()
    db.refresh(batch)
    return batch


def reconciliation_ok(batch: ImportBatch) -> bool:
    return batch.total_source_rows == (
        batch.imported_count + batch.duplicate_count + batch.exception_count + batch.ignored_count
    )


def create_sample_predator_file(path: Path) -> Path:
    wb = Workbook()
    ws = wb.active
    ws.title = "Alerts"
    ws.append(
        [
            "Alert ID",
            "Customer ID",
            "Customer Name",
            "Assigned PIC",
            "Account Number",
            "Alert Date",
            "Alert Type",
            "Amount",
        ]
    )
    ws.append(["ALT-0001", "00123456", "Ahmad Bin Ali", "aml.officer.a", "00098765", "01/08/2026", "Cash Structuring", "95000"])
    ws.append(["ALT-0002", "00123456", "Ahmad Bin Ali", "aml.officer.a", "00098765", "02/08/2026", "Rapid Movement", "120000"])
    ws.append(["ALT-0003", "00998877", "Siti Aminah", "aml.officer.b", "00112233", "03/08/2026", "High Risk Country", "45000"])
    ws.append(["ALT-0004", "00001122", "Tan Wei Ming", "aml.officer.b", "00445566", "04/08/2026", "Unusual Pattern", "78000"])
    ws.append(["", "", "", "", "", "", "", ""])  # ignored blank
    path.parent.mkdir(parents=True, exist_ok=True)
    wb.save(path)
    return path


def batch_to_dict(batch: ImportBatch) -> dict[str, Any]:
    return {
        "batch_id": batch.batch_id,
        "filename": batch.filename,
        "file_hash": batch.file_hash,
        "sheet_name": batch.sheet_name,
        "imported_at": batch.imported_at.isoformat() if batch.imported_at else None,
        "total_source_rows": batch.total_source_rows,
        "imported_count": batch.imported_count,
        "duplicate_count": batch.duplicate_count,
        "exception_count": batch.exception_count,
        "ignored_count": batch.ignored_count,
        "status": batch.status,
        "reconciled": reconciliation_ok(batch),
    }