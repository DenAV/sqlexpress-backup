#requires -Version 5.1
BeforeDiscovery {
    Import-Module (Join-Path $PSScriptRoot '../src/SqlExpressBackup.psm1') -Force
}
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/SqlExpressBackup.psm1')
    $script:examplePath = Join-Path $PSScriptRoot '../config/project.example.json'
}

Describe 'Configuration boundaries' {
    BeforeEach {
        $config = Get-Content -LiteralPath $script:examplePath -Raw | ConvertFrom-Json
        $path = Join-Path $TestDrive 'config.json'
    }
    It 'accepts both supplied profiles' {
        (Read-BackupConfiguration $script:examplePath).SchemaVersion | Should -Be 1
        $exos = Read-BackupConfiguration (Join-Path $PSScriptRoot '../config/exos9300.example.json')
        @($exos.Jobs | Where-Object { $_.Kind -eq 'Procedure' -and $_.Enabled }).Count | Should -Be 0
    }
    It 'rejects a remote instance' {
        $config.Instance = 'server.example.com\SQLEXPRESS'
        $config | ConvertTo-Json -Depth 8 | Set-Content $path
        { Read-BackupConfiguration $path } | Should -Throw '*only local*'
    }
    It 'rejects duplicate database identities' {
        $config.Databases = @($config.Databases[0], $config.Databases[0])
        $config | ConvertTo-Json -Depth 8 | Set-Content $path
        { Read-BackupConfiguration $path } | Should -Throw '*duplicate*'
    }
    It 'rejects invalid storage paths: <BadPath>' -ForEach @(
        @{ BadPath = '..\backups' }, @{ BadPath = 'D:\backups\..\data' },
        @{ BadPath = 'D:\backups\*' }, @{ BadPath = 'D:\' },
        @{ BadPath = 'D:\backups:stream' }, @{ BadPath = 'D:\backups.\child' }
    ) {
        $config.BackupRoot = $BadPath
        $config | ConvertTo-Json -Depth 8 | Set-Content $path
        { Read-BackupConfiguration $path } | Should -Throw '*Storage paths*'
    }
    It 'accepts UNC paths and weekly schedules' {
        $config.BackupRoot = '\\server.example.com\backups'
        $config.Jobs[0].Schedule = @{ Mode = 'Weekly'; At = '03:00'; Days = @('Monday', 'Friday') }
        $config | ConvertTo-Json -Depth 8 | Set-Content $path
        (Read-BackupConfiguration $path).Jobs[0].Schedule.Mode | Should -Be 'Weekly'
    }
    It 'rejects a zero interval' {
        $config.Jobs[1].Schedule.EveryMinutes = 0
        $config | ConvertTo-Json -Depth 8 | Set-Content $path
        { Read-BackupConfiguration $path } | Should -Throw '*EveryMinutes*'
    }
    It 'rejects job kind casing that would create unrecognized filenames' {
        $config.Jobs[0].Kind = 'full'
        $config | ConvertTo-Json -Depth 8 | Set-Content $path
        { Read-BackupConfiguration $path } | Should -Throw '*case-sensitive*'
    }
    It 'rejects string booleans' {
        $config.CleanupEnabled = 'false'
        $config | ConvertTo-Json -Depth 8 | Set-Content $path
        { Read-BackupConfiguration $path } | Should -Throw '*boolean*'
    }
    It 'does not write files or connect to SQL under WhatIf' {
        { Invoke-BackupJob -ConfigPath $script:examplePath -JobId full -WhatIf } | Should -Not -Throw
    }
}

Describe 'Retention recovery window' {
    InModuleScope SqlExpressBackup {
        BeforeAll {
            function New-TestRecord {
                param([string]$Name, [string]$Kind, [datetime]$Started, [datetime]$Completed = $Started.AddMinutes(1))
                [pscustomobject]@{
                    FileName = $Name; Kind = $Kind; Started = $Started; Completed = $Completed
                    FamilyGuid = 'family1'; RecoveryForkId = 'fork1'
                }
            }
        }
        It 'keeps the full before the cutoff and all overlapping/subsequent logs' {
            $records = @(
                New-TestRecord old Full '2026-01-01'
                New-TestRecord oldLog Log '2026-01-02'
                New-TestRecord anchor Full '2026-01-09'
                New-TestRecord overlap Log '2026-01-08' '2026-01-09T01:00:00'
                New-TestRecord newerLog Log '2026-01-10'
                New-TestRecord recent Full '2026-01-11'
                New-TestRecord newest Full '2026-01-12'
            )
            $candidates = @(Get-RetentionCandidate $records ([datetime]'2026-01-10') 2)
            $candidates.FileName | Should -Be @('old', 'oldLog')
        }
        It 'keeps a minimum number of full backups even after a prolonged outage' {
            $records = @(
                New-TestRecord old Full '2026-01-01'
                New-TestRecord second Full '2026-01-02'
                New-TestRecord newest Full '2026-01-03'
            )
            @(Get-RetentionCandidate $records ([datetime]'2026-03-01') 2).FileName | Should -Be @('old')
        }
        It 'deletes nothing without an anchor before the window' {
            $records = @(
                New-TestRecord first Full '2026-01-11'
                New-TestRecord second Full '2026-01-12'
                New-TestRecord newest Full '2026-01-13'
            )
            @(Get-RetentionCandidate $records ([datetime]'2026-01-10') 2).Count | Should -Be 0
        }
        It 'does not conflate restored databases or forks' {
            $records = @(
                New-TestRecord first Full '2026-01-01'
                New-TestRecord second Full '2026-01-02'
                New-TestRecord newest Full '2026-01-03'
            )
            $records[2].RecoveryForkId = 'fork2'
            { Get-RetentionCandidate $records ([datetime]'2026-03-01') 2 } | Should -Throw '*recovery forks*'
        }
        It 'keeps the latest two when there are no older full backups to remove' {
            $records = @(
                New-TestRecord first Full '2026-01-01'
                New-TestRecord second Full '2026-01-02'
            )
            @(Get-RetentionCandidate $records ([datetime]'2026-03-01') 2).Count | Should -Be 0
        }
    }
}

Describe 'Backup verification and failures' {
    InModuleScope SqlExpressBackup {
        BeforeEach {
            $config = [pscustomobject]@{ ProjectId = 'test'; Instance = '.\SQLEXPRESS'; CommandTimeoutSeconds = 60 }
            $database = [pscustomobject]@{ Name = "Application]';--"; Id = 'application' }
            $job = [pscustomobject]@{ Kind = 'Full' }
            $directory = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            [void](New-Item -ItemType Directory -Path $directory)
            $script:header = [pscustomobject]@{
                DatabaseName = $database.Name; BackupType = 1; HasBackupChecksums = $true; IsDamaged = $false
                BackupSetGUID = [guid]::NewGuid(); FamilyGUID = [guid]::NewGuid(); RecoveryForkID = [guid]::NewGuid()
                FirstLSN = [decimal]100; LastLSN = [decimal]200; CheckpointLSN = [decimal]150
            }
            Mock Invoke-BackupSql {
                if ($Sql -like 'BACKUP *') { [IO.File]::WriteAllText($Parameters.path, 'simulated backup') }
                if ($Sql -like 'RESTORE HEADERONLY*') { return [pscustomobject]@{ Rows = @($script:header) } }
            }
        }
        It 'parameterizes identifiers and paths and writes a manifest only after verification' {
            $record = Invoke-DatabaseBackup $null $config $job $database $directory
            $record.Verified | Should -BeTrue
            @(Get-BackupRecord $directory $config $database).Count | Should -Be 1
            Should -Invoke Invoke-BackupSql -Times 1 -ParameterFilter {
                $Sql -eq 'BACKUP DATABASE @database TO DISK = @path WITH CHECKSUM, NO_COMPRESSION, STOP_ON_ERROR;' -and
                $Parameters.database -eq "Application]';--"
            }
            Should -Invoke Invoke-BackupSql -Times 1 -ParameterFilter { $Sql -like 'RESTORE VERIFYONLY*' }
        }
        It 'does not record an unsuccessful backup as verified' {
            Mock Invoke-BackupSql { throw 'SQL disk full' } -ParameterFilter { $Sql -like 'BACKUP *' }
            { Invoke-DatabaseBackup $null $config $job $database $directory } | Should -Throw '*disk full*'
            @(Get-ChildItem $directory -Filter '*.backup.json').Count | Should -Be 0
            Should -Invoke Invoke-BackupSql -Times 0 -ParameterFilter { $Sql -like 'RESTORE VERIFYONLY*' }
        }
        It 'retains an unverified file for investigation without a success manifest' {
            Mock Invoke-BackupSql { throw 'Checksum failure' } -ParameterFilter { $Sql -like 'RESTORE VERIFYONLY*' }
            { Invoke-DatabaseBackup $null $config $job $database $directory } | Should -Throw '*Checksum*'
            @(Get-ChildItem $directory -Filter '*.bak').Count | Should -Be 1
            @(Get-ChildItem $directory -Filter '*.backup.json').Count | Should -Be 0
        }
        It 'can take a new full backup even if old manifests are damaged' {
            Set-Content -LiteralPath (Join-Path $directory 'broken.backup.json') -Value 'invalid json'
            { Invoke-DatabaseBackup $null $config $job $database $directory } | Should -Not -Throw
        }
        It 'blocks logs before the initial managed full backup' {
            $job.Kind = 'Log'
            { Invoke-DatabaseBackup $null $config $job $database $directory } | Should -Throw '*initial Full*'
            Should -Invoke Invoke-BackupSql -Times 0
        }
        It 'rejects a header for a different database' {
            $script:header.DatabaseName = 'OtherDatabase'
            { Invoke-DatabaseBackup $null $config $job $database $directory } | Should -Throw '*header validation*'
            @(Get-ChildItem $directory -Filter '*.backup.json').Count | Should -Be 0
        }
        It 'escapes bracketed identifiers for maintenance without injecting SQL' {
            ConvertTo-SqlIdentifier "Name]; DROP DATABASE x;--" | Should -Be '[Name]]; DROP DATABASE x;--]'
        }
        It 'rejects tampered manifest paths before accessing a sibling directory' {
            $record = Invoke-DatabaseBackup $null $config $job $database $directory
            $manifest = Join-Path $directory ($record.FileName + '.backup.json')
            $record.FileName = '..\another.bak'
            $record | ConvertTo-Json | Set-Content $manifest
            { Get-BackupRecord $directory $config $database } | Should -Throw '*Unrecognized*'
        }
        It 'rejects changed backup length' {
            $record = Invoke-DatabaseBackup $null $config $job $database $directory
            Add-Content -LiteralPath (Join-Path $directory $record.FileName) -Value 'tampered'
            { Get-BackupRecord $directory $config $database } | Should -Throw '*changed*'
        }
        It 'saves and validates a log that overlaps the full backup LSN' {
            [void](Invoke-DatabaseBackup $null $config $job $database $directory)
            $job.Kind = 'Log'
            $script:header.BackupType = 2
            $script:header.BackupSetGUID = [guid]::NewGuid()
            $script:header.FirstLSN = [decimal]180
            $script:header.LastLSN = [decimal]250
            $record = Invoke-DatabaseBackup $null $config $job $database $directory
            $record.Kind | Should -Be 'Log'
            @(Get-BackupRecord $directory $config $database).Count | Should -Be 2
        }
        It 'reports an external log gap after preserving the new log' {
            [void](Invoke-DatabaseBackup $null $config $job $database $directory)
            $job.Kind = 'Log'
            $script:header.BackupType = 2
            $script:header.BackupSetGUID = [guid]::NewGuid()
            $script:header.FirstLSN = [decimal]300
            $script:header.LastLSN = [decimal]400
            { Invoke-DatabaseBackup $null $config $job $database $directory } | Should -Throw '*Log chain gap*'
            @(Get-ChildItem $directory -Filter '*.trn').Count | Should -Be 1
        }
    }
}

Describe 'Filesystem retention safeguards' {
    InModuleScope SqlExpressBackup {
        BeforeEach {
            $directory = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            [void](New-Item -ItemType Directory -Path $directory)
            $config = [pscustomobject]@{ RetentionDays = 30; MinimumFullBackups = 2; CommandTimeoutSeconds = 60 }
            $database = [pscustomobject]@{ Name = 'Application' }
            $script:records = @(
                foreach ($days in @(60, 31, 1)) {
                    $path = Join-Path $directory ("Full_$days.bak")
                    Set-Content -LiteralPath $path -Value 'backup'
                    Set-Content -LiteralPath ($path + '.backup.json') -Value 'manifest'
                    [pscustomobject]@{
                        FileName = "Full_$days.bak"; Kind = 'Full'
                        Started = [DateTime]::UtcNow.AddDays(-$days)
                        Completed = [DateTime]::UtcNow.AddDays(-$days).AddMinutes(1)
                        FamilyGuid = 'family'; RecoveryForkId = 'fork'; BackupSetGuid = "guid-$days"
                        BackupPath = $path; ManifestPath = $path + '.backup.json'
                    }
                }
            )
            Mock Get-BackupRecord { $script:records }
            Mock Invoke-BackupSql {
                if ($Sql -like 'RESTORE HEADERONLY*') {
                    $record = $script:records | Where-Object BackupPath -eq $Parameters.path
                    [pscustomobject]@{ Rows = @([pscustomobject]@{ BackupSetGUID = $record.BackupSetGuid }) }
                }
            }
            Mock Write-BackupEvent {}
        }
        It 'deletes only expired recognized files after verifying the anchor and headers' {
            Remove-ExpiredBackup $null $config $database $directory 'unused' 'run' -Confirm:$false
            Test-Path -LiteralPath $script:records[0].BackupPath | Should -BeFalse
            Test-Path -LiteralPath $script:records[0].ManifestPath | Should -BeFalse
            Test-Path -LiteralPath $script:records[1].BackupPath | Should -BeTrue
            Test-Path -LiteralPath $script:records[2].BackupPath | Should -BeTrue
            Should -Invoke Invoke-BackupSql -Times 1 -ParameterFilter { $Sql -like 'RESTORE VERIFYONLY*' }
            Should -Invoke Invoke-BackupSql -Times 2 -ParameterFilter { $Sql -like 'RESTORE HEADERONLY*' }
        }
        It 'does not delete anything when anchor verification fails' {
            Mock Invoke-BackupSql { throw 'Anchor corrupt' } -ParameterFilter { $Sql -like 'RESTORE VERIFYONLY*' }
            { Remove-ExpiredBackup $null $config $database $directory 'unused' 'run' -Confirm:$false } | Should -Throw '*Anchor corrupt*'
            @(Get-ChildItem $directory -Filter '*.bak').Count | Should -Be 3
        }
        It 'does not delete anything if a candidate has been replaced' {
            Mock Invoke-BackupSql {
                [pscustomobject]@{ Rows = @([pscustomobject]@{ BackupSetGUID = 'replaced' }) }
            } -ParameterFilter { $Sql -like 'RESTORE HEADERONLY*' -and $Parameters.path -like '*Full_60.bak' }
            { Remove-ExpiredBackup $null $config $database $directory 'unused' 'run' -Confirm:$false } | Should -Throw '*identity mismatch*'
            @(Get-ChildItem $directory -Filter '*.bak').Count | Should -Be 3
        }
        It 'honors WhatIf on cleanup' {
            Remove-ExpiredBackup $null $config $database $directory 'unused' 'run' -WhatIf
            @(Get-ChildItem $directory -Filter '*.bak').Count | Should -Be 3
            @(Get-ChildItem $directory -Filter '*.backup.json').Count | Should -Be 3
        }
        It 'restores the manifest if backup-file removal fails' {
            Mock Remove-Item { throw 'Access denied' } -ParameterFilter { $LiteralPath -like '*.bak' }
            { Remove-ExpiredBackup $null $config $database $directory 'unused' 'run' -Confirm:$false } | Should -Throw '*Access denied*'
            Test-Path -LiteralPath $script:records[0].BackupPath | Should -BeTrue
            Test-Path -LiteralPath $script:records[0].ManifestPath | Should -BeTrue
        }
    }
}

Describe 'SQL preflight' {
    InModuleScope SqlExpressBackup {
        BeforeEach {
            $config = [pscustomobject]@{ Jobs = @([pscustomobject]@{ Kind = 'Log'; Enabled = $true }) }
            $job = [pscustomobject]@{ Kind = 'Full' }
            $script:state = [pscustomobject]@{ MajorVersion = 12; state_desc = 'ONLINE'; recovery_model_desc = 'FULL'; CanBackup = 1; CanVerify = 1 }
            Mock Invoke-BackupSql { [pscustomobject]@{ Rows = @($script:state) } }
        }
        It 'accepts SQL 2014 and 2025 without changing the recovery model' {
            (Test-DatabaseRequirement $null $config $job).MajorVersion | Should -Be 12
            $script:state.MajorVersion = 17
            (Test-DatabaseRequirement $null $config $job).MajorVersion | Should -Be 17
            Should -Invoke Invoke-BackupSql -Times 0 -ParameterFilter { $Sql -match 'ALTER DATABASE' }
        }
        It 'rejects SIMPLE when logs are scheduled' {
            $script:state.recovery_model_desc = 'SIMPLE'
            { Test-DatabaseRequirement $null $config $job } | Should -Throw '*Log backups require*'
        }
        It 'requires log scheduling for FULL recovery' {
            $config.Jobs[0].Enabled = $false
            { Test-DatabaseRequirement $null $config $job } | Should -Throw '*requires an enabled Log*'
        }
        It 'accepts full-only backups for SIMPLE recovery' {
            $config.Jobs[0].Enabled = $false
            $script:state.recovery_model_desc = 'SIMPLE'
            { Test-DatabaseRequirement $null $config $job } | Should -Not -Throw
        }
        It 'does not silently omit an offline database' {
            $script:state.state_desc = 'OFFLINE'
            { Test-DatabaseRequirement $null $config $job } | Should -Throw '*ONLINE*'
        }
        It 'requires verification permission separately from backup permission' {
            $script:state.CanVerify = 0
            { Test-DatabaseRequirement $null $config $job } | Should -Throw '*CREATE ANY DATABASE*'
        }
    }
}

Describe 'Run orchestration' {
    InModuleScope SqlExpressBackup {
        BeforeEach {
            $script:savedOs = $env:OS
            $env:OS = 'Windows_NT'
            $script:config = [pscustomobject]@{
                ProjectId = 'test'; LogRoot = $TestDrive; BackupRoot = $TestDrive
                LockTimeoutSeconds = 1; CleanupEnabled = $false
                Jobs = @([pscustomobject]@{ Id = 'full'; Kind = 'Full'; Enabled = $true })
                Databases = @(
                    [pscustomobject]@{ Name = 'First'; Id = 'first' },
                    [pscustomobject]@{ Name = 'Second'; Id = 'second' }
                )
            }
            $logDirectory = Join-Path $TestDrive 'test'
            if (-not (Test-Path $logDirectory)) { [void](New-Item -ItemType Directory -Path $logDirectory) }
            Mock Read-BackupConfiguration { $script:config }
            Mock Assert-SafeDirectory {}
            # Use a disposable object to exercise the real finally path.
            Mock Connect-BackupDatabase {
                $connection = [pscustomobject]@{}
                $connection | Add-Member -MemberType ScriptMethod -Name Dispose -Value {}
                return $connection
            }
            Mock Test-DatabaseRequirement { [pscustomobject]@{ recovery_model_desc = 'FULL' } }
            Mock Invoke-BackupSql { [pscustomobject]@{ Rows = @([pscustomobject]@{ Result = 0 }) } }
            Mock Invoke-DatabaseBackup {
                if ($Database.Name -eq 'First') { throw 'SQL backup failed' }
                [pscustomobject]@{ FileName = 'verified.bak' }
            }
        }
        AfterEach { $env:OS = $script:savedOs }
        It 'attempts remaining databases and records an overall failure' {
            { Invoke-BackupJob -ConfigPath unused -JobId full } | Should -Throw '*1 database operation*'
            Should -Invoke Invoke-DatabaseBackup -Times 1 -ParameterFilter { $Database.Name -eq 'Second' }
            $events = @(Get-ChildItem (Join-Path $TestDrive 'test') -Filter '*.jsonl' | ForEach-Object {
                Get-Content $_.FullName | ForEach-Object { $_ | ConvertFrom-Json }
            })
            @($events | Where-Object { $_.Event -eq 'Run' -and $_.Status -eq 'Failed' }).Count | Should -BeGreaterThan 0
        }
        It 'preflight never invokes backup or acquires a write-work lock' {
            { Invoke-BackupJob -ConfigPath unused -JobId full -ValidateOnly } | Should -Not -Throw
            Should -Invoke Invoke-DatabaseBackup -Times 0
            Should -Invoke Invoke-BackupSql -Times 0
        }
        It 'does not run backup after a lock timeout' {
            Mock Invoke-BackupSql { [pscustomobject]@{ Rows = @([pscustomobject]@{ Result = -1 }) } }
            { Invoke-BackupJob -ConfigPath unused -JobId full } | Should -Throw '*2 database operation*'
            Should -Invoke Invoke-DatabaseBackup -Times 0
        }
    }
}
