from __future__ import annotations

from datetime import datetime
from typing import Optional

from sqlalchemy import (
    Boolean,
    DateTime,
    ForeignKey,
    Integer,
    String,
    Text,
    UniqueConstraint,
)
from sqlalchemy.orm import Mapped, mapped_column, relationship

from src.configuration.db import Base, utc_now


class User(Base):
    __tablename__ = "users"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    username: Mapped[str] = mapped_column(String(100), unique=True, nullable=False)
    display_name: Mapped[str] = mapped_column(String(200), nullable=False)
    password_hash: Mapped[str] = mapped_column(String(255), nullable=False)
    is_active: Mapped[bool] = mapped_column(Boolean, default=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)

    roles: Mapped[list[UserRole]] = relationship(back_populates="user", cascade="all, delete-orphan")


class UserRole(Base):
    __tablename__ = "user_roles"
    __table_args__ = (UniqueConstraint("user_id", "role", name="uq_user_role"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), nullable=False)
    role: Mapped[str] = mapped_column(String(50), nullable=False)

    user: Mapped[User] = relationship(back_populates="roles")


class OffenceCode(Base):
    __tablename__ = "offence_codes"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    code: Mapped[str] = mapped_column(String(50), unique=True, nullable=False)
    description: Mapped[str] = mapped_column(String(500), nullable=False)
    is_active: Mapped[bool] = mapped_column(Boolean, default=True)


class Branch(Base):
    __tablename__ = "branches"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    code: Mapped[str] = mapped_column(String(50), unique=True, nullable=False)
    name: Mapped[str] = mapped_column(String(200), nullable=False)


class ImportBatch(Base):
    __tablename__ = "import_batches"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    batch_id: Mapped[str] = mapped_column(String(50), unique=True, nullable=False)
    filename: Mapped[str] = mapped_column(String(500), nullable=False)
    file_hash: Mapped[str] = mapped_column(String(128), nullable=False)
    sheet_name: Mapped[str] = mapped_column(String(200), nullable=False)
    imported_by: Mapped[int] = mapped_column(ForeignKey("users.id"), nullable=False)
    imported_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    total_source_rows: Mapped[int] = mapped_column(Integer, default=0)
    imported_count: Mapped[int] = mapped_column(Integer, default=0)
    duplicate_count: Mapped[int] = mapped_column(Integer, default=0)
    exception_count: Mapped[int] = mapped_column(Integer, default=0)
    ignored_count: Mapped[int] = mapped_column(Integer, default=0)
    status: Mapped[str] = mapped_column(String(50), default="COMPLETED")
    notes: Mapped[Optional[str]] = mapped_column(Text, nullable=True)

    rows: Mapped[list[AlertImportRow]] = relationship(back_populates="batch", cascade="all, delete-orphan")


class AlertImportRow(Base):
    __tablename__ = "alert_import_rows"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    batch_id: Mapped[int] = mapped_column(ForeignKey("import_batches.id"), nullable=False)
    source_row_no: Mapped[int] = mapped_column(Integer, nullable=False)
    alert_id_raw: Mapped[Optional[str]] = mapped_column(String(100), nullable=True)
    raw_json: Mapped[str] = mapped_column(Text, nullable=False)
    disposition: Mapped[str] = mapped_column(String(50), nullable=False)  # imported|duplicate|exception|ignored
    disposition_reason: Mapped[Optional[str]] = mapped_column(Text, nullable=True)
    alert_id: Mapped[Optional[int]] = mapped_column(ForeignKey("alerts.id"), nullable=True)

    batch: Mapped[ImportBatch] = relationship(back_populates="rows")


class Customer(Base):
    __tablename__ = "customers"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    customer_id_normalized: Mapped[str] = mapped_column(String(100), unique=True, nullable=False)
    customer_name: Mapped[str] = mapped_column(String(500), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)

    accounts: Mapped[list[Account]] = relationship(back_populates="customer")
    cases: Mapped[list[Case]] = relationship(back_populates="customer")


class Account(Base):
    __tablename__ = "accounts"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    account_number_raw: Mapped[str] = mapped_column(String(100), nullable=False)
    account_number_normalized: Mapped[str] = mapped_column(String(100), nullable=False)
    customer_id: Mapped[Optional[int]] = mapped_column(ForeignKey("customers.id"), nullable=True)
    account_role: Mapped[Optional[str]] = mapped_column(String(100), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)

    customer: Mapped[Optional[Customer]] = relationship(back_populates="accounts")


