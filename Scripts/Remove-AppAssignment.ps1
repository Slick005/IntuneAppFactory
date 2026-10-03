<#
.SYNOPSIS
    This script removes assignments from previous versions of applications that were published to Intune in the current pipeline execution.

.DESCRIPTION
    This script removes assignments from previous versions of applications that were published to Intune in the current pipeline execution.
    For each application in the AppsAssignList.json file, Intune is queried for Win32 apps with the same publisher and a display name constructed
    with the same naming convention. Any matching Win32 app with a lower version than the newly published app has all of its assignments removed,
    ensuring devices and users are only targeted by the latest version. The previous versions themselves are not deleted from Intune.

.EXAMPLE
    .\Remove-AppAssignment.ps1 -TenantID "<tenant_id>" -ClientID "<client_id>" -ClientSecret "<client_secret>"

.NOTES
    FileName:    Remove-AppAssignment.ps1
    Created:     2026-10-03
    Updated:     2026-10-03

    Version history:
    1.0.0 - (2026-10-03) Script created
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param (
    [parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$TenantID,

    [parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ClientID,

    [parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ClientSecret
)
Process {
    # Functions
    function Get-AppDisplayNamePrefix {
        <#
        .SYNOPSIS
            Construct the version independent part of the display name used for an app in Intune, based on the naming convention.
        #>
        param(
            [parameter(Mandatory = $false)]
            [string]$NamingConvention,

            [parameter(Mandatory = $true)]
            [string]$Publisher,

            [parameter(Mandatory = $true)]
            [string]$DisplayName
        )
        switch ($NamingConvention) {
            "PublisherAppNameAppVersion" {
                return -join@($Publisher, " ", $DisplayName)
            }
            "PublisherAppName" {
                return -join@($Publisher, " ", $DisplayName)
            }
            default {
                return $DisplayName
            }
        }
    }

    function ConvertTo-AppVersion {
        <#
        .SYNOPSIS
            Convert a version string to a System.Version object, returning null when it can't be parsed.
        #>
        param(
            [parameter(Mandatory = $false)]
            [string]$Version
        )
        # System.Version requires at least two components, append a minor version to versions such as '24'
        if ($Version -match "^\d+$") {
            $Version = -join@($Version, ".0")
        }
        $ParsedVersion = $null
        if ([System.Version]::TryParse($Version, [ref]$ParsedVersion)) {
            return $ParsedVersion
        }
        return $null
    }

    function Get-PreviousAppVersion {
        <#
        .SYNOPSIS
            Filter a list of Win32 apps from Intune, returning only previous versions of the newly published app.
        #>
        param(
            [parameter(Mandatory = $false)]
            [System.Object[]]$Win32Apps,

            [parameter(Mandatory = $true)]
            [string]$NewAppID,

            [parameter(Mandatory = $true)]
            [string]$NewAppVersion,

            [parameter(Mandatory = $true)]
            [string]$Publisher,

            [parameter(Mandatory = $true)]
            [string]$DisplayNamePrefix
        )
        $NewVersion = ConvertTo-AppVersion -Version $NewAppVersion
        if ($NewVersion -eq $null) {
            Write-Warning -Message "Unable to parse version '$($NewAppVersion)' of the published app, skipping detection of previous versions"
            return
        }

        foreach ($Win32App in $Win32Apps) {
            # Skip the newly published app and apps from other publishers
            if ($Win32App.id -eq $NewAppID) {
                continue
            }
            if ($Win32App.publisher -ne $Publisher) {
                continue
            }

            # Only match apps named exactly as the naming convention would have named them, with or without their own version appended
            if (($Win32App.displayName -ne $DisplayNamePrefix) -and ($Win32App.displayName -ne (-join@($DisplayNamePrefix, " ", $Win32App.displayVersion)))) {
                continue
            }

            # Only match apps with a lower version than the newly published app
            $Win32AppVersion = ConvertTo-AppVersion -Version $Win32App.displayVersion
            if ($Win32AppVersion -eq $null) {
                Write-Warning -Message "Unable to parse version '$($Win32App.displayVersion)' of Win32 app '$($Win32App.displayName)' with ID '$($Win32App.id)', skipping"
                continue
            }
            if ($Win32AppVersion -lt $NewVersion) {
                Write-Output -InputObject $Win32App
            }
        }
    }

    # Construct path for AppsAssignList.json file created in publish stage
    $AppsAssignListFileName = "AppsAssignList.json"
    $AppsAssignListFilePath = Join-Path -Path (Join-Path -Path $env:BUILD_ARTIFACTSTAGINGDIRECTORY -ChildPath "AppsPublishedList") -ChildPath $AppsAssignListFileName

    if (Test-Path -Path $AppsAssignListFilePath) {
        # Retrieve authentication token using client secret from key vault
        $AuthToken = Connect-MSIntuneGraph -TenantID $TenantID -ClientID $ClientID -ClientSecret $ClientSecret -ErrorAction "Stop"

        # Read content from AppsAssignList.json file and convert from JSON format
        Write-Output -InputObject "Reading contents from: $($AppsAssignListFilePath)"
        $AppsAssignList = Get-Content -Path $AppsAssignListFilePath | ConvertFrom-Json

        # Process each published application and remove assignments from previous versions
        foreach ($App in $AppsAssignList) {
            Write-Output -InputObject "[APPLICATION: $($App.IntuneAppName)] - Initializing"

            # Read app specific App.json manifest and convert from JSON
            $AppDataFile = Join-Path -Path $App.AppPublishFolderPath -ChildPath "App.json"
            if (Test-Path -Path $AppDataFile) {
                Write-Output -InputObject "Reading contents from: $($AppDataFile)"
                $AppData = Get-Content -Path $AppDataFile | ConvertFrom-Json

                # Construct the display name prefix shared by all versions of the app
                $DisplayNamePrefix = Get-AppDisplayNamePrefix -NamingConvention $App.IntuneAppNamingConvention -Publisher $AppData.Information.Publisher -DisplayName $AppData.Information.DisplayName
                Write-Output -InputObject "Searching for previous versions of '$($DisplayNamePrefix)' with publisher '$($AppData.Information.Publisher)' and a version lower than: $($AppData.Information.AppVersion)"

                try {
                    # Retrieve Win32 apps with a display name containing the prefix, and filter for previous versions
                    $Win32Apps = Get-IntuneWin32App -DisplayName $DisplayNamePrefix -ErrorAction "Stop"
                    $PreviousWin32Apps = @(Get-PreviousAppVersion -Win32Apps $Win32Apps -NewAppID $App.IntuneAppObjectID -NewAppVersion $AppData.Information.AppVersion -Publisher $AppData.Information.Publisher -DisplayNamePrefix $DisplayNamePrefix)
                    Write-Output -InputObject "Found $($PreviousWin32Apps.Count) previous version(s) of the application"

                    foreach ($PreviousWin32App in $PreviousWin32Apps) {
                        try {
                            # Remove all assignments for the previous version, if any exist
                            $Win32AppAssignments = @(Get-IntuneWin32AppAssignment -ID $PreviousWin32App.id -ErrorAction "Stop")
                            if ($Win32AppAssignments.Count -ge 1) {
                                if ($PSCmdlet.ShouldProcess("$($PreviousWin32App.displayName) ($($PreviousWin32App.id))", "Remove $($Win32AppAssignments.Count) assignment(s)")) {
                                    Write-Output -InputObject "Removing $($Win32AppAssignments.Count) assignment(s) from '$($PreviousWin32App.displayName)' version '$($PreviousWin32App.displayVersion)' with ID: $($PreviousWin32App.id)"
                                    Remove-IntuneWin32AppAssignment -ID $PreviousWin32App.id -ErrorAction "Stop"
                                }
                            }
                            else {
                                Write-Output -InputObject "No assignments found for '$($PreviousWin32App.displayName)' version '$($PreviousWin32App.displayVersion)' with ID: $($PreviousWin32App.id)"
                            }
                        }
                        catch [System.Exception] {
                            Write-Warning -Message "An error occurred while attempting to remove assignments for Win32 app with ID: '$($PreviousWin32App.id)'. Error message: $($_.Exception.Message)"
                        }
                    }
                }
                catch [System.Exception] {
                    Write-Warning -Message "An error occurred while attempting to retrieve previous versions of '$($DisplayNamePrefix)'. Error message: $($_.Exception.Message)"
                }
            }
            else {
                Write-Output -InputObject "Could not find app specific App.json manifest in: $($App.AppPublishFolderPath)"
            }

            # Handle current application output completed message
            Write-Output -InputObject "[APPLICATION: $($App.IntuneAppName)] - Completed"
        }
    }
    else {
        Write-Output -InputObject "Attempted to read contents from: $($AppsAssignListFilePath)"
        Write-Output -InputObject "No application assignment list found, skipping removal of previous version assignments"
    }
}
