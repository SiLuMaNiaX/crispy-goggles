# AML Centralized Workflow Management Solution

Pilot implementation of the **AML Centralized Workflow Management Solution Blueprint v1.0** (6 August 2026).

## Purpose

A deterministic, auditable workflow platform that:

- Imports Predator alert extracts (read-only; Predator remains authoritative)
- Allocates PIC-based officer queues
- Separates officer suspicious assessment from HOD direction
- Tracks RFV/RFI, freeze (tracking only), and STR workflows
- Blocks closure while mandatory data or directed actions remain open
- Preserves a tamper-evident audit history

**Governing design principle:** one centralized case, one complete history, one accountable owner at every stage, and no unrecorded handoff.

## Explicit non-goals (initial release)

- No AI / automated suspicious classification or risk scoring
- No automatic Predator update, account freeze, regulator STR submission, or outbound email send
- No deletion or overwrite of historical source records

## Stack

- Python 3.12, FastAPI, SQLAlchemy, SQLite (pilot)
- Jinja2 intranet UI
- openpyxl for Predator import and controlled Excel exports

## Quick start

```bash
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
export PYTHONPATH=.
python scripts/generate_sample_extract.py
uvicorn src.api.main:app --host 0.0.0.0 --port 8000
```

Open http://localhost:8000 — pilot password for all seeded users: `ChangeMe1!`

| Username | Role |
|----------|------|
| `officer1` | Alert Coordinator / Officer 1 |
| `aml.officer.a` / `aml.officer.b` | AML Officer |
| `hod` | Head of Department |
| `str.reviewer` | STR Reviewer/Approver |
| `str.submitter` | STR Submitter |
| `admin` | System Administrator |
| `auditor` | Auditor (read-only) |

## Module map (Blueprint §18.3)

```
src/
  identity_access/   imports/   case_core/   investigation/
  hod_review/        actions/   rfv_rfi/     freeze/
  str_workflow/      documents/ communications/ reporting/
  audit/             configuration/  api/  web/
```

## Configuration

- `config/settings.yaml` — app, DB, SLA placeholders (CONFIGURABLE)
- `config/reference_data.yaml` — roles, statuses, offences, branches, users

SLA periods, retention, offence taxonomy authority, and production hosting remain **business-configurable** per Appendix B.

## Tests

```bash
export PYTHONPATH=.
pytest -q
```

Acceptance scenarios AT-001 … AT-015 are covered in `tests/test_acceptance.py`.

## Known limitations / open decisions

See `docs/OPEN_DECISIONS.md` and `docs/KNOWN_LIMITATIONS.md`.