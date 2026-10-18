#requires -Version 5.1
#requires -Modules ScheduledTasks
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [System.Management.Automation.PSCredential]$Credential,
    [switch]$Enable
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\SqlExpressBackup.psm1') -Force
$config = Read-BackupConfiguration $ConfigPath
$resolvedConfig = (Resolve-Path -LiteralPath $ConfigPath).ProviderPath
$runner = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot 'Invoke-SqlExpressBackup.ps1')).ProviderPath
if ($resolvedConfig -match '["\r\n]' -or $runner -match '["\r\n]') { throw 'Invalid script/configuration path.' }
if ($resolvedConfig.StartsWith('\\') -or $runner.StartsWith('\\')) { throw 'Scripts and configuration must be installed on a local disk.' }
$isSystem = $config.Account -in @('SYSTEM', 'NT AUTHORITY\SYSTEM', 'S-1-5-18')
if (-not $isSystem -and -not $WhatIfPreference) {
    if ($null -eq $Credential) { $Credential = Get-Credential -UserName $config.Account -Message 'Account used by the backup scheduled tasks' }
    if ($null -eq $Credential -or $Credential.UserName -ine $config.Account) { throw 'Credential must match Account in the configuration.' }
}
$taskPath = '\SqlExpressBackup\' + $config.ProjectId + '\'
$powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$ownedDescription = 'Managed by SqlExpressBackup schema 1.'
$taskFolderReady = $false
$existing = @(Get-ScheduledTask | Where-Object TaskPath -eq $taskPath)
foreach ($task in $existing) {
    if ($task.Description -ne $ownedDescription) { throw 'Task folder contains unmanaged tasks; refusing to overwrite.' }
}
foreach ($job in $config.Jobs | Where-Object Enabled) {
    $arguments = '-NoLogo -NoProfile -NonInteractive -File "{0}" -ConfigPath "{1}" -JobId "{2}"' -f $runner, $resolvedConfig, $job.Id
    $action = New-ScheduledTaskAction -Execute $powerShell -Argument $arguments -WorkingDirectory $PSScriptRoot
    switch ($job.Schedule.Mode) {
        'Daily' { $trigger = New-ScheduledTaskTrigger -Daily -At ([datetime]::Today.Add([timespan]::Parse($job.Schedule.At))) }
        'Weekly' { $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $job.Schedule.Days -At ([datetime]::Today.Add([timespan]::Parse($job.Schedule.At))) }
        'Interval' {
            $trigger = New-ScheduledTaskTrigger -Once -At ([datetime]::Now.AddMinutes(2)) -RepetitionInterval (New-TimeSpan -Minutes $job.Schedule.EveryMinutes)
        }
    }
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([timespan]::Zero)
    if (-not $Enable) { $settings.Enabled = $false }
    $principal = if ($isSystem) {
        New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Limited
    } else {
        New-ScheduledTaskPrincipal -UserId $config.Account -LogonType Password -RunLevel Limited
    }
    $definition = New-ScheduledTask -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description $ownedDescription
    if ($PSCmdlet.ShouldProcess($taskPath + $job.Id, "Register task (enabled: $([bool]$Enable))")) {
        if (-not $taskFolderReady) {
            $scheduler = New-Object -ComObject 'Schedule.Service'
            $scheduler.Connect()
            $folder = $scheduler.GetFolder('\')
            foreach ($segment in @('SqlExpressBackup', $config.ProjectId)) {
                try { $folder = $folder.GetFolder($segment) } catch {
                    if (($_.Exception.GetBaseException().HResult -band 0xFFFF) -notin @(2, 3)) { throw }
                    $folder = $folder.CreateFolder($segment)
                }
            }
            $taskFolderReady = $true
        }
        if ($isSystem) {
            Register-ScheduledTask -TaskName $job.Id -TaskPath $taskPath -InputObject $definition -Force | Out-Null
        } else {
            # Task Scheduler receives the password in-process and stores its credential protected by Windows.
            $password = $Credential.GetNetworkCredential().Password
            try {
                Register-ScheduledTask -TaskName $job.Id -TaskPath $taskPath -InputObject $definition -User $config.Account -Password $password -Force | Out-Null
            } finally { $password = $null }
        }
    }
}
$enabledIds = @($config.Jobs | Where-Object Enabled | Select-Object -ExpandProperty Id)
foreach ($task in $existing | Where-Object { $_.TaskName -notin $enabledIds }) {
    if ($PSCmdlet.ShouldProcess($taskPath + $task.TaskName, 'Disable removed or disabled managed job')) {
        Disable-ScheduledTask -TaskName $task.TaskName -TaskPath $taskPath | Out-Null
    }
}
