#!/usr/bin/env python3
"""
Resolve K8s resource ownership against ArgoCD and Terraform state data.

Reads:  kubectl get ... --all-namespaces -o json  (from stdin)
Writes: CSV rows to stdout

Usage:
  kubectl get deployments,statefulsets,... --all-namespaces -o json | \\
      python3 resolve_ownership.py \\
          --argocd <status_file> --tfc <ndjson_file> \\
          --cluster <kube_context> --env <env> --region <region>
"""
import argparse
import csv
import datetime
import json
import os
import sys

# EKS-managed system components provisioned by AWS — present on every cluster
EKS_MANAGED_RESOURCES = frozenset({
    ("kube-system", "aws-node"),
    ("kube-system", "kube-proxy"),
    ("kube-system", "eks-pod-identity-agent"),
    ("kube-system", "kube-dns"),
    ("kube-system", "eks-extension-metrics-api"),
    ("default", "kubernetes"),
})

# Helm releases installed by eks-bootstrap (manual bootstrap, not Terraform or ArgoCD)
BOOTSTRAP_HELM_RELEASES = frozenset({
    "ingress-nginx",
    "pub-ssp", "pub-shaapi", "pub-discover-chat", "pub-eng", "pub-nlb", "ssl-nlb", "llm-eval",
    "linkerd-crds", "linkerd-control-plane", "linkerd-viz", "linkerd-smi",
    "datadog-operator",
})


CSV_HEADER = [
    "cluster", "env", "region", "namespace", "resource_type", "resource_name",
    "argocd_app", "argocd_sync_status", "argocd_health_status",
    "argocd_last_sync", "argocd_days_since_sync", "argocd_source_path",
    "tfc_workspace", "tfc_module", "tfc_resource_type",
    "team_label",
    "ownership_source",
    "migration_candidate",
    "notes",
]


def load_argocd_statuses(path):
    """Returns dict: app_name -> (sync_status, health_status, last_sync, source_path)"""
    statuses = {}
    if not path or not os.path.exists(path):
        return statuses
    with open(path) as f:
        for line in f:
            parts = line.strip().split("\t")
            if parts and parts[0]:
                statuses[parts[0]] = (
                    parts[1] if len(parts) > 1 else "",
                    parts[2] if len(parts) > 2 else "",
                    parts[3] if len(parts) > 3 else "",
                    parts[4] if len(parts) > 4 else "",
                )
    return statuses


def _days_since(ts):
    if not ts:
        return ""
    try:
        dt = datetime.datetime.fromisoformat(ts.replace("Z", "+00:00"))
        today = datetime.datetime.now(datetime.timezone.utc)
        return str((today - dt).days)
    except ValueError:
        return ""


def load_tfc_resources(path):
    """Returns list of resource dicts from tfc_client.py NDJSON output."""
    resources = []
    if not path or not os.path.exists(path):
        return resources
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                try:
                    resources.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
    return resources


def build_tfc_index(tfc_resources):
    """Index by (namespace, name). namespace may be None for cluster-scoped resources."""
    idx = {}
    for r in tfc_resources:
        key = (r.get("namespace"), r["name"])
        if key not in idx:
            idx[key] = r
    return idx


