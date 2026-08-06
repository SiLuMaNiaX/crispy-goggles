from __future__ import annotations

import tempfile
from pathlib import Path
from typing import Annotated, Any, Optional

from fastapi import Depends, FastAPI, File, Form, HTTPException, Request, UploadFile
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session, joinedload

from src.actions import service as actions_svc
from src.audit.service import list_audit_for_entity, list_case_history
from src.case_core import closure as closure_svc
from src.case_core import service as case_svc
from src.communications import service as comms_svc
from src.configuration.bootstrap import bootstrap_db
from src.configuration.db import Base, get_db, init_engine, model_to_dict
from src.configuration.errors import WorkflowError
from src.configuration.models import (
    Action,
    Alert,
    Case,
    Customer,
    FreezeAction,
    HODReview,
    ImportBatch,
    Investigation,
    RFVRFI,
    STRCase,
    User,
)
from src.configuration.settings import ROOT, ensure_runtime_dirs, get_reference_data, get_settings
from src.documents import service as docs_svc
from src.freeze import service as freeze_svc
from src.hod_review import service as hod_svc
from src.identity_access.service import (
    DEFAULT_PASSWORD,
    AuthUser,
    authenticate,
    list_users,
    require_permission,
)
from src.imports import service as import_svc
from src.investigation import service as inv_svc
from src.reporting import service as reporting_svc
from src.reporting.notifications import list_notifications, mark_read
from src.rfv_rfi import service as rfv_svc
from src.str_workflow import service as str_svc

ensure_runtime_dirs()
init_engine()
from src.configuration.db import SessionLocal, engine  # noqa: E402

Base.metadata.create_all(bind=engine)
with SessionLocal() as _db:
    bootstrap_db(_db)

settings = get_settings()
app = FastAPI(title=settings.app_name, version=settings.app_version)

STATIC_DIR = Path(__file__).resolve().parent / "web" / "static"
TEMPLATES_DIR = Path(__file__).resolve().parent / "web" / "templates"
app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")
templates = Jinja2Templates(directory=str(TEMPLATES_DIR))

# Simple cookie session for pilot intranet auth
SESSIONS: dict[str, AuthUser] = {}


def _set_session(response, user: AuthUser) -> str:
    import secrets

    token = secrets.token_urlsafe(24)
    SESSIONS[token] = user
    response.set_cookie("aml_session", token, httponly=True, samesite="lax")
    return token


def current_user(request: Request) -> AuthUser | None:
    token = request.cookies.get("aml_session")
    if not token:
        return None
    return SESSIONS.get(token)


def require_user(request: Request) -> AuthUser:
    user = current_user(request)
    if not user:
        raise WorkflowError("Authentication required", status_code=401)
    return user


@app.exception_handler(WorkflowError)
async def workflow_error_handler(request: Request, exc: WorkflowError):
    accept = request.headers.get("accept", "")
    if "text/html" in accept and not request.url.path.startswith("/api"):
        user = current_user(request)
        return templates.TemplateResponse(
            "error.html",
            {"request": request, "user": user, "error": exc.to_dict(), "status_code": exc.status_code},
            status_code=exc.status_code,
        )
    return JSONResponse(status_code=exc.status_code, content=exc.to_dict())


# ---------- Auth ----------


class LoginBody(BaseModel):
    username: str
    password: str


@app.post("/api/login")
def api_login(body: LoginBody, db: Session = Depends(get_db)):
    user = authenticate(db, body.username, body.password)
    response = JSONResponse({"username": user.username, "display_name": user.display_name, "roles": user.roles})
    _set_session(response, user)
    return response


@app.post("/login")
def web_login(
    request: Request,
    username: str = Form(...),
    password: str = Form(...),
    db: Session = Depends(get_db),
):
    user = authenticate(db, username, password)
    response = RedirectResponse("/my-work", status_code=303)
    _set_session(response, user)
    return response


@app.post("/logout")
@app.get("/logout")
def logout():
    response = RedirectResponse("/login", status_code=303)
    response.delete_cookie("aml_session")
    return response


# ---------- Pages ----------


@app.get("/login", response_class=HTMLResponse)
def login_page(request: Request):
    return templates.TemplateResponse(
        "login.html",
        {"request": request, "default_password": DEFAULT_PASSWORD, "users": get_reference_data().get("users", [])},
    )


