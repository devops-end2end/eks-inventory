#!/usr/bin/env bash
# label.sh — two-phase team label workflow
#
# Phase 1 (report): generates needs-team.csv listing resources missing team label
#   ./label.sh <env-file>          → output/{env}-{region}/needs-team.csv
#   ./label.sh --all               → output/all/needs-team.csv  (all clusters merged)
#
# Phase 2 (apply): reads filled CSV, generates Kustomize patches + Terraform HCL, opens PRs
#   ./label.sh <env-file> --apply <csv>
#   ./label.sh --all --apply       → reads output/all/needs-team.csv
#
# Note: if an env-file is provided, --all is ignored.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

ALL_NEEDS_TEAM_CSV="$PROJECT_DIR/output/all/needs-team.csv"

# ── Arg parsing ───────────────────────────────────────────────────────────────
ALL_MODE=false
ENV_FILE=""
APPLY_MODE=false
APPLY_CSV=""
TEAMS=""
LIMIT=0
TAG=""
CLUSTERS=""

while [[ $# -gt 0 ]]; do
    case "${1:-}" in
        --all)
            ALL_MODE=true
            shift
            ;;
        --apply)
            APPLY_MODE=true
            shift
            # Optional CSV path (not --flag and not empty)
            if [[ -n "${1:-}" && "${1:-}" != --* ]]; then
                APPLY_CSV="$1"
                shift
            fi
            ;;
        --teams)
            TEAMS="${2:-}"
            shift 2
            ;;
        --limit)
            LIMIT="${2:-0}"
            shift 2
            ;;
        --tag)
            TAG="${2:-}"
            shift 2
            ;;
        --clusters)
            CLUSTERS="${2:-}"
            shift 2
            ;;
        --*)
            echo "Unknown option: $1" >&2; exit 1
            ;;
        *)
            # Positional: env file (first non-flag arg)
            if [[ -z "$ENV_FILE" ]]; then
                ENV_FILE="$1"
                ALL_MODE=false
            fi
            shift
            ;;
    esac
done

if ! $ALL_MODE && [[ -z "$ENV_FILE" ]]; then
    echo "Usage: label.sh <env-file> [--apply [csv]] [--teams t1,t2] [--limit N] [--tag TAG]" >&2
    echo "       label.sh --all [--apply]  [--teams t1,t2] [--limit N] [--tag TAG] [--clusters env-region,...]" >&2
    exit 1
fi
if [[ -n "$ENV_FILE" ]]; then
    [[ -f "$ENV_FILE" ]] || { echo "Error: env config not found: $ENV_FILE" >&2; exit 1; }
fi
if $APPLY_MODE && ! $ALL_MODE && [[ -z "$APPLY_CSV" ]]; then
    echo "Error: --apply requires a CSV path" >&2; exit 1
fi
if $ALL_MODE && $APPLY_MODE && [[ -z "$APPLY_CSV" ]]; then
    APPLY_CSV="$ALL_NEEDS_TEAM_CSV"
fi

# ── Phase 1: Report ───────────────────────────────────────────────────────────
if ! $APPLY_MODE; then

    if $ALL_MODE; then
        echo "=== Label Report: All Clusters ==="
        echo ""
        mkdir -p "$PROJECT_DIR/output/all"

        python3 - "$PROJECT_DIR" "$ALL_NEEDS_TEAM_CSV" <<'PYEOF'
import csv, sys
from pathlib import Path

HEADER = ["team", "cluster", "namespace", "resource_type", "resource_name",
          "ownership_source", "argocd_app", "tfc_module", "argocd_source_path"]

rows = []
output_dir = Path(sys.argv[1]) / "output"
for inv in sorted(output_dir.glob("*/inventory.csv")):
    if inv.parent.name == "all":
        continue
    with open(inv) as f:
        for row in csv.DictReader(f):
            if row.get("team_label"):
                continue
            rows.append({
                "team":               "",
                "cluster":            row["cluster"],
                "namespace":          row["namespace"],
                "resource_type":      row["resource_type"],
                "resource_name":      row["resource_name"],
                "ownership_source":   row["ownership_source"],
                "argocd_app":         row.get("argocd_app", ""),
                "tfc_module":         row.get("tfc_module", ""),
                "argocd_source_path": row.get("argocd_source_path", ""),
            })

