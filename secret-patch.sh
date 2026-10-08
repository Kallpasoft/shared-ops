#!/usr/bin/env bash
# =============================================================================
# Fusiona claves de un JSON en un secret de AWS Secrets Manager sin pisar el resto.
#
# Uso:
#   secret-patch.sh <secret-id> --from-file <patch.json> [--region R] [--profile P]
#                   [--create] [--apply] [--overwrite]
#
# El patch es un objeto JSON plano de strings. Por defecto solo AGREGA claves que
# faltan; una clave existente con valor distinto es un conflicto y no se toca salvo
# --overwrite. --create permite crear el secret si no existe. Dry-run por defecto.
#
# NUNCA imprime valores: solo nombres de clave y su estado
# (nueva · igual · conflicto · se sobrescribe). Los valores viajan por archivos
# temporales (umask 077, borrados con trap) y `file://`, nunca por argv.
#
# Requiere: aws cli, jq.
# Códigos de salida: 0 nada que hacer (o aplicado sin conflictos) · 2 cambios pendientes
# o conflictos sin resolver · 1 error
# =============================================================================
set -euo pipefail
umask 077

SECRET=""; PATCH=""; CREAR=0; APLICAR=0; SOBRE=0; AWS_OPTS=()
usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//;$d'; }
die() { echo "ERROR: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --from-file) PATCH="${2:?falta valor de --from-file}"; shift 2 ;;
    --region) AWS_OPTS+=(--region "${2:?falta valor de --region}"); shift 2 ;;
    --profile) AWS_OPTS+=(--profile "${2:?falta valor de --profile}"); shift 2 ;;
    --create) CREAR=1; shift ;;
    --apply) APLICAR=1; shift ;;
    --overwrite) SOBRE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) usage >&2; die "opción desconocida '$1'" ;;
    *) [ -z "$SECRET" ] || die "solo un <secret-id>"; SECRET="$1"; shift ;;
  esac
done

[ -n "$SECRET" ] || { usage >&2; die "falta <secret-id>"; }
[ -n "$PATCH" ] || die "falta --from-file"
[ -f "$PATCH" ] || die "no existe $PATCH"
command -v jq >/dev/null || die "falta jq"
jq -e 'type=="object" and all(.[]; type=="string")' "$PATCH" >/dev/null 2>&1 \
  || die "$PATCH debe ser un objeto JSON plano de strings"

aws_() { aws "${AWS_OPTS[@]+"${AWS_OPTS[@]}"}" "$@"; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

EXISTE=1
if ! aws_ secretsmanager get-secret-value --secret-id "$SECRET" --query SecretString --output text \
     > "$TMP/actual.json" 2> "$TMP/err"; then
  grep -q ResourceNotFoundException "$TMP/err" || { cat "$TMP/err" >&2; die "no se pudo leer el secret"; }
  EXISTE=0; echo '{}' > "$TMP/actual.json"
fi
jq -e 'type=="object"' "$TMP/actual.json" >/dev/null 2>&1 || die "el secret actual no es un objeto JSON"
if [ "$EXISTE" -eq 0 ] && [ "$CREAR" -eq 0 ]; then
  die "el secret '$SECRET' no existe (usar --create para crearlo)"
fi

# Estado por clave, calculado dentro de jq: los valores no salen de ahí.
jq -nr --slurpfile a "$TMP/actual.json" --slurpfile p "$PATCH" --argjson sobre "$SOBRE" '
  $a[0] as $a | $p[0] | to_entries[]
  | if (.key as $k | $a | has($k) | not) then "nueva\t\(.key)"
    elif $a[.key] == .value then "igual\t\(.key)"
    elif $sobre == 1 then "se sobrescribe\t\(.key)"
    else "conflicto\t\(.key)" end' > "$TMP/estado"

echo "== Secret: $SECRET$([ "$EXISTE" -eq 0 ] && echo ' (no existe, se crearía)')"
awk -F'\t' '{ printf "  %-15s %s\n", $1, $2 }' "$TMP/estado"
N_CAMBIOS=$(grep -c -E '^(nueva|se sobrescribe)' "$TMP/estado" || true)
N_CONF=$(grep -c '^conflicto' "$TMP/estado" || true)
echo
[ "$N_CONF" -eq 0 ] || echo "AVISO: $N_CONF conflicto(s) sin cambiar; --overwrite para pisarlos."

if [ "$N_CAMBIOS" -eq 0 ] && [ "$EXISTE" -eq 1 ]; then
  echo "Nada que escribir."
  [ "$N_CONF" -eq 0 ] && exit 0 || exit 2
fi
if [ "$APLICAR" -eq 0 ]; then
  echo "Dry-run: no se escribió nada. Repetir con --apply para aplicar."
  exit 2
fi

# Solo se fusionan las claves nuevas / a sobrescribir; los conflictos quedan como están.
jq -n --slurpfile a "$TMP/actual.json" --slurpfile p "$PATCH" --argjson sobre "$SOBRE" '
  $a[0] + ($p[0] | with_entries(select($sobre == 1 or (.key as $k | $a[0] | has($k) | not))))' > "$TMP/final.json"

if [ "$EXISTE" -eq 0 ]; then
  aws_ secretsmanager create-secret --name "$SECRET" --secret-string "file://$TMP/final.json" >/dev/null
  echo "Secret creado."
else
  aws_ secretsmanager put-secret-value --secret-id "$SECRET" --secret-string "file://$TMP/final.json" >/dev/null
  echo "Secret actualizado."
fi
[ "$N_CONF" -eq 0 ] || exit 2
