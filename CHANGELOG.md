# Change Log

All notable changes to this project will be documented in this file. The format is based on [Keep a Changelog](https://keepachangelog.com), and this project adheres to [Semantic Versioning](https://semver.org).

## [2.7.1] - 2026-11-11

### Fixed
- **Throttled batch sub-requests no longer return empty results.** Since 2.7.0, a sub-request in a `$batch` call that Microsoft Graph throttled (429) or failed transiently (5xx) was logged as a warning and returned as an empty result, so an import could report groups, teams or channels without members while the run succeeded. `Invoke-MSEntraBatchRequest` now retries only the failed sub-requests, waiting for the longest `Retry-After` they returned (exponential backoff when absent), up to 5 retries. If they keep failing, the import fails instead of returning incomplete data.
  - The `$batch` call itself and the `@odata.nextLink` pagination calls are now retried on 429/500/502/503/504 with respect to `Retry-After` as well (new helpers `Invoke-MSEntraRestMethodWithRetry` and `Get-MSEntraRetryDelay`).
  - Other non-success sub-responses (for example 404) keep the previous behavior: a warning and an empty result.
  - Applies to all 10 scripts listed under 2.7.0.

### Added
- **Automated tests** (`tests/`, see `tests/README.md`) and a `Tests` workflow that runs them on every pull request:
  - Pester unit tests for the batch and retry helpers, run against every script that contains them, on PowerShell 7 and Windows PowerShell 5.1.
  - Static checks: all scripts parse, no `[scriptblock]` parameters, and the shared helpers are identical in every script.
  - Integration tests that run `permissions/groups/importPermission.ps1` against a mocked Microsoft Graph in [Dev Proxy](https://aka.ms/devproxy) with injected throttling and 5xx errors.

## [2.7.0] - 2026-09-30

### Changed
- **Import and sub-permission scripts** now use Microsoft Graph JSON batching (`$batch`, max 20 requests per batch) for all per-item GET requests (group members/owners, team channels, channel members) instead of one request per item. This makes imports of large tenants significantly faster. Failed sub-requests (429/5xx) are retried individually with respect to `Retry-After`.
  - `permissions/groups/importPermission.ps1` and `subPermissionsImport.ps1`
  - `permissions/groups/filterExamples/importOnlyGuestGroups.ps1` and `importOnlyMemberGroups.ps1`
  - `permissions/teamChannels/importPermission.ps1` and `permissions.ps1`
  - `permissions/educationalGroups/members/import.ps1` and `importSubPermissions.ps1`
  - `permissions/educationalGroups/owners/import.ps1` and `importSubPermissions.ps1`
- **Invoke-MSEntraBatchRequest** takes a list of requests (`Method` and `Uri`), so no ScriptBlocks are used (these are blocked by HelloID).

## [2.6.2] - 2026-09-09

### Hotfix
- Disable and Delete script failed when `Origin` = `enforcement`
- 
## [2.6.1] - 2026-09-08

### Changed
- **correlateOnly/import.ps1**: Accounts with `onPremisesSyncEnabled -eq $true` are now always imported with `Enabled = false`, regardless of their actual `accountEnabled` value in Entra ID. This prevents reconciliation actions/errors on AD synced accounts, since that insight is already provided by the AD connector.

### Fixed
- **permissions/teamChannels/grantPermission.ps1**: Removed a leftover debug `Write-Warning` that dumped the request body.
- **permissions/teamChannels/importPermission.ps1**: Removed a leftover debug `Write-Warning` that dumped the raw error object at the start of the catch block.
- **permissions/teamChannels/permissions.ps1**: Removed a leftover debug `Write-Warning` that dumped the raw error object at the start of the catch block.
- **README.md**: Removed a misplaced `Configuration` subsection under `Inviting Guest Accounts` that actually described the correlate only setup, which is already covered by `Correlate only mode` and `correlateOnly/README.md`.

## [2.6.0] - 02-09-2026

### Fixed
- **update.ps1**: Fixed a bug where the Entra account comparison was skipped whenever `actionContext.Data` was not empty but did not contain any mapped fields, preventing `None` mapped fields (e.g. `userPrincipalName`) from being read and stored in the account data.

### Added
- **correlateOnly/README.md**: Added documentation for the correlate only setup: when to use it, how to set it up, its limitations compared to the full CRUD connector, how to add the regular update/enable/disable/delete scripts on top of it, and how to keep read-only fields in sync using a `None` mapping.
- **README.md**: Added `Correlate only` to the supported features table and a pointer to `correlateOnly/README.md`.

## [2.5.5] - 2026-08-19

### Added
- **correlateOnly/delete.ps1**: Added support for deleting cloud-only accounts via Reconciliation. The script validates that accounts are not synchronized from on-premises Active Directory before allowing deletion.
- **correlateOnly/disable.ps1**: Added support for disabling cloud-only accounts via Reconciliation. The script validates that accounts are not synchronized from on-premises Active Directory before allowing the disable action.
- **correlateOnly/fieldMapping.json**: Added `onPremisesSyncEnabled` as a read-only attribute to determine whether an account is synchronized from on-premises AD. This attribute is used by the delete and disable scripts to prevent actions on synced accounts.

### Changed
- **correlateOnly**: Delete and disable actions now only execute when triggered from Reconciliation (`$actionContext.Origin -eq 'Reconciliation'`). Regular provisioning flows are unaffected.

### Fixed
- Manager not found catch was not working when running the connector on-prem (PSv5)

## [2.5.4] - 2026-08-11

### Fixed
- Fixed an issue where import scripts without field mapping added a trailing whitespace character to `accountEnabled`.

## [2.5.3] - 04-08-2026

### Added
- Import examples how to filter data for account and memberships

### Fixed
- Added private key check in scripts where it was missing

### Changed
- Empty or whitespace `department` values are now converted to `$null`, allowing the field to be cleared correctly instead of placing a whitespace.

## [2.5.2] - 30-07-2026
### Fixed
- **correlateOnly/create.ps1**: Changed correlation value from `accountFieldValue` to `personFieldValue` to support Governance correlation scenarios correctly.
- **create.ps1**: Fixed Exchange mailbox creation to use `mailNickName` for the `Name` parameter (which must be unique) and added explicit `DisplayName` parameter. This resolves errors when creating mailboxes for users with duplicate display names.
- **permissions/emailAuthenticationMethods/grantPermission.ps1**: Changed email authentication method to use personal email address instead of business email address. This ensures password reset codes are sent to an accessible email address rather than the business account being reset.
- **permissions/groups/subPermissions.ps1**: Fixed undefined `$resource` variable in `$actionMessage`. The message now correctly displays `$correlationField`, `$correlationValue`, and `$contract.ExternalId` for improved logging clarity.

### Added
- **correlateOnly/fieldMapping.json**: Added `userPrincipalName` as an additional correlation field alongside `employeeId`, enabling environments to correlate on either attribute as needed.

## [2.5.1] - 30-07-2026
### Fixed
- **uniquenessCheck.ps1**: Fixed bug where email addresses were incorrectly flagged as non-unique during `create` operations, even when the person was already using that email address themselves. The script now properly performs correlation lookup (employeeId → givenName fallback) during create to identify if the account already exists, and correctly checks self-usage across all operation types.

### Changed
- **uniquenessCheck.ps1**: Added explicit `$correlationField` and `$entraMailboxFallbackLookupPropertyValue` variables for consistency with `create.ps1`.

### Added
- **README.md**: Added documentation explaining that correlation configuration must be manually updated in `uniquenessCheck.ps1` when using different correlation fields, as `$actionContext.CorrelationConfiguration` is not available in the uniqueness check lifecycle action.

## [2.5.0] - 10-07-2026
### Added
- Support for managing team channels

## [2.4.0] - 11-05-2026
### Added
- Support for managing en creating educational groups

## [2.3.0] - 13-04-2026
### Added
- Resource creation for teams.
- PerUserMfaState permissions.

### Fixed
- Reconciliation action to disable or delete account was not working.
- Correlation now works for `onPremisesExtensionAttributes.extensionAttribute`

## [2.2.0] - 16-02-2026
### Added
- Feature: Added guest invite capability to invite external users as guest accounts in Microsoft Entra ID.
- Added separate `guestInvite` folder containing:
  - `configuration.json`: Configuration template for guest invite operations.
  - `create.ps1`: PowerShell script to create and invite guest accounts.
  - `fieldMapping.json`: Field mapping for guest account attributes including invitation details and guest-specific properties.
- Added documentation for "Inviting Guest Accounts" section in README with detailed setup and usage instructions.
- Add a check to throw the script when `The certificate does not have a private key`

## [2.1.2] - 03-02-2026
- Fix: when no account was found, the script used a throw. This was changed so the script flow works as intended.

## [2.1.1] - 03-02-2026
- Fix, success was not true when no person was found when revoking a group

## [2.1.0] - 29-12-2025
- Feature, skip ExO actions in update, disable and delete when no ExO account was found.
- Fix, data returned to in create script was incomplete

## [2.0.4] - 18-12-2025
- Fixed retrieving security groups from Entra ID returned duplicate records when the number of groups exceeded 1,000.
- Removed license scripts from the repository in accordance with Microsoft best practices.

## [2.0.3] - 09-12-2025
### Fixed
- Corrected audit logging messages in the disable script for Entra account updates (previously incorrectly referenced "delete action").

## [2.0.2] - 14-11-2025
### Updated
 - Update import scripts because length to max 100 char was calculated incorrectly.
 - Update import account to return data to HelloID with each page.

## [2.0.1] - 12-11-2025
### Updated
 - Update configuration placeholders to use empty GUIDs instead of fake GUIDs.


## [2.0.0] - 29-10-2025
### Updated
- Field mapping logic for `mail`, `mailNickname`, `userPrincipalName`, and `exchangeOnline.EmailAddresses` updated to follow best practices for naming conventions, uniqueness, and attribute length limits.

### Added
- Project logo/icon added to the README for improved visual identification.

### Changed
- Expanded and improved documentation in the README, including:
  - Clearer explanation of group-based licensing.
  - Addition and clarification of used Graph API endpoints.
  - Extended explanation about the custom cmdlet `Connect-ManagedExchangeOnline` and the HelloID cloud agent.
  - Various textual and structural improvements.
- Feature table updated: "Resources: Groups" now marked as supported.
- Consistent use of `.Id` instead of `.Reference` for permission identifiers in all permission scripts (groups and licenses).
- Improved output formatting and handling of display names and descriptions in group and license import scripts.
- More robust logic for batching and reporting group and license members.
- Clarified and corrected endpoint documentation in README.
- README: clarified that `Connect-ManagedExchangeOnline` is only available in the HelloID cloud agent environment.
- Minor textual corrections in README and script comments.
- Minor corrections and additions in the changelog and feature table.

### Fixed
- Multiple small fixes in the import scripts for permissions (groups and licenses).

## [1.2.2] - 28-10-2025

### Authentication methods
- Fixed: Changed only boolean names back to onlySetMobileWhenEmpty and onlySetEmailWhenEmpty
- Fixed: Changed a true/false bug in the processing logic of these booleans
- Fixed: Changed dryRun and actionMessages so that the changed attribute value is shown
- Fixed: Changed dryRun and actionMessages so it doesn't use the Permission.displayName as this doesn't work in the dryRun

## [1.2.1] - 14-10-2025

### Changed
- Fixed: Granting already granted permissions no longer results in an error.
- Fixed: Retrieving security groups.
- Fixed: `Update` action does no longer result in an error when no ExchangeOnline properties are required to be updated.
- Fixed: `Update` action now supports the switch between primary and alias.
- Fixed: `UniquenessCheck` now supports the issue that occurred when mailbox was created but the `Create` action fails.
- Fixed: Issue in the PhoneAuthenticationMethod where the `Grant` and `Revoke` looked up the wrong permission property.
- Fixed: Actions in `Grant` and `Revoke` for email and phone authenticationMethods now work correctly.
- Improvements to the `Readme`.

### Removed
- Removed: displayName from the `UniquenessCheck` script.

## [1.2.0] - 10-07-2025

### Added
- Added support for reconciliation actions on unmanaged accounts.
- Added notification support for `enable`, `disable`, and `delete` actions (Data vs PreviousData).

### Changed
- Optimized field mapping to store less accountData.
- Fixed: ActionMessage in the delete script.
- Fixed: Boolean comparisons in the `Update`, `Disable`, and `Delete` scripts.
- Fixed: Get user in the disable script.
- Fixed: Missing audit logging for Entra updates in the disable script.


## [1.1.0] - 12-06-2025

### Added
- Permissions functionality added, based on existing permissions in the target system. The following permissions are available:
 - Groups
 - Licenses
 - Phone authentication methods
 - Email authentication methods

Note that for both groups and licenses, the _import_ feature is also supported.

## [1.0.0] - 15-03-2025

This is the first official release of _HelloID-Conn-Prov-Target-MS-Entra-Exo_. This release is based on template version _v2.0.1_.

### Added

### Changed

### Deprecated

### Removed