class Case(Base):
    __tablename__ = "cases"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    case_id: Mapped[str] = mapped_column(String(30), unique=True, nullable=False)  # AML-YYYY-NNNNNN
    customer_id: Mapped[Optional[int]] = mapped_column(ForeignKey("customers.id"), nullable=True)
    current_stage: Mapped[str] = mapped_column(String(50), nullable=False, default="IMPORTED")
    current_status: Mapped[str] = mapped_column(String(50), nullable=False, default="OPEN")
    current_owner_user_id: Mapped[Optional[int]] = mapped_column(ForeignKey("users.id"), nullable=True)
    priority: Mapped[str] = mapped_column(String(20), default="NORMAL")
    final_outcome: Mapped[Optional[str]] = mapped_column(String(100), nullable=True)
    closure_rationale: Mapped[Optional[str]] = mapped_column(Text, nullable=True)
    closed_by: Mapped[Optional[int]] = mapped_column(ForeignKey("users.id"), nullable=True)
    closed_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True), nullable=True)
    version: Mapped[int] = mapped_column(Integer, default=1)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now, onupdate=utc_now)

    customer: Mapped[Optional[Customer]] = relationship(back_populates="cases")
    alerts: Mapped[list[Alert]] = relationship(back_populates="case")
    investigations: Mapped[list[Investigation]] = relationship(back_populates="case")
    hod_reviews: Mapped[list[HODReview]] = relationship(back_populates="case")
    actions: Mapped[list[Action]] = relationship(back_populates="case")
    documents: Mapped[list[Document]] = relationship(back_populates="case")
    communications: Mapped[list[Communication]] = relationship(back_populates="case")
    case_links: Mapped[list[CaseLink]] = relationship(
        back_populates="from_case",
        foreign_keys="CaseLink.from_case_id",
    )


class Alert(Base):
    __tablename__ = "alerts"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    alert_id: Mapped[str] = mapped_column(String(100), unique=True, nullable=False)
    case_id: Mapped[Optional[int]] = mapped_column(ForeignKey("cases.id"), nullable=True)
    source_batch_id: Mapped[int] = mapped_column(ForeignKey("import_batches.id"), nullable=False)
    source_row_no: Mapped[int] = mapped_column(Integer, nullable=False)
    customer_id_raw: Mapped[str] = mapped_column(String(100), nullable=False)
    customer_id_normalized: Mapped[str] = mapped_column(String(100), nullable=False)
    customer_name_raw: Mapped[str] = mapped_column(String(500), nullable=False)
    account_number_raw: Mapped[Optional[str]] = mapped_column(String(100), nullable=True)
    assigned_pic_raw: Mapped[str] = mapped_column(String(200), nullable=False)
    assigned_user_id: Mapped[Optional[int]] = mapped_column(ForeignKey("users.id"), nullable=True)
    alert_date_raw: Mapped[Optional[str]] = mapped_column(String(100), nullable=True)
    alert_type_raw: Mapped[Optional[str]] = mapped_column(String(200), nullable=True)
    amount_raw: Mapped[Optional[str]] = mapped_column(String(100), nullable=True)
    raw_payload_json: Mapped[str] = mapped_column(Text, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)

    case: Mapped[Optional[Case]] = relationship(back_populates="alerts")


class CaseLink(Base):
    __tablename__ = "case_links"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    from_case_id: Mapped[int] = mapped_column(ForeignKey("cases.id"), nullable=False)
    to_case_id: Mapped[int] = mapped_column(ForeignKey("cases.id"), nullable=False)
    relationship_reason: Mapped[str] = mapped_column(Text, nullable=False)
    linked_by: Mapped[int] = mapped_column(ForeignKey("users.id"), nullable=False)
    linked_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    unlinked_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True), nullable=True)
    unlink_reason: Mapped[Optional[str]] = mapped_column(Text, nullable=True)

    from_case: Mapped[Case] = relationship(back_populates="case_links", foreign_keys=[from_case_id])


