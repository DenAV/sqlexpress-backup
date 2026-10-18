-- Run as a SQL administrator after replacing the login and database placeholders.
-- SYSTEM is supported, but is not automatically a SQL administrator.
-- For the SYSTEM profile, replace [DOMAIN\sql-backup] with [NT AUTHORITY\SYSTEM].
USE [master];
GO
IF SUSER_ID(N'DOMAIN\sql-backup') IS NULL
    CREATE LOGIN [DOMAIN\sql-backup] FROM WINDOWS;
GRANT CONNECT SQL TO [DOMAIN\sql-backup];
-- Required by RESTORE VERIFYONLY and RESTORE HEADERONLY. This also permits
-- database creation; a DBA must approve this grant to the dedicated account.
GRANT CREATE ANY DATABASE TO [DOMAIN\sql-backup];
GO
USE [ApplicationDatabase];
GO
IF USER_ID(N'DOMAIN\sql-backup') IS NULL
    CREATE USER [DOMAIN\sql-backup] FOR LOGIN [DOMAIN\sql-backup];
GRANT CONNECT TO [DOMAIN\sql-backup];
GRANT BACKUP DATABASE TO [DOMAIN\sql-backup];
GRANT BACKUP LOG TO [DOMAIN\sql-backup];
GO
-- Optional EXOS jobs: confirm the actual schemas and vendor requirements first.
-- GRANT EXECUTE ON OBJECT::[dbo].[libIndexesDefrag] TO [DOMAIN\sql-backup];
-- GRANT EXECUTE ON OBJECT::[dbo].[libShrinkExosLogTables] TO [DOMAIN\sql-backup];
-- Procedures using dynamic SQL may need additional permissions: inspect their code.

-- Optional generic Indexes job:
-- GRANT VIEW DATABASE STATE TO [DOMAIN\sql-backup];
-- GRANT ALTER TO [DOMAIN\sql-backup];
-- On SQL Server 2022+ also grant VIEW DATABASE PERFORMANCE STATE as needed.

-- CHECKDB requires db_owner or sysadmin. Prefer a separate maintenance account
-- and DBA-run CHECKDB rather than elevating the backup account automatically.
