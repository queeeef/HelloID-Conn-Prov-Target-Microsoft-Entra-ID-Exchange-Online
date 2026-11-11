# Tests

Automated tests for the connector scripts. None of them need a Microsoft 365 tenant or credentials.

| Suite | What it covers | Runs on |
|---|---|---|
| `tests/unit` | Pester tests for the Graph batch and retry helpers in **every** import script (they are copied into each script, so each copy is tested), plus static checks: every script parses, no `[scriptblock]` parameters (blocked by HelloID), and the shared helpers are identical in all scripts. | PowerShell 7 (Linux and Windows) and Windows PowerShell 5.1 |
| `tests/integration` | Runs `permissions/groups/importPermission.ps1` unmodified against a mocked Microsoft Graph served by [Dev Proxy](https://aka.ms/devproxy), which injects throttling (429) and transient 5xx errors. | PowerShell 7 on Linux |

## Run the unit tests

```powershell
Install-Module Pester -MinimumVersion 5.5.0 -Force -SkipPublisherCheck -Scope CurrentUser
./tests/Invoke-Tests.ps1
```

`Invoke-RestMethod` is mocked with an in-memory fake of Microsoft Graph, so the tests run in seconds and never touch the network.

## Run the integration tests

1. [Install Dev Proxy](https://learn.microsoft.com/microsoft-cloud/dev/dev-proxy/get-started/set-up) and trust its root certificate.
2. Start it with one of the scenarios from `tests/integration/devproxy`:

   | Config | Scenario | Expected result |
   |---|---|---|
   | `devproxyrc.transient.json` | 20% of the pagination (`@odata.nextLink`) calls return 429/500/502/503/504, and retries sent before `Retry-After` are rejected | The import returns complete data |
   | `devproxyrc.persistent.json` | In otherwise successful `$batch` calls, one group's members sub-request is always throttled (the 2.7.0 bug) | The import fails instead of leaving that group out |

   ```bash
   cd tests/integration/devproxy
   devproxy --config-file devproxyrc.transient.json
   ```

3. In another terminal:

   ```powershell
   $env:DEVPROXY_SCENARIO = 'transient'   # or 'persistent', matching the config Dev Proxy runs with
   $env:HTTPS_PROXY = 'http://127.0.0.1:8000'
   ./tests/Invoke-Tests.ps1 -Suite integration
   ```

The Graph responses come from `tests/integration/devproxy/mocks.json` (25 groups with 3 members each, spread over 2 pages) and `mocks.persistent.json` (the same, plus the throttled group). Requests without a mock are blocked, so nothing reaches the real Microsoft Graph.

Random errors are not injected into `$batch` calls, because Dev Proxy's `GraphMockResponsePlugin` (v4.0.0) overwrites an error response that another plugin already set for a batch request. Transient throttling of batch sub-requests is covered by the unit tests instead.

## CI

`.github/workflows/tests.yaml` runs both suites on every pull request.
