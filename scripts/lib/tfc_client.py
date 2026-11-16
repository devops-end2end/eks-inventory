#!/usr/bin/env python3
"""
Query Terraform Cloud state and extract K8s resources for a specific cluster module.

Usage: python3 tfc_client.py --org ORG --workspace WS --module MODULE_PREFIX
Env:   TFC_TOKEN — Terraform Cloud API token

Output: NDJSON, one JSON object per K8s resource found in the given module prefix.
State file cached to /tmp/tfc-state-{workspace}.json to avoid repeat downloads.
"""
import argparse
import json
import os
import sys
import urllib.error
import urllib.request

TFC_BASE = "https://app.terraform.io/api/v2"
K8S_TYPES = frozenset({
    "helm_release",
    "kubernetes_service_account_v1",
    "kubernetes_role_binding_v1",
    "kubectl_manifest",
})


def tfc_get(path, token):
    req = urllib.request.Request(
        f"{TFC_BASE}{path}",
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/vnd.api+json",
        },
    )
    try:
        with urllib.request.urlopen(req) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as e:
        print(f"Error: TFC API {path} returned HTTP {e.code}: {e.read().decode()}", file=sys.stderr)
        sys.exit(1)


def download_url(url, token):
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req) as resp:
        return json.load(resp)


def extract_name_namespace(resource):
    rtype = resource["type"]
    instances = resource.get("instances", [])
    if not instances:
        return None, None
    attrs = instances[0].get("attributes", {})

    if rtype == "helm_release":
        return attrs.get("name"), attrs.get("namespace")

    if rtype in ("kubernetes_service_account_v1", "kubernetes_role_binding_v1"):
        meta = attrs.get("metadata")
        if meta:
            if isinstance(meta, list):
                meta = meta[0]
            return meta.get("name"), meta.get("namespace")
        return None, None

    if rtype == "kubectl_manifest":
        return attrs.get("name"), attrs.get("namespace")

    return None, None


def get_state(org, workspace, token):
    cache_path = f"/tmp/tfc-state-{workspace}.json"
    if os.path.exists(cache_path):
        print(f"  [tfc] Using cached state: {cache_path}", file=sys.stderr)
        with open(cache_path) as f:
            return json.load(f)

    print(f"  [tfc] Fetching workspace: {workspace}", file=sys.stderr)
    ws_data = tfc_get(f"/organizations/{org}/workspaces/{workspace}", token)
    ws_id = ws_data["data"]["id"]

    print("  [tfc] Fetching current state version...", file=sys.stderr)
    sv = tfc_get(f"/workspaces/{ws_id}/current-state-version", token)
    state_url = sv["data"]["attributes"]["hosted-state-download-url"]

    print("  [tfc] Downloading state...", file=sys.stderr)
    state = download_url(state_url, token)

    with open(cache_path, "w") as f:
        json.dump(state, f)
    print(f"  [tfc] Cached to {cache_path}", file=sys.stderr)
    return state


def main():
    parser = argparse.ArgumentParser(description="Extract K8s resources from TFC state")
    parser.add_argument("--org", required=True, help="TFC organization name")
    parser.add_argument("--workspace", required=True, help="TFC workspace name")
    parser.add_argument("--module", required=True, dest="module_prefix",
                        help="Terraform module prefix(es), comma-separated (e.g. module.eks_stg_use1_01)")
    args = parser.parse_args()

    token = os.environ.get("TFC_TOKEN")
    if not token:
        print("Error: TFC_TOKEN not set — run: source scripts/creds.sh", file=sys.stderr)
        sys.exit(1)

    prefixes = [p.strip() for p in args.module_prefix.split(",") if p.strip()]

    state = get_state(args.org, args.workspace, token)

    results = []
    for resource in state.get("resources", []):
        if resource.get("mode") == "data":
            continue
        module = resource.get("module", "")
        if not any(module.startswith(p) for p in prefixes):
            continue
        if resource.get("type") not in K8S_TYPES:
            continue

        name, namespace = extract_name_namespace(resource)
        if not name:
            continue

        results.append({
            "tfc_workspace": args.workspace,
            "tfc_module": module,
            "tfc_resource_type": resource["type"],
            "name": name,
            "namespace": namespace,
        })

    print(f"  [tfc] Found {len(results)} K8s resources for prefix(es) {args.module_prefix!r}", file=sys.stderr)
    for r in results:
        print(json.dumps(r))


if __name__ == "__main__":
    main()
