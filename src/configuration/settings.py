from __future__ import annotations

from functools import lru_cache
from pathlib import Path
from typing import Any

import yaml
from pydantic_settings import BaseSettings

ROOT = Path(__file__).resolve().parents[2]
CONFIG_DIR = ROOT / "config"
DATA_DIR = ROOT / "data"
UPLOAD_DIR = DATA_DIR / "uploads"
EXPORT_DIR = DATA_DIR / "exports"
DOC_STORE_DIR = DATA_DIR / "documents"


class Settings(BaseSettings):
    app_name: str = "AML Centralized Workflow Management"
    app_version: str = "1.0.0"
    timezone: str = "Asia/Kuala_Lumpur"
    database_url: str = f"sqlite:///{DATA_DIR / 'aml_workflow.db'}"
    secret_key: str = "pilot-change-me-not-for-production"
    session_timeout_minutes: int = 60
    rfv_response_days: int = 7
    rfi_response_days: int = 5
    action_due_soon_days: int = 2
    hod_review_due_days: int = 3
    monitoring_default_days: int = 30


def _load_yaml(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    with path.open("r", encoding="utf-8") as fh:
        return yaml.safe_load(fh) or {}


@lru_cache
def get_settings() -> Settings:
    raw = _load_yaml(CONFIG_DIR / "settings.yaml")
    app = raw.get("app", {})
    db = raw.get("database", {})
    auth = raw.get("auth", {})
    sla = raw.get("sla", {})
    return Settings(
        app_name=app.get("name", "AML Centralized Workflow Management"),
        app_version=app.get("version", "1.0.0"),
        timezone=app.get("timezone", "Asia/Kuala_Lumpur"),
        database_url=db.get("url", f"sqlite:///{DATA_DIR / 'aml_workflow.db'}"),
        session_timeout_minutes=auth.get("session_timeout_minutes", 60),
        rfv_response_days=sla.get("rfv_response_days", 7),
        rfi_response_days=sla.get("rfi_response_days", 5),
        action_due_soon_days=sla.get("action_due_soon_days", 2),
        hod_review_due_days=sla.get("hod_review_due_days", 3),
        monitoring_default_days=sla.get("monitoring_default_days", 30),
    )


@lru_cache
def get_reference_data() -> dict[str, Any]:
    return _load_yaml(CONFIG_DIR / "reference_data.yaml")


def ensure_runtime_dirs() -> None:
    for path in (DATA_DIR, UPLOAD_DIR, EXPORT_DIR, DOC_STORE_DIR):
        path.mkdir(parents=True, exist_ok=True)