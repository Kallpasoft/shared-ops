#!/usr/bin/env bash
# =============================================================================
# Compara y aplica el rol OIDC de deploy de GitHub Actions: su política inline y,
# si se pasa --repo, su trust policy. Dry-run por defecto.
#
# Uso:
#   deploy-role.sh --rol <nombre> --policy-file <ruta.json> [opciones]
#
# Opciones:
#   --rol <nombre>            nombre del rol IAM (obligatorio)
#   --policy-file <ruta>      política inline deseada, JSON (obligatorio)
#   --policy-name <nombre>    nombre de la política inline (default: cdk-deploy)
#   --repo <owner/name>       con --environments, construye y verifica la trust policy
#   --environments <a,b>      environments de GitHub autorizados (sub = repo:*:environment:E; el repo lo atan repository_id/owner_id)
#   --region <r> --profile <p>  se pasan tal cual al aws cli
#   --apply                   escribe (crea el rol si falta, actualiza trust e inline)
#
# CUIDADO: put-role-policy REEMPLAZA la política entera; un permiso agregado a mano
# y ausente del JSON aparece como eliminación en el diff antes de perderse.
#
# La trust policy replica: provider token.actions.githubusercontent.com de la cuenta,
# aud = sts.amazonaws.com, repository_id y repository_owner_id (leídos con `gh api`)
# y sub (StringLike) por cada environment. El provider OIDC NO se crea: si falta, error.
#
# Requiere: aws cli, jq y (con --repo) gh autenticado.
# Salida: la última línea de stdout es el ARN del rol (solo si no hay diferencias
# pendientes o tras --apply).
#
# Códigos de salida: 0 en sincronía (o aplicado) · 2 hay diferencias (dry-run) · 1 error
# =============================================================================
set -euo pipefail

ROL=""; POLICY_FILE=""; POLICY_NAME="cdk-deploy"; REPO=""; ENVS=""
APLICAR=0; AWS_OPTS=()

usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//;$d'; }
die() { echo "ERROR: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --rol) ROL="${2:?falta valor de --rol}"; shift 2 ;;
    --policy-file) POLICY_FILE="${2:?falta valor de --policy-file}"; shift 2 ;;
    --policy-name) POLICY_NAME="${2:?falta valor de --policy-name}"; shift 2 ;;
    --repo) REPO="${2:?falta valor de --repo}"; shift 2 ;;
    --environments) ENVS="${2:?falta valor de --environments}"; shift 2 ;;
    --region) AWS_OPTS+=(--region "${2:?falta valor de --region}"); shift 2 ;;
    --profile) AWS_OPTS+=(--profile "${2:?falta valor de --profile}"); shift 2 ;;
    --apply) APLICAR=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "opción desconocida '$1'" ;;
  esac
done

