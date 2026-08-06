# Open Decisions Register

Items labelled CONFIGURABLE in Blueprint v1.0 Appendix B. Not silently converted to mandatory rules.

| Decision | Owner | Status in this build |
|----------|-------|----------------------|
| Exact meaning of RFV vs RFI | Business owner | Both supported as separate request types; selection rules pending |
| HOD direction list and authority limits | HOD/Compliance | Full catalogue from §5.4 implemented; authority limits pending |
| Freeze workflow and references | Operations/Legal/Compliance | Tracking statuses implemented; evidence rules pending sign-off |
| STR review/approval hierarchy | Compliance | Reviewer + submitter segregation implemented |
| Offence taxonomy | Compliance | Seed codes in `config/reference_data.yaml` — replace with approved list |
| SLA and reminder periods | Business owner | Placeholder days in `config/settings.yaml` |
| Retention and archival | Records/Legal | Schema supports policies; no period assumed |
| Production technology/hosting | IT/Security | SQLite pilot only; migrate to approved RDBMS for multi-user production |
| Authentication method | IT/Security | Local named accounts for pilot; Entra ID ready as future option |
| Document storage location | Records/IT | Local `data/documents/` — replace with approved repository |
| Excel exports remain official? | Business owner | Controlled exports available; cutover decision pending |
| Outlook draft generation | Business owner/IT | Disabled (`features.outlook_draft_generation: false`) |