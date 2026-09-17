#!/usr/bin/env bash
#
# Siembra y audita las Variables/Secrets de un GitHub Environment a partir de un
# manifiesto versionado ($ENV_DIR/<env>.json). Crea el environment si no existe.
#
#   setup-github-env.sh staging              # dry-run: solo muestra el diff
#   setup-github-env.sh staging --apply      # escribe las que difieren
#   setup-github-env.sh prod --secrets-file infra/environments/prod.secrets.env --apply
#
# Se corre desde la raíz del repo consumidor. Env:
#   REPO_ROOT  raíz del repo (default: $PWD) — de ahí salen los workflows para el drift
#   ENV_DIR    carpeta de manifiestos (default: $REPO_ROOT/infra/environments)
#
# Manifiesto: githubEnvironment, repo, aws{region,stack}, variables{}, optionalVariables[],
# secrets[], y opcionalmente requiredReviewer: "owner" (required reviewer en ese env).
# Valores dinámicos: "@stack:<Output>" (CloudFormation), "@acm:<dominio>" (cert emitido en la
# región del manifiesto) y "@acm-<región>:<dominio>" (cert en otra región, p. ej. us-east-1).
#
# Prereqs: gh (autenticado como ADMIN del repo: environments/variables son solo-admin
# y GitHub responde 404, no 403, cuando falta el permiso), aws CLI, jq.
#
# Salida: 0 = todo alineado · 2 = hay diferencias pendientes · 1 = error.
#
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$PWD}"
ENV_DIR="${ENV_DIR:-$REPO_ROOT/infra/environments}"

APPLY=false
ENV_KEY=""
REPO_OVERRIDE=""
SECRETS_FILE=""

usage() {
  sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --apply)        APPLY=true; shift ;;
    --repo)         REPO_OVERRIDE="${2:-}"; shift 2 ;;
    --secrets-file) SECRETS_FILE="${2:-}"; shift 2 ;;
    -h|--help)      usage 0 ;;
    -*)             echo "Opción desconocida: $1" >&2; usage 1 ;;
    *)              ENV_KEY="$1"; shift ;;
  esac
done

[ -n "$ENV_KEY" ] || { echo "Falta el entorno (ej. staging | prod)." >&2; usage 1; }

MANIFEST="$ENV_DIR/$ENV_KEY.json"
[ -f "$MANIFEST" ] || {
  echo "No existe $MANIFEST" >&2
  echo "Entornos disponibles: $(ls "$ENV_DIR"/*.json 2>/dev/null | xargs -n1 basename | sed 's/\.json$//' | tr '\n' ' ')" >&2
  exit 1
}

for bin in gh aws jq; do
  command -v "$bin" >/dev/null 2>&1 || { echo "Falta '$bin' en el PATH." >&2; exit 1; }
done

GH_ENV=$(jq -r '.githubEnvironment' "$MANIFEST")
REPO=${REPO_OVERRIDE:-$(jq -r '.repo' "$MANIFEST")}
AWS_REGION_M=$(jq -r '.aws.region // ""' "$MANIFEST")
AWS_STACK=$(jq -r '.aws.stack // ""' "$MANIFEST")
REVIEWER=$(jq -r '.requiredReviewer // ""' "$MANIFEST")

admin=$(gh api "repos/$REPO" --jq '.permissions.admin' 2>/dev/null || echo false)
if [ "$admin" != "true" ]; then
  cuenta=$(gh api user --jq '.login' 2>/dev/null || echo "?")
  echo "ERROR: la cuenta '$cuenta' no es admin de $REPO (environments y variables son solo-admin)." >&2
  exit 1
fi

echo "Repo:        $REPO"
echo "Environment: $GH_ENV   (manifiesto: $MANIFEST)"
echo "Modo:        $([ "$APPLY" = true ] && echo 'APLICAR' || echo 'dry-run (usá --apply para escribir)')"
echo

# ---------------------------------------------------------------------------
# Resolvers: @stack:<Output> y @acm:<dominio>. Cualquier otra cosa es literal.
# ---------------------------------------------------------------------------
STACK_OUTPUTS=""   # cache del describe-stacks (se pide una sola vez)

resolve_stack_output() {
  local key="$1"
  if [ -z "$STACK_OUTPUTS" ]; then
    [ -n "$AWS_STACK" ] || return 1
    STACK_OUTPUTS=$(aws cloudformation describe-stacks \
      --stack-name "$AWS_STACK" --region "$AWS_REGION_M" \
      --query 'Stacks[0].Outputs' --output json 2>/dev/null) || return 1
  fi
  local v
  v=$(printf '%s' "$STACK_OUTPUTS" | jq -r --arg k "$key" '(.[]? | select(.OutputKey==$k) | .OutputValue) // ""')
  [ -n "$v" ] || return 1
  printf '%s' "$v"
}

