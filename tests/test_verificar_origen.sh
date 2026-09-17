#!/usr/bin/env bash
# Tres casos sobre un repo temporal: commit en main con tag anterior contenido → OK;
# commit fuera de main → falla; tag nuevo que no contiene al anterior → falla.
set -euo pipefail
S="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/verificar-origen-deploy.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
git init -q --bare "$T/origin.git"
git -C "$T" clone -q "$T/origin.git" repo; R="$T/repo"
g() { git -C "$R" -c user.name=t -c user.email=t@t "$@"; }
g checkout -q -b main
g commit -q --allow-empty -m A; g tag v0.1.0; g push -q origin main --tags
g commit -q --allow-empty -m B; g tag v0.2.0; g push -q origin main --tags
(cd "$R" && GITHUB_REF_NAME=v0.2.0 bash "$S" >/dev/null) && echo "ok: main con tag anterior contenido"
g checkout -q -b feature v0.1.0; g commit -q --allow-empty -m C
if (cd "$R" && bash "$S" 2>/dev/null >/dev/null); then echo "FALLO: aceptó un commit fuera de main"; exit 1; fi
echo "ok: rechaza commit fuera de main"
g checkout -q main; g reset -q --hard v0.1.0; g commit -q --allow-empty -m E; g tag v0.3.0; g push -q -f origin main --tags
if (cd "$R" && GITHUB_REF_NAME=v0.3.0 bash "$S" 2>/dev/null >/dev/null); then echo "FALLO: aceptó un tag que no contiene al anterior"; exit 1; fi
echo "ok: rechaza deploy que pisaría v0.2.0"
