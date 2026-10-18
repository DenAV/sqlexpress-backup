#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-IntegerRange {
    param($Value, [string]$Name, [int]$Minimum, [int]$Maximum)
    if (($Value -isnot [int] -and $Value -isnot [long]) -or $Value -lt $Minimum -or $Value -gt $Maximum) {
        throw "$Name must be an integer from $Minimum to $Maximum."
    }
}

function Assert-WindowsPath {
    param([string]$Path)
    if ($Path -notmatch '^(?:[A-Za-z]:\\[^\\]|\\\\[^\\]+\\[^\\]+)' -or
        $Path -match '[\x00-\x1f"<>|?*]' -or $Path -match '(?:^|\\)\.\.?(?:\\|$)' -or
        $Path -match '[ .](?:\\|$)' -or $Path.Substring(2).Contains(':')) {
        throw 'Storage paths must be absolute Windows drive or UNC paths without traversal or wildcards.'
    }
}

function Read-BackupConfiguration {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $config = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($config.SchemaVersion -ne 1) { throw 'Unsupported configuration schema.' }
    if ($config.ProjectId -cnotmatch '^[a-z0-9][a-z0-9-]{0,47}$') { throw 'Invalid ProjectId.' }
    if ($config.Instance -notmatch '^\.(\\[A-Za-z][A-Za-z0-9_]{0,15})?$') {
        throw 'Instance must be . or .\INSTANCE; only local SQL Server is supported.'
    }
    Assert-WindowsPath $config.BackupRoot
    Assert-WindowsPath $config.LogRoot
    if ([string]::IsNullOrWhiteSpace($config.Account) -or $config.Account -match '[\r\n"]') { throw 'Invalid task account.' }
    Assert-IntegerRange $config.ConnectTimeoutSeconds 'ConnectTimeoutSeconds' 1 300
    Assert-IntegerRange $config.CommandTimeoutSeconds 'CommandTimeoutSeconds' 1 86400
    Assert-IntegerRange $config.LockTimeoutSeconds 'LockTimeoutSeconds' 0 3600
    Assert-IntegerRange $config.RetentionDays 'RetentionDays' 1 36500
    Assert-IntegerRange $config.MinimumFullBackups 'MinimumFullBackups' 2 1000
    if ($config.CleanupEnabled -isnot [bool]) { throw 'CleanupEnabled must be boolean.' }
    if (@($config.Databases).Count -eq 0 -or @($config.Jobs).Count -eq 0) { throw 'Databases and Jobs cannot be empty.' }
    $ids = @{}
    $names = @{}
    foreach ($database in $config.Databases) {
        if ($database.Id -cnotmatch '^[a-z0-9][a-z0-9-]{0,47}$' -or $ids.ContainsKey($database.Id)) { throw 'Invalid or duplicate database Id.' }
        if ([string]::IsNullOrWhiteSpace($database.Name) -or $database.Name.Length -gt 128 -or
            $database.Name -match '[\x00-\x1f]' -or $names.ContainsKey($database.Name) -or
            $database.Name -in @('master', 'model', 'msdb', 'tempdb')) { throw 'Invalid, duplicate or system database name.' }
        $ids[$database.Id] = $true
        $names[$database.Name] = $true
    }
    $ids = @{}
    foreach ($job in $config.Jobs) {
        if ($job.Id -cnotmatch '^[a-z0-9][a-z0-9-]{0,47}$' -or $ids.ContainsKey($job.Id)) { throw 'Invalid or duplicate job Id.' }
        $ids[$job.Id] = $true
        if ($job.Kind -cnotin @('Full', 'Log', 'CheckDb', 'Indexes', 'Procedure')) { throw 'Unsupported job kind; names are case-sensitive.' }
        if ($job.Enabled -isnot [bool]) { throw 'Enabled must be boolean.' }
        switch ($job.Schedule.Mode) {
            'Interval' { Assert-IntegerRange $job.Schedule.EveryMinutes 'EveryMinutes' 1 44640 }
            { $_ -in @('Daily', 'Weekly') } {
                if ($job.Schedule.At -notmatch '^(?:[01][0-9]|2[0-3]):[0-5][0-9]$') { throw 'At must use HH:mm.' }
                if ($job.Schedule.Mode -eq 'Weekly') {
                    if (@($job.Schedule.Days).Count -eq 0) { throw 'Weekly schedule needs Days.' }
                    foreach ($day in $job.Schedule.Days) {
                        if ($day -notin [Enum]::GetNames([DayOfWeek])) { throw 'Invalid weekday.' }
                    }
                }
            }
            default { throw 'Unsupported schedule mode.' }
        }
        if ($job.Kind -eq 'Procedure') {
            foreach ($value in @($job.ProcedureSchema, $job.ProcedureName)) {
                if ($value.Length -gt 128 -or $value -match '[\x00-\x1f]') { throw 'Invalid procedure identifier.' }
            }
            if ([string]::IsNullOrWhiteSpace($job.ProcedureName)) { throw 'ProcedureName is required.' }
            if ($job.Enabled -and [string]::IsNullOrWhiteSpace($job.ProcedureSchema)) { throw 'Confirm the procedure schema before enabling this job.' }
        }
        if ($job.Kind -eq 'Indexes') {
            Assert-IntegerRange $job.MinimumPages 'MinimumPages' 128 2147483647
            Assert-IntegerRange $job.MinimumFragmentationPercent 'MinimumFragmentationPercent' 1 99
        }
    }
    if (@($config.Jobs | Where-Object { $_.Enabled -and $_.Kind -eq 'Full' }).Count -ne 1) {
        throw 'Exactly one enabled Full job is required.'
    }
    if (@($config.Jobs | Where-Object { $_.Enabled -and $_.Kind -eq 'Log' }).Count -gt 1) { throw 'Only one enabled Log job is allowed.' }
    return $config
}

