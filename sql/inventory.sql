SELECT SERVERPROPERTY('ProductVersion') AS ProductVersion,
       SERVERPROPERTY('Edition') AS Edition,
       SERVERPROPERTY('InstanceName') AS InstanceName;

SELECT name, state_desc, recovery_model_desc, log_reuse_wait_desc,
       page_verify_option_desc
FROM sys.databases
WHERE database_id > 4;

SELECT name, physical_name FROM sys.backup_devices;

-- Run in the application database to discover EXOS procedure schemas.
SELECT s.name AS SchemaName, p.name AS ProcedureName
FROM sys.procedures AS p
JOIN sys.schemas AS s ON s.schema_id = p.schema_id
WHERE p.name IN (N'libIndexesDefrag', N'libShrinkExosLogTables');