@app.get("/", response_class=HTMLResponse)
def home(request: Request):
    if not current_user(request):
        return RedirectResponse("/login")
    return RedirectResponse("/my-work")


def _case_row(db: Session, case: Case, user: AuthUser) -> dict[str, Any]:
    alerts = db.query(Alert).filter(Alert.case_id == case.id).all()
    customer = db.get(Customer, case.customer_id) if case.customer_id else None
    owner = db.get(User, case.current_owner_user_id) if case.current_owner_user_id else None
    matches = []
    if customer:
        matches = case_svc.find_historical_matches(db, customer.customer_id_normalized, case.case_id)
    gate = closure_svc.closure_completeness(db, case) if case.current_stage in {"CLOSURE_REVIEW", "CLOSED"} else None
    open_actions = case_svc.open_required_actions(db, case)
    return {
        "case": case,
        "alert_ids": [a.alert_id for a in alerts],
        "customer_name": customer.customer_name if customer else "",
        "customer_id": customer.customer_id_normalized if customer else "",
        "owner_name": owner.display_name if owner else "",
        "historical_matches": matches,
        "open_actions_count": len(open_actions),
        "completeness": gate.to_dict() if gate else None,
        "next_action": _next_action_label(case),
    }


def _next_action_label(case: Case) -> str:
    mapping = {
        "ASSIGNED": "Start investigation",
        "UNDER_INVESTIGATION": "Record officer outcome",
        "PENDING_HOD_REVIEW": "HOD direction required",
        "RETURNED_TO_OFFICER": "Revise investigation",
        "ACTION_OPEN": "Complete directed action",
        "CLOSURE_REVIEW": "Close case / resolve outstanding",
        "NON_SUSPICIOUS_REVIEW": "Confirm closure",
        "CLOSED": "Locked",
        "IMPORT_EXCEPTION": "Resolve PIC mapping",
    }
    return mapping.get(case.current_stage, case.current_stage)


@app.get("/my-work", response_class=HTMLResponse)
def my_work(request: Request, db: Session = Depends(get_db)):
    user = require_user(request)
    cases = case_svc.list_cases_for_user(db, user)
    rows = [_case_row(db, c, user) for c in cases if c.current_status != "CLOSED" or user.has_role("HOD", "AUDITOR")]
    notes = list_notifications(db, user.id, unread_only=True)
    return templates.TemplateResponse(
        "my_work.html",
        {"request": request, "user": user, "rows": rows, "notifications": notes, "page": "my-work"},
    )


@app.get("/hod-review", response_class=HTMLResponse)
def hod_review_page(request: Request, db: Session = Depends(get_db)):
    user = require_user(request)
    require_permission(user, "hod.review")
    cases = hod_svc.list_pending_hod_queue(db)
    rows = [_case_row(db, c, user) for c in cases]
    return templates.TemplateResponse(
        "hod_queue.html",
        {"request": request, "user": user, "rows": rows, "page": "hod-review"},
    )


@app.get("/imports", response_class=HTMLResponse)
def imports_page(request: Request, db: Session = Depends(get_db)):
    user = require_user(request)
    require_permission(user, "import.batch")
    batches = db.query(ImportBatch).order_by(ImportBatch.imported_at.desc()).all()
    return templates.TemplateResponse(
        "imports.html",
        {
            "request": request,
            "user": user,
            "batches": [import_svc.batch_to_dict(b) for b in batches],
            "page": "imports",
        },
    )


@app.post("/imports/upload")
async def upload_import(
    request: Request,
    file: UploadFile = File(...),
    db: Session = Depends(get_db),
):
    user = require_user(request)
    require_permission(user, "import.batch")
    suffix = Path(file.filename or "upload.xlsx").suffix
    with tempfile.NamedTemporaryFile(delete=False, suffix=suffix) as tmp:
        tmp.write(await file.read())
        tmp_path = Path(tmp.name)
    try:
        batch = import_svc.import_predator_extract(
            db, source_path=tmp_path, original_filename=file.filename or "upload.xlsx", actor=user
        )
    finally:
        tmp_path.unlink(missing_ok=True)
    return RedirectResponse(f"/imports?batch={batch.batch_id}", status_code=303)