function ConvertTo-SqlIdentifier {
    param([Parameter(Mandatory)][string]$Value)
    return '[' + $Value.Replace(']', ']]') + ']'
}

function Connect-BackupDatabase {
    param($Config, [string]$Database = 'master')
    $builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $builder.DataSource = 'lpc:' + $Config.Instance
    $builder.InitialCatalog = $Database
    $builder.IntegratedSecurity = $true
    $builder.ConnectTimeout = $Config.ConnectTimeoutSeconds
    $builder.ApplicationName = 'SqlExpressBackup'
    $builder.Pooling = $false
    $connection = New-Object System.Data.SqlClient.SqlConnection $builder.ConnectionString
    try { $connection.Open() } catch { $connection.Dispose(); throw }
    return $connection
}

function Invoke-BackupSql {
    param($Connection, [string]$Sql, [hashtable]$Parameters = @{}, [int]$Timeout = 30)
    $command = $Connection.CreateCommand()
    $command.CommandText = $Sql
    $command.CommandTimeout = $Timeout
    try {
        foreach ($key in $Parameters.Keys) {
            $parameter = $command.Parameters.Add('@' + $key, [System.Data.SqlDbType]::NVarChar, 4000)
            $parameter.Value = [string]$Parameters[$key]
        }
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter $command
        $table = New-Object System.Data.DataTable
        try { [void]$adapter.Fill($table) } finally { $adapter.Dispose() }
        return ,$table
    } finally { $command.Dispose() }
}

function Assert-SafeDirectory {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force
    if (-not $item.PSIsContainer) { throw 'Expected a directory.' }
    while ($null -ne $item) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Reparse points are not allowed in managed storage paths.' }
        $item = $item.Parent
    }
}

function Get-DatabaseDirectory {
    param($Config, $Database)
    return Join-Path (Join-Path $Config.BackupRoot $Config.ProjectId) $Database.Id
}

