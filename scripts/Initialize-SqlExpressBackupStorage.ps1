#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param([Parameter(Mandatory)][string]$ConfigPath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\SqlExpressBackup.psm1') -Force
$config = Read-BackupConfiguration $ConfigPath
if ($env:OS -ne 'Windows_NT') { throw 'Storage initialization requires Windows.' }
$serviceName = if ($config.Instance -eq '.') { 'MSSQLSERVER' } else { 'MSSQL$' + $config.Instance.Substring(2) }
$account = if ($config.Account -in @('SYSTEM', 'NT AUTHORITY\SYSTEM', 'S-1-5-18')) { 'S-1-5-18' } else { $config.Account }
function Resolve-AccountSid {
    param([string]$Name)
    if ($Name -match '^S-1-') { return New-Object System.Security.Principal.SecurityIdentifier $Name }
    $identity = New-Object System.Security.Principal.NTAccount $Name
    return $identity.Translate([System.Security.Principal.SecurityIdentifier])
}
$taskSid = Resolve-AccountSid $account
$sqlSid = Resolve-AccountSid ('NT SERVICE\' + $serviceName)
$targets = @(
    @{ Root = $config.BackupRoot; SqlAccess = $true },
    @{ Root = $config.LogRoot; SqlAccess = $false }
)
foreach ($target in $targets) {
    $projectPath = Join-Path $target.Root $config.ProjectId
    if ($target.Root.StartsWith('\\')) {
        Write-Warning 'UNC storage must be prepared by the file-server administrator; no remote ACLs are changed.'
        continue
    }
    if (-not (Test-Path -LiteralPath $target.Root -PathType Container)) { throw 'Create the configured storage root first.' }
    $ancestor = Get-Item -LiteralPath $target.Root -Force
    while ($null -ne $ancestor) {
        if (($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Storage cannot use reparse points.' }
        $ancestor = $ancestor.Parent
    }
    if (Test-Path -LiteralPath $projectPath) {
        Write-Warning "Project directory already exists; its ACL is not changed: $projectPath. Review it manually."
        continue
    }
    if ($PSCmdlet.ShouldProcess($projectPath, 'Create project storage with restricted inherited ACLs')) {
        $acl = New-Object System.Security.AccessControl.DirectorySecurity
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule (
                (Resolve-AccountSid $sid), 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'
            )
            $acl.AddAccessRule($rule)
        }
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule ($taskSid, 'Modify', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
        if ($target.SqlAccess) {
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule ($sqlSid, 'Modify', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
            $acl.AddAccessRule($rule)
        }
        # Windows PowerShell/.NET Framework creates the directory with its ACL in one call.
        [void][IO.Directory]::CreateDirectory($projectPath, $acl)
        if ($target.SqlAccess) {
            foreach ($database in $config.Databases) {
                [void][IO.Directory]::CreateDirectory((Join-Path $projectPath $database.Id))
            }
        }
    }
}