@app.get("/cases/{case_id}", response_class=HTMLResponse)
def case_workspace(request: Request, case_id: str, db: Session = Depends(get_db)):
    user = require_user(request)
    case = case_svc.get_case_by_id(db, case_id)
    if not (
        user.can("case.view_all")
        or user.has_role("HOD", "SYSTEM_ADMIN", "AUDITOR", "STR_REVIEWER", "STR_SUBMITTER")
        or case.current_owner_user_id == user.id
    ):
        raise WorkflowError("Access denied", status_code=403)

    alerts = db.query(Alert).filter(Alert.case_id == case.id).all()
    customer = db.get(Customer, case.customer_id) if case.customer_id else None
    investigations = (
        db.query(Investigation).filter(Investigation.case_id == case.id).order_by(Investigation.created_at.desc()).all()
    )
    hod_reviews = db.query(HODReview).filter(HODReview.case_id == case.id).order_by(HODReview.created_at.desc()).all()
    actions = db.query(Action).options(
        joinedload(Action.rfv_rfi), joinedload(Action.freeze_action), joinedload(Action.str_case)
    ).filter(Action.case_id == case.id).all()
    history = list_audit_for_entity(db, "Case", case.case_id)
    matches = (
        case_svc.find_historical_matches(db, customer.customer_id_normalized, case.case_id) if customer else []
    )
    gate = closure_svc.closure_completeness(db, case)
    users = list_users(db)
    offences = get_reference_data().get("offences", [])
    branches = get_reference_data().get("branches", [])
    directions = get_reference_data().get("hod_directions", [])

    return templates.TemplateResponse(
        "case_workspace.html",
        {
            "request": request,
            "user": user,
            "case": case,
            "alerts": alerts,
            "customer": customer,
            "investigations": investigations,
            "hod_reviews": hod_reviews,
            "actions": actions,
            "history": history,
            "matches": matches,
            "completeness": gate.to_dict(),
            "users": users,
            "offences": offences,
            "branches": branches,
            "directions": directions,
            "page": "cases",
        },
    )


@app.get("/dashboards", response_class=HTMLResponse)
def dashboards(request: Request, db: Session = Depends(get_db)):
    user = require_user(request)
    data = reporting_svc.dashboard_for(db, user)
    return templates.TemplateResponse(
        "dashboard.html",
        {"request": request, "user": user, "data": data, "page": "dashboards"},
    )


@app.get("/rfv-rfi", response_class=HTMLResponse)
def rfv_list(request: Request, db: Session = Depends(get_db)):
    user = require_user(request)
    q = db.query(RFVRFI)
    if not user.has_role("HOD", "SYSTEM_ADMIN", "AUDITOR"):
        q = q.join(Action).filter(Action.owner_user_id == user.id)
    records = q.order_by(RFVRFI.updated_at.desc()).all()
    case_map = {c.id: c.case_id for c in db.query(Case).all()}
    rows = [{"record": r, "case_id": case_map.get(r.case_id, "")} for r in records]
    return templates.TemplateResponse(
        "rfv_list.html",
        {"request": request, "user": user, "rows": rows, "page": "rfv-rfi"},
    )


@app.get("/freeze", response_class=HTMLResponse)
def freeze_list(request: Request, db: Session = Depends(get_db)):
    user = require_user(request)
    records = db.query(FreezeAction).order_by(FreezeAction.updated_at.desc()).all()
    return templates.TemplateResponse(
        "freeze_list.html",
        {"request": request, "user": user, "records": records, "page": "freeze"},
    )


@app.get("/str", response_class=HTMLResponse)
def str_list(request: Request, db: Session = Depends(get_db)):
    user = require_user(request)
    records = db.query(STRCase).order_by(STRCase.updated_at.desc()).all()
    return templates.TemplateResponse(
        "str_list.html",
        {"request": request, "user": user, "records": records, "page": "str"},
    )


# ---------- Case actions (forms) ----------


@app.post("/cases/{case_id}/investigation/start")
def start_inv(case_id: str, request: Request, db: Session = Depends(get_db)):
    user = require_user(request)
    case = case_svc.get_case_by_id(db, case_id)
    inv_svc.start_investigation(db, case, user)
    return RedirectResponse(f"/cases/{case_id}#investigation", status_code=303)


