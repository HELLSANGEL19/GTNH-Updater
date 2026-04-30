#Requires -Version 7.0
<#
.SYNOPSIS
    Parse-check all GTNH Updater PowerShell files for syntax errors.
.DESCRIPTION
    Uses the PowerShell AST parser to check every .ps1 file in the project
    for syntax errors without executing them. Run this first on a new machine
    to verify everything parses cleanly before launching the updater.
.NOTES
    Must be run with PowerShell 7+ (pwsh) since the scripts use PS7 syntax.
    Usage: pwsh -File tests\check-syntax.ps1
#>

$projectRoot = Split-Path -Parent $PSScriptRoot
$allFiles = @(
    Join-Path $projectRoot 'Update-GTNH.ps1'
) + @(Get-ChildItem -Path (Join-Path $projectRoot 'lib') -Filter '*.ps1' | ForEach-Object { $_.FullName })

$totalFiles = $allFiles.Count
$passed = 0
$failed = 0

Write-Host ""
Write-Host "  GTNH Updater - Syntax Check" -ForegroundColor Cyan
Write-Host "  Checking $totalFiles files..." -ForegroundColor Gray
Write-Host ""

foreach ($file in $allFiles) {
    $relativeName = $file.Replace($projectRoot, '').TrimStart('\', '/')
    $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$errors)

    if ($errors.Count -eq 0) {
        Write-Host "  PASS  $relativeName" -ForegroundColor Green
        $passed++
    }
    else {
        Write-Host "  FAIL  $relativeName" -ForegroundColor Red
        foreach ($err in $errors) {
            Write-Host "        Line $($err.Extent.StartLineNumber): $($err.Message)" -ForegroundColor Yellow
        }
        $failed++
    }
}

Write-Host ""
if ($failed -eq 0) {
    Write-Host "  All $passed files passed syntax check." -ForegroundColor Green
}
else {
    Write-Host "  $failed of $totalFiles files have syntax errors." -ForegroundColor Red
}
Write-Host ""

exit $failed
