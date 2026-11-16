#!/usr/bin/env bash
# check-images.sh — verify container images for ArgoCD-managed Deployments are pullable.
#
# Reads output/all/inventory.csv, fetches current images from each cluster via kubectl,
# checks each unique image with `docker manifest inspect`, and reports failures.
#
# Usage:
#   ./scripts/check-images.sh [--days N]   # default: all ArgoCD deployments
#                                           # --days N: only those not synced in >N days
#
# Output:
#   output/all/image-check.csv   (image, cluster, namespace, deployment, argocd_app, days_since_sync, status)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

INVENTORY="$PROJECT_DIR/output/all/inventory.csv"
OUTPUT="$PROJECT_DIR/output/all/image-check.csv"
DAYS_FILTER="${2:-0}"  # 0 = all

if [[ "${1:-}" == "--days" ]]; then
    DAYS_FILTER="${2:-60}"
fi

[[ -f "$INVENTORY" ]] || { echo "Error: $INVENTORY not found — run inventory-all.sh first" >&2; exit 1; }

command -v docker &>/dev/null || { echo "Error: docker not found in PATH" >&2; exit 1; }

echo "=== Image Availability Check ==="
echo "  Inventory: $INVENTORY"
[[ "$DAYS_FILTER" -gt 0 ]] && echo "  Filter: not synced in >${DAYS_FILTER} days" || echo "  Filter: all ArgoCD Deployments"
echo ""

# Step 1: extract target deployments from inventory
TARGETS=$(python3 - "$INVENTORY" "$DAYS_FILTER" <<'PYEOF'
import csv, sys, json

inv, days_filter = sys.argv[1], int(sys.argv[2])
targets = []
with open(inv) as f:
    for row in csv.DictReader(f):
        if row["ownership_source"] != "argocd" or row["resource_type"] != "Deployment":
            continue
        days = row.get("argocd_days_since_sync", "") or "0"
        try:
            days = int(days)
        except ValueError:
            days = 0
        if days_filter > 0 and days <= days_filter:
            continue
        targets.append({
            "cluster":    row["cluster"],
            "namespace":  row["namespace"],
            "name":       row["resource_name"],
            "argocd_app": row.get("argocd_app", ""),
            "days":       days,
        })
print(json.dumps(targets))
PYEOF
)

TOTAL=$(echo "$TARGETS" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")
echo "  Deployments to check: $TOTAL"
echo ""

# Step 2: fetch images from each cluster via kubectl, check with docker manifest inspect
TMP=$(mktemp /tmp/image-check.XXXXXX.json)
trap "rm -f '$TMP'" EXIT
echo "$TARGETS" > "$TMP"

python3 - "$TMP" "$OUTPUT" <<'PYEOF'
import json, subprocess, sys, csv
from collections import defaultdict

targets = json.load(open(sys.argv[1]))
output_path = sys.argv[2]

# Group by cluster for batch kubectl calls
by_cluster = defaultdict(list)
for t in targets:
    by_cluster[t["cluster"]].append(t)

results = []
checked_images = {}  # image -> "ok" | "missing" | "error: ..."

for cluster, items in sorted(by_cluster.items()):
    print(f"  Fetching images from {cluster} ({len(items)} deployments)...", flush=True)

    # Build a single kubectl call per cluster: get all target deployments at once
    # Group by namespace for efficiency
    by_ns = defaultdict(list)
    for item in items:
        by_ns[item["namespace"]].append(item)

    deploy_images = {}  # (namespace, name) -> [images]
    for ns, ns_items in by_ns.items():
        names = [i["name"] for i in ns_items]
        try:
            out = subprocess.check_output(
                ["kubectl", "--context", cluster, "-n", ns,
                 "get", "deployments"] + names +
                ["-o", "jsonpath={range .items[*]}{.metadata.namespace}/{.metadata.name}{'\\t'}"
                 "{range .spec.template.spec.containers[*]}{.image}{' '}{end}{'\\n'}{end}"],
                stderr=subprocess.DEVNULL, text=True
            )
            for line in out.strip().splitlines():
                if not line.strip():
                    continue
                parts = line.split("\t")
                if len(parts) < 2:
                    continue
                key = tuple(parts[0].split("/", 1))  # (namespace, name)
                images = parts[1].strip().split()
                deploy_images[key] = images
        except subprocess.CalledProcessError:
            for item in ns_items:
                deploy_images[(ns, item["name"])] = ["kubectl-error"]

    for item in items:
        key = (item["namespace"], item["name"])
        images = deploy_images.get(key, ["not-found"])
        for image in images:
            if image in ("kubectl-error", "not-found"):
                status = image
            elif image in checked_images:
                status = checked_images[image]
            else:
                try:
                    subprocess.check_output(
                        ["docker", "manifest", "inspect", image],
                        stderr=subprocess.DEVNULL
                    )
                    status = "ok"
                except subprocess.CalledProcessError:
                    status = "missing"
                checked_images[image] = status
                indicator = "✓" if status == "ok" else "✗ MISSING"
                print(f"    {indicator}  {image}", flush=True)

            results.append({
                "image":         image,
                "cluster":       item["cluster"],
                "namespace":     item["namespace"],
                "deployment":    item["name"],
                "argocd_app":    item["argocd_app"],
                "days_since_sync": item["days"],
                "status":        status,
            })

HEADER = ["status", "image", "cluster", "namespace", "deployment", "argocd_app", "days_since_sync"]
with open(output_path, "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=HEADER)
    w.writeheader()
    # Sort: missing first, then by days_since_sync desc
    results.sort(key=lambda r: (r["status"] != "missing", -r["days_since_sync"]))
    w.writerows(results)

ok      = sum(1 for r in results if r["status"] == "ok")
missing = sum(1 for r in results if r["status"] == "missing")
errors  = sum(1 for r in results if r["status"] not in ("ok", "missing"))
print(f"\n  Images OK:      {ok}")
print(f"  Images MISSING: {missing}")
print(f"  Errors:         {errors}")
print(f"  Output: {output_path}")
PYEOF