def build_tfc_helm_index(tfc_resources):
    """Secondary index: helm release name → resource, for Helm sub-resource matching."""
    idx = {}
    for r in tfc_resources:
        if r.get("tfc_resource_type") == "helm_release":
            idx.setdefault(r["name"], r)
    return idx


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--argocd", help="ArgoCD status file (tab-separated name/sync/health)")
    parser.add_argument("--tfc", help="TFC resources NDJSON file")
    parser.add_argument("--cluster", required=True)
    parser.add_argument("--env", required=True)
    parser.add_argument("--region", required=True)
    parser.add_argument("--skip-namespaces", default="kube-public,kube-node-lease",
                        help="Comma-separated namespaces to omit entirely")
    args = parser.parse_args()

    skip_ns = set(args.skip_namespaces.split(",")) if args.skip_namespaces else set()
    argocd = load_argocd_statuses(args.argocd)
    tfc_resources = load_tfc_resources(args.tfc)
    tfc_idx = build_tfc_index(tfc_resources)
    tfc_helm_idx = build_tfc_helm_index(tfc_resources)

    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError as e:
        print(f"Error: failed to parse kubectl JSON: {e}", file=sys.stderr)
        sys.exit(1)

    writer = csv.writer(sys.stdout, lineterminator="\n")
    writer.writerow(CSV_HEADER)

    count = 0
    for item in data.get("items", []):
        kind = item.get("kind", "")
        meta = item.get("metadata", {})
        name = meta.get("name", "")
        namespace = meta.get("namespace", "")
        labels = meta.get("labels") or {}

        if namespace in skip_ns:
            continue

        # ArgoCD ownership — only confirmed if the instance label matches a known ArgoCD app
        instance_label = labels.get("app.kubernetes.io/instance", "")
        managed_by = labels.get("app.kubernetes.io/managed-by", "")
        is_argocd = bool(instance_label) and instance_label in argocd
        if is_argocd:
            argocd_app = instance_label
            argocd_sync, argocd_health, argocd_last_sync, argocd_source_path = argocd[argocd_app]
            argocd_days_since_sync = _days_since(argocd_last_sync)
        else:
            argocd_app = argocd_sync = argocd_health = argocd_last_sync = argocd_days_since_sync = argocd_source_path = ""

        # TFC ownership:
        # 1. Exact (namespace, name) match — covers main resources named same as release/SA
        # 2. Cluster-scoped (None, name) match — kubectl_manifest resources
        # 3. Helm sub-resource: managed-by=Helm, instance label not in ArgoCD → look up
        #    the release name (= instance_label) in the helm release index
        tfc_match = (
            tfc_idx.get((namespace, name))
            or tfc_idx.get((None, name))
            or (tfc_helm_idx.get(instance_label)
                if managed_by == "Helm" and instance_label and not is_argocd
                else None)
        )
        tfc_workspace = tfc_match["tfc_workspace"] if tfc_match else ""
        tfc_module = tfc_match["tfc_module"] if tfc_match else ""
        tfc_resource_type = tfc_match["tfc_resource_type"] if tfc_match else ""
        is_terraform = bool(tfc_match)

        is_eks_managed = (namespace, name) in EKS_MANAGED_RESOURCES

        is_eks_bootstrap = (
            not is_argocd and not is_terraform and not is_eks_managed
            and (
                (managed_by == "Helm" and instance_label in BOOTSTRAP_HELM_RELEASES)
                or name.startswith("eventbus-")
            )
        )

        if is_argocd and is_terraform:
            ownership_source = "both"
        elif is_argocd:
            ownership_source = "argocd"
        elif is_terraform:
            ownership_source = "terraform"
        elif is_eks_managed:
            ownership_source = "eks-managed"
        elif is_eks_bootstrap:
            ownership_source = "eks-bootstrap"
        else:
            ownership_source = "none"

        if ownership_source == "argocd":
            migration_candidate = "yes"
        elif ownership_source in ("terraform", "eks-managed", "eks-bootstrap"):
            migration_candidate = "skip"
        else:
            migration_candidate = "manual-review"

        team_label = labels.get("team", "")

        writer.writerow([
            args.cluster, args.env, args.region,
            namespace, kind, name,
            argocd_app, argocd_sync, argocd_health, argocd_last_sync, argocd_days_since_sync, argocd_source_path,
            tfc_workspace, tfc_module, tfc_resource_type,
            team_label,
            ownership_source,
            migration_candidate,
            "",
        ])
        count += 1

    print(f"  [resolve] Wrote {count} resource rows", file=sys.stderr)


if __name__ == "__main__":
    main()
