#!/usr/bin/env python3
"""
Generates a deterministic, realistic mock Microsoft 365 tenant and a stream of permission mutations
for the dry run.

Outputs (in --out):
  tenant.json   users, groups (with the properties the import filters on) and memberships
  ops.jsonl     one mutation per line: grant/revoke of a group for a user, as HelloID would send them

Users get Dutch names from Faker (nl_NL); groups follow a typical enterprise naming scheme:
department and location groups, role groups, application access groups, license groups,
file share groups, Microsoft 365 team/project/community groups, plus groups the import must
skip (dynamic, synced from on-premises AD, mail-enabled security).
"""
import argparse
import json
import random
import uuid
from collections import Counter
from pathlib import Path

from faker import Faker

NAMESPACE = uuid.UUID("6f1c4a52-2b8e-4d0a-9a51-6d5b2b1f0c11")

DEPARTMENTS = {
    "Finance": 0.08, "HR": 0.05, "IT": 0.10, "Sales": 0.14, "Marketing": 0.07, "Operations": 0.16,
    "Legal": 0.03, "Customer Service": 0.12, "R&D": 0.09, "Procurement": 0.04, "Facilities": 0.04,
    "Logistics": 0.08,
}
CITIES = {"Utrecht": 0.30, "Amsterdam": 0.22, "Rotterdam": 0.18, "Eindhoven": 0.12, "Groningen": 0.08, "Antwerpen": 0.10}
JOB_LEVELS = [("Medewerker", 0.62), ("Senior medewerker", 0.18), ("Teamleider", 0.08), ("Manager", 0.05),
              ("Stagiair", 0.05), ("Directeur", 0.02)]
APPS = ["SAP", "Salesforce", "ServiceNow", "Workday", "Jira", "Confluence", "AFAS", "Exact-Online", "TOPdesk",
        "Adobe-CC", "AutoCAD", "PowerBI", "Tableau", "GitHub", "Azure-DevOps", "Zendesk", "HubSpot", "Visma",
        "Nmbrs", "Mendix", "Qlik", "SolidWorks", "Snowflake", "Databricks", "DocuSign", "Miro", "Figma",
        "Slack", "Zoom", "Okta-Legacy", "Citrix", "Ivanti", "Lansweeper", "Bamboo", "Coupa", "Basware",
        "Kofax", "OpenText", "Planon", "Ultimo"]
APP_AFFINITY = {  # departments that typically use an app
    "SAP": ["Finance", "Procurement", "Logistics", "Operations"], "Salesforce": ["Sales", "Marketing", "Customer Service"],
    "ServiceNow": ["IT"], "Workday": ["HR"], "Jira": ["IT", "R&D"], "Confluence": ["IT", "R&D", "Operations"],
    "AFAS": ["HR", "Finance"], "Exact-Online": ["Finance"], "TOPdesk": ["IT", "Facilities"], "Adobe-CC": ["Marketing"],
    "AutoCAD": ["R&D", "Facilities"], "PowerBI": ["Finance", "Sales", "Operations"], "GitHub": ["IT", "R&D"],
    "Azure-DevOps": ["IT", "R&D"], "Zendesk": ["Customer Service"], "HubSpot": ["Marketing", "Sales"],
    "Nmbrs": ["HR"], "Coupa": ["Procurement"], "Basware": ["Finance", "Procurement"], "Planon": ["Facilities"],
}
LICENSES = ["M365-E3", "M365-E5", "M365-F3", "PowerBI-Pro", "Visio-Plan2", "Project-Plan3", "Teams-Phone", "Copilot"]
SHARES = ["Algemeen", "Archief", "Projecten", "Rapportages", "Contracten", "Personeel", "Budget", "Templates"]
PROJECT_CODENAMES = ["Atlas", "Borealis", "Cobalt", "Delta", "Eclipse", "Falcon", "Granite", "Horizon", "Iris",
                     "Jade", "Kestrel", "Lumen", "Meridian", "Nova", "Orion", "Pegasus", "Quartz", "Raven",
                     "Sirius", "Tundra", "Umbra", "Vega", "Willow", "Xenon", "Yarrow", "Zephyr"]
COMMUNITIES = ["Duurzaamheid", "Innovatie", "Wellbeing", "Young Professionals", "Data & AI", "Security Champions",
               "Hardlopen", "Fotografie", "Diversiteit & Inclusie", "Agile Coaches", "Lean Six Sigma",
               "Toastmasters", "Gaming", "Koken", "Vrijwilligerswerk", "Fietsclub"]


def det_id(kind, key):
    return str(uuid.uuid5(NAMESPACE, f"{kind}:{key}"))


def weighted(rng, mapping):
    keys = list(mapping)
    return rng.choices(keys, weights=[mapping[k] for k in keys], k=1)[0]


