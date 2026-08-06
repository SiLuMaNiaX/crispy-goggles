# Known Limitations

## Pilot scope

- SQLite database suitable for single-user/pilot demos. For concurrent multi-officer production use an approved multi-user RDBMS (Blueprint §17.1).
- Cookie-based session store is in-process (not shared across multiple uvicorn workers).
- Document store is local filesystem references only.
- No Microsoft Entra ID / SSO integration yet.
- No automatic email send; communication register only.
- Freeze and STR regulator submission are tracking/status only.
- Historical workbook migration loaders for RFV/RFI and AMCP STR Excel files are not included in this first cut; import focuses on Predator alert extracts.
- UI is an intranet-style server-rendered application, not a full SPA.

## Security

- Default pilot password must be rotated before any shared environment.
- Secret key in settings is a pilot placeholder.
- Masking of customer identifiers is role-aware in service helpers but not fully applied on every UI field yet.

## Compliance posture

- The system never auto-classifies suspiciousness (BR-005).
- Officer recommendation and HOD direction are stored as separate events (BR-004).
- Source Predator extract files are copied and hashed; originals are not modified (BR-002).