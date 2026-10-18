#requires -Version 5.1
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module Pester -RequiredVersion 5.6.1
Import-Module PSScriptAnalyzer -RequiredVersion 1.22.0
$root = Split-Path $PSScriptRoot -Parent
$files = @(Get-ChildItem (Join-Path $root 'src'), (Join-Path $root 'scripts'), $PSScriptRoot -Recurse -File | Where-Object Extension -in @('.ps1', '.psm1'))
foreach ($file in $files) {
    $parseErrors = $null
    $tokens = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { throw ($parseErrors | Out-String) }
}
$findings = @(
    foreach ($directory in @('src', 'scripts')) {
        Invoke-ScriptAnalyzer -Path (Join-Path $root $directory) -Recurse -Severity Error, Warning
        Invoke-ScriptAnalyzer -Path (Join-Path $root $directory) -Recurse -Settings @{
            IncludeRules = @('PSUseCompatibleSyntax')
            Rules = @{ PSUseCompatibleSyntax = @{ Enable = $true; TargetVersions = @('5.1') } }
        }
    }
)
if ($findings.Count -gt 0) { $findings | Format-Table -AutoSize | Out-Host; throw 'Static analysis failed.' }
$configuration = New-PesterConfiguration
$configuration.Run.Path = $PSScriptRoot
$configuration.Run.PassThru = $true
$configuration.Output.Verbosity = 'Detailed'
$result = Invoke-Pester -Configuration $configuration
if ($result.Result -ne 'Passed' -or $result.PassedCount -eq 0) { throw 'Tests failed or no tests ran.' }
