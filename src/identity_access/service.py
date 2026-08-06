from __future__ import annotations

from dataclasses import dataclass

from passlib.context import CryptContext
from sqlalchemy.orm import Session

from src.audit.service import record_audit
from src.configuration.errors import WorkflowError
from src.configuration.models import User, UserRole
from src.configuration.settings import get_reference_data

pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")

# Pilot default password — change in production / directory sync
DEFAULT_PASSWORD = "ChangeMe1!"


ROLE_PERMISSIONS: dict[str, set[str]] = {
    "OFFICER_1": {
        "import.batch",
        "case.view_all_batches",
        "case.reassign",
        "case.view_own",
        "investigation.update_own",
    },
    "AML_OFFICER": {
        "case.view_own",
        "investigation.update_own",
        "investigation.refer_suspicious",
        "action.update_own",
        "rfv_rfi.update_own",
        "freeze.update_own",
        "str.draft_own",
        "document.upload",
        "communication.record",
    },
    "HOD": {
        "case.view_all",
        "hod.review",
        "hod.direct",
        "dashboard.hod",
        "dashboard.management",
        "case.close",
        "document.upload",
        "communication.record",
    },
    "STR_REVIEWER": {
        "case.view_all",
        "str.review",
        "str.approve",
        "document.upload",
    },
    "STR_SUBMITTER": {
        "case.view_all",
        "str.submit",
    },
    "SYSTEM_ADMIN": {
        "admin.users",
        "admin.reference",
        "case.view_all",
        "dashboard.management",
        "audit.view",
        "export.run",
    },
    "AUDITOR": {
        "case.view_all",
        "audit.view",
        "dashboard.management",
        "export.run",
    },
}


@dataclass
class AuthUser:
    id: int
    username: str
    display_name: str
    roles: list[str]

    def has_role(self, *roles: str) -> bool:
        return any(r in self.roles for r in roles)

    def can(self, permission: str) -> bool:
        for role in self.roles:
            if permission in ROLE_PERMISSIONS.get(role, set()):
                return True
        return False

    def permissions(self) -> set[str]:
        perms: set[str] = set()
        for role in self.roles:
            perms |= ROLE_PERMISSIONS.get(role, set())
        return perms


def hash_password(password: str) -> str:
    return pwd_context.hash(password)


def verify_password(password: str, password_hash: str) -> bool:
    return pwd_context.verify(password, password_hash)


def seed_users(db: Session) -> None:
    ref = get_reference_data()
    if db.query(User).count() > 0:
        return
    for item in ref.get("users", []):
        user = User(
            username=item["username"],
            display_name=item["display_name"],
            password_hash=hash_password(DEFAULT_PASSWORD),
            is_active=True,
        )
        db.add(user)
        db.flush()
        for role in item.get("roles", []):
            db.add(UserRole(user_id=user.id, role=role))
    db.commit()


def authenticate(db: Session, username: str, password: str) -> AuthUser:
    user = db.query(User).filter(User.username == username, User.is_active.is_(True)).one_or_none()
    if not user or not verify_password(password, user.password_hash):
        record_audit(
            db,
            event_category="Authentication",
            entity_type="User",
            entity_id=username,
            action="login_failed",
            actor_username=username,
            after={"username": username},
        )
        db.commit()
        raise WorkflowError("Invalid credentials", status_code=401, rule_ids=["SEC-auth"])
    roles = [r.role for r in user.roles]
    record_audit(
        db,
        event_category="Authentication",
        entity_type="User",
        entity_id=str(user.id),
        action="login",
        actor_user_id=user.id,
        actor_username=user.username,
        after={"username": user.username, "roles": roles},
    )
    db.commit()
    return AuthUser(id=user.id, username=user.username, display_name=user.display_name, roles=roles)


def require_permission(user: AuthUser, permission: str) -> None:
    if not user.can(permission):
        raise WorkflowError(
            f"Access denied: missing permission '{permission}'",
            status_code=403,
            rule_ids=["BR-segregation", "AT-013"],
            requirement_ids=["FR-HOD-001"] if permission.startswith("hod.") else [],
        )


def get_user_by_username(db: Session, username: str) -> User | None:
    return db.query(User).filter(User.username == username).one_or_none()


def resolve_pic_to_user(db: Session, pic_raw: str) -> User | None:
    """Map Assigned PIC text to an internal user. Exact username or display name match."""
    text = (pic_raw or "").strip()
    if not text:
        return None
    user = db.query(User).filter(User.username == text).one_or_none()
    if user:
        return user
    return db.query(User).filter(User.display_name == text).one_or_none()


def list_users(db: Session) -> list[User]:
    return db.query(User).order_by(User.username).all()