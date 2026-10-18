# Windows acceptance checks

Run these checks on a disposable database using Windows PowerShell **5.1**, the intended task identity and actual storage type. Automated mock tests cannot prove SQL or Task Scheduler behavior. SQL 2014 and SQL 2025 are the compatibility endpoints; validate intermediate versions used by your deployments as well.

## Prerequisites and initial run

1. Run `tests/Invoke-Checks.ps1` using `powershell.exe`, not only `pwsh.exe`.
2. Inspect SQL version/recovery model with `sql/inventory.sql`. Confirm Shared Memory is enabled and Windows authentication works.
3. Copy an example into a new `*.local.json`. Choose a unique project/database ID and an isolated backup directory. Use a disposable application database containing a table with known rows.
4. Prepare the directories and DBA-reviewed SQL permissions. Check ACLs as both SQL service and task account. Confirm the task account cannot modify installed scripts/configuration.
5. Register tasks disabled. Inspect task principal, action quoting, local timezone, repetition, disabled state and execution policy. Test SYSTEM and the actual non-SYSTEM account where both will be supported.
6. Enable/run only Full first, using Task Scheduler. Confirm exit `0`, JSONL completion, a nonempty `.bak`, a verified manifest and a successful test restore/CHECKDB.
7. For FULL recovery, insert known rows, run Log, insert another row and run Log again. Restore the Full plus both logs into a new database. Confirm the added rows. Test STOPAT between the inserts if point-in-time recovery is required.

## Failure and recovery checks

| Scenario | Expected evidence |
| --- | --- |
| Log job on SIMPLE | Failure, no automatic recovery-model change |
| Log before initial managed Full | Failure, initial-full message |
| Missing SQL backup or verification permission | Nonzero task result and failure log |
| Missing SQL service write permission | Backup failure, no verified manifest |
| Missing task-account read/manifest permission | Nonzero task result; file may remain for investigation |
| SQL service stopped or Shared Memory disabled | Connection failure, not an empty successful run |
| Offline/missing configured database | Overall failure, other configured databases still attempted |
| CHECKSUM/VERIFYONLY failure | Backup retained without success manifest; no cleanup |
| Backup storage full or UNC unavailable | Failure; existing backups preserved |
| Two jobs for the same database | Serialized by application lock, or explicit lock-timeout failure |
| Task restart after host reboot/missed trigger | Runs according to StartWhenAvailable; no claim to replay missed intervals |
| External log backup between tool logs | Gap reported when the next log no longer covers the expected LSN |
| Recovery-model switch or restored database | Baseline/chain reviewed; mixed-fork cleanup refused |
| Removed or disabled job, then re-registration | Old managed task disabled; unmanaged tasks not overwritten |
| `-WhatIf` on execution/registration/storage setup | No backups, deletions, task changes or directory changes |

Exercise disk-full/permissions failures on isolated test storage only; do not fill production disks or revoke production service access. Check task results even when a filesystem failure prevents writing a completion log.

## Retention check

Build a disposable backup history spanning the configured retention cutoff; do not falsify production manifests or change the server clock. Confirm at least the configured minimum full copies, the full before the cutoff, overlapping logs and all subsequent logs remain. Restore from that retained anchor through the log chain. Corrupt a **copy** of an old manifest/backup and confirm cleanup stops; never use the only recovery copy in a destructive test.

Unit tests exercise synthetic time windows without needing to wait days. SQL-backed retention testing is still required before enabling `CleanupEnabled` on existing operational storage. You can initially set it to `false` while checking backup/restore behavior.

## Migration and rollback

1. Preserve existing EXOS XML exports, old backup-device contents and current recovery-model information.
2. Bootstrap and restore-test the new Full before retiring the old schedule. Coordinate Log cutover: disable the old Log task, take a new Full in this tool, then start the new Log task. Preserve any legacy logs needed for older recovery points.
3. Enable vendor maintenance only after its schema, code, permissions and business-data retention policy are confirmed.
4. To stop the new schedule, disable the tasks in `\SqlExpressBackup\<project-id>\`. Preserve backups/manifests/logs.
5. Before resuming an old Log schedule, have the DBA establish and verify its new recovery baseline; simply switching task names does not consolidate two sets of log files.

Record engine/build, Windows/PowerShell version, task identity type, storage type, test restore outcome, recovered timestamp and recovery duration. A successful mock test or VERIFYONLY is not a completed restore drill.
