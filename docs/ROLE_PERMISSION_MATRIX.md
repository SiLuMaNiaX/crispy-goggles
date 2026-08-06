# Role–Permission Matrix

| Permission | OFFICER_1 | AML_OFFICER | HOD | STR_REVIEWER | STR_SUBMITTER | SYSTEM_ADMIN | AUDITOR |
|------------|-----------|-------------|-----|--------------|---------------|--------------|---------|
| import.batch | ✓ | | | | | | |
| case.view_own | ✓ | ✓ | | | | | |
| case.view_all | | | ✓ | ✓ | ✓ | ✓ | ✓ |
| case.reassign | ✓ | | | | | | |
| case.close | | | ✓ | | | | |
| investigation.update_own | ✓ | ✓ | | | | | |
| investigation.refer_suspicious | | ✓ | | | | | |
| hod.review / hod.direct | | | ✓ | | | | |
| action / rfv / freeze update own | | ✓ | | | | | |
| str.draft_own | | ✓ | | | | | |
| str.review / str.approve | | | | ✓ | | | |
| str.submit | | | | | ✓ | | |
| admin.* | | | | | | ✓ | |
| audit.view / export.run | | | | | | ✓ | ✓ |
| dashboard.hod / management | | | ✓ | | | ✓ | ✓ |

Server-side enforcement via `require_permission()` — UI hiding is not sufficient (Blueprint §4.1).