#!/usr/bin/env bash
# Frena un deploy a producción cuyo commit podría borrar código de prod.
#
#   1. El commit a desplegar tiene que estar en origin/<rama principal>. En auto-system,
#      v0.13.4 y v0.13.5 se tagearon sobre una rama sin mergear y el siguiente deploy
#      desde main borró lo que traían (incidente 2026-09-12).
#   2. El tag anterior tiene que estar contenido en el commit nuevo. Si no, el deploy
#      pisa algo que prod ya tenía (el chequeo que habría frenado v0.14.0).
#
# Requiere historial completo y tags: actions/checkout con fetch-depth: 0.
#
# Uso:  verificar-origen-deploy.sh [sha] [tag-actual]
#       (por defecto HEAD y GITHUB_REF_NAME)
# Env:  RAMA_PRINCIPAL=main   PATRON_TAG='v*.*.*'   REMOTO=origin
set -euo pipefail

RAMA="${RAMA_PRINCIPAL:-main}"
PATRON="${PATRON_TAG:-v*.*.*}"
REMOTO="${REMOTO:-origin}"

sha=$(git rev-parse "${1:-HEAD}^{commit}")
tag_actual="${2:-${GITHUB_REF_NAME:-}}"

git fetch --quiet --no-tags "$REMOTO" "+refs/heads/$RAMA:refs/remotes/$REMOTO/$RAMA" 2>/dev/null || true

if ! git merge-base --is-ancestor "$sha" "$REMOTO/$RAMA"; then
  echo "::error::El commit ${sha:0:7} no está en $RAMA. Producción solo se despliega desde commits mergeados a $RAMA."
  exit 1
fi

# Tag anterior = el inmediatamente inferior al que se despliega, no el más alto: así
# un rollback (re-desplegar v0.14.0 teniendo v0.14.1) compara contra v0.13.x y pasa.
# Sin tag (workflow_dispatch desde main) se compara contra el más alto.
tags=$(git tag --list "$PATRON" --sort=v:refname)
if printf '%s\n' "$tags" | grep -qxF "$tag_actual"; then
  tag_anterior=$(printf '%s\n' "$tags" | awk -v t="$tag_actual" '$0 == t { print p; exit } { p = $0 }')
else
  tag_anterior=$(printf '%s\n' "$tags" | tail -1)
fi
if [ -n "$tag_anterior" ] && ! git merge-base --is-ancestor "$tag_anterior" "$sha"; then
  echo "::error::El tag anterior $tag_anterior no está contenido en ${sha:0:7}: este deploy borraría de prod estos commits:"
  git log --oneline "$sha..$tag_anterior"
  exit 1
fi

echo "OK: ${sha:0:7} está en $RAMA y contiene ${tag_anterior:-(sin tag anterior)}."
