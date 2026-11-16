#!/usr/bin/env bash
# Bitbucket Cloud API wrapper — create branch, commit files, open PR.
#
# Usage:
#   bitbucket-pr.sh <branch> <pr_title> <pr_body_file> <repo_path:local_file>...
#
# Required env:
#   BB_API_TOKEN   — Bitbucket personal access token (from scripts/creds.sh)
#
# Optional env:
#   BB_WORKSPACE   — Bitbucket workspace  (default: admarketplace)
#   BB_REPO_SLUG   — Bitbucket repo slug  (default: cd-deploy-configs)
#
# Stdout: PR URL

set -euo pipefail

BB_BASE="https://api.bitbucket.org/2.0"
BB_WORKSPACE="${BB_WORKSPACE:-admarketplace}"
BB_REPO_SLUG="${BB_REPO_SLUG:-cd-deploy-configs}"
# BB_TARGET_BRANCH overrides the repo's default mainbranch as PR destination.
# Used by label.sh to route cd-deploy-configs PRs to master (npe) vs prod.
BB_TARGET_BRANCH="${BB_TARGET_BRANCH:-}"
REPO_URL="$BB_BASE/repositories/$BB_WORKSPACE/$BB_REPO_SLUG"

[[ -n "${BB_API_TOKEN:-}" ]] || { echo "Error: BB_API_TOKEN not set — run: source scripts/creds.sh" >&2; exit 1; }
[[ $# -ge 4 ]] || {
    echo "Usage: bitbucket-pr.sh <branch> <title> <body_file> <repo_path:local_file>..." >&2
    exit 1
}

BRANCH="$1"
TITLE="$2"
BODY_FILE="$3"
shift 3

[[ -f "$BODY_FILE" ]] || { echo "Error: PR body file not found: $BODY_FILE" >&2; exit 1; }

# ── Helper: curl with auth, output to stdout, exit on HTTP error ─────────────
bb_get() {
    local url="$1"
    local response
    response=$(curl -sf -H "Authorization: Bearer $BB_API_TOKEN" "$url") || {
        echo "Error: GET $url failed" >&2; exit 1
    }
    echo "$response"
}

bb_post() {
    local url="$1"; shift
    local tmp_body tmp_status
    tmp_body=$(mktemp); tmp_status=$(mktemp)
    trap "rm -f '$tmp_body' '$tmp_status'" RETURN

    curl -s -o "$tmp_body" -w "%{http_code}" \
        -H "Authorization: Bearer $BB_API_TOKEN" \
        "$@" "$url" > "$tmp_status"

    local status
    status=$(cat "$tmp_status")
    if [[ "$status" != "200" && "$status" != "201" ]]; then
        echo "Error: POST $url returned HTTP $status" >&2
        cat "$tmp_body" >&2
        exit 1
    fi
    cat "$tmp_body"
}

# ── Resolve target branch and HEAD hash ──────────────────────────────────────
if [[ -n "$BB_TARGET_BRANCH" ]]; then
    default_branch="$BB_TARGET_BRANCH"
    echo "  [bb] Target branch (override): $default_branch" >&2
else
    echo "  [bb] Querying default branch..." >&2
    repo_json=$(bb_get "$REPO_URL")
    default_branch=$(echo "$repo_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['mainbranch']['name'])")
    echo "  [bb] Default branch: $default_branch" >&2
fi

branch_enc=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$default_branch")
branch_json=$(bb_get "$REPO_URL/refs/branches/$branch_enc")
tip_hash=$(echo "$branch_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['target']['hash'])")

echo "  [bb] @ ${tip_hash:0:8}" >&2

# ── Create branch ─────────────────────────────────────────────────────────────
echo "  [bb] Creating branch: $BRANCH" >&2
branch_payload=$(python3 -c "
import json, sys
print(json.dumps({'name': sys.argv[1], 'target': {'hash': sys.argv[2]}}))
" "$BRANCH" "$tip_hash")

tmp_body=$(mktemp); tmp_status=$(mktemp)
curl -s -o "$tmp_body" -w "%{http_code}" \
    -X POST \
    -H "Authorization: Bearer $BB_API_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$branch_payload" \
    "$REPO_URL/refs/branches" > "$tmp_status"

http_status=$(cat "$tmp_status")
case "$http_status" in
    200|201) echo "  [bb] Branch created" >&2 ;;
    400)
        err=$(cat "$tmp_body")
        if echo "$err" | grep -qi "already exists"; then
            echo "Error: branch '$BRANCH' already exists — delete it or use a different name" >&2
        else
            echo "Error: branch creation failed (HTTP $http_status): $err" >&2
        fi
        rm -f "$tmp_body" "$tmp_status"
        exit 1
        ;;
    *)
        echo "Error: branch creation failed (HTTP $http_status)" >&2
        cat "$tmp_body" >&2
        rm -f "$tmp_body" "$tmp_status"
        exit 1
        ;;
esac
rm -f "$tmp_body" "$tmp_status"

# ── Commit files ──────────────────────────────────────────────────────────────
echo "  [bb] Committing $# file(s) to $BRANCH..." >&2

commit_args=(
    -X POST
    -F "branch=$BRANCH"
    -F "message=migrate(eks): Ingress -> HTTPRoute for $BRANCH"
)
file_count=0
for spec in "$@"; do
    repo_path="${spec%%:*}"
    local_file="${spec#*:}"
    [[ -f "$local_file" ]] || { echo "Error: local file not found: $local_file" >&2; exit 1; }
    commit_args+=(-F "$repo_path=<$local_file")
    echo "    $repo_path" >&2
    (( file_count++ )) || true
done

tmp_body=$(mktemp); tmp_status=$(mktemp)
curl -s -o "$tmp_body" -w "%{http_code}" \
    "${commit_args[@]}" \
    -H "Authorization: Bearer $BB_API_TOKEN" \
    "$REPO_URL/src" > "$tmp_status"

http_status=$(cat "$tmp_status")
if [[ "$http_status" != "200" && "$http_status" != "201" ]]; then
    echo "Error: commit failed (HTTP $http_status)" >&2
    cat "$tmp_body" >&2
    rm -f "$tmp_body" "$tmp_status"
    exit 1
fi
rm -f "$tmp_body" "$tmp_status"
echo "  [bb] $file_count file(s) committed" >&2

# ── Create PR ─────────────────────────────────────────────────────────────────
echo "  [bb] Creating PR: $TITLE" >&2
pr_payload=$(python3 - "$TITLE" "$BRANCH" "$default_branch" "$BODY_FILE" <<'PYEOF'
import json, sys
title, branch, dest, body_file = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(body_file) as f:
    desc = f.read()
print(json.dumps({
    'title': title,
    'description': desc,
    'source': {'branch': {'name': branch}},
    'destination': {'branch': {'name': dest}},
    'close_source_branch': True,
}))
PYEOF
)

pr_response=$(bb_post "$REPO_URL/pullrequests" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$pr_payload")

pr_url=$(echo "$pr_response" | python3 -c "import json,sys; print(json.load(sys.stdin)['links']['html']['href'])")
echo "  [bb] PR created: $pr_url" >&2
echo "$pr_url"
