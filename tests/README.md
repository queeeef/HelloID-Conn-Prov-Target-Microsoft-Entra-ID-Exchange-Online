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
   | `devproxyrc.transient.json` | 20% of `$batch` and pagination calls return 429/500/502/503/504 | The import returns complete data |
   | `devproxyrc.persistent.json` | Every `$batch` call is throttled | The import fails instead of reporting groups without members |

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

The Graph responses come from `tests/integration/devproxy/mocks.json` (25 groups with 3 members each, spread over 2 pages). Requests without a mock are blocked, so nothing reaches the real Microsoft Graph.

## CI

`.github/workflows/tests.yaml` runs both suites on every pull request.