class Investigation(Base):
    __tablename__ = "investigations"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    case_id: Mapped[int] = mapped_column(ForeignKey("cases.id"), nullable=False)
    officer_user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), nullable=False)
    started_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True), nullable=True)
    completed_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True), nullable=True)
    predator_reference: Mapped[Optional[str]] = mapped_column(String(200), nullable=True)
    assessment_summary: Mapped[Optional[str]] = mapped_column(Text, nullable=True)
    officer_outcome: Mapped[Optional[str]] = mapped_column(String(50), nullable=True)
    recommendation: Mapped[Optional[str]] = mapped_column(String(50), nullable=True)
    grounds_for_suspicion: Mapped[Optional[str]] = mapped_column(Text, nullable=True)
    suspected_offence_code: Mapped[Optional[str]] = mapped_column(String(50), nullable=True)
    predator_disposition_confirmed: Mapped[bool] = mapped_column(Boolean, default=False)
    predator_disposition_date: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True), nullable=True)
    status: Mapped[str] = mapped_column(String(50), default="IN_PROGRESS")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now, onupdate=utc_now)

    case: Mapped[Case] = relationship(back_populates="investigations")


class HODReview(Base):
    __tablename__ = "hod_reviews"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    case_id: Mapped[int] = mapped_column(ForeignKey("cases.id"), nullable=False)
    investigation_id: Mapped[Optional[int]] = mapped_column(ForeignKey("investigations.id"), nullable=True)
    reviewer_user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), nullable=False)
    review_date: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    direction_code: Mapped[str] = mapped_column(String(50), nullable=False)
    direction_remarks: Mapped[Optional[str]] = mapped_column(Text, nullable=True)
    action_owner_id: Mapped[Optional[int]] = mapped_column(ForeignKey("users.id"), nullable=True)
    action_due_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True), nullable=True)
    priority: Mapped[str] = mapped_column(String(20), default="NORMAL")
    link_target_case_id: Mapped[Optional[str]] = mapped_column(String(30), nullable=True)
    created_action_id: Mapped[Optional[int]] = mapped_column(ForeignKey("actions.id"), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)

    case: Mapped[Case] = relationship(back_populates="hod_reviews")


class Action(Base):
    __tablename__ = "actions"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    action_id: Mapped[str] = mapped_column(String(40), unique=True, nullable=False)
    case_id: Mapped[int] = mapped_column(ForeignKey("cases.id"), nullable=False)
    action_type: Mapped[str] = mapped_column(String(50), nullable=False)  # RFV|RFI|FREEZE|STR|ASSESS|MONITOR|OTHER|RETURN|NFA
    status: Mapped[str] = mapped_column(String(50), nullable=False, default="OPEN")
    owner_user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), nullable=False)
    priority: Mapped[str] = mapped_column(String(20), default="NORMAL")
    due_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True), nullable=True)
    description: Mapped[Optional[str]] = mapped_column(Text, nullable=True)
    outcome_summary: Mapped[Optional[str]] = mapped_column(Text, nullable=True)
    hod_review_id: Mapped[Optional[int]] = mapped_column(Integer, nullable=True)
    completed_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True), nullable=True)
    completed_by: Mapped[Optional[int]] = mapped_column(ForeignKey("users.id"), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now, onupdate=utc_now)

    case: Mapped[Case] = relationship(back_populates="actions")
    rfv_rfi: Mapped[Optional[RFVRFI]] = relationship(back_populates="action", uselist=False)
    freeze_action: Mapped[Optional[FreezeAction]] = relationship(back_populates="action", uselist=False)
    str_case: Mapped[Optional[STRCase]] = relationship(back_populates="action", uselist=False)


class RFVRFI(Base):
    __tablename__ = "rfv_rfi"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    rfv_rfi_id: Mapped[str] = mapped_column(String(40), unique=True, nullable=False)
    action_id: Mapped[int] = mapped_column(ForeignKey("actions.id"), nullable=False)
    case_id: Mapped[int] = mapped_column(ForeignKey("cases.id"), nullable=False)
    request_type: Mapped[str] = mapped_column(String(10), nullable=False)  # RFV|RFI
    status: Mapped[str] = mapped_column(String(50), default="DRAFT")
    branch_code: Mapped[Optional[str]] = mapped_column(String(50), nullable=True)
    recipient: Mapped[Optional[str]] = mapped_column(String(200), nullable=True)
    requested_information: Mapped[Optional[str]] = mapped_column(Text, nullable=True)
    sent_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True), nullable=True)
    response_due_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True), nullable=True)
    follow_up_1_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True), nullable=True)
    follow_up_2_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True), nullable=True)
    response_received_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True), nullable=True)
    response_status: Mapped[Optional[str]] = mapped_column(String(100), nullable=True)
    evidence_assessment: Mapped[Optional[str]] = mapped_column(Text, nullable=True)
    final_conclusion: Mapped[Optional[str]] = mapped_column(Text, nullable=True)
    post_assessment_route: Mapped[Optional[str]] = mapped_column(String(50), nullable=True)  # CLOSURE|RETURN_HOD
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now, onupdate=utc_now)

    action: Mapped[Action] = relationship(back_populates="rfv_rfi")


