# Solution Architecture (Pilot)

## Layers

1. **Client** — Jinja2 intranet UI (`src/web`)
2. **Application** — FastAPI routes + modular rule-based services (`src/*`)
3. **Database** — SQLite pilot (`data/aml_workflow.db`); SQLAlchemy models in `src/configuration/models.py`
4. **Files** — Import copies, document store, export artifacts under `data/`

## Threat model (summary)

| Threat | Control |
|--------|---------|
| Unauthorized HOD decision | Role permission `hod.direct`; audited denial |
| Silent AI classification | Feature disabled; no scoring module |
| Duplicate alert pollution | Unique Alert ID; import reconciliation |
| Lost handoff | Mandatory owner; audit before/after; notifications |
| Tampering submitted STR | Lock + additive amendments only |
| Premature closure | Completeness engine + open-action gate |
| Source extract alteration | Copy + SHA-256 hash; original not modified |

## Command / query

State-changing operations go through service commands that require actor identity, validate stage gates, and write audit events inside the same DB transaction.