resolve_acm() {
  local domain="$1" region="${2:-$AWS_REGION_M}" arns count
  arns=$(aws acm list-certificates --certificate-statuses ISSUED --region "$region" \
    --query "CertificateSummaryList[?DomainName=='$domain'].CertificateArn" --output text 2>/dev/null) || return 1
  count=$(printf '%s' "$arns" | tr '\t' '\n' | grep -c . || true)
  [ "$count" = "1" ] || return 1
  printf '%s' "$arns"
}

# ---------------------------------------------------------------------------
# Estado deseado (manifiesto + resolvers) vs. estado actual (gh)
# ---------------------------------------------------------------------------
desired='{}'
pending=''

while IFS=$'\t' read -r name raw; do
  value=""
  case "$raw" in
    @stack:*) value=$(resolve_stack_output "${raw#@stack:}") || value="" ;;
    @acm:*)   value=$(resolve_acm "${raw#@acm:}")            || value="" ;;
    # @acm-<región>:<dominio> — cert en otra región (CloudFront solo lee los de us-east-1)
    @acm-*:*) r="${raw#@acm-}"; value=$(resolve_acm "${r#*:}" "${r%%:*}") || value="" ;;
    *)        value="$raw" ;;
  esac
  if [ -z "$value" ]; then
    pending="$pending $name"
    continue
  fi
  desired=$(jq -c --arg n "$name" --arg v "$value" '. + {($n): $v}' <<<"$desired")
done < <(jq -r '.variables | to_entries[] | select(.key | startswith("//") | not) | [.key, (.value|tostring)] | @tsv' "$MANIFEST")

current=$(gh variable list --repo "$REPO" --env "$GH_ENV" --json name,value 2>/dev/null \
  | jq -c 'map({(.name): .value}) | add // {}') || {
  echo "No se pudo leer las variables de $REPO / $GH_ENV (¿permisos de admin en el repo?)." >&2
  exit 1
}

rows=$(jq -r --argjson cur "$current" '
  to_entries[]
  | .key as $n | .value as $want
  | ($cur[$n] // null) as $have
  | [ $n,
      ($have // "—"),
      $want,
      (if $have == null then "crear" elif $have == $want then "ok" else "actualizar" end) ]
  | @tsv' <<<"$desired")

printf '%-32s %-12s %s\n' "VARIABLE" "ACCION" "VALOR"
printf '%-32s %-12s %s\n' "--------" "------" "-----"
changes=0
while IFS=$'\t' read -r name have want action; do
  [ -n "$name" ] || continue
  case "$action" in
    ok)         printf '%-32s %-12s %s\n' "$name" "ok" "$want" ;;
    crear)      printf '%-32s %-12s %s\n' "$name" "CREAR" "$want"; changes=$((changes+1)) ;;
    actualizar) printf '%-32s %-12s %s\n' "$name" "ACTUALIZAR" "$have  ->  $want"; changes=$((changes+1)) ;;
  esac
done <<<"$rows"

for p in $pending; do
  printf '%-32s %-12s %s\n' "$p" "pendiente" "no se pudo resolver (¿el stack/cert todavía no existe?)"
done

# Variables que existen en GitHub pero el manifiesto no declara: se informan, no se borran.
# Las que quedaron "pendiente" (resolver sin resultado) no son huérfanas: sí están declaradas.
pending_json=$(printf '%s\n' $pending | jq -R . | jq -sc 'map(select(length>0))')
huerfanas=$(jq -r --argjson want "$desired" --argjson pend "$pending_json" \
  'keys[] | select($want[.] == null) | select(IN($pend[]) | not)' <<<"$current")
if [ -n "$huerfanas" ]; then
  echo
  echo "En GitHub pero fuera del manifiesto (no se tocan):"
  for h in $huerfanas; do echo "  - $h"; done
fi