function Get-BackupRecord {
    param([string]$Directory, $Config, $Database)
    Assert-SafeDirectory $Directory
    foreach ($file in Get-ChildItem -LiteralPath $Directory -Filter '*.backup.json' -File) {
        if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Linked manifest rejected.' }
        $record = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($record.SchemaVersion -ne 1 -or $record.ProjectId -ne $Config.ProjectId -or
            $record.Instance -ne $Config.Instance -or $record.Database -cne $Database.Name -or
            $record.Verified -isnot [bool] -or $record.Verified -ne $true -or $record.Kind -notin @('Full', 'Log') -or
            $record.FileName -cnotmatch '^(Full|Log)_[0-9]{8}T[0-9]{9}Z_[a-f0-9]{32}\.(bak|trn)$' -or
            $file.Name -cne ($record.FileName + '.backup.json') -or
            -not $record.FileName.StartsWith($record.Kind + '_', [StringComparison]::Ordinal)) {
            throw 'Unrecognized backup manifest; cleanup stopped.'
        }
        [void][guid]::Parse($record.BackupSetGuid)
        [void][guid]::Parse($record.FamilyGuid)
        [void][guid]::Parse($record.RecoveryForkId)
        [void][decimal]::Parse($record.FirstLsn, [Globalization.CultureInfo]::InvariantCulture)
        [void][decimal]::Parse($record.LastLsn, [Globalization.CultureInfo]::InvariantCulture)
        $started = [DateTimeOffset]::Parse($record.StartedUtc).UtcDateTime
        $completed = [DateTimeOffset]::Parse($record.CompletedUtc).UtcDateTime
        if ($completed -lt $started -or $completed -gt [DateTime]::UtcNow.AddMinutes(5)) { throw 'Invalid backup timestamps.' }
        $backupPath = Join-Path $Directory $record.FileName
        $backup = Get-Item -LiteralPath $backupPath -Force
        if ($backup.PSIsContainer -or ($backup.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            $backup.Length -ne $record.Length) { throw 'Backup file missing, linked or changed; cleanup stopped.' }
        $record | Add-Member -NotePropertyName Started -NotePropertyValue $started
        $record | Add-Member -NotePropertyName Completed -NotePropertyValue $completed
        $record | Add-Member -NotePropertyName BackupPath -NotePropertyValue $backupPath
        $record | Add-Member -NotePropertyName ManifestPath -NotePropertyValue $file.FullName
        $record
    }
}

function Get-RetentionCandidate {
    param([object[]]$Records, [datetime]$Cutoff, [int]$MinimumFullBackups)
    $full = @($Records | Where-Object Kind -eq 'Full' | Sort-Object Started -Descending)
    if ($full.Count -le $MinimumFullBackups) { return }
    if (@($Records | Select-Object -ExpandProperty FamilyGuid -Unique).Count -ne 1 -or
        @($Records | Select-Object -ExpandProperty RecoveryForkId -Unique).Count -ne 1) {
        throw 'Multiple database families or recovery forks; manual retention review required.'
    }
    $older = @($full | Where-Object { $_.Completed -le $Cutoff })
    if ($older.Count -eq 0) { return }
    $anchor = $older[0]
    $minimumAnchor = $full[$MinimumFullBackups - 1]
    if ($minimumAnchor.Started -lt $anchor.Started) { $anchor = $minimumAnchor }
    # Preserve an anchor before the window and every file which may overlap it.
    $Records | Where-Object { $_.Completed -lt $anchor.Started }
}

function Write-BackupEvent {
    param([string]$Path, [string]$RunId, [string]$EventName, [string]$Status, [string]$Database = '', [string]$Message = '')
    [ordered]@{
        TimestampUtc = [DateTime]::UtcNow.ToString('o'); RunId = $RunId
        Event = $EventName; Status = $Status; Database = $Database; Message = $Message
    } | ConvertTo-Json -Compress | Add-Content -LiteralPath $Path -Encoding UTF8
}

function Test-DatabaseRequirement {
    param($Connection, $Config, $Job)
    $result = Invoke-BackupSql $Connection @'
SELECT CONVERT(int, SERVERPROPERTY('ProductMajorVersion')) AS MajorVersion,
       state_desc, recovery_model_desc, is_read_only,
       HAS_PERMS_BY_NAME(DB_NAME(), 'DATABASE', 'BACKUP DATABASE') AS CanBackup,
       HAS_PERMS_BY_NAME(NULL, 'SERVER', 'CREATE ANY DATABASE') AS CanVerify
FROM sys.databases WHERE name = DB_NAME();
'@
    if ($result.Rows.Count -ne 1) { throw 'Cannot read database state.' }
    $row = $result.Rows[0]
    if ($row.MajorVersion -lt 12 -or $row.MajorVersion -gt 17) { throw 'Supported SQL Server versions are 2014 through 2025.' }
    if ($row.state_desc -ne 'ONLINE') { throw 'Database must be ONLINE.' }
    $logsEnabled = @($Config.Jobs | Where-Object { $_.Enabled -and $_.Kind -eq 'Log' }).Count -gt 0
    if (($logsEnabled -or $Job.Kind -eq 'Log') -and $row.recovery_model_desc -notin @('FULL', 'BULK_LOGGED')) {
        throw 'Log backups require FULL or BULK_LOGGED. Change the configuration or have the DBA approve a recovery-model change.'
    }
    if (-not $logsEnabled -and $row.recovery_model_desc -ne 'SIMPLE') {
        throw 'FULL/BULK_LOGGED requires an enabled Log job in this backup project.'
    }
    if ($Job.Kind -in @('Full', 'Log') -and ($row.CanBackup -ne 1 -or $row.CanVerify -ne 1)) {
        throw 'The login needs BACKUP DATABASE and CREATE ANY DATABASE (for VERIFYONLY/HEADERONLY).'
    }
    if ($Job.Kind -eq 'Procedure') {
        $procedure = Invoke-BackupSql $Connection @'
SELECT p.object_id FROM sys.procedures AS p
JOIN sys.schemas AS s ON s.schema_id = p.schema_id
WHERE s.name = @schema AND p.name = @name
AND HAS_PERMS_BY_NAME(QUOTENAME(s.name) + '.' + QUOTENAME(p.name), 'OBJECT', 'EXECUTE') = 1;
'@ @{ schema = $Job.ProcedureSchema; name = $Job.ProcedureName }
        if ($procedure.Rows.Count -ne 1) { throw 'Configured procedure is missing or EXECUTE is not granted.' }
    }
    if ($Job.Kind -eq 'CheckDb') {
        $permission = Invoke-BackupSql $Connection "SELECT IS_MEMBER('db_owner') AS IsOwner, IS_SRVROLEMEMBER('sysadmin') AS IsAdmin;"
        if ($permission.Rows[0].IsOwner -ne 1 -and $permission.Rows[0].IsAdmin -ne 1) { throw 'CHECKDB requires db_owner or sysadmin.' }
    }
    if ($Job.Kind -eq 'Indexes') {
        $permission = Invoke-BackupSql $Connection "SELECT HAS_PERMS_BY_NAME(DB_NAME(), 'DATABASE', 'ALTER') AS CanAlter, HAS_PERMS_BY_NAME(DB_NAME(), 'DATABASE', 'VIEW DATABASE STATE') AS CanView;"
        if ($permission.Rows[0].CanAlter -ne 1 -or $permission.Rows[0].CanView -ne 1) { throw 'Indexes job requires ALTER and VIEW DATABASE STATE; SQL 2022+ may also require VIEW DATABASE PERFORMANCE STATE.' }
        if ($row.MajorVersion -ge 16) {
            $permission = Invoke-BackupSql $Connection "SELECT HAS_PERMS_BY_NAME(DB_NAME(), 'DATABASE', 'VIEW DATABASE PERFORMANCE STATE') AS CanView;"
            if ($permission.Rows[0].CanView -ne 1) { throw 'SQL Server 2022+ index inspection requires VIEW DATABASE PERFORMANCE STATE.' }
        }
    }
    return $row
}

function Invoke-DatabaseBackup {
    param($Connection, $Config, $Job, $Database, [string]$Directory)
    $records = @()
    if ($Job.Kind -eq 'Log') { $records = @(Get-BackupRecord $Directory $Config $Database) }
    if ($Job.Kind -eq 'Log' -and @($records | Where-Object Kind -eq 'Full').Count -eq 0) {
        throw 'Run and verify an initial Full backup with this project before starting Log backups.'
    }
    $started = [DateTime]::UtcNow
    $extension = if ($Job.Kind -eq 'Full') { 'bak' } else { 'trn' }
    $fileName = '{0}_{1}_{2}.{3}' -f $Job.Kind, $started.ToString('yyyyMMddTHHmmssfffZ'), [guid]::NewGuid().ToString('N'), $extension
    $path = Join-Path $Directory $fileName
    if ($path.Length -ge 260) { throw 'Backup file path must be shorter than 260 characters for Windows PowerShell 5.1 compatibility.' }
    if (Test-Path -LiteralPath $path) { throw 'Backup destination already exists.' }
    $verb = if ($Job.Kind -eq 'Full') { 'DATABASE' } else { 'LOG' }
    $sql = "BACKUP $verb @database TO DISK = @path WITH CHECKSUM, NO_COMPRESSION, STOP_ON_ERROR;"
    [void](Invoke-BackupSql $Connection $sql @{ database = $Database.Name; path = $path } $Config.CommandTimeoutSeconds)
    [void](Invoke-BackupSql $Connection 'RESTORE VERIFYONLY FROM DISK = @path WITH CHECKSUM, STOP_ON_ERROR;' @{ path = $path } $Config.CommandTimeoutSeconds)
    $headerTable = Invoke-BackupSql $Connection 'RESTORE HEADERONLY FROM DISK = @path;' @{ path = $path } $Config.CommandTimeoutSeconds
    if ($headerTable.Rows.Count -ne 1) { throw 'Expected exactly one backup set.' }
    $header = $headerTable.Rows[0]
    $expectedType = if ($Job.Kind -eq 'Full') { 1 } else { 2 }
    if ($header.DatabaseName -cne $Database.Name -or $header.BackupType -ne $expectedType -or
        -not $header.HasBackupChecksums -or $header.IsDamaged) { throw 'Backup header validation failed.' }
    $file = Get-Item -LiteralPath $path
    $record = [ordered]@{
        SchemaVersion = 1; ProjectId = $Config.ProjectId; Instance = $Config.Instance
        Database = $Database.Name; Kind = $Job.Kind; FileName = $fileName
        StartedUtc = $started.ToString('o'); CompletedUtc = [DateTime]::UtcNow.ToString('o')
        Verified = $true; Length = $file.Length
        BackupSetGuid = [string]$header.BackupSetGUID; FamilyGuid = [string]$header.FamilyGUID
        RecoveryForkId = [string]$header.RecoveryForkID
        FirstLsn = ([decimal]$header.FirstLSN).ToString([Globalization.CultureInfo]::InvariantCulture)
        LastLsn = ([decimal]$header.LastLSN).ToString([Globalization.CultureInfo]::InvariantCulture)
        CheckpointLsn = ([decimal]$header.CheckpointLSN).ToString([Globalization.CultureInfo]::InvariantCulture)
    }
    $manifest = $path + '.backup.json'
    $record | ConvertTo-Json | Set-Content -LiteralPath ($manifest + '.partial') -Encoding UTF8
    Move-Item -LiteralPath ($manifest + '.partial') -Destination $manifest
    if ($Job.Kind -eq 'Log') {
        $previous = @($records | Where-Object Kind -eq 'Log' | Sort-Object Completed -Descending)
        $full = @($records | Where-Object Kind -eq 'Full' | Sort-Object Completed -Descending)[0]
        if ($full.FamilyGuid -ne $record.FamilyGuid -or $full.RecoveryForkId -ne $record.RecoveryForkId) {
            throw 'Recovery fork/database changed. Backup saved; take a new Full backup and review the restore chain.'
        }
        $requiredLsn = [decimal]$full.LastLsn
        if ($previous.Count -gt 0 -and $previous[0].Completed -gt $full.Completed) { $requiredLsn = [decimal]$previous[0].LastLsn }
        if ([decimal]$record.FirstLsn -gt $requiredLsn) { throw 'Log chain gap detected. Backup saved; investigate other backup tools/recovery-model changes and take a new Full backup.' }
    }
    return [pscustomobject]$record
}

function Remove-ExpiredBackup {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param($Connection, $Config, $Database, [string]$Directory, [string]$LogPath, [string]$RunId)
    $records = @(Get-BackupRecord $Directory $Config $Database)
    $candidates = @(Get-RetentionCandidate $records ([DateTime]::UtcNow.AddDays(-$Config.RetentionDays)) $Config.MinimumFullBackups)
    if ($candidates.Count -eq 0) { return }
    $keptFull = @($records | Where-Object { $_.Kind -eq 'Full' -and $_ -notin $candidates } | Sort-Object Started)
    $anchor = $keptFull[0]
    [void](Invoke-BackupSql $Connection 'RESTORE VERIFYONLY FROM DISK = @path WITH CHECKSUM, STOP_ON_ERROR;' @{ path = $anchor.BackupPath } $Config.CommandTimeoutSeconds)
    # Check all identities before deleting anything; manifests alone are not deletion authority.
    foreach ($record in @($anchor) + $candidates) {
        $header = Invoke-BackupSql $Connection 'RESTORE HEADERONLY FROM DISK = @path;' @{ path = $record.BackupPath } $Config.CommandTimeoutSeconds
        if ($header.Rows.Count -ne 1 -or [string]$header.Rows[0].BackupSetGUID -ne $record.BackupSetGuid) { throw 'Backup identity mismatch; cleanup stopped.' }
    }
    foreach ($record in $candidates | Sort-Object Completed) {
        if ($PSCmdlet.ShouldProcess($record.BackupPath, 'Delete expired managed backup and manifest')) {
            $expiredManifest = $record.ManifestPath + '.expired'
            Move-Item -LiteralPath $record.ManifestPath -Destination $expiredManifest
            try { Remove-Item -LiteralPath $record.BackupPath -Force } catch {
                Move-Item -LiteralPath $expiredManifest -Destination $record.ManifestPath
                throw
            }
            Remove-Item -LiteralPath $expiredManifest -Force
            Write-BackupEvent $LogPath $RunId 'Retention' 'Deleted' $Database.Name $record.FileName
        }
    }
}

function Invoke-DatabaseMaintenance {
    param($Connection, $Config, $Job, $Database)
    $quotedDatabase = ConvertTo-SqlIdentifier $Database.Name
    switch ($Job.Kind) {
        'CheckDb' {
            [void](Invoke-BackupSql $Connection "DBCC CHECKDB ($quotedDatabase) WITH NO_INFOMSGS, ALL_ERRORMSGS;" @{} $Config.CommandTimeoutSeconds)
        }
        'Procedure' {
            $procedure = (ConvertTo-SqlIdentifier $Job.ProcedureSchema) + '.' + (ConvertTo-SqlIdentifier $Job.ProcedureName)
            [void](Invoke-BackupSql $Connection "DECLARE @result int; EXEC @result = $procedure; IF @result <> 0 THROW 51000, 'Maintenance procedure returned a nonzero status.', 1;" @{} $Config.CommandTimeoutSeconds)
        }
        'Indexes' {
            $indexes = Invoke-BackupSql $Connection @'
SELECT s.name AS SchemaName, o.name AS TableName, i.name AS IndexName, p.partition_number
FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'LIMITED') AS p
JOIN sys.indexes AS i ON i.object_id = p.object_id AND i.index_id = p.index_id
JOIN sys.objects AS o ON o.object_id = i.object_id
JOIN sys.schemas AS s ON s.schema_id = o.schema_id
WHERE o.type = 'U' AND o.is_ms_shipped = 0 AND i.type IN (1, 2)
AND i.is_disabled = 0 AND i.is_hypothetical = 0 AND i.allow_page_locks = 1
AND p.index_level = 0 AND p.alloc_unit_type_desc = 'IN_ROW_DATA'
AND p.page_count >= CONVERT(int, @pages)
AND p.avg_fragmentation_in_percent >= CONVERT(int, @fragmentation);
'@ @{ pages = $Job.MinimumPages; fragmentation = $Job.MinimumFragmentationPercent } $Config.CommandTimeoutSeconds
            foreach ($index in $indexes.Rows) {
                $table = (ConvertTo-SqlIdentifier $index.SchemaName) + '.' + (ConvertTo-SqlIdentifier $index.TableName)
                $name = ConvertTo-SqlIdentifier $index.IndexName
                $partition = [int]$index.partition_number
                [void](Invoke-BackupSql $Connection "ALTER INDEX $name ON $table REORGANIZE PARTITION = $partition;" @{} $Config.CommandTimeoutSeconds)
            }
        }
    }
}

