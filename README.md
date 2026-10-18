# SQL Express Backup

Configuration-driven backups and optional database maintenance for **Windows PowerShell 5.1** and **SQL Server Express 2014, 2016, 2017, 2019, 2022 and 2025**.

Run on the SQL Server host through Task Scheduler as SYSTEM or a specified Windows account. SQL commands use the .NET Framework `System.Data.SqlClient` provider over **local Shared Memory** (`lpc:`) with Windows authentication. No SQL Agent, `sqlcmd`, SSMS or downloaded PowerShell module is required at runtime.

The code targets these SQL versions; it has not yet been integration-tested against Windows/SQL Server. Complete the [Windows acceptance checks](docs/windows-validation.md) before replacing an existing backup schedule. SQL version compatibility does not extend Microsoft's product support lifecycle.

## Included

- Full `.bak` and transaction log `.trn` backups with unique names, `CHECKSUM`, `STOP_ON_ERROR` and `RESTORE VERIFYONLY`.
- Daily, weekly or every-N-minutes schedules, configured separately for each job.
- Multiple explicitly selected application databases per project; independent configuration per project.
- Initial-full requirement, recovery-model validation and log-gap detection.
- Database-scoped SQL application locks across this tool's backup/maintenance jobs, including different configurations and Windows accounts.
- Verified JSON manifests and conservative recovery-window retention after successful full backups.
- JSONL run logs and exit code `1` on failure, including a failed database in a multi-database run.
- Disabled-by-default CHECKDB, targeted rowstore index reorganization and vendor stored-procedure adapters.
- Restricted local storage preparation, idempotent task registration and task status reporting.

Differential backups are supported by SQL Express but are not implemented here: the reference design uses full and log backups. The scripts do not change recovery models, shrink database files, install procedures in `master`, enable `xp_cmdshell`, grant SQL permissions or restore over a database automatically.

## Layout

| Path | Purpose |
| --- | --- |
| `config/project.example.json` | Generic project template |
| `config/exos9300.example.json` | EXOS template derived from the supplied task exports |
| `src/SqlExpressBackup.psm1` | Configuration, SQL operations, verification and retention |
| `scripts/Initialize-SqlExpressBackupStorage.ps1` | Prepare new local project directories and ACLs |
| `scripts/Register-SqlExpressBackup.ps1` | Create/update scheduled tasks |
| `scripts/Invoke-SqlExpressBackup.ps1` | Scheduler entry point; propagates failure exit codes |
| `scripts/Get-SqlExpressBackupStatus.ps1` | Scheduler state, previous result and next run |
| `sql/inventory.sql` | Inspect version, recovery models, backup devices and EXOS procedures |
| `sql/permissions.example.sql` | DBA-reviewed permission template |
| `docs/restore.md` | Full and point-in-time restore procedures |
| `docs/windows-validation.md` | Required target-host acceptance checks |

The original `exos9300-db-backup/` exports remain local reference material and are ignored by Git because they contain environment-specific information. Local configurations (`*.local.json`), backup files and logs are also ignored. Keep templates free of real infrastructure details.

## SQL Express prerequisites

1. A running, patched SQL Express **service instance**, with Shared Memory enabled in SQL Server Configuration Manager. LocalDB is not supported. Do not enable TCP or SQL Browser solely for this tool.
2. Windows PowerShell **5.1**, .NET Framework and the built-in ScheduledTasks module. Use a Windows version supported by the installed SQL release; PowerShell 5.1 alone does not establish OS compatibility.
3. A login for the task account, a mapped user in every selected database, `CONNECT`, `BACKUP DATABASE`, `BACKUP LOG`, and server permission `CREATE ANY DATABASE` for `VERIFYONLY`/`HEADERONLY`. Review `sql/permissions.example.sql` with the DBA. This additional permission permits database creation; the tool does not silently grant it or require `sysadmin` for backups.
4. `FULL` recovery for full + log backups. `BULK_LOGGED` also works, but some bulk operations prevent point-in-time recovery inside the affected log backup. `SIMPLE` works only with the Log job disabled. Switching recovery models requires DBA approval and a new initial full backup; the script never switches them.
5. Existing storage roots with sufficient free space. Plan for uncompressed data, log volume between backups, the retention window, at least two full backups and one additional full during rotation. Retention runs **after** backup, never to make room before one.
6. Task account access to scripts/configuration (read/execute), backup project directory (modify), logs (modify), and **Log on as a batch job** for normal Windows accounts. A deny-logon policy overrides an allow policy. Registration requires suitable local administrator permissions.