def build_tenant(user_count, seed):
    rng = random.Random(seed)
    fake = Faker("nl_NL")
    fake.seed_instance(seed)

    users = []
    seen_upns = Counter()
    for n in range(user_count):
        first, last = fake.first_name(), fake.last_name()
        base = f"{first}.{last}".lower().replace(" ", "").replace("'", "")
        seen_upns[base] += 1
        upn = f"{base}{seen_upns[base] if seen_upns[base] > 1 else ''}@contoso.nl"
        level = rng.choices([j for j, _ in JOB_LEVELS], weights=[w for _, w in JOB_LEVELS], k=1)[0]
        users.append({
            "id": det_id("user", n), "displayName": f"{first} {last}", "userPrincipalName": upn,
            "department": weighted(rng, DEPARTMENTS), "officeLocation": weighted(rng, CITIES), "jobTitle": level,
        })

    groups, members = [], {}

    def add_group(name, kind, member_ids, description=None):
        props = {
            "security": {"groupTypes": [], "securityEnabled": True, "mailEnabled": False, "onPremisesSyncEnabled": None},
            "m365": {"groupTypes": ["Unified"], "securityEnabled": False, "mailEnabled": True, "onPremisesSyncEnabled": None},
            "dynamic": {"groupTypes": ["DynamicMembership"], "securityEnabled": True, "mailEnabled": False, "onPremisesSyncEnabled": None},
            "synced": {"groupTypes": [], "securityEnabled": True, "mailEnabled": False, "onPremisesSyncEnabled": True},
            "mailsecurity": {"groupTypes": [], "securityEnabled": True, "mailEnabled": True, "onPremisesSyncEnabled": None},
        }[kind]
        gid = det_id("group", name)
        groups.append({"id": gid, "displayName": name, "description": description or f"{name} ({kind})", "kind": kind, **props})
        members[gid] = sorted(set(member_ids))

    by_dept = {d: [u for u in users if u["department"] == d] for d in DEPARTMENTS}
    leaders = {"Teamleider", "Manager", "Directeur"}

    add_group("SG-All-Employees", "security", [u["id"] for u in users], "Alle medewerkers")
    for dept, dept_users in by_dept.items():
        slug = dept.replace(" ", "-").replace("&", "and")
        add_group(f"SG-Dept-{slug}", "security", [u["id"] for u in dept_users])
        add_group(f"SG-Role-{slug}-Leidinggevenden", "security", [u["id"] for u in dept_users if u["jobTitle"] in leaders])
        add_group(f"SG-Role-{slug}-Stagiairs", "security", [u["id"] for u in dept_users if u["jobTitle"] == "Stagiair"])
        for city in CITIES:
            add_group(f"SG-Dept-{slug}-{city}", "security", [u["id"] for u in dept_users if u["officeLocation"] == city])
            add_group(f"Team - {dept} {city}", "m365", [u["id"] for u in dept_users if u["officeLocation"] == city])
        for share in SHARES:
            share_users = [u["id"] for u in dept_users if rng.random() < 0.6]
            add_group(f"FS-{slug}-{share}-RW", "security", share_users)
            add_group(f"FS-{slug}-{share}-RO", "security", [u["id"] for u in dept_users if u["id"] not in set(share_users) and rng.random() < 0.5])
        add_group(f"DYN-{slug}", "dynamic", [u["id"] for u in dept_users])
        add_group(f"AD-{slug}-Legacy", "synced", [u["id"] for u in dept_users if rng.random() < 0.7])
        add_group(f"MSG-{slug}", "mailsecurity", [u["id"] for u in dept_users if rng.random() < 0.5])

    for city in CITIES:
        add_group(f"SG-Location-{city}", "security", [u["id"] for u in users if u["officeLocation"] == city])

    for app in APPS:
        affinity = set(APP_AFFINITY.get(app, rng.sample(list(DEPARTMENTS), 2)))
        app_users = [u["id"] for u in users if (u["department"] in affinity and rng.random() < 0.75) or rng.random() < 0.02]
        add_group(f"APP-{app}-Users", "security", app_users)
        add_group(f"APP-{app}-Admins", "security", rng.sample(app_users, k=min(len(app_users), rng.randint(2, 12))))
        add_group(f"APP-{app}-KeyUsers", "security", rng.sample(app_users, k=min(len(app_users), rng.randint(5, 40))))

    for lic in LICENSES:
        share = {"M365-E3": 0.7, "M365-E5": 0.15, "M365-F3": 0.15}.get(lic, 0.08)
        add_group(f"LIC-{lic}", "security", [u["id"] for u in users if rng.random() < share])

    for codename in PROJECT_CODENAMES:
        for phase in ["", " - Stuurgroep"]:
            add_group(f"Project {codename}{phase}", "m365", [u["id"] for u in rng.sample(users, k=rng.randint(4, 120))])
    for topic in COMMUNITIES:
        add_group(f"Community - {topic}", "m365", [u["id"] for u in rng.sample(users, k=rng.randint(15, 400))])

    deleted_users = [det_id("deleted-user", n) for n in range(50)]
    deleted_groups = [{"id": det_id("deleted-group", n), "displayName": f"SG-Decommissioned-{n:02d}"} for n in range(10)]
    return {"users": users, "groups": groups, "members": members,
            "deletedUserIds": deleted_users, "deletedGroups": deleted_groups}