function Invoke-BackupJob {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$ConfigPath, [Parameter(Mandatory)][string]$JobId, [switch]$ValidateOnly)
    $config = Read-BackupConfiguration $ConfigPath
    $jobs = @($config.Jobs | Where-Object Id -eq $JobId)
    if ($jobs.Count -ne 1 -or -not $jobs[0].Enabled) { throw 'Job not found or disabled.' }
    $job = $jobs[0]
    if (-not $ValidateOnly -and -not $PSCmdlet.ShouldProcess($config.ProjectId, "Run $JobId for configured databases")) { return }
    if ($env:OS -ne 'Windows_NT') { throw 'Execution requires Windows PowerShell 5.1 on the SQL Server host.' }
    $runId = [guid]::NewGuid().ToString('N')
    $started = [DateTime]::UtcNow
    $logDirectory = Join-Path $config.LogRoot $config.ProjectId
    Assert-SafeDirectory $logDirectory
    $logPath = Join-Path $logDirectory ($started.ToString('yyyyMMddTHHmmssfffZ') + '_' + $JobId + '_' + $runId + '.jsonl')
    $failed = 0
    Write-BackupEvent $logPath $runId 'Run' 'Started' '' $JobId
    foreach ($database in $config.Databases) {
        $connection = $null
        try {
            $directory = Get-DatabaseDirectory $config $database
            Assert-SafeDirectory $directory
            $connection = Connect-BackupDatabase $config $database.Name
            $state = Test-DatabaseRequirement $connection $config $job
            if ($ValidateOnly) {
                [pscustomobject]@{ Database = $database.Name; Job = $JobId; RecoveryModel = $state.recovery_model_desc; Status = 'PreflightPassed' }
                Write-BackupEvent $logPath $runId 'Preflight' 'Success' $database.Name
                continue
            }
            # Database-scoped session lock also serializes different projects/accounts for this DB.
            $lock = Invoke-BackupSql $connection @'
DECLARE @result int;
EXEC @result = sys.sp_getapplock @Resource = N'SqlExpressBackup.Database',
    @LockMode = 'Exclusive', @LockOwner = 'Session', @LockTimeout = @milliseconds;
SELECT @result AS Result;
'@ @{ milliseconds = $config.LockTimeoutSeconds * 1000 } ($config.LockTimeoutSeconds + 30)
            if ($lock.Rows[0].Result -lt 0) { throw 'Another backup/maintenance run holds the database lock.' }
            if ($job.Kind -in @('Full', 'Log')) {
                $record = Invoke-DatabaseBackup $connection $config $job $database $directory
                Write-BackupEvent $logPath $runId 'Backup' 'Verified' $database.Name $record.FileName
                if ($job.Kind -eq 'Full' -and $config.CleanupEnabled) {
                    Remove-ExpiredBackup $connection $config $database $directory $logPath $runId -Confirm:$false
                }
            } else {
                Invoke-DatabaseMaintenance $connection $config $job $database
            }
            Write-BackupEvent $logPath $runId 'Database' 'Success' $database.Name
        } catch {
            $failed++
            Write-BackupEvent $logPath $runId 'Database' 'Failed' $database.Name $_.Exception.Message
            Write-Warning ("Database '{0}' failed: {1}" -f $database.Name, $_.Exception.Message)
        } finally {
            if ($null -ne $connection) { $connection.Dispose() }
        }
    }
    $status = if ($failed -eq 0) { 'Success' } else { 'Failed' }
    $summary = [ordered]@{
        Job = $JobId; Databases = @($config.Databases).Count; Failed = $failed
        DurationSeconds = [math]::Round(([DateTime]::UtcNow - $started).TotalSeconds, 2)
    } | ConvertTo-Json -Compress
    Write-BackupEvent $logPath $runId 'Run' $status '' $summary
    if ($failed -gt 0) { throw "$failed database operation(s) failed. See the protected run log." }
    [pscustomobject]@{ RunId = $runId; Status = $status; LogPath = $logPath }
}

Export-ModuleMember -Function Read-BackupConfiguration, Invoke-BackupJob
