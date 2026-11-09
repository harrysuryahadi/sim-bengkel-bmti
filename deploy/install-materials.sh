#!/usr/bin/env bash
set -Eeuo pipefail

app_dir=/opt/ruang-praktik/SIM_Bengkel_SMK_v2
release_commit=${1:-}
if [[ ! "$release_commit" =~ ^[0-9a-f]{40}$ ]]; then
  echo 'Masukkan SHA commit paket sebagai argumen pertama.' >&2
  exit 1
fi
[[ $(id -u) == 0 ]] || { echo 'Jalankan sebagai root.' >&2; exit 1; }
[[ -f "$app_dir/server/index.mjs" && -f "$app_dir/web/core.js" && -f "$app_dir/web/app.js" ]]
systemctl is-active --quiet sim-bengkel
stage_dir=$(mktemp -d /root/sim-bengkel-materials.XXXXXXXX)
backup_dir="$stage_dir/backup"
mkdir "$backup_dir"
base_url="https://raw.githubusercontent.com/harrysuryahadi/sim-bengkel-bmti/$release_commit"
for filename in core.js app.js; do
  curl --fail --silent --show-error --location --max-time 60 "$base_url/$filename" -o "$stage_dir/$filename"
  node --input-type=module --check < "$stage_dir/$filename"
done
(cd "$stage_dir" && sha256sum --check <<'HASHES'
89a1d41ccbaa41fdc91369ab1f4b847990d5e0cf33c7b387015e3f0d0ab0fe8d  core.js
2f182f5ee6faddf7315bd29b4700e96e303210c3a8c4ad8cb70e4700fc44efb2  app.js
HASHES
)
cp -p "$app_dir/web/core.js" "$backup_dir/core.js"
cp -p "$app_dir/web/app.js" "$backup_dir/app.js"
rollback() {
  result=$?
  trap - ERR
  echo 'Pemasangan gagal. Memulihkan berkas sebelumnya.' >&2
  systemctl stop sim-bengkel || true
  cp -p "$backup_dir/core.js" "$app_dir/web/core.js"
  cp -p "$backup_dir/app.js" "$app_dir/web/app.js"
  systemctl start sim-bengkel || true
  echo "Cadangan berkas tersimpan di $backup_dir" >&2
  exit "$result"
}
trap rollback ERR
systemctl stop sim-bengkel
install -o root -g sim-bengkel -m 640 "$stage_dir/core.js" "$app_dir/web/core.js"
install -o root -g sim-bengkel -m 640 "$stage_dir/app.js" "$app_dir/web/app.js"
(cd "$app_dir" && npm test)
systemctl start sim-bengkel
healthy=false
for attempt in 1 2 3 4 5; do
  if curl --fail --silent --show-error --max-time 5 http://127.0.0.1:8080/api/health > "$stage_dir/health.json"; then
    healthy=true
    break
  fi
  sleep 1
done
[[ "$healthy" == true ]]
node -e 'const fs=require("node:fs");if(JSON.parse(fs.readFileSync(process.argv[1],"utf8")).ok!==true)process.exit(1)' "$stage_dir/health.json"
systemctl is-active --quiet sim-bengkel
trap - ERR
cat "$stage_dir/health.json"
echo
sha256sum "$app_dir/web/core.js" "$app_dir/web/app.js"
echo "Backend bahan berhasil diperbarui. Cadangan berkas: $backup_dir"
echo 'Lanjutkan pembaruan frontend GitHub Pages setelah hasil ini dikonfirmasi.'
