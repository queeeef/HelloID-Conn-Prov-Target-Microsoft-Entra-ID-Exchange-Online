# Dry run: 100k mutations against a fake tenant

Load and correctness test that runs the **unmodified** connector scripts against a stateful fake of
Microsoft Graph with a realistic mock tenant and Graph-like throttling. Nothing touches a real tenant.

Run by `.github/workflows/dryrun.yaml` on pushes to `dryrun/**` (or manually). The workflow needs
`sudo` on the runner: it points `graph.microsoft.com` and `login.microsoftonline.com` at 127.0.0.1
and trusts a throwaway CA, so the scripts connect to the fake exactly as they would to Graph.

## Mock tenant (`generate_tenant.py`, deterministic seed)

- 5,000 users with Dutch names (Faker `nl_NL`), departments, offices in 6 cities, job levels
- 611 groups with a typical enterprise naming scheme: `SG-All-Employees` (5,000 members, 6 pages),
  `SG-Dept-*`, `SG-Dept-*-<city>`, `SG-Role-*`, `SG-Location-*`, `APP-<app>-Users/Admins/KeyUsers`,
  `LIC-*`, `FS-<dept>-<share>-RW/RO`, M365 `Team - <dept> <city>`, `Project <codename>`, `Community - *`,
  plus groups the import must skip: dynamic (`DYN-*`), synced from on-premises (`AD-*-Legacy`) and
  mail-enabled security (`MSG-*`)
- about 110,000 memberships; 50 deleted users and 10 deleted groups for not-found cases

## Operations (`ops.jsonl`)

100,000 grant/revoke operations, as HelloID would send them, plus 5,000 with HelloID `DryRun = true`:
grant a new membership (42%), revoke an existing one (38%), grant an existing one (8%), revoke a
non-member (7%), and grant/revoke for deleted users or groups (5%). They are split over 4 shards
(runners) × 2 workers, which own disjoint groups.

## What is checked

For every operation, what the connector reported (`outputContext.Success`) is compared with the
tenant's state after the call (`silent_failure` = reported success but the tenant is wrong).
Imports run before, during (every 90 s, sharing the quota) and after the mutations; the before/after
imports are compared with the tenant's actual memberships. A separate job runs the 2.7.0 and the
fixed `importPermission.ps1` alternately under heavy throttling.

## Fake Graph throttling (`fake_graph.py`)

Per-app token bucket (`FAKE_RATE`/s, `FAKE_BURST`), each `$batch` sub-request counts separately and is
throttled individually, plus random 429 (`FAKE_RANDOM_429`) and 503 (`FAKE_RANDOM_503`). A simulated
intranet takes `FAKE_INTRANET_RPS` from the same quota and counts how often it was refused.

`FAKE_NONMEMBER_MESSAGE_ID` (`member`/`group`) sets which id the 404 message for removing a
non-member contains. `revokePermission.ps1` only treats the 404 as "already removed" when the message
contains the group id; the default (`member`) is our best understanding of real Graph and still
needs to be confirmed against a real tenant.