# ---------------------------------------------------------------------------
# Secrets: gh nunca devuelve el valor, solo se puede saber si existen.
# ---------------------------------------------------------------------------
echo
echo "SECRETS"
secret_names=$(gh secret list --repo "$REPO" --env "$GH_ENV" --json name 2>/dev/null | jq -r '.[].name' || true)
secret_changes=0
while read -r s; do
  [ -n "$s" ] || continue
  file_value=""
  if [ -n "$SECRETS_FILE" ] && [ -f "$SECRETS_FILE" ]; then
    file_value=$(grep -E "^${s}=" "$SECRETS_FILE" | head -1 | cut -d= -f2- || true)
  fi
  if printf '%s\n' "$secret_names" | grep -qx "$s"; then
    if [ -n "$file_value" ]; then
      printf '  %-30s %s\n' "$s" "existe — se sobrescribe desde --secrets-file"
      secret_changes=$((secret_changes+1))
    else
      printf '  %-30s %s\n' "$s" "ok (existe)"
    fi
  elif [ -n "$file_value" ]; then
    printf '  %-30s %s\n' "$s" "FALTA — se crea desde --secrets-file"
    secret_changes=$((secret_changes+1))
  else
    printf '  %-30s %s\n' "$s" "FALTA — cargalo a mano o pasá --secrets-file"
    secret_changes=$((secret_changes+1))
  fi
done <<<"$(jq -r '.secrets[]?' "$MANIFEST")"

# ---------------------------------------------------------------------------
# Drift: lo que los workflows usan vs. lo que el manifiesto declara
# ---------------------------------------------------------------------------
echo
echo "DRIFT vs. .github/workflows/"
usadas=$(grep -rhoE 'vars\.[A-Z0-9_]+' "$REPO_ROOT/.github/workflows/" 2>/dev/null | sed 's/^vars\.//' | sort -u)
declaradas=$(jq -r '.variables | keys[] | select(startswith("//") | not)' "$MANIFEST" | sort -u)
opcionales=$(jq -r '.optionalVariables[]? ' "$MANIFEST" | sort -u)
faltan=$(comm -23 <(printf '%s\n' "$usadas") <(printf '%s\n' "$declaradas" "$opcionales" | sort -u))
sobran=$(comm -13 <(printf '%s\n' "$usadas") <(printf '%s\n' "$declaradas"))
if [ -n "$faltan" ]; then
  echo "  Usadas por un workflow y NO declaradas acá (revisá si aplican a este entorno):"
  for f in $faltan; do echo "    - $f"; done
fi
if [ -n "$sobran" ]; then
  echo "  Declaradas acá y no usadas por ningún workflow:"
  for s in $sobran; do echo "    - $s"; done
fi
[ -n "$faltan$sobran" ] || echo "  sin drift"

# ---------------------------------------------------------------------------
# Aplicar
# ---------------------------------------------------------------------------
echo
if [ "$APPLY" != true ]; then
  if [ "$changes" -gt 0 ] || [ "$secret_changes" -gt 0 ]; then
    echo "Dry-run: $changes variable(s) y $secret_changes secret(s) pendientes. Volvé a correr con --apply."
    exit 2
  fi
  echo "Todo alineado. Nada que aplicar."
  exit 0
fi

# PUT es idempotente: crea el environment si no existe y no toca el que ya está.
gh api -X PUT "repos/$REPO/environments/$GH_ENV" --silent

while IFS=$'\t' read -r name have want action; do
  [ -n "$name" ] || continue
  [ "$action" = "ok" ] && continue
  echo "  gh variable set $name"
  gh variable set "$name" --repo "$REPO" --env "$GH_ENV" --body "$want"
done <<<"$rows"

if [ -n "$SECRETS_FILE" ] && [ -f "$SECRETS_FILE" ]; then
  while read -r s; do
    [ -n "$s" ] || continue
    file_value=$(grep -E "^${s}=" "$SECRETS_FILE" | head -1 | cut -d= -f2- || true)
    [ -n "$file_value" ] || continue
    echo "  gh secret set $s"
    printf '%s' "$file_value" | gh secret set "$s" --repo "$REPO" --env "$GH_ENV"
  done <<<"$(jq -r '.secrets[]?' "$MANIFEST")"
fi

# Required reviewer: lo que convierte "deploy a prod" en una acción aprobada por una
# persona. En repos privados de cuentas Free la API lo rechaza; se avisa y se sigue.
if [ "$REVIEWER" = "owner" ]; then
  owner_id=$(gh api "repos/$REPO" --jq '.owner.id')
  if gh api -X PUT "repos/$REPO/environments/$GH_ENV" \
       -F "reviewers[][type]=User" -F "reviewers[][id]=$owner_id" --silent 2>/dev/null; then
    echo "  required reviewer: owner"
  else
    echo "AVISO: no se pudo poner el required reviewer en $GH_ENV (plan Free). Configurarlo a mano en Settings → Environments." >&2
  fi
fi

echo
echo "Listo. Verificá con: gh variable list --repo $REPO --env $GH_ENV"
