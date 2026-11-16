OUT=output/all/inventory.csv
FILES=(
    output/prod-pdx1/inventory.csv
)

head -1 "${FILES[0]}" > "$OUT"
for f in "${FILES[@]}"; do
    tail -n +2 "$f"
done >> "$OUT"

	
