from __future__ import annotations

from datetime import datetime, timezone
from typing import Any

from sqlalchemy import create_engine, event
from sqlalchemy.orm import DeclarativeBase, Session, sessionmaker

from src.configuration.settings import ensure_runtime_dirs, get_settings


class Base(DeclarativeBase):
    pass


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


engine = None
SessionLocal: sessionmaker[Session] | None = None


def init_engine(url: str | None = None):
    global engine, SessionLocal
    ensure_runtime_dirs()
    settings = get_settings()
    db_url = url or settings.database_url
    connect_args = {"check_same_thread": False} if db_url.startswith("sqlite") else {}
    engine = create_engine(db_url, connect_args=connect_args, future=True)

    if db_url.startswith("sqlite"):

        @event.listens_for(engine, "connect")
        def _set_sqlite_pragma(dbapi_connection, connection_record):  # noqa: ARG001
            cursor = dbapi_connection.cursor()
            cursor.execute("PRAGMA foreign_keys=ON")
            cursor.close()

    SessionLocal = sessionmaker(bind=engine, autoflush=False, autocommit=False, future=True)
    return engine


def get_db():
    if SessionLocal is None:
        init_engine()
    assert SessionLocal is not None
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


def utc_now() -> datetime:
    return _utc_now()


def model_to_dict(obj: Any, exclude: set[str] | None = None) -> dict[str, Any]:
    exclude = exclude or set()
    result: dict[str, Any] = {}
    for col in obj.__table__.columns:
        if col.name in exclude:
            continue
        val = getattr(obj, col.name)
        if isinstance(val, datetime):
            result[col.name] = val.isoformat()
        else:
            result[col.name] = val
    return result