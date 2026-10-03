<#
.SYNOPSIS
    Runs PSScriptAnalyzer on the pipeline scripts, app scripts and app template.

.DESCRIPTION
    Errors and parse errors fail the run. Warnings and information findings are reported as annotations only.
    The bundled PSAppDeployToolkit framework in Templates\Framework is third-party code and is not analyzed.
#>
param (
    [string[]]$Path = @("Scripts", "Apps", "Templates/Application", ".github/scripts")
)
$Findings = foreach ($Item in $Path) {
    Invoke-ScriptAnalyzer -Path $Item -Recurse
}

foreach ($Finding in $Findings) {
    $File = Resolve-Path -Path $Finding.ScriptPath -Relative
    $Level = if ($Finding.Severity -in @("Error", "ParseError")) { "error" } else { "warning" }
    Write-Output -InputObject "::$($Level) file=$($File),line=$($Finding.Line),title=$($Finding.RuleName)::$($Finding.Message)"
}

$Errors = @($Findings | Where-Object { $_.Severity -in @("Error", "ParseError") })
Write-Output -InputObject "PSScriptAnalyzer: $(@($Findings).Count) findings, $($Errors.Count) errors"
if ($Errors.Count -gt 0) {
    exit 1
}
