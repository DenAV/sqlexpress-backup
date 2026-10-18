#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ConfigPath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\SqlExpressBackup.psm1') -Force
$config = Read-BackupConfiguration $ConfigPath
$taskPath = '\SqlExpressBackup\' + $config.ProjectId + '\'
foreach ($job in $config.Jobs | Where-Object Enabled) {
    $task = Get-ScheduledTask -TaskPath $taskPath -TaskName $job.Id -ErrorAction SilentlyContinue
    if ($null -eq $task) {
        [pscustomobject]@{ Job = $job.Id; State = 'Missing'; LastRun = $null; LastResult = $null; NextRun = $null }
        continue
    }
    $info = Get-ScheduledTaskInfo -InputObject $task
    [pscustomobject]@{
        Job = $job.Id; State = $task.State; LastRun = $info.LastRunTime
        LastResult = ('0x{0:X}' -f $info.LastTaskResult); NextRun = $info.NextRunTime
    }
}
