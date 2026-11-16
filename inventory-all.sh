#!/usr/bin/env bash
# Run inventory.sh across all cluster configs, then merge into output/all/inventory.csv
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== EKS Inventory: All Clusters ==="
echo ""

failed=()
for env_file in "$SCRIPT_DIR"/config/*.env; do
    [[ -f "$env_file" ]] || continue
    echo "──────────────────────────────────────────"
    if ! "$SCRIPT_DIR/scripts/inventory.sh" "$env_file"; then
        failed+=("$env_file")
        echo "  ERROR: inventory failed for $env_file" >&2
    fi
    echo ""
done

# Merge all per-cluster CSVs into output/all/inventory.csv
OUTPUT_ALL="$SCRIPT_DIR/output/all/inventory.csv"
mkdir -p "$SCRIPT_DIR/output/all"

header_written=0
> "$OUTPUT_ALL"
for csv_file in "$SCRIPT_DIR"/output/*/inventory.csv; do
    [[ -f "$csv_file" ]] || continue
    [[ "$csv_file" == "$OUTPUT_ALL" ]] && continue
    if [[ $header_written -eq 0 ]]; then
        cat "$csv_file" >> "$OUTPUT_ALL"
        header_written=1
    else
        tail -n +2 "$csv_file" >> "$OUTPUT_ALL"
    fi
done

TOTAL=$(( $(wc -l < "$OUTPUT_ALL") - 1 ))
echo "=== All Clusters Complete ==="
echo "  Merged: $TOTAL rows"
echo "  Output: $OUTPUT_ALL"

if [[ ${#failed[@]} -gt 0 ]]; then
    echo ""
    echo "  Failed configs:"
    for f in "${failed[@]}"; do echo "    $f"; done
    exit 1
fi