def build_ops(tenant, count, shards, dryrun_count, seed):
    """Mutations as HelloID would send them. State is simulated per shard (shards own disjoint groups)."""
    rng = random.Random(seed + 1)
    managed = [g for g in tenant["groups"] if g["kind"] in ("security", "m365") and g["displayName"] != "SG-All-Employees"]
    shard_of = {g["id"]: int(uuid.UUID(g["id"])) % shards for g in managed}
    state = {g["id"]: set(tenant["members"][g["id"]]) for g in managed}
    user_ids = [u["id"] for u in tenant["users"]]
    names = {g["id"]: g["displayName"] for g in managed}
    for g in tenant["deletedGroups"]:
        names[g["id"]] = g["displayName"]

    mix = [("grant-new", 0.42), ("revoke-existing", 0.38), ("grant-existing", 0.08), ("revoke-nonmember", 0.07),
           ("grant-deleted-user", 0.015), ("revoke-deleted-user", 0.015), ("revoke-deleted-group", 0.01),
           ("grant-deleted-group", 0.01)]
    kinds, weights = zip(*mix)

    ops = []
    for seq in range(count + dryrun_count):
        kind = rng.choices(kinds, weights=weights, k=1)[0]
        group = rng.choice(managed)
        gid = group["id"]
        current = state[gid]
        if kind == "grant-new":
            candidates = [u for u in rng.sample(user_ids, 30) if u not in current]
            if not candidates:
                kind, uid = "grant-existing", rng.choice(sorted(current))
            else:
                uid = candidates[0]
        elif kind in ("revoke-existing", "grant-existing"):
            if not current:
                kind, uid = "grant-new", rng.choice(user_ids)
            else:
                uid = rng.choice(sorted(current)) if len(current) < 2000 else rng.choice(user_ids)
                if uid not in current:
                    kind = "grant-new" if kind == "grant-existing" else "revoke-nonmember"
        elif kind == "revoke-nonmember":
            uid = next((u for u in rng.sample(user_ids, 30) if u not in current), rng.choice(user_ids))
        elif kind in ("grant-deleted-user", "revoke-deleted-user"):
            uid = rng.choice(tenant["deletedUserIds"])
        else:
            uid = rng.choice(user_ids)
            deleted = rng.choice(tenant["deletedGroups"])
            gid = deleted["id"]
            shard_of.setdefault(gid, int(uuid.UUID(gid)) % shards)

        dry = seq < dryrun_count
        if not dry:
            if kind == "grant-new":
                current.add(uid)
            elif kind == "revoke-existing":
                current.discard(uid)
        ops.append({
            "seq": seq, "shard": shard_of[gid], "action": "grant" if kind.startswith("grant") else "revoke",
            "kind": kind, "dryRun": dry, "account": uid, "permissionId": gid, "permissionDisplayName": names[gid],
        })
    return ops


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True)
    parser.add_argument("--users", type=int, default=5000)
    parser.add_argument("--ops", type=int, default=100000)
    parser.add_argument("--dryrun-ops", type=int, default=5000, help="extra ops run with HelloID DryRun = true first")
    parser.add_argument("--shards", type=int, default=4)
    parser.add_argument("--seed", type=int, default=20261111)
    args = parser.parse_args()

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    tenant = build_tenant(args.users, args.seed)
    (out / "tenant.json").write_text(json.dumps(tenant))
    ops = build_ops(tenant, args.ops, args.shards, args.dryrun_ops, args.seed)
    with (out / "ops.jsonl").open("w") as f:
        for op in ops:
            f.write(json.dumps(op) + "\n")

    kinds = Counter(g["kind"] for g in tenant["groups"])
    memberships = sum(len(v) for v in tenant["members"].values())
    print(json.dumps({
        "users": len(tenant["users"]), "groups": len(tenant["groups"]), "groupsByKind": kinds,
        "memberships": memberships, "largestGroup": max(len(v) for v in tenant["members"].values()),
        "ops": len(ops), "opsByKind": Counter(o["kind"] for o in ops), "opsByShard": Counter(o["shard"] for o in ops),
        "dryRunOps": sum(1 for o in ops if o["dryRun"]),
    }, indent=2))


if __name__ == "__main__":
    main()