class FreezeAction(Base):
    __tablename__ = "freeze_actions"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    freeze_id: Mapped[str] = mapped_column(String(40), unique=True, nullable=False)
    action_id: Mapped[int] = mapped_column(ForeignKey("actions.id"), nullable=False)
    case_id: Mapped[int] = mapped_column(ForeignKey("cases.id"), nullable=False)
    status: Mapped[str] = mapped_column(String(50), default="DIRECTED")
    affected_account_raw: Mapped[Optional[str]] = mapped_column(String(100), nullable=True)
    affected_account_id: Mapped[Optional[int]] = mapped_column(ForeignKey("accounts.id"), nullable=True)
    external_reference: Mapped[Optional[str]] = mapped_column(String(200), nullable=True)
    initiated_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True), nullable=True)
    confirmed_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True), nullable=True)
    effective_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True), nullable=True)
    outcome: Mapped[Optional[str]] = mapped_column(String(50), nullable=True)
    creates_str_obligation: Mapped[bool] = mapped_column(Boolean, default=False)
    creates_followup_obligation: Mapped[bool] = mapped_column(Boolean, default=False)
    notes: Mapped[Optional[str]] = mapped_column(Text, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now, onupdate=utc_now)

    action: Mapped[Action] = relationship(back_populates="freeze_action")


class STRCase(Base):
    __tablename__ = "str_cases"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    str_case_id: Mapped[str] = mapped_column(String(40), unique=True, nullable=False)
    action_id: Mapped[int] = mapped_column(ForeignKey("actions.id"), nullable=False)
    case_id: Mapped[int] = mapped_column(ForeignKey("cases.id"), nullable=False)
    status: Mapped[str] = mapped_column(String(50), default="PENDING_DRAFT")
    primary_offence_code: Mapped[Optional[str]] = mapped_column(String(50), nullable=True)
    reporting_type: Mapped[Optional[str]] = mapped_column(String(50), nullable=True)
    duplicate_status: Mapped[str] = mapped_column(String(50), default="NOT_DUPLICATE")
    grounds_for_suspicion: Mapped[Optional[str]] = mapped_column(Text, nullable=True)
    narrative: Mapped[Optional[str]] = mapped_column(Text, nullable=True)
    referral_source: Mapped[Optional[str]] = mapped_column(String(200), nullable=True)
    review_period_from: Mapped[Optional[str]] = mapped_column(String(50), nullable=True)
    review_period_to: Mapped[Optional[str]] = mapped_column(String(50), nullable=True)
    str_pic_user_id: Mapped[Optional[int]] = mapped_column(ForeignKey("users.id"), nullable=True)
    reviewed_by: Mapped[Optional[int]] = mapped_column(ForeignKey("users.id"), nullable=True)
    reviewed_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True), nullable=True)
    approved_by: Mapped[Optional[int]] = mapped_column(ForeignKey("users.id"), nullable=True)
    approved_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True), nullable=True)
    str_reference: Mapped[Optional[str]] = mapped_column(String(100), nullable=True)
    submitted_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True), nullable=True)
    submitted_by: Mapped[Optional[int]] = mapped_column(ForeignKey("users.id"), nullable=True)
    acknowledged_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True), nullable=True)
    amendment_notes: Mapped[Optional[str]] = mapped_column(Text, nullable=True)
    locked: Mapped[bool] = mapped_column(Boolean, default=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now, onupdate=utc_now)

    action: Mapped[Action] = relationship(back_populates="str_case")
    amendments: Mapped[list[STRAmendment]] = relationship(back_populates="str_case", cascade="all, delete-orphan")


