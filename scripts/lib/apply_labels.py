#!/usr/bin/env python3
"""
Apply team labels from a user-filled needs-team.csv.

Generates:
  - Modified kustomization.yaml files  (for argocd resources — adds team to labels block)
  - Modified Terraform HCL files       (for terraform resources)

Called by label.sh --apply. Outputs go to --tmp-dir, then label.sh creates PRs.
"""
import argparse
import csv
import json
import re
import sys
from pathlib import Path


# ── Kustomize label application ────────────────────────────────────────────────

def find_app_overlay(deploy_configs, argocd_source_path):
    """Locate the kustomization.yaml using the source.path from the ArgoCD Application spec."""
    if not argocd_source_path:
        return None
    kust = Path(deploy_configs) / argocd_source_path / "kustomization.yaml"
    return kust if kust.exists() else None


def apply_team_to_kustomization(kust_path, team, tmp_dir, deploy_configs):
    """
    Add team label to the kustomization.yaml overlay in-place.

    Uses labels: [{pairs: {team: ...}, includeSelectors: false, includeTemplates: true}]
    rather than commonLabels so the team label is not added to Deployment selectors
    (which are immutable on running resources).

    Returns True if the file was changed.
    """
    content = kust_path.read_text()

    # Idempotency: skip if team label already present anywhere in the file
    for line in content.splitlines():
        stripped = line.strip()
        if re.match(r'^team\s*:', stripped):
            return False

    lines = content.splitlines(keepends=True)

    # Find existing top-level labels: block (if any)
    labels_start = None
    for i, line in enumerate(lines):
        if line.rstrip() == "labels:":
            labels_start = i
            break

    if labels_start is not None:
        # Detect list-item indentation from the first item after labels:
        # Style A: "  - pairs:" (2-space)  Style B: "- pairs:" (0-space)
        list_indent = "  "
        if labels_start + 1 < len(lines):
            first = lines[labels_start + 1]
            if first.startswith("- "):
                list_indent = ""

        # Find end of the labels block: stop at the next top-level key.
        # Lines starting with '-' or whitespace are still part of the block.
        j = labels_start + 1
        while j < len(lines):
            ln = lines[j]
            if ln.strip() and not ln.strip().startswith("#") and ln[0] not in (' ', '\t', '-'):
                break
            j += 1

        new_item = (
            f"{list_indent}- pairs:\n"
            f"{list_indent}    team: {team}\n"
            f"{list_indent}  includeSelectors: false\n"
            f"{list_indent}  includeTemplates: true\n"
        )
        new_lines = lines[:j] + [new_item] + lines[j:]
    else:
        # Append a new labels block at end of file (default to 2-space indent style)
        new_item = (
            "  - pairs:\n"
            f"      team: {team}\n"
            "    includeSelectors: false\n"
            "    includeTemplates: true\n"
        )
        suffix = "" if content.endswith("\n") else "\n"
        new_lines = lines + [suffix + "\n", "labels:\n", new_item]

    new_content = "".join(new_lines)

    rel_path = kust_path.relative_to(Path(deploy_configs))
    out_path = Path(tmp_dir) / "kustomize" / rel_path
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(new_content)
    return True


# ── Terraform HCL modification ────────────────────────────────────────────────

def derive_cluster_dir(tfc_module, tf_repo):
    """
    Map a tfc_module string to the relative web-identities directory path.
    e.g. module.eks_stg_use1_01_web_identities.module.service_account_foo
         -> eks-stage/eks-stg-use1-01-web-identities
    """
    parts = tfc_module.split(".")
    if len(parts) < 2:
        return None
    top_module = parts[1]  # e.g. eks_stg_use1_01_web_identities

    for env_dir in sorted(Path(tf_repo).iterdir()):
        if not env_dir.is_dir() or not env_dir.name.startswith("eks-"):
            continue
        for cluster_dir in sorted(env_dir.iterdir()):
            if not cluster_dir.is_dir() or not cluster_dir.name.endswith("-web-identities"):
                continue
            normalized = cluster_dir.name.replace("-", "_")
            if normalized == top_module:
                return str(cluster_dir.relative_to(Path(tf_repo)))
    return None


def apply_web_identity_team_labels(tf_repo, tmp_dir, cluster_dir, sa_changes):
    """
    Add team = "..." to module "service_account_{app}" blocks in a web-identities main.tf.
    sa_changes: list of (app_name, team) tuples.
    Returns count of blocks updated.
    """
    caller_path = Path(tf_repo) / cluster_dir / "main.tf"
    if not caller_path.exists():
        print(f"  Warning: {caller_path} not found", file=sys.stderr)
        return 0

    content = caller_path.read_text()
    applied = 0

    for app_name, team in sa_changes:
        module_key = app_name.replace("-", "_")
        pattern = (
            rf'(module\s+"service_account_{re.escape(module_key)}"\s*\{{)'
            rf'(.*?)'
            rf'(^(\s*)\}})'
        )

        def replacer(m, t=team):
            opening, body, closing, indent = m.group(1), m.group(2), m.group(3), m.group(4)
            if re.search(r'\bteam\b', body):
                return m.group(0)
            return f'{opening}{body}{indent}  team             = "{t}"\n{closing}'

        new_content, count = re.subn(pattern, replacer, content, flags=re.MULTILINE | re.DOTALL)
        if count > 0:
            content = new_content
            applied += 1
        else:
            print(f"  Warning: module 'service_account_{module_key}' not found in {cluster_dir}/main.tf",
                  file=sys.stderr)

    if applied > 0:
        out = Path(tmp_dir) / "terraform" / cluster_dir / "main.tf"
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(content)

    return applied


