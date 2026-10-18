# Restore and recovery

`RESTORE VERIFYONLY` checks readability and backup checksums; it does not restore the database or verify its complete logical structure. Prove recovery through regular restores into a **different database on an isolated test instance**, followed by CHECKDB and application-level checks. Record recovery duration and the latest recovered transaction.

Use a SQL administrator for restores. The backup account is not automatically permitted to restore over existing databases. These are reviewed manual examples, not a script to run unchanged. SQL Server cannot restore a backup made by a newer major version into an older engine. Test on the same version or a compatible newer version; restored data must also fit the target edition's capacity.

## 1. Select and inspect the backup

Use the protected manifests to identify verified files. Confirm the database family, recovery fork, backup GUID, timestamps and LSNs with SQL headers. Do not rely only on filenames or modification dates.

```sql
RESTORE HEADERONLY FROM DISK = N'D:\SQLBackups\sample-project\application\Full_example.bak';
RESTORE VERIFYONLY FROM DISK = N'D:\SQLBackups\sample-project\application\Full_example.bak'
    WITH CHECKSUM, STOP_ON_ERROR;
RESTORE FILELISTONLY FROM DISK = N'D:\SQLBackups\sample-project\application\Full_example.bak';
```

Replace `Full_example.bak` with a real backup. Record **all** logical file names from FILELISTONLY. For extra data/log files or FILESTREAM containers, add the necessary MOVE clauses and prepare supported destination storage. Ensure the SQL service can read backups and write the restore directories.

## 2. Restore a full backup to a new database

Confirm `Application_RestoreTest` does not already exist. Do not use `WITH REPLACE` or production file paths.

```sql
USE [master];
IF DB_ID(N'Application_RestoreTest') IS NOT NULL
    THROW 51000, 'Restore target already exists. Choose a new test database.', 1;

RESTORE DATABASE [Application_RestoreTest]
FROM DISK = N'D:\SQLBackups\sample-project\application\Full_example.bak'
WITH MOVE N'ApplicationData' TO N'D:\SQLRestoreTest\Application_RestoreTest.mdf',
     MOVE N'ApplicationLog' TO N'D:\SQLRestoreTest\Application_RestoreTest_log.ldf',
     CHECKSUM, STOP_ON_ERROR, RECOVERY;

DBCC CHECKDB ([Application_RestoreTest]) WITH NO_INFOMSGS, ALL_ERRORMSGS;
```

Replace both logical names with FILELISTONLY results. Run this as one batch so the existence guard terminates the batch before RESTORE if needed. Check known rows and application invariants; do not connect production application services to the restored test database.

## 3. Restore a full backup plus logs

Select a full backup completed before the target time. Restore it using the same MOVE clauses but **NORECOVERY**, not RECOVERY. Apply every required log in LSN sequence, including the log whose covered interval overlaps the full backup. A log's file creation time alone does not establish whether it is needed.

```sql
RESTORE LOG [Application_RestoreTest]
FROM DISK = N'D:\SQLBackups\sample-project\application\Log_first.trn'
WITH CHECKSUM, STOP_ON_ERROR, NORECOVERY;

RESTORE LOG [Application_RestoreTest]
FROM DISK = N'D:\SQLBackups\sample-project\application\Log_next.trn'
WITH CHECKSUM, STOP_ON_ERROR, NORECOVERY;

-- After the last required log, recover to the end of the chain:
RESTORE DATABASE [Application_RestoreTest] WITH RECOVERY;
DBCC CHECKDB ([Application_RestoreTest]) WITH NO_INFOMSGS, ALL_ERRORMSGS;
```

For point-in-time recovery, apply `STOPAT` consistently while applying the required logs, using an explicit, reviewed SQL-server-local timestamp. Do not recover the database until the log containing the target has been applied:

```sql
RESTORE LOG [Application_RestoreTest]
FROM DISK = N'D:\SQLBackups\sample-project\application\Log_containing_target.trn'
WITH CHECKSUM, STOP_ON_ERROR, STOPAT = '2026-01-15T10:30:00', NORECOVERY;
RESTORE DATABASE [Application_RestoreTest] WITH RECOVERY;
```

Replace the example time. Validate that it falls within the available chain. Under BULK_LOGGED, a log backup containing bulk operations may require restoration to the end of that log. A missing/corrupt log can prevent reaching later points even when later files are readable. Preserve the full chain and investigate other backup systems if a gap is reported. Never skip a SQL restore error and declare recovery successful.

## Production incident

Stop application writes and coordinate with the DBA. If the source log is still accessible, assess a **tail-log backup** before restoring to reduce data loss. Tail-log operations can change database availability; they are deliberately not automated by this tool. Preserve originals, copy recovery media to protected working storage, and record the chosen recovery point. Obtain approval before replacing an existing database or removing the restored test database.

Database backups do not include instance-level logins, server configuration, certificates, linked servers or application configuration. Maintain those separately. Confirm login/user mapping and application prerequisites during disaster-recovery tests.

References: [Restore SQL databases](https://learn.microsoft.com/en-us/sql/relational-databases/backup-restore/restore-and-recovery-overview-sql-server), [apply transaction logs](https://learn.microsoft.com/en-us/sql/relational-databases/backup-restore/apply-transaction-log-backups-sql-server), [tail-log backups](https://learn.microsoft.com/en-us/sql/relational-databases/backup-restore/tail-log-backups-sql-server).