class STRAmendment(Base):
    __tablename__ = "str_amendments"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    str_case_pk: Mapped[int] = mapped_column(ForeignKey("str_cases.id"), nullable=False)
    amendment_text: Mapped[str] = mapped_column(Text, nullable=False)
    created_by: Mapped[int] = mapped_column(ForeignKey("users.id"), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)

    str_case: Mapped[STRCase] = relationship(back_populates="amendments")


class Document(Base):
    __tablename__ = "documents"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    case_id: Mapped[int] = mapped_column(ForeignKey("cases.id"), nullable=False)
    action_id: Mapped[Optional[int]] = mapped_column(ForeignKey("actions.id"), nullable=True)
    filename: Mapped[str] = mapped_column(String(500), nullable=False)
    storage_uri: Mapped[str] = mapped_column(String(1000), nullable=False)
    content_type: Mapped[Optional[str]] = mapped_column(String(100), nullable=True)
    verification_status: Mapped[str] = mapped_column(String(50), default="NOT_REVIEWED")
    uploaded_by: Mapped[int] = mapped_column(ForeignKey("users.id"), nullable=False)
    uploaded_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    notes: Mapped[Optional[str]] = mapped_column(Text, nullable=True)

    case: Mapped[Case] = relationship(back_populates="documents")


class Communication(Base):
    __tablename__ = "communications"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    case_id: Mapped[int] = mapped_column(ForeignKey("cases.id"), nullable=False)
    action_id: Mapped[Optional[int]] = mapped_column(ForeignKey("actions.id"), nullable=True)
    communication_type: Mapped[str] = mapped_column(String(50), nullable=False)
    subject: Mapped[Optional[str]] = mapped_column(String(500), nullable=True)
    body: Mapped[Optional[str]] = mapped_column(Text, nullable=True)
    direction: Mapped[str] = mapped_column(String(20), default="OUTBOUND")
    occurred_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    recorded_by: Mapped[int] = mapped_column(ForeignKey("users.id"), nullable=False)
    attachment_ref: Mapped[Optional[str]] = mapped_column(String(1000), nullable=True)

    case: Mapped[Case] = relationship(back_populates="communications")


class Notification(Base):
    __tablename__ = "notifications"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), nullable=False)
    event_type: Mapped[str] = mapped_column(String(100), nullable=False)
    title: Mapped[str] = mapped_column(String(500), nullable=False)
    message: Mapped[str] = mapped_column(Text, nullable=False)
    case_id: Mapped[Optional[str]] = mapped_column(String(30), nullable=True)
    is_read: Mapped[bool] = mapped_column(Boolean, default=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)


class AuditEvent(Base):
    __tablename__ = "audit_events"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    event_category: Mapped[str] = mapped_column(String(50), nullable=False)
    entity_type: Mapped[str] = mapped_column(String(50), nullable=False)
    entity_id: Mapped[str] = mapped_column(String(100), nullable=False)
    action: Mapped[str] = mapped_column(String(100), nullable=False)
    actor_user_id: Mapped[Optional[int]] = mapped_column(ForeignKey("users.id"), nullable=True)
    actor_username: Mapped[Optional[str]] = mapped_column(String(100), nullable=True)
    before_json: Mapped[Optional[str]] = mapped_column(Text, nullable=True)
    after_json: Mapped[Optional[str]] = mapped_column(Text, nullable=True)
    reason: Mapped[Optional[str]] = mapped_column(Text, nullable=True)
    rule_ids: Mapped[Optional[str]] = mapped_column(String(200), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)


class CaseSequence(Base):
    __tablename__ = "case_sequences"

    year: Mapped[int] = mapped_column(Integer, primary_key=True)
    last_value: Mapped[int] = mapped_column(Integer, default=0)


class ExportJob(Base):
    __tablename__ = "export_jobs"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    export_type: Mapped[str] = mapped_column(String(50), nullable=False)
    exported_by: Mapped[int] = mapped_column(ForeignKey("users.id"), nullable=False)
    exported_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    as_of: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    filter_json: Mapped[Optional[str]] = mapped_column(Text, nullable=True)
    row_count: Mapped[int] = mapped_column(Integer, default=0)
    control_hash: Mapped[Optional[str]] = mapped_column(String(128), nullable=True)
    template_version: Mapped[str] = mapped_column(String(50), default="1.0")
    status: Mapped[str] = mapped_column(String(50), default="SUCCESS")
    artifact_uri: Mapped[Optional[str]] = mapped_column(String(1000), nullable=True)