@app.post("/cases/{case_id}/investigation/non-suspicious")
def inv_non_suspicious(
    case_id: str,
    request: Request,
    assessment_summary: str = Form(...),
    predator_reference: str = Form(""),
    predator_disposition_confirmed: Optional[str] = Form(None),
    db: Session = Depends(get_db),
):
    user = require_user(request)
    case = case_svc.get_case_by_id(db, case_id)
    inv_svc.complete_non_suspicious(
        db,
        case,
        user,
        assessment_summary=assessment_summary,
        predator_disposition_confirmed=predator_disposition_confirmed == "on",
        predator_reference=predator_reference or None,
    )
    return RedirectResponse(f"/cases/{case_id}#investigation", status_code=303)


@app.post("/cases/{case_id}/investigation/suspicious")
def inv_suspicious(
    case_id: str,
    request: Request,
    assessment_summary: str = Form(...),
    grounds_for_suspicion: str = Form(...),
    suspected_offence_code: str = Form(...),
    recommendation: str = Form(""),
    predator_reference: str = Form(""),
    db: Session = Depends(get_db),
):
    user = require_user(request)
    case = case_svc.get_case_by_id(db, case_id)
    inv_svc.refer_suspicious(
        db,
        case,
        user,
        assessment_summary=assessment_summary,
        grounds_for_suspicion=grounds_for_suspicion,
        suspected_offence_code=suspected_offence_code,
        recommendation=recommendation or None,
        predator_reference=predator_reference or None,
    )
    return RedirectResponse(f"/cases/{case_id}#hod", status_code=303)


@app.post("/cases/{case_id}/hod/direct")
def hod_direct(
    case_id: str,
    request: Request,
    direction_code: str = Form(...),
    direction_remarks: str = Form(""),
    action_owner_id: Optional[int] = Form(None),
    priority: str = Form("NORMAL"),
    link_target_case_id: str = Form(""),
    description: str = Form(""),
    db: Session = Depends(get_db),
):
    user = require_user(request)
    case = case_svc.get_case_by_id(db, case_id)
    hod_svc.record_hod_direction(
        db,
        case,
        user,
        direction_code=direction_code,
        direction_remarks=direction_remarks or None,
        action_owner_id=action_owner_id,
        priority=priority,
        link_target_case_id=link_target_case_id or None,
        description=description or None,
    )
    return RedirectResponse(f"/cases/{case_id}#actions", status_code=303)


@app.post("/cases/{case_id}/close")
def close_case_form(
    case_id: str,
    request: Request,
    final_outcome: str = Form(...),
    closure_rationale: str = Form(...),
    db: Session = Depends(get_db),
):
    user = require_user(request)
    case = case_svc.get_case_by_id(db, case_id)
    closure_svc.close_case(db, case, user, final_outcome=final_outcome, closure_rationale=closure_rationale)
    return RedirectResponse(f"/cases/{case_id}", status_code=303)


@app.post("/rfv-rfi/{rfv_rfi_id}/send")
def rfv_send(
    rfv_rfi_id: str,
    request: Request,
    branch_code: str = Form(...),
    recipient: str = Form(...),
    requested_information: str = Form(...),
    db: Session = Depends(get_db),
):
    user = require_user(request)
    rec = rfv_svc.get_rfv_rfi(db, rfv_rfi_id)
    rfv_svc.mark_sent(
        db,
        rec,
        user,
        branch_code=branch_code,
        recipient=recipient,
        requested_information=requested_information,
    )
    case = db.get(Case, rec.case_id)
    return RedirectResponse(f"/cases/{case.case_id}#rfv", status_code=303)


@app.post("/rfv-rfi/{rfv_rfi_id}/response")
def rfv_response(
    rfv_rfi_id: str,
    request: Request,
    response_status: str = Form(...),
    db: Session = Depends(get_db),
):
    user = require_user(request)
    rec = rfv_svc.get_rfv_rfi(db, rfv_rfi_id)
    rfv_svc.record_response(db, rec, user, response_status)
    case = db.get(Case, rec.case_id)
    return RedirectResponse(f"/cases/{case.case_id}#rfv", status_code=303)


