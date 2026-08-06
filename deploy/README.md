# Deployment notes (pilot)

## Local / demo

```bash
pip install -r requirements.txt
export PYTHONPATH=.
uvicorn src.api.main:app --host 0.0.0.0 --port 8000
```

## Backup / restore

```bash
# backup
cp data/aml_workflow.db backups/aml_workflow_$(date +%Y%m%d).db
cp -a data/uploads data/documents data/exports backups/

# restore
cp backups/aml_workflow_YYYYMMDD.db data/aml_workflow.db
```

## Rollback

Redeploy previous application revision and restore the matching database backup. Do not delete audit_events or submitted STR records.

## Production note

Replace SQLite with an approved multi-user RDBMS before concurrent officer use (Blueprint §17.1).