Express cannot create compressed or natively encrypted SQL backup files, including in SQL Server 2025. The script explicitly uses `NO_COMPRESSION`. Protect backup storage with access controls and storage-level encryption. Maintain an independently protected off-host/offline copy using your existing backup system; local retention is not an off-site backup service.

## Storage identities and paths

`BackupRoot` is evaluated by SQL Server on the local host. A drive path such as `D:\SQLBackups` is a server path. A UNC path such as `\\server.example.com\backups` is allowed. Do not use user-mapped network drives.

Two identities need access:

- **SQL Server service** writes and reads SQL backup files. For local folders the initializer grants its service SID, e.g. `NT SERVICE\MSSQL$SQLEXPRESS`, modify access.
- **Task account** reads files/manifests and performs retention. Changing the task account does not change the SQL Server service account.

For UNC storage, pre-create `BackupRoot\ProjectId\DatabaseId` for each database and grant both share and NTFS permissions to the appropriate network identities. A local SQL virtual service account and SYSTEM normally use the computer's domain account on the network; a local service SID cannot be granted as a remote-domain identity. Workgroup deployments need a separately designed authenticated share-access setup. The initializer does not modify remote ACLs or store share passwords. Require SMB 3 encryption for sensitive backup traffic and protect the destination at rest.

Storage roots and their parent directories must be administrator-controlled. Reparse points/junctions are rejected. Do not reuse a project directory for a different database or instance; change `ProjectId` or `Database.Id` when changing database identity. Keep scripts/configuration in an administrator-writable installation directory, separate from writable backup/log storage. An account able to edit a scheduled script/configuration can control its execution.

## Setup

Run installation commands in elevated **Windows PowerShell 5.1**. The following paths are examples.

### 1. Configure a project

```powershell
Set-Location C:\Tools\SqlExpressBackup
Copy-Item .\config\project.example.json .\config\application.local.json
notepad .\config\application.local.json
```

Set `ProjectId`, `Instance` (`.` or `.\SQLEXPRESS`), database `Id`/`Name`, storage roots, `Account`, schedules and retention. For a normal account use its exact Windows name, e.g. `DOMAIN\sql-backup`. SYSTEM may be written as `SYSTEM` or `NT AUTHORITY\SYSTEM`.

Run `sql/inventory.sql` in a SQL query tool to confirm the actual version, recovery models and legacy backup-device paths. An instance name containing `2014` is not evidence of the engine version.

### 2. Prepare storage and permissions

Create `BackupRoot` and `LogRoot` on the host first. Then preview and apply project-directory creation:

```powershell
.\scripts\Initialize-SqlExpressBackupStorage.ps1 -ConfigPath .\config\application.local.json -WhatIf
.\scripts\Initialize-SqlExpressBackupStorage.ps1 -ConfigPath .\config\application.local.json
```

New local project directories receive non-inherited ACLs: administrators/SYSTEM have full control, the task account has modify access, and the SQL service has modify access to backups. Existing project directories and ACLs are preserved with a warning; review their permissions and create any new database subdirectories explicitly. The initializer requires the SQL instance/service SID to exist.

Have the DBA adapt and execute `sql/permissions.example.sql`. SYSTEM is **not automatically a SQL sysadmin**. Optional CHECKDB requires `db_owner` or `sysadmin`; if those rights are inappropriate for the backup account, leave the job disabled and have the DBA run CHECKDB separately. All jobs in one configuration use its single `Account`. Vendor procedures may need permissions beyond `EXECUTE` depending on their implementation.

### 3. Validate and register disabled tasks

```powershell
Import-Module .\src\SqlExpressBackup.psm1 -Force
Read-BackupConfiguration .\config\application.local.json
.\scripts\Invoke-SqlExpressBackup.ps1 -ConfigPath .\config\application.local.json -JobId full -WhatIf
.\scripts\Register-SqlExpressBackup.ps1 -ConfigPath .\config\application.local.json -WhatIf
.\scripts\Register-SqlExpressBackup.ps1 -ConfigPath .\config\application.local.json
```

Non-SYSTEM registration prompts for a `PSCredential`, or accepts `-Credential (Get-Credential)`. The password is passed in-process to Task Scheduler and stored by Windows, not in JSON/XML/files or command-line arguments. Password changes require re-registration. gMSA registration is not implemented.