with open(sys.argv[2], "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=HEADER)
    w.writeheader()
    w.writerows(rows)

by_cluster = {}
for r in rows:
    by_cluster.setdefault(r["cluster"], {})
    s = r["ownership_source"]
    by_cluster[r["cluster"]][s] = by_cluster[r["cluster"]].get(s, 0) + 1

print(f"  Unlabeled resources: {len(rows)}")
for cluster, sources in sorted(by_cluster.items()):
    print(f"  {cluster}:")
    for src, n in sorted(sources.items()):
        print(f"    {src}: {n}")
print(f"\n  Output: {sys.argv[2]}")
print("\n  Fill in the 'team' column, then run:")
print("  ./label.sh --all --apply")
PYEOF

    else
        source "$ENV_FILE"
        INVENTORY_CSV="$PROJECT_DIR/output/$ENV-$REGION/inventory.csv"
        NEEDS_TEAM_CSV="$PROJECT_DIR/output/$ENV-$REGION/needs-team.csv"

        [[ -f "$INVENTORY_CSV" ]] || {
            echo "Error: $INVENTORY_CSV not found — run inventory.sh first" >&2
            exit 1
        }

        echo "=== Label Report: $ENV-$REGION ==="
        echo "  Inventory: $INVENTORY_CSV"
        echo ""

        python3 - "$INVENTORY_CSV" "$NEEDS_TEAM_CSV" <<'PYEOF'
import csv, sys

HEADER = ["team", "cluster", "namespace", "resource_type", "resource_name",
          "ownership_source", "argocd_app", "tfc_module", "argocd_source_path"]

rows = []
with open(sys.argv[1]) as f:
    for row in csv.DictReader(f):
        if row.get("team_label"):
            continue
        rows.append({
            "team":               "",
            "cluster":            row["cluster"],
            "namespace":          row["namespace"],
            "resource_type":      row["resource_type"],
            "resource_name":      row["resource_name"],
            "ownership_source":   row["ownership_source"],
            "argocd_app":         row.get("argocd_app", ""),
            "tfc_module":         row.get("tfc_module", ""),
            "argocd_source_path": row.get("argocd_source_path", ""),
        })

with open(sys.argv[2], "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=HEADER)
    w.writeheader()
    w.writerows(rows)

by_source = {}
for r in rows:
    s = r["ownership_source"]
    by_source[s] = by_source.get(s, 0) + 1

print(f"  Unlabeled resources: {len(rows)}")
for src, n in sorted(by_source.items()):
    print(f"    {src}: {n}")
print(f"  Output: {sys.argv[2]}")
print()
print("  Fill in the 'team' column, then run:")
print(f"  ./label.sh {sys.argv[1]} --apply {sys.argv[2]}")
PYEOF
    fi

    exit 0
fi

# ── Phase 2: Apply ────────────────────────────────────────────────────────────
[[ -f "$APPLY_CSV" ]] || { echo "Error: apply CSV not found: $APPLY_CSV" >&2; exit 1; }
[[ -n "${BB_API_TOKEN:-}" ]] || { echo "Error: BB_API_TOKEN not set — run: source scripts/creds.sh" >&2; exit 1; }

WORKSPACE="$(cd "$PROJECT_DIR/.." && pwd)"
DEPLOY_CONFIGS="$WORKSPACE/cd-deploy-configs"
TF_REPO="$WORKSPACE/eks_infrastructure"

[[ -d "$DEPLOY_CONFIGS" ]] || { echo "Error: cd-deploy-configs not found at $DEPLOY_CONFIGS" >&2; exit 1; }
[[ -d "$TF_REPO" ]] || { echo "Error: eks_infrastructure not found at $TF_REPO" >&2; exit 1; }

# Pull cd-deploy-configs so the already-labeled check reads current state, not a stale local copy.
echo "Pulling cd-deploy-configs..."
git -C "$DEPLOY_CONFIGS" pull --ff-only 2>&1 | sed 's/^/  /' || {
    echo "  Warning: git pull failed — already-labeled check may read stale files" >&2
}

# ── apply_one_cluster: run apply_labels.py + open PRs for a single cluster ───
# Args: ENV REGION KUBE_CONTEXT DEPLOY_CONFIGS_BRANCH CLUSTER_CSV
apply_one_cluster() {
    local env="$1" region="$2" cluster="$3" deploy_branch="$4" cluster_csv="$5"

    # Skip if no team values filled in for this cluster
    local filled
    filled=$(python3 -c "
import csv, sys
count = sum(1 for r in csv.DictReader(open(sys.argv[1])) if r.get('team','').strip())
print(count)
" "$cluster_csv")
    if [[ "$filled" -eq 0 ]]; then
        echo "  Skipping $env-$region: no team values filled in"
        return 0
    fi

    echo "=== Label Apply: $env-$region ==="
    echo "  Input CSV: $cluster_csv ($filled rows with team)"
    echo ""

    local tmp_dir
    tmp_dir=$(mktemp -d /tmp/label-apply.XXXXXX)
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp_dir'" RETURN

    local branch="eks-team-labels-$env-$region-$(date +%Y%m%d)${TAG:+-$TAG}"

    local py_extra_args=()
    [[ -n "$TEAMS" ]] && py_extra_args+=(--teams "$TEAMS")
    [[ "$LIMIT" -gt 0 ]] && py_extra_args+=(--limit "$LIMIT")

    local summary
    summary=$(python3 "$LIB_DIR/apply_labels.py" \
        --apply-csv "$cluster_csv" \
        --deploy-configs "$DEPLOY_CONFIGS" \
        --tf-repo "$TF_REPO" \
        --tmp-dir "$tmp_dir" \
        --env "$env" \
        --region "$region" \
        --cluster "$cluster" \
        "${py_extra_args[@]}")

    local kustomize_count tf_sa_count manual_count has_kustomize has_terraform
    kustomize_count=$(echo "$summary" | python3 -c "import json,sys; print(json.load(sys.stdin)['kustomize_count'])")
    tf_sa_count=$(echo "$summary"     | python3 -c "import json,sys; print(json.load(sys.stdin)['terraform_sa_count'])")
    manual_count=$(echo "$summary"    | python3 -c "import json,sys; print(json.load(sys.stdin)['manual_review_count'])")
    has_kustomize=$(echo "$summary"   | python3 -c "import json,sys; print(json.load(sys.stdin)['has_kustomize'])")
    has_terraform=$(echo "$summary"   | python3 -c "import json,sys; print(json.load(sys.stdin)['has_terraform'])")

    echo "  ArgoCD apps labeled:  $kustomize_count"
    echo "  Terraform SA changes: $tf_sa_count"
    echo "  Manual review:        $manual_count"
    echo ""

    if [[ "$has_kustomize" == "True" ]]; then
        echo "Opening PR to cd-deploy-configs..."
        mapfile -d '' patch_files < <(find "$tmp_dir/kustomize" -name "*.yaml" -print0 2>/dev/null | sort -z)
        if [[ ${#patch_files[@]} -gt 0 ]]; then
            local pr_body_file
            pr_body_file=$(mktemp)
            cat > "$pr_body_file" <<EOF
Add team labels to $kustomize_count ArgoCD app overlays in $env-$region.

Added \`team\` label directly to each app's \`$env-$region/kustomization.yaml\` using
a \`labels:\` entry with \`includeSelectors: false\` so existing Deployment selectors
are not affected.
EOF
            local commit_args=()
            for patch_file in "${patch_files[@]}"; do
                commit_args+=("${patch_file#"$tmp_dir/kustomize/"}:$patch_file")
            done
            local kustomize_pr
            kustomize_pr=$(BB_REPO_SLUG="cd-deploy-configs" BB_TARGET_BRANCH="$deploy_branch" \
                "$LIB_DIR/bitbucket-pr.sh" \
                "$branch" \
                "[${env}-${region}] Add team labels ($kustomize_count ArgoCD apps)" \
                "$pr_body_file" \
                "${commit_args[@]}")
            rm -f "$pr_body_file"
            echo "  cd-deploy-configs PR: $kustomize_pr"
        fi
    fi

    if [[ "$has_terraform" == "True" ]]; then
        echo ""
        echo "Opening PR to eks_infrastructure..."
        mapfile -d '' tf_files < <(find "$tmp_dir/terraform" -type f ! -name "pr-body.md" -print0 2>/dev/null | sort -z)
        if [[ ${#tf_files[@]} -gt 0 ]]; then
            local commit_args=()
            for tf_file in "${tf_files[@]}"; do
                commit_args+=("${tf_file#"$tmp_dir/terraform/"}:$tf_file")
            done
            local tf_pr
            tf_pr=$(BB_REPO_SLUG="${TF_REPO_SLUG:-eks-infrastructure}" \
                "$LIB_DIR/bitbucket-pr.sh" \
                "$branch" \
                "[${env}-${region}] Add team labels to Terraform-managed K8s resources" \
                "$tmp_dir/terraform/pr-body.md" \
                "${commit_args[@]}")
            echo "  eks_infrastructure PR: $tf_pr"
        fi
    fi

    echo ""
    echo "=== Done: $env-$region ==="
    [[ "$manual_count" -gt 0 ]] && echo "  Note: $manual_count resources require manual edits (see PR description)"
    echo ""
}

# ── Single cluster ─────────────────────────────────────────────────────────────
if ! $ALL_MODE; then
    source "$ENV_FILE"
    if [[ "$ENV" == "prod" || "$ENV" == "mgmt" ]]; then
        DEPLOY_CONFIGS_BRANCH="prod"
    else
        DEPLOY_CONFIGS_BRANCH="master"
    fi
    apply_one_cluster "$ENV" "$REGION" "$KUBE_CONTEXT" "$DEPLOY_CONFIGS_BRANCH" "$APPLY_CSV"
    exit 0
fi

# ── All clusters ───────────────────────────────────────────────────────────────
echo "=== Label Apply: All Clusters ==="
echo "  Input CSV: $APPLY_CSV"
echo ""

failed=()
for env_file in "$PROJECT_DIR"/config/*.env; do
    [[ -f "$env_file" ]] || continue

    # Source into subshell vars to avoid polluting the outer env between iterations
    env_vars=$(bash -c "source '$env_file'; echo \"ENV=\$ENV\"; echo \"REGION=\$REGION\"; echo \"KUBE_CONTEXT=\$KUBE_CONTEXT\"")
    eval "$env_vars"

    # --clusters filter: skip envs not in the list (matches env-region, e.g. dev-ric1)
    if [[ -n "$CLUSTERS" ]]; then
        match=false
        IFS=',' read -ra cluster_list <<< "$CLUSTERS"
        for c in "${cluster_list[@]}"; do
            [[ "$c" == "$ENV-$REGION" ]] && match=true && break
        done
        $match || continue
    fi

    # Filter merged CSV to this cluster
    cluster_csv=$(mktemp /tmp/label-cluster.XXXXXX.csv)
    python3 - "$APPLY_CSV" "$KUBE_CONTEXT" "$cluster_csv" <<'PYEOF'
import csv, sys
src, cluster, dst = sys.argv[1], sys.argv[2], sys.argv[3]
with open(src) as f:
    reader = csv.DictReader(f)
    rows = [r for r in reader if r["cluster"] == cluster]
with open(dst, "w", newline="") as f:
    if rows:
        w = csv.DictWriter(f, fieldnames=reader.fieldnames)
        w.writeheader()
        w.writerows(rows)
    else:
        f.write("")
PYEOF

    if [[ "$ENV" == "prod" || "$ENV" == "mgmt" ]]; then
        DEPLOY_CONFIGS_BRANCH="prod"
    else
        DEPLOY_CONFIGS_BRANCH="master"
    fi

    # Run in subshell with explicit set -e so errors inside the function are not
    # suppressed by the conditional context (bash disables set -e for functions
    # called via if/||/!/&&).
    ec=0
    (set -eo pipefail; apply_one_cluster "$ENV" "$REGION" "$KUBE_CONTEXT" "$DEPLOY_CONFIGS_BRANCH" "$cluster_csv") || ec=$?
    [[ $ec -eq 0 ]] || failed+=("$ENV-$REGION")
    rm -f "$cluster_csv"
done

if [[ ${#failed[@]} -gt 0 ]]; then
    echo "Failed clusters:"
    for f in "${failed[@]}"; do echo "  $f"; done
    exit 1
fi