@app.post("/rfv-rfi/{rfv_rfi_id}/complete")
def rfv_complete(
    rfv_rfi_id: str,
    request: Request,
    evidence_assessment: str = Form(...),
    final_conclusion: str = Form(...),
    post_assessment_route: str = Form(...),
    db: Session = Depends(get_db),
):
    user = require_user(request)
    rec = rfv_svc.get_rfv_rfi(db, rfv_rfi_id)
    rfv_svc.complete_assessment(
        db,
        rec,
        user,
        evidence_assessment=evidence_assessment,
        final_conclusion=final_conclusion,
        post_assessment_route=post_assessment_route,
    )
    case = db.get(Case, rec.case_id)
    return RedirectResponse(f"/cases/{case.case_id}#rfv", status_code=303)


@app.post("/freeze/{freeze_id}/update")
def freeze_update(
    freeze_id: str,
    request: Request,
    status: str = Form(...),
    external_reference: str = Form(""),
    affected_account_raw: str = Form(""),
    outcome: str = Form(""),
    creates_str_obligation: Optional[str] = Form(None),
    notes: str = Form(""),
    db: Session = Depends(get_db),
):
    user = require_user(request)
    rec = freeze_svc.get_freeze(db, freeze_id)
    freeze_svc.update_freeze_status(
        db,
        rec,
        user,
        status=status,
        external_reference=external_reference or None,
        affected_account_raw=affected_account_raw or None,
        outcome=outcome or None,
        creates_str_obligation=creates_str_obligation == "on",
        notes=notes or None,
    )
    case = db.get(Case, rec.case_id)
    return RedirectResponse(f"/cases/{case.case_id}#freeze", status_code=303)


@app.post("/str/{str_case_id}/draft")
def str_draft(
    str_case_id: str,
    request: Request,
    narrative: str = Form(""),
    grounds_for_suspicion: str = Form(""),
    primary_offence_code: str = Form(""),
    reporting_type: str = Form("INITIAL"),
    mark_draft_completed: Optional[str] = Form(None),
    db: Session = Depends(get_db),
):
    user = require_user(request)
    rec = str_svc.get_str(db, str_case_id)
    str_svc.update_draft(
        db,
        rec,
        user,
        narrative=narrative or None,
        grounds_for_suspicion=grounds_for_suspicion or None,
        primary_offence_code=primary_offence_code or None,
        reporting_type=reporting_type,
        mark_draft_completed=mark_draft_completed == "on",
    )
    case = db.get(Case, rec.case_id)
    return RedirectResponse(f"/cases/{case.case_id}#str", status_code=303)


@app.post("/str/{str_case_id}/review")
def str_review_form(
    str_case_id: str,
    request: Request,
    decision: str = Form(...),
    remarks: str = Form(""),
    db: Session = Depends(get_db),
):
    user = require_user(request)
    rec = str_svc.get_str(db, str_case_id)
    str_svc.review_str(db, rec, user, decision=decision, remarks=remarks or None)
    case = db.get(Case, rec.case_id)
    return RedirectResponse(f"/cases/{case.case_id}#str", status_code=303)


@app.post("/str/{str_case_id}/submit")
def str_submit_form(
    str_case_id: str,
    request: Request,
    str_reference: str = Form(...),
    db: Session = Depends(get_db),
):
    user = require_user(request)
    rec = str_svc.get_str(db, str_case_id)
    str_svc.submit_str(db, rec, user, str_reference=str_reference)
    case = db.get(Case, rec.case_id)
    return RedirectResponse(f"/cases/{case.case_id}#str", status_code=303)


@app.post("/str/{str_case_id}/amend")
def str_amend_form(
    str_case_id: str,
    request: Request,
    amendment_text: str = Form(...),
    db: Session = Depends(get_db),
):
    user = require_user(request)
    rec = str_svc.get_str(db, str_case_id)
    str_svc.add_amendment(db, rec, user, amendment_text)
    case = db.get(Case, rec.case_id)
    return RedirectResponse(f"/cases/{case.case_id}#str", status_code=303)


@app.post("/exports/rfv-rfi")
def export_rfv(request: Request, db: Session = Depends(get_db)):
    user = require_user(request)
    require_permission(user, "export.run")
    job = reporting_svc.export_rfv_rfi_register(db, user)
    return RedirectResponse(f"/dashboards?exported={job.id}", status_code=303)


@app.get("/api/health")
def health():
    return {"status": "ok", "app": settings.app_name, "version": settings.app_version}