Tasks are created **disabled** unless `-Enable` is passed. Existing tasks in the project's managed folder are updated; managed jobs removed/disabled in configuration are disabled, not deleted. Unmanaged tasks in that folder block registration. Changes to `Account` also require a manual ACL review. Registrations are per-task, not transactional: re-run after resolving a registration failure. Project renames require explicitly disabling the old project's tasks.

Task actions use `powershell.exe -NoProfile -NonInteractive -File`; they do not bypass execution policy. Use your organization's signing/unblocking policy for trusted deployment files. Save configuration files as UTF-8; the reader explicitly uses UTF-8, with or without a BOM. Generated backup paths must be shorter than 260 characters for Windows PowerShell 5.1 compatibility.

### 4. Bootstrap under the actual task identity

Use the registered Full task to bootstrap under SYSTEM or the selected account:

```powershell
$taskPath = '\SqlExpressBackup\sample-project\' # Use the configured ProjectId.
Enable-ScheduledTask -TaskPath $taskPath -TaskName full
Start-ScheduledTask -TaskPath $taskPath -TaskName full
.\scripts\Get-SqlExpressBackupStatus.ps1 -ConfigPath .\config\application.local.json
```

Wait for completion; confirm `LastResult = 0x0`, a recent manifest with `Verified: true`, and a final `Run` event with `Status: Success`. A task merely starting is not success. Perform a test restore as described in [restore.md](docs/restore.md).

After the full backup succeeds, enable and run the Log task, then inspect it in the same way:

```powershell
Enable-ScheduledTask -TaskPath $taskPath -TaskName log
Start-ScheduledTask -TaskPath $taskPath -TaskName log
```

For full-only/SIMPLE configurations skip the Log step. Enable any approved maintenance jobs separately. Alternatively re-register with `-Enable` once the initial full and permissions are verified. Do not leave overlapping legacy log-backup tasks active: they can create files required for recovery outside this project's inventory.

`-ValidateOnly` checks configuration, directories, SQL version/state/recovery model and relevant SQL permissions, and writes a preflight log. It does **not** prove service write access, disk capacity or restorability. Run it under the intended account where practical. A preflight run under an administrator cannot prove SYSTEM's permissions.

## Schedules and operation

Examples for any job's `Schedule`:

```json
{ "Mode": "Daily", "At": "03:15" }
```

```json
{ "Mode": "Interval", "EveryMinutes": 360 }
```

```json
{ "Mode": "Weekly", "At": "04:00", "Days": ["Monday", "Thursday"] }
```

Calendar times use the server's local timezone and Task Scheduler DST behavior. Interval schedules start two minutes after registration and repeat indefinitely; re-registration resets their phase. `StartWhenAvailable` catches up a missed trigger; it does not replay every missed backup. `IgnoreNew` prevents overlap of the same task; SQL application locks serialize this tool's different jobs for a database. Lock timeout is a reported failure, not silent success. Native SQL connections are not pooled, so session locks end when the connection is disposed.

Choose log frequency from the allowable loss of committed data; 15 minutes is an example, not an RPO guarantee. Backup/maintenance duration, failed executions and storage availability also affect recovery. Long maintenance or full backups can delay Log jobs because of the shared lock. Measure durations and adjust the maintenance window, lock timeout and frequency accordingly. Every SQL command has a timeout. Task Scheduler has no hard execution limit, to avoid killing a valid multi-database operation based on an arbitrary total duration; monitor stuck/long-running tasks externally.

## Retention and failure behavior

- Files are stored under `BackupRoot\ProjectId\DatabaseId`. Each verified file has a `.backup.json` manifest with backup GUID, database family, recovery fork and LSNs.
- `RetentionDays` is a recovery window, not an unconditional file age limit. Keep the latest full completed before the cutoff, all subsequent files, and at least `MinimumFullBackups` full backups (minimum two). Logs overlapping the retained anchor are preserved. Actual storage can exceed the nominal number of days.
- Cleanup runs only after a newly verified Full backup. It re-verifies the oldest retained full and checks candidate/anchor backup-set GUIDs against SQL headers before deletion. Only recognized managed files are deleted; legacy files, unverified files and other projects are left alone.
- Changed/missing files, malformed manifests, mixed database families/forks or failed anchor verification stop cleanup and fail the run. The newly created full backup remains saved. Preserve evidence and investigate; do not fix such a failure by indiscriminately deleting manifests.
- A backup that fails verification is retained without a success manifest. A manifest is published only after verification. Partial/expired manifests left by an interrupted filesystem operation require operator review and are not treated as valid inventory.
- A Log backup requires an initial verified Full from this project. LSN gaps/fork changes produce failure after saving the new log, so diagnostic evidence is not discarded. Investigate any other backup tools/recovery-model changes and take a new full baseline. This check is not a complete restore-chain validator.
- A full backup does not break the log chain. This tool must own the regular full/log strategy for its databases. External conventional full backups can change a third-party differential base; coordinate migration with the DBA.
- A failed database does not silently disappear: remaining databases are attempted, each result is logged, and the overall process exits `1`. There is no automatic SQL command retry; the next scheduled run has a new filename.

