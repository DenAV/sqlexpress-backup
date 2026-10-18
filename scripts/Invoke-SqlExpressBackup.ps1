#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(Mandatory)][string]$JobId,
    [switch]$ValidateOnly
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try {
    Import-Module (Join-Path $PSScriptRoot '..\src\SqlExpressBackup.psm1') -Force
    Invoke-BackupJob -ConfigPath $ConfigPath -JobId $JobId -ValidateOnly:$ValidateOnly -WhatIf:$WhatIfPreference
    exit 0
} catch {
    Write-Error -Message $_.Exception.Message -ErrorAction Continue
    exit 1
}
