from __future__ import annotations

from sqlalchemy.orm import Session

from src.configuration.models import Branch, OffenceCode
from src.configuration.settings import get_reference_data
from src.identity_access.service import seed_users


def seed_reference_data(db: Session) -> None:
    ref = get_reference_data()
    if db.query(OffenceCode).count() == 0:
        for item in ref.get("offences", []):
            db.add(OffenceCode(code=item["code"], description=item["description"]))
    if db.query(Branch).count() == 0:
        for item in ref.get("branches", []):
            db.add(Branch(code=item["code"], name=item["name"]))
    db.commit()
    seed_users(db)


def bootstrap_db(db: Session) -> None:
    seed_reference_data(db)