Monitor Task Scheduler results **and freshness** of verified full/log backups per database, failed/missing final log events, free disk space, log-file growth and task duration. `Get-SqlExpressBackupStatus.ps1` is a status view, not a freshness alerting service. JSONL logs are protected by storage ACLs and may contain database names and SQL error details; forward them only to authorized monitoring. Apply an operational retention policy to these small logs separately.

## EXOS9300 migration

| Original task | New profile |
| --- | --- |
| Full backup at 03:15, `WITH FORMAT` | Full at 03:15 into separate verified files |
| Log backup at 01:15 | Log every 15 minutes by default; set `Daily` / `01:15` to reproduce the old cadence |
| `libShrinkExosLogTables` at 01:20 | Procedure job at 01:20, disabled until schema/behavior confirmed |
| `libIndexesDefrag` at 01:40 | Procedure job at 01:40, disabled until schema/behavior confirmed |
| SYSTEM identity | SYSTEM in the EXOS template; configurable per deployment |

The XML files contain procedure calls, not their definitions. Query the application database using `sql/inventory.sql`, review the vendor's procedure code and business-data retention requirements, set `ProcedureSchema`, grant required permissions, and set `Enabled: true`. The runner checks existence and execute permission, executes the exact quoted schema/name, and treats a nonzero procedure return code as failure. No arbitrary SQL file is loaded from configuration.

The generic Indexes job is an opt-in rowstore **REORGANIZE**, with configurable minimum page count and fragmentation percentage. It skips heaps, disabled/hypothetical indexes and indexes without page locks; it does not update statistics or rebuild every index. Thresholds are selection filters after a workload-specific decision, not universal best practices. Microsoft recommends measuring maintenance benefit, not blindly rebuilding based on percentages. Do not enable both the EXOS index procedure and generic index maintenance without a reason.

There is no generic equivalent of `libShrinkExosLogTables`: its name does not establish whether it deletes application history or shrinks files. Routine file shrink is not part of this backup strategy. CHECKDB checks integrity without requesting repair/data loss and is disabled until permissions and a maintenance window are approved.

## Development verification

Install **Pester 5.6.1** and **PSScriptAnalyzer 1.22.0** in your approved development/test environment, then run:

```powershell
.\tests\Invoke-Checks.ps1
```

Checks cover parsing, static analysis, PowerShell 5.1 syntax compatibility and mocked boundary/retention/failure tests. Linux PowerShell checks do not validate Windows Task Scheduler, .NET Framework Shared Memory connectivity, ACLs or actual SQL restores. See [Windows validation](docs/windows-validation.md).

GitHub Actions runs the same checks on Windows PowerShell 5.1 for pushes and pull requests. The required check is named `Windows PowerShell 5.1`. Changes enter `develop` through a pull request, then are promoted from `develop` to `main` through a separate pull request. CI does not include a running SQL Server instance or replace the target-host acceptance checks.

## Microsoft references

Reviewed 2026-10-18:

- [Schedule SQL Express backups](https://learn.microsoft.com/en-us/troubleshoot/sql/database-engine/backup-restore/schedule-automate-backup-database)
- [SQL Server 2025 edition capabilities](https://learn.microsoft.com/en-us/sql/sql-server/editions-and-components-of-sql-server-2025)
- [BACKUP syntax and permissions](https://learn.microsoft.com/en-us/sql/t-sql/statements/backup-transact-sql)
- [VERIFYONLY behavior and permissions](https://learn.microsoft.com/en-us/sql/t-sql/statements/restore-statements-verifyonly-transact-sql)
- [Backup devices, paths and service identities](https://learn.microsoft.com/en-us/sql/relational-databases/backup-restore/backup-devices-sql-server)
- [Transaction log backups and frequency](https://learn.microsoft.com/en-us/sql/relational-databases/backup-restore/transaction-log-backups-sql-server)
- [Workload-driven index maintenance](https://learn.microsoft.com/en-us/sql/relational-databases/indexes/reorganize-and-rebuild-indexes)
