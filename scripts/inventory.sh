#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

ENV_FILE="${1:-$PROJECT_DIR/config/dev-ric1.env}"
[[ -f "$ENV_FILE" ]] || { echo "Error: env config not found: $ENV_FILE" >&2; exit 1; }
source "$ENV_FILE"

[[ -n "${TFC_TOKEN:-}" ]] || { echo "Error: TFC_TOKEN not set — run: source scripts/creds.sh" >&2; exit 1; }
[[ -n "${TFC_ORG:-}" ]]   || { echo "Error: TFC_ORG not set — run: source scripts/creds.sh" >&2; exit 1; }
[[ -n "${TFC_WORKSPACE:-}" ]] || { echo "Error: TFC_WORKSPACE not set in $ENV_FILE" >&2; exit 1; }
[[ -n "${TFC_MODULE:-}" ]] || { echo "Error: TFC_MODULE not set in $ENV_FILE" >&2; exit 1; }

OUTPUT_DIR="$PROJECT_DIR/output/$ENV-$REGION"
mkdir -p "$OUTPUT_DIR"
OUTPUT_FILE="$OUTPUT_DIR/inventory.csv"

ARGOCD_STATUS_FILE=$(mktemp /tmp/argocd-status.XXXXXX)
TFC_RESOURCES_FILE=$(mktemp /tmp/tfc-resources.XXXXXX)
trap "rm -f '$ARGOCD_STATUS_FILE' '$TFC_RESOURCES_FILE'" EXIT

echo "=== EKS Cluster Inventory ==="
echo "  Cluster: $KUBE_CONTEXT"
echo "  Env:     $ENV   Region: $REGION"
echo "  Output:  $OUTPUT_FILE"
echo ""

# Step 1: ArgoCD app statuses — filter to apps targeting THIS cluster only.
# npe-argocd and prod-argocd each serve multiple clusters; we match on
# destination.server (URL). The URL is looked up from ArgoCD cluster secrets
# by matching the secret's name field (cluster ARN) ending with /{KUBE_CONTEXT}.
CLUSTER_URL="${OLD_CLUSTER_URL:-}"
if [[ -z "$CLUSTER_URL" ]]; then
    CLUSTER_URL=$(kubectl --context "$ARGOCD_CONTEXT" -n "$ARGOCD_NAMESPACE" \
        get secrets -l argocd.argoproj.io/secret-type=cluster \
        -o json 2>/dev/null | \
        KUBE_CONTEXT="$KUBE_CONTEXT" python3 -c '
import json, sys, os, base64
ctx = os.environ["KUBE_CONTEXT"]
for secret in json.load(sys.stdin).get("items", []):
    d = secret.get("data", {})
    name_b64 = d.get("name", "")
    if not name_b64:
        continue
    name = base64.b64decode(name_b64).decode()
    if name == ctx or name.endswith("/" + ctx):
        server_b64 = d.get("server", "")
        if server_b64:
            print(base64.b64decode(server_b64).decode())
            break
' 2>/dev/null || true)
fi
echo "Fetching ArgoCD statuses ($ARGOCD_CONTEXT / $ARGOCD_NAMESPACE, destination: $KUBE_CONTEXT)..."
if kubectl --context "$ARGOCD_CONTEXT" -n "$ARGOCD_NAMESPACE" get applications \
    -o json 2>/dev/null | \
    ARGOCD_DEST_NAME="$KUBE_CONTEXT" \
    ARGOCD_DEST_URL="$CLUSTER_URL" \
    python3 -c '
import json, sys, os
ctx = os.environ["ARGOCD_DEST_NAME"]
url = os.environ.get("ARGOCD_DEST_URL", "")
for app in json.load(sys.stdin).get("items", []):
    dest = app.get("spec", {}).get("destination", {})
    if dest.get("name") != ctx and (not url or dest.get("server") != url):
        continue
    m = app.get("metadata", {})
    s = app.get("status", {})
    name       = m.get("name", "")
    sync       = s.get("sync", {}).get("status", "")
    health     = s.get("health", {}).get("status", "")
    last_sync  = s.get("operationState", {}).get("finishedAt", "")
    source_path = app.get("spec", {}).get("source", {}).get("path", "")
    print(name + "\t" + sync + "\t" + health + "\t" + last_sync + "\t" + source_path)
' > "$ARGOCD_STATUS_FILE"; then
    echo "  Apps for $KUBE_CONTEXT: $(wc -l < "$ARGOCD_STATUS_FILE" | tr -d ' ')"
else
    echo "  Warning: ArgoCD fetch failed — sync/health will be empty" >&2
    touch "$ARGOCD_STATUS_FILE"
fi

# Step 2: TFC state — extract K8s resources for this cluster module
echo ""
echo "Fetching Terraform state (workspace: $TFC_WORKSPACE, module: $TFC_MODULE)..."
if python3 "$LIB_DIR/tfc_client.py" \
    --org "$TFC_ORG" \
    --workspace "$TFC_WORKSPACE" \
    --module "$TFC_MODULE" \
    > "$TFC_RESOURCES_FILE"; then
    echo "  TFC resources: $(wc -l < "$TFC_RESOURCES_FILE" | tr -d ' ')"
else
    echo "  Warning: TFC state fetch failed — Terraform ownership will be empty" >&2
    touch "$TFC_RESOURCES_FILE"
fi

# Step 3: Fetch K8s resources and resolve ownership
echo ""
RESOURCE_TYPES="deployments,statefulsets,daemonsets,services,ingresses,cronjobs,horizontalpodautoscalers"

for crd in \
    "httproutes.gateway.networking.k8s.io:httproutes" \
    "cronworkflows.argoproj.io:cronworkflows" \
    "workflowtemplates.argoproj.io:workflowtemplates" \
    "externalsecrets.external-secrets.io:externalsecrets" \
    "eventbus.argoproj.io:eventbus" \
    "eventsources.argoproj.io:eventsources" \
    "sensors.argoproj.io:sensors" \
    "verticalpodautoscalers.autoscaling.k8s.io:verticalpodautoscalers"; do
    crd_name="${crd%%:*}"
    resource="${crd##*:}"
    if kubectl --context "$KUBE_CONTEXT" get crd "$crd_name" &>/dev/null 2>&1; then
        RESOURCE_TYPES="$RESOURCE_TYPES,$resource"
    fi
done

echo "Fetching cluster resources: $RESOURCE_TYPES"
echo "  Context: $KUBE_CONTEXT"

kubectl --context "$KUBE_CONTEXT" get "$RESOURCE_TYPES" \
    --all-namespaces -o json 2>/dev/null | \
    python3 "$LIB_DIR/resolve_ownership.py" \
        --argocd "$ARGOCD_STATUS_FILE" \
        --tfc "$TFC_RESOURCES_FILE" \
        --cluster "$KUBE_CONTEXT" \
        --env "$ENV" \
        --region "$REGION" \
    > "$OUTPUT_FILE"

ROWS=$(( $(wc -l < "$OUTPUT_FILE") - 1 ))
echo ""
echo "=== Complete ==="
echo "  Rows:   $ROWS"
echo "  Output: $OUTPUT_FILE"