[ -n "$ROL" ] || die "falta --rol"
[ -n "$POLICY_FILE" ] || die "falta --policy-file"
[ -f "$POLICY_FILE" ] || die "no existe $POLICY_FILE"
if [ -n "$REPO$ENVS" ]; then
  [ -n "$REPO" ] && [ -n "$ENVS" ] || die "--repo y --environments van juntos"
  [[ "$REPO" == */* ]] || die "--repo debe ser owner/name"
fi
command -v jq >/dev/null || die "falta jq"
jq empty "$POLICY_FILE" 2>/dev/null || die "$POLICY_FILE no es JSON válido"

aws_() { aws "${AWS_OPTS[@]+"${AWS_OPTS[@]}"}" "$@"; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
# Arrays ordenados y claves ordenadas: IAM no devuelve el orden del archivo.
norm() { jq --sort-keys 'walk(if type=="array" then sort else . end)'; }

echo "== Rol:      $ROL"
echo "== Política: $POLICY_NAME ($POLICY_FILE)"
[ -n "$REPO" ] && echo "== Trust:    $REPO [$ENVS]"
echo

# --- ¿existe el rol? --------------------------------------------------------
EXISTE=1
if ! aws_ iam get-role --role-name "$ROL" --output json > "$TMP/role.json" 2> "$TMP/err"; then
  grep -q NoSuchEntity "$TMP/err" || { cat "$TMP/err" >&2; die "no se pudo leer el rol"; }
  EXISTE=0
fi
[ "$EXISTE" -eq 1 ] && echo "Rol existente." || echo "El rol NO existe."

DIFF=0
[ "$EXISTE" -eq 0 ] && DIFF=1

# --- trust policy deseada ---------------------------------------------------
if [ -n "$REPO" ]; then
  command -v gh >/dev/null || die "falta gh (necesario con --repo)"
  CUENTA=$(aws_ sts get-caller-identity --query Account --output text) || die "sts get-caller-identity falló"
  PROV="arn:aws:iam::$CUENTA:oidc-provider/token.actions.githubusercontent.com"
  aws_ iam get-open-id-connect-provider --open-id-connect-provider-arn "$PROV" >/dev/null 2>&1 \
    || die "no existe el OIDC provider $PROV (no se crea desde este script)"
  gh api "repos/$REPO" --jq '[.id, .owner.id] | @tsv' > "$TMP/ids" || die "gh api repos/$REPO falló"
  REPO_ID=$(cut -f1 "$TMP/ids"); OWNER_ID=$(cut -f2 "$TMP/ids")
  jq -n --arg prov "$PROV" --arg repo "$REPO" --arg rid "$REPO_ID" --arg oid "$OWNER_ID" --arg envs "$ENVS" '
    "token.actions.githubusercontent.com" as $h
    | { Version: "2012-10-17", Statement: [{
        Effect: "Allow", Principal: { Federated: $prov },
        Action: "sts:AssumeRoleWithWebIdentity",
        Condition: {
          StringEquals: { ($h+":aud"): "sts.amazonaws.com",
                          ($h+":repository_id"): $rid, ($h+":repository_owner_id"): $oid },
          StringLike: { ($h+":sub"): [ $envs | split(",")[] | "repo:*:environment:\(.)" ] } } }] }' \
    > "$TMP/trust.json"
  if [ "$EXISTE" -eq 1 ]; then
    jq '.Role.AssumeRolePolicyDocument' "$TMP/role.json" | norm > "$TMP/trust_viva"
    norm < "$TMP/trust.json" > "$TMP/trust_deseada"
    if ! diff -u --label "AWS (trust vivo)" "$TMP/trust_viva" --label "trust deseado" "$TMP/trust_deseada" > "$TMP/trust_diff"; then
      echo; echo "Diferencias en la trust policy:"; cat "$TMP/trust_diff"; DIFF=1; TRUST_DIFF=1
    else
      echo "Trust policy en sincronía."
    fi
  fi
elif [ "$EXISTE" -eq 0 ]; then
  die "el rol no existe y sin --repo/--environments no hay trust policy para crearlo"
fi

# --- política inline --------------------------------------------------------
if [ "$EXISTE" -eq 1 ] && aws_ iam get-role-policy --role-name "$ROL" --policy-name "$POLICY_NAME" \
     --query PolicyDocument --output json 2>/dev/null | jq --sort-keys . > "$TMP/viva"; then :; else
  echo '{}' > "$TMP/viva"
fi
jq --sort-keys . "$POLICY_FILE" > "$TMP/deseada"
if diff -u --label "AWS (vivo)" "$TMP/viva" --label "${POLICY_FILE##*/}" "$TMP/deseada" > "$TMP/pol_diff"; then
  echo "Política inline en sincronía."
else
  echo; echo "Diferencias en la política inline (- AWS, + quedaría):"; cat "$TMP/pol_diff"; DIFF=1
fi
echo

if [ "$DIFF" -eq 0 ]; then
  echo "Nada que hacer."
  jq -r '.Role.Arn' "$TMP/role.json"
  exit 0
fi
if [ "$APLICAR" -eq 0 ]; then
  echo "Dry-run: no se escribió nada. Repetir con --apply para aplicar."
  exit 2
fi

# --- aplicar ----------------------------------------------------------------
if [ "$EXISTE" -eq 0 ]; then
  ARN=$(aws_ iam create-role --role-name "$ROL" --assume-role-policy-document "file://$TMP/trust.json" \
          --query Role.Arn --output text)
  echo "Rol creado."
else
  ARN=$(jq -r '.Role.Arn' "$TMP/role.json")
  if [ "${TRUST_DIFF:-0}" -eq 1 ]; then
    aws_ iam update-assume-role-policy --role-name "$ROL" --policy-document "file://$TMP/trust.json"
    echo "Trust policy actualizada."
  fi
fi
aws_ iam put-role-policy --role-name "$ROL" --policy-name "$POLICY_NAME" --policy-document "file://$POLICY_FILE"
echo "Política inline aplicada."
echo "$ARN"
