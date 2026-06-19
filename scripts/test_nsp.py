#!/usr/bin/env python
"""Validate the Microsoft Foundry + Azure AI Search Network Security Perimeter demo.

Mirrors the "Validate before enforcement" section of:
  https://learn.microsoft.com/azure/foundry/how-to/add-foundry-to-network-security-perimeter

Checks performed:
  1. Control plane  - both resources are associated to the SAME NSP profile.
  2. Topology       - Foundry and AI Search live in DIFFERENT regions.
  3. Data plane     - an in-perimeter client (Azure CLI identity) can reach the
                      Foundry and Search data planes across regions.
  4. Access logs    - NspAccessLogs in Log Analytics record allow/deny decisions.

Auth: uses AzureCliCredential (the cached `az login` token). Service principals
are blocked on the data plane in this tenant, so run `az login` first.

Usage:
  # Resolve config straight from the deployment outputs, then run all checks:
  python scripts/test_nsp.py --deployment <sub-deployment-name>

  # Or set the endpoints yourself and run as a pytest module:
  pytest scripts/test_nsp.py -v
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from dataclasses import dataclass

import requests
from azure.identity import AzureCliCredential

ARM = "https://management.azure.com"
ARM_SCOPE = "https://management.azure.com/.default"
SEARCH_SCOPE = "https://search.azure.com/.default"
COGNITIVE_SCOPE = "https://cognitiveservices.azure.com/.default"
LOGS_SCOPE = "https://api.loganalytics.io/.default"

NSP_API = "2024-07-01"
SEARCH_DATA_API = "2024-07-01"
FOUNDRY_DATA_API = "2024-10-21"


@dataclass
class Config:
    subscription_id: str
    resource_group: str
    foundry_endpoint: str
    search_endpoint: str
    nsp_id: str
    nsp_profile_id: str
    law_customer_id: str
    access_mode: str


_credential: AzureCliCredential | None = None


def _cred() -> AzureCliCredential:
    global _credential
    if _credential is None:
        _credential = AzureCliCredential()
    return _credential


def _token(scope: str) -> str:
    return _cred().get_token(scope).token


def _bearer(scope: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {_token(scope)}"}


def load_config_from_deployment(
    deployment_name: str, resource_group: str | None = None
) -> Config:
    """Read deployment outputs via the Azure CLI.

    If ``resource_group`` is given, reads a resource-group scoped deployment
    (``az deployment group show``); otherwise a subscription scoped one.
    """
    if resource_group:
        cmd = [
            "az", "deployment", "group", "show",
            "--resource-group", resource_group,
            "--name", deployment_name,
        ]
    else:
        cmd = ["az", "deployment", "sub", "show", "--name", deployment_name]
    raw = subprocess.check_output(
        cmd + ["--query", "properties.outputs", "-o", "json"],
        text=True,
    )
    out = json.loads(raw)

    def val(key: str) -> str:
        return out[key]["value"]

    sub_id = subprocess.check_output(
        ["az", "account", "show", "--query", "id", "-o", "tsv"], text=True
    ).strip()

    return Config(
        subscription_id=sub_id,
        resource_group=val("resourceGroupName"),
        foundry_endpoint=val("foundryEndpoint").rstrip("/"),
        search_endpoint=val("searchEndpoint").rstrip("/"),
        nsp_id=val("nspId"),
        nsp_profile_id=val("nspProfileId"),
        law_customer_id=val("logAnalyticsWorkspaceCustomerId"),
        access_mode=val("accessMode"),
    )


def load_config_from_env() -> Config:
    """Read config from environment variables (for `pytest` runs)."""
    missing = [
        k
        for k in (
            "NSP_SUBSCRIPTION_ID",
            "NSP_RESOURCE_GROUP",
            "NSP_FOUNDRY_ENDPOINT",
            "NSP_SEARCH_ENDPOINT",
            "NSP_ID",
            "NSP_PROFILE_ID",
            "NSP_LAW_CUSTOMER_ID",
        )
        if not os.environ.get(k)
    ]
    if missing:
        raise RuntimeError(
            "Missing env vars: "
            + ", ".join(missing)
            + ". Run with --deployment <name> or export them first."
        )
    return Config(
        subscription_id=os.environ["NSP_SUBSCRIPTION_ID"],
        resource_group=os.environ["NSP_RESOURCE_GROUP"],
        foundry_endpoint=os.environ["NSP_FOUNDRY_ENDPOINT"].rstrip("/"),
        search_endpoint=os.environ["NSP_SEARCH_ENDPOINT"].rstrip("/"),
        nsp_id=os.environ["NSP_ID"],
        nsp_profile_id=os.environ["NSP_PROFILE_ID"],
        law_customer_id=os.environ["NSP_LAW_CUSTOMER_ID"],
        access_mode=os.environ.get("NSP_ACCESS_MODE", "Learning"),
    )


def _get_config() -> Config:
    """pytest entry point: build config from env vars."""
    return load_config_from_env()


# --------------------------------------------------------------------------- #
# Check 1 - both resources associated to the same NSP profile (control plane)
# --------------------------------------------------------------------------- #
def check_associations(cfg: Config) -> list[dict]:
    url = f"{ARM}{cfg.nsp_id}/resourceAssociations?api-version={NSP_API}"
    resp = requests.get(url, headers=_bearer(ARM_SCOPE), timeout=30)
    resp.raise_for_status()
    associations = resp.json().get("value", [])

    profile_ids = {
        a["properties"]["profile"]["id"].lower()
        for a in associations
        if a.get("properties", {}).get("profile")
    }
    linked = {
        a["properties"]["privateLinkResource"]["id"].lower()
        for a in associations
        if a.get("properties", {}).get("privateLinkResource")
    }

    assert any(
        "/cognitiveservices/accounts/" in r for r in linked
    ), "Foundry (CognitiveServices) account is not associated to the NSP"
    assert any(
        "/searchservices/" in r for r in linked
    ), "Azure AI Search service is not associated to the NSP"
    assert cfg.nsp_profile_id.lower() in profile_ids, (
        "Resources are not associated to the expected NSP profile"
    )
    return associations


# --------------------------------------------------------------------------- #
# Check 2 - Foundry and Search are in different regions
# --------------------------------------------------------------------------- #
def check_cross_region(cfg: Config) -> tuple[str, str]:
    def location_of(resource_filter: str) -> str:
        url = (
            f"{ARM}/subscriptions/{cfg.subscription_id}/resourceGroups/"
            f"{cfg.resource_group}/resources?$filter={resource_filter}"
            "&api-version=2021-04-01"
        )
        resp = requests.get(url, headers=_bearer(ARM_SCOPE), timeout=30)
        resp.raise_for_status()
        items = resp.json().get("value", [])
        assert items, f"No resource found for filter {resource_filter}"
        return items[0]["location"]

    foundry_loc = location_of("resourceType eq 'Microsoft.CognitiveServices/accounts'")
    search_loc = location_of("resourceType eq 'Microsoft.Search/searchServices'")
    assert foundry_loc != search_loc, (
        f"Foundry and Search are both in {foundry_loc}; expected different regions"
    )
    return foundry_loc, search_loc


# --------------------------------------------------------------------------- #
# Check 3 - in-perimeter data-plane reachability (across regions)
# --------------------------------------------------------------------------- #
def check_search_data_plane(cfg: Config) -> int:
    url = f"{cfg.search_endpoint}/servicestats?api-version={SEARCH_DATA_API}"
    resp = requests.get(url, headers=_bearer(SEARCH_SCOPE), timeout=30)
    assert resp.status_code == 200, (
        f"Search data plane returned {resp.status_code}: {resp.text[:300]}"
    )
    return resp.status_code


def check_foundry_data_plane(cfg: Config) -> int:
    url = f"{cfg.foundry_endpoint}/openai/deployments?api-version={FOUNDRY_DATA_API}"
    resp = requests.get(url, headers=_bearer(COGNITIVE_SCOPE), timeout=30)
    # 200 = reachable; an empty account still answers. Anything 2xx means the
    # NSP/publicNetworkAccess path let the in-perimeter client through.
    assert resp.status_code == 200, (
        f"Foundry data plane returned {resp.status_code}: {resp.text[:300]}"
    )
    return resp.status_code


# --------------------------------------------------------------------------- #
# Check 4 - NspAccessLogs recorded allow/deny decisions
# --------------------------------------------------------------------------- #
def query_access_logs(cfg: Config, lookback_minutes: int = 60) -> list[dict]:
    query = (
        "NspAccessLogs "
        f"| where TimeGenerated > ago({lookback_minutes}m) "
        "| summarize Count = count() by AccessResult = tostring(AccessResult), "
        "MatchedRule = tostring(MatchedRule) "
        "| order by Count desc"
    )
    url = f"https://api.loganalytics.io/v1/workspaces/{cfg.law_customer_id}/query"
    resp = requests.post(
        url,
        headers={**_bearer(LOGS_SCOPE), "Content-Type": "application/json"},
        json={"query": query},
        timeout=60,
    )
    resp.raise_for_status()
    tables = resp.json().get("tables", [])
    if not tables:
        return []
    cols = [c["name"] for c in tables[0]["columns"]]
    return [dict(zip(cols, row)) for row in tables[0]["rows"]]


# --------------------------------------------------------------------------- #
# pytest tests
# --------------------------------------------------------------------------- #
def test_associations_present():
    check_associations(_get_config())


def test_resources_cross_region():
    check_cross_region(_get_config())


def test_search_reachable_in_perimeter():
    check_search_data_plane(_get_config())


def test_foundry_reachable_in_perimeter():
    check_foundry_data_plane(_get_config())


def test_access_logs_emitted():
    rows = query_access_logs(_get_config())
    # Logs can take up to ~15 min to surface; treat empty as a soft skip.
    if not rows:
        import pytest

        pytest.skip("No NspAccessLogs yet — allow up to 15 minutes after traffic.")
    assert any(int(r.get("Count", 0)) > 0 for r in rows)


# --------------------------------------------------------------------------- #
# CLI runner
# --------------------------------------------------------------------------- #
def _run_cli(cfg: Config) -> int:
    failures = 0

    def step(name: str, fn):
        nonlocal failures
        try:
            result = fn()
            print(f"  [PASS] {name}: {result}")
        except AssertionError as exc:
            failures += 1
            print(f"  [FAIL] {name}: {exc}")
        except Exception as exc:  # noqa: BLE001
            failures += 1
            print(f"  [ERROR] {name}: {exc}")

    print(f"\nNSP validation — access mode: {cfg.access_mode}\n")

    print("1. NSP associations (control plane)")
    step("both resources associated to NSP profile", lambda: f"{len(check_associations(cfg))} associations")

    print("2. Cross-region topology")
    step("Foundry and Search in different regions", lambda: " vs ".join(check_cross_region(cfg)))

    print("3. In-perimeter data-plane reachability")
    step("Azure AI Search /servicestats", lambda: check_search_data_plane(cfg))
    step("Microsoft Foundry /openai/deployments", lambda: check_foundry_data_plane(cfg))

    print("4. NSP access logs")

    def logs():
        rows = query_access_logs(cfg)
        if not rows:
            return "no rows yet (allow up to 15 min)"
        return "; ".join(
            f"{r.get('AccessResult')}/{r.get('MatchedRule')}={r.get('Count')}" for r in rows
        )

    step("NspAccessLogs decisions", logs)

    print(f"\nDone — {failures} failure(s).")
    return failures


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--deployment",
        help="Deployment name to read outputs from (via az).",
    )
    parser.add_argument(
        "--resource-group",
        dest="resource_group",
        help="Resource group of an RG-scoped deployment (omit for sub-scoped).",
    )
    parser.add_argument(
        "--lookback",
        type=int,
        default=60,
        help="Minutes of NspAccessLogs history to summarize (default 60).",
    )
    args = parser.parse_args()

    if args.deployment:
        cfg = load_config_from_deployment(args.deployment, args.resource_group)
    else:
        cfg = load_config_from_env()

    return _run_cli(cfg)


if __name__ == "__main__":
    sys.exit(main())
