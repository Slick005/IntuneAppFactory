<#
.SYNOPSIS
    Validates appList.json and the App.json manifest of every onboarded app.

.DESCRIPTION
    Catches the configuration mistakes that would otherwise only show up as a skipped app in the Azure DevOps pipeline:
    invalid JSON, missing required properties, unsupported values, missing app files and unfilled template placeholders.
#>
param (
    [string]$SourceDirectory = (Get-Location).Path
)
$script:Errors = New-Object -TypeName "System.Collections.ArrayList"
function Add-Error {
    param([string]$File, [string]$Message)
    [void]$script:Errors.Add($Message)
    Write-Output -InputObject "::error file=$($File)::$($Message)"
}

$AppListPath = Join-Path -Path $SourceDirectory -ChildPath "appList.json"
try {
    $AppList = Get-Content -Path $AppListPath -Raw -ErrorAction "Stop" | ConvertFrom-Json -ErrorAction "Stop"
}
catch [System.Exception] {
    Add-Error -File "appList.json" -Message "appList.json is not valid JSON: $($_.Exception.Message)"
    exit 1
}

$RequiredAppListProperties = @("IntuneAppName", "IntuneAppNamingConvention", "AppPublisher", "AppSource", "AppID", "AppFolderName")
$NamingConventions = @("PublisherAppNameAppVersion", "PublisherAppName", "AppNameAppVersion", "AppName")
$AppSources = @("Evergreen", "Winget", "StorageAccount")
$AppsFolder = Join-Path -Path $SourceDirectory -ChildPath "Apps"
$AppFolders = @(Get-ChildItem -Path $AppsFolder -Directory)

foreach ($App in $AppList.Apps) {
    $Name = if ($App.IntuneAppName) { $App.IntuneAppName } else { "<unnamed app>" }
    foreach ($Property in $RequiredAppListProperties) {
        if ([string]::IsNullOrEmpty($App.$Property)) {
            Add-Error -File "appList.json" -Message "[$($Name)] Missing required property '$($Property)'"
        }
    }
    if ($App.IntuneAppNamingConvention -and $App.IntuneAppNamingConvention -notin $NamingConventions) {
        Add-Error -File "appList.json" -Message "[$($Name)] IntuneAppNamingConvention '$($App.IntuneAppNamingConvention)' must be one of: $($NamingConventions -join ', ')"
    }
    if ($App.AppSource -and $App.AppSource -notin $AppSources) {
        Add-Error -File "appList.json" -Message "[$($Name)] AppSource '$($App.AppSource)' must be one of: $($AppSources -join ', ')"
    }
    if ($App.AppSource -eq "StorageAccount") {
        foreach ($Property in @("StorageAccountName", "StorageAccountContainerName")) {
            if ([string]::IsNullOrEmpty($App.$Property)) {
                Add-Error -File "appList.json" -Message "[$($Name)] AppSource 'StorageAccount' requires property '$($Property)'"
            }
        }
    }
    if ([string]::IsNullOrEmpty($App.AppFolderName)) {
        continue
    }

    # The pipeline runs on Windows, so the folder name is matched without regard to case
    $AppFolder = $AppFolders | Where-Object { $_.Name -eq $App.AppFolderName } | Select-Object -First 1
    if ($null -eq $AppFolder) {
        Add-Error -File "appList.json" -Message "[$($Name)] App folder 'Apps/$($App.AppFolderName)' does not exist"
        continue
    }
    foreach ($FileName in @("App.json", "Deploy-Application.ps1")) {
        if (-not(Test-Path -Path (Join-Path -Path $AppFolder.FullName -ChildPath $FileName))) {
            Add-Error -File "Apps/$($AppFolder.Name)" -Message "[$($Name)] Missing required file '$($FileName)'"
        }
    }

    $AppJsonFile = "Apps/$($AppFolder.Name)/App.json"
    $AppJsonPath = Join-Path -Path $AppFolder.FullName -ChildPath "App.json"
    if (-not(Test-Path -Path $AppJsonPath)) {
        continue
    }
    $AppJsonRaw = Get-Content -Path $AppJsonPath -Raw
    try {
        $AppData = $AppJsonRaw | ConvertFrom-Json -ErrorAction "Stop"
    }
    catch [System.Exception] {
        Add-Error -File $AppJsonFile -Message "[$($Name)] App.json is not valid JSON: $($_.Exception.Message)"
        continue
    }

    # Template placeholders such as <<SELECT_VALUE:[...]>> must be replaced, <replaced_by_pipeline> values are filled in automatically
    foreach ($Match in [regex]::Matches($AppJsonRaw, '<{1,2}(ENTER_VALUE|SELECT_VALUE|OPTIONAL_ENTER_VALUE|OPTIONAL_SELECT_VALUE)[^>]*>>')) {
        Add-Error -File $AppJsonFile -Message "[$($Name)] Unfilled template placeholder: $($Match.Value)"
    }

    if (@($AppData.DetectionRule).Count -eq 0) {
        Add-Error -File $AppJsonFile -Message "[$($Name)] At least one detection rule is required"
    }
    if ((@($AppData.DetectionRule).Count -ge 2) -and ("Script" -in $AppData.DetectionRule.Type)) {
        Add-Error -File $AppJsonFile -Message "[$($Name)] A 'Script' detection rule can't be combined with other detection rules"
    }
    foreach ($DetectionRule in @($AppData.DetectionRule | Where-Object { $_.Type -eq "Script" })) {
        if (-not(Test-Path -Path (Join-Path -Path $AppFolder.FullName -ChildPath $DetectionRule.ScriptFile))) {
            Add-Error -File $AppJsonFile -Message "[$($Name)] Detection script file '$($DetectionRule.ScriptFile)' does not exist"
        }
    }
    if ([string]::IsNullOrEmpty($AppData.PackageInformation.IconURL) -and -not(Test-Path -Path (Join-Path -Path $AppFolder.FullName -ChildPath "Icon.png"))) {
        Add-Error -File $AppJsonFile -Message "[$($Name)] No IconURL is set and Icon.png is missing"
    }

    foreach ($Assignment in @($AppData.Assignment)) {
        if ($Assignment.Intent -notin @("available", "required", "uninstall")) {
            Add-Error -File $AppJsonFile -Message "[$($Name)] Assignment Intent '$($Assignment.Intent)' must be available, required or uninstall"
        }
        if (($Assignment.Type -eq "Group") -and ($Assignment.GroupMode -notin @("include", "exclude"))) {
            Add-Error -File $AppJsonFile -Message "[$($Name)] Assignment GroupMode '$($Assignment.GroupMode)' must be include or exclude"
        }
        if (-not([string]::IsNullOrEmpty($Assignment.FilterMode)) -and ($Assignment.FilterMode -notin @("include", "exclude"))) {
            Add-Error -File $AppJsonFile -Message "[$($Name)] Assignment FilterMode '$($Assignment.FilterMode)' must be include or exclude"
        }
    }
}

Write-Output -InputObject "Validated $(@($AppList.Apps).Count) apps, $($script:Errors.Count) errors"
if ($script:Errors.Count -gt 0) {
    exit 1
}
