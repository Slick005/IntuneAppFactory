# Setting up IntuneAppFactory

This guide covers everything `publish.yml` expects to exist before the pipeline can run in your tenant: an app registration, Azure resources, an Azure DevOps agent pool and two variable groups. Every name below is the exact name the pipeline references, so use them as written unless you also change `publish.yml`.

## 1. App registration (Microsoft Graph)

The pipeline authenticates to Graph with a client secret (`Connect-MSIntuneGraph` / `Get-AccessToken`).

1. In Entra ID, create an app registration, for example `IntuneAppFactory`.
2. Add these **application** permissions for Microsoft Graph and grant admin consent:
   - `DeviceManagementApps.ReadWrite.All`: read existing Win32 apps to compare versions, create apps, upload content and add assignments.
   - `DeviceManagementRBAC.ReadWrite.All`: resolve `ScopeTagName` from `App.json` (required since 1.0.2).
3. Create a client secret and note its value, along with the tenant ID and the application (client) ID.

## 2. Azure resources

| Resource | Used by | Notes |
| --- | --- | --- |
| Key Vault | Variable group `KeyVault` | Holds the three secrets in section 4. |
| Storage account | `Test-AppList.ps1`, `Save-Installer.ps1`, `New-AppArchive.ps1` | Needed for apps with `"AppSource": "StorageAccount"` and for archiving. Its access key is passed to every run, so the secret must exist even if you only use Evergreen or Winget. Public blob access can stay disabled. |
| Log Analytics workspace | `New-Win32App.ps1` | Receives an `IntuneAppFactory_CL` record per published app. See the note below. |

**Log Analytics note:** reporting uses the HTTP Data Collector API (`*.ods.opinsights.azure.com/api/logs`), which Microsoft announced for retirement in September 2026. A failed send is caught and only logged, so publishing still works. The `-WorkspaceID` and `-SharedKey` parameters are mandatory, though, so `ReportWorkspaceID` and `LA-IntuneAppFactory-PrimaryKey` must be set to some value.

## 3. Agent pool

`publish.yml` has `pool: name: '<<POOLNAME>>'`. Replace it with the name of your agent pool before the first run.

Use a **self-hosted Windows agent**. The scripts call Windows-only tooling: `IntuneWinAppUtil.exe` through the IntuneWin32App module, MSI property reads for `###PRODUCTCODE###`, and `winget` for apps with `"AppSource": "Winget"` (winget must be installed for the agent's account). The agent also needs outbound access to the PowerShell Gallery, `graph.microsoft.com`, `login.microsoftonline.com`, your storage account and the vendor download sites Evergreen and Winget resolve to.

`Install-Modules.ps1` installs or updates these modules on every run: `Evergreen`, `IntuneWin32App`, `Az.Storage`, `Az.Resources` and `MSGraphRequest`.

## 4. Variable groups

Create both under **Pipelines > Library** and give the pipeline permission to use them.

### `IntuneAppFactory` (plain variables)

| Variable | Value |
| --- | --- |
| `TenantID` | Entra tenant ID |
| `ClientID` | Application (client) ID of the app registration |
| `ArchiveStorageAccountName` | Storage account for archived packages (used when `archiveMode` is `Yes`) |
| `ArchiveContainerName` | Blob container in that storage account |
| `ReportWorkspaceID` | Log Analytics workspace ID |

### `KeyVault` (linked to Azure Key Vault)

Link the group to your Key Vault and add these secrets. The names contain hyphens because they are Key Vault secret names.

| Secret | Value |
| --- | --- |
| `SP-IntuneAppFactory-ClientSecret` | Client secret of the app registration |
| `SA-IntuneAppFactory-AccessKey` | Access key of the storage account |
| `LA-IntuneAppFactory-PrimaryKey` | Primary key of the Log Analytics workspace |

## 5. Create the pipeline

1. Import this repository into Azure Repos, or connect Azure DevOps to GitHub.
2. Create a pipeline from the existing YAML file `publish.yml`.
3. The pipeline has no CI trigger (`trigger: none`). It runs on a schedule every 6 hours against `main`, and you can also run it manually.

### Run parameters

| Parameter | Values | Effect |
| --- | --- | --- |
| `operationalMode` | `Verify`, `Package`, `Publish` (default) | `Verify` checks app files only. `Package` also downloads and builds packages. `Publish` also uploads them to Intune and assigns them. |
| `archiveMode` | `Yes`, `No` (default) | Uploads packaged apps to the archive storage account. |

For a first run, use `Verify`, then `Package`, then `Publish`.

## 6. Onboard applications

1. Add an entry to `appList.json`. The required properties are `IntuneAppName`, `IntuneAppNamingConvention`, `AppPublisher`, `AppSource` (`Evergreen`, `Winget` or `StorageAccount`), `AppID` and `AppFolderName`. Storage account apps also need `StorageAccountName` and `StorageAccountContainerName`.
2. Copy `Templates/Application` to `Apps/<AppFolderName>` and fill in every `<<...>>` placeholder in `App.json`. Values marked `<replaced_by_pipeline>` are set automatically.
3. Edit `Deploy-Application.ps1` for the app's install and uninstall steps.

`AppFolderName` must match the folder name under `Apps` exactly, including case. Windows agents don't care about case, but other systems do.

### Assignment `GroupMode` values

Use `include` or `exclude` for `GroupMode` in group assignments. The `App.json` template offers `included` and `excluded`, but the version of `New-AppAssignment.ps1` in this branch only matches the short forms, so a group assignment using the template's wording is skipped without an error. The short forms keep working after the script is changed to accept both spellings.