def ensure_web_identities_module_updated(tf_repo, tmp_dir):
    """
    Add team variable + labels block to the shared web_identities_k8s module.
    Idempotent — checks before modifying.
    """
    module_dir = Path(tf_repo) / "modules" / "web_identities_k8s"

    vars_path = module_dir / "variables.tf"
    vars_content = vars_path.read_text()
    if 'variable "team"' not in vars_content:
        vars_content += (
            '\nvariable "team" {\n'
            '  description = "Team label applied to the Kubernetes service account"\n'
            '  type        = string\n'
            '  default     = ""\n'
            '}\n'
        )
        out = Path(tmp_dir) / "terraform" / "modules" / "web_identities_k8s" / "variables.tf"
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(vars_content)
        print("  [tf] Updated modules/web_identities_k8s/variables.tf", file=sys.stderr)

    main_path = module_dir / "main.tf"
    main_content = main_path.read_text()
    if '"team" = var.team' not in main_content:
        old_block = (
            '    annotations = {\n'
            '      "eks.amazonaws.com/role-arn" = aws_iam_role.web_identity_role.arn\n'
            '    }'
        )
        new_block = old_block + (
            '\n    labels = {\n'
            '      "team" = var.team\n'
            '    }'
        )
        if old_block in main_content:
            main_content = main_content.replace(old_block, new_block)
            out = Path(tmp_dir) / "terraform" / "modules" / "web_identities_k8s" / "main.tf"
            out.parent.mkdir(parents=True, exist_ok=True)
            out.write_text(main_content)
            print("  [tf] Updated modules/web_identities_k8s/main.tf", file=sys.stderr)
        else:
            print("  Warning: annotations block not found in web_identities_k8s/main.tf — manual edit required",
                  file=sys.stderr)


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--apply-csv", required=True)
    parser.add_argument("--deploy-configs", required=True)
    parser.add_argument("--tf-repo", required=True)
    parser.add_argument("--tmp-dir", required=True)
    parser.add_argument("--env", required=True)
    parser.add_argument("--region", required=True)
    parser.add_argument("--cluster", required=True)
    parser.add_argument("--teams", default="",
                        help="Comma-separated team names to include (default: all)")
    parser.add_argument("--limit", type=int, default=0,
                        help="Max ArgoCD apps to process (default: unlimited). "
                             "Apps are sorted for determinism; already-labeled apps are skipped.")
    args = parser.parse_args()

    teams_filter = set(t.strip() for t in args.teams.split(",") if t.strip())

    (Path(args.tmp_dir) / "kustomize").mkdir(parents=True, exist_ok=True)
    (Path(args.tmp_dir) / "terraform").mkdir(parents=True, exist_ok=True)

    # Collect all rows first
    # ArgoCD: group by argocd_app -> (team, source_path) — source_path from CSV column
    argocd_apps = {}       # argocd_app -> (team, source_path)
    argocd_conflicts = []  # (argocd_app, team_a, team_b)

    # Terraform: group web-identity SA changes by cluster directory
    web_identity_changes = {}  # cluster_dir -> [(app_name, team)]
    module_update_needed = False

    manual_review = []
    terraform_sa_count = 0

    with open(args.apply_csv) as f:
        for row in csv.DictReader(f):
            team = (row.get("team") or "").strip()
            if not team:
                continue

            ownership = row.get("ownership_source", "")
            name = row.get("resource_name", "")
            namespace = row.get("namespace", "")
            argocd_app = row.get("argocd_app", "").strip()
            argocd_source_path = row.get("argocd_source_path", "").strip()
            tfc_module = row.get("tfc_module", "")
            tfc_resource_type = row.get("tfc_resource_type", "")

            if ownership in ("argocd", "both") and argocd_app:
                if teams_filter and team not in teams_filter:
                    continue
                if argocd_app in argocd_apps and argocd_apps[argocd_app][0] != team:
                    argocd_conflicts.append((argocd_app, argocd_apps[argocd_app][0], team))
                else:
                    argocd_apps[argocd_app] = (team, argocd_source_path)

            if ownership in ("terraform", "both"):
                if tfc_resource_type == "kubernetes_service_account_v1":
                    app_name = name[3:] if name.startswith("wi-") else name
                    cluster_dir = derive_cluster_dir(tfc_module, args.tf_repo)
                    if cluster_dir:
                        web_identity_changes.setdefault(cluster_dir, []).append((app_name, team))
                        module_update_needed = True
                        terraform_sa_count += 1
                    else:
                        manual_review.append(
                            f"kubernetes_service_account_v1/{name} in {namespace} "
                            f"(module: {tfc_module}) — cluster dir not found"
                        )
                elif tfc_resource_type == "helm_release":
                    manual_review.append(
                        f"helm_release/{name} (ns: {namespace or 'cluster-scoped'}, "
                        f"module: {tfc_module}) — add team label via chart values/set block"
                    )
                elif tfc_resource_type:
                    manual_review.append(
                        f"{tfc_resource_type}/{name} in {namespace} (module: {tfc_module})"
                    )

            if ownership == "none":
                manual_review.append(
                    f"{row.get('resource_type', 'resource')}/{name} in {namespace} "
                    f"— no ownership source; adopt into an ArgoCD app or Terraform before labeling"
                )

    # Warn about conflicting team assignments within a single ArgoCD app
    for app, team_a, team_b in argocd_conflicts:
        print(f"  Warning: ArgoCD app {app!r} has conflicting teams {team_a!r} and {team_b!r} — using {team_a!r}",
              file=sys.stderr)

    # Apply --limit: cap to first N *unlabeled* apps so re-runs advance to the next batch.
    # Pre-scan kustomization files to exclude already-labeled apps from the count.
    if args.limit > 0:
        unlabeled = {}
        for app, (team, source_path) in sorted(argocd_apps.items()):
            kust_path = find_app_overlay(args.deploy_configs, source_path)
            if kust_path is None:
                unlabeled[app] = (team, source_path)
                continue
            content = kust_path.read_text()
            already = any(re.match(r'^team\s*:', line.strip()) for line in content.splitlines())
            if not already:
                unlabeled[app] = (team, source_path)
        argocd_apps = {k: unlabeled[k] for k in sorted(unlabeled)[:args.limit]}

    # Apply kustomization edits — one file per ArgoCD app overlay
    kustomize_count = 0
    kustomize_missing = []

    for argocd_app, (team, source_path) in sorted(argocd_apps.items()):
        kust_path = find_app_overlay(args.deploy_configs, source_path)
        if kust_path is None:
            detail = f"source path: {source_path!r}" if source_path else "argocd_source_path not set — re-run inventory"
            kustomize_missing.append(f"{argocd_app} — {detail}")
            continue
        changed = apply_team_to_kustomization(kust_path, team, args.tmp_dir, args.deploy_configs)
        if changed:
            kustomize_count += 1
            print(f"  [kustomize] {argocd_app}: team={team}", file=sys.stderr)
        else:
            print(f"  [kustomize] {argocd_app}: already labeled, skipped", file=sys.stderr)

    manual_review.extend(
        f"{item} — kustomization overlay not found" for item in kustomize_missing
    )

    # Apply shared Terraform module changes
    if module_update_needed:
        ensure_web_identities_module_updated(args.tf_repo, args.tmp_dir)

    for cluster_dir, sa_changes in web_identity_changes.items():
        applied = apply_web_identity_team_labels(args.tf_repo, args.tmp_dir, cluster_dir, sa_changes)
        print(f"  [tf] {cluster_dir}: {applied}/{len(sa_changes)} SAs updated", file=sys.stderr)

    # Write PR body for Terraform PR
    pr_body_path = Path(args.tmp_dir) / "terraform" / "pr-body.md"
    lines = [
        f"Add `team` labels to Terraform-managed K8s resources in `{args.env}-{args.region}`.\n"
    ]
    if module_update_needed:
        lines += [
            "**Shared module changes:**",
            "- `modules/web_identities_k8s/variables.tf` — added `team` variable",
            "- `modules/web_identities_k8s/main.tf` — added `labels` block to service account\n",
        ]
    if web_identity_changes:
        total_sas = sum(len(v) for v in web_identity_changes.values())
        lines.append(f"**Web identity service accounts:** {total_sas}")
        for d, sas in sorted(web_identity_changes.items()):
            for app, team in sas:
                lines.append(f"  - `{d}`: `wi-{app}` → `team={team}`")
        lines.append("")
    if manual_review:
        lines += [
            f"**Requires manual changes** ({len(manual_review)} resources):",
        ]
        for item in manual_review:
            lines.append(f"  - {item}")

    pr_body_path.write_text("\n".join(lines) + "\n")

    summary = {
        "kustomize_count": kustomize_count,
        "terraform_sa_count": terraform_sa_count,
        "manual_review_count": len(manual_review),
        "has_kustomize": kustomize_count > 0,
        "has_terraform": module_update_needed or bool(web_identity_changes),
    }
    print(json.dumps(summary))


if __name__ == "__main__":
    main()
