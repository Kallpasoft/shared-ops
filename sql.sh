#!/usr/bin/env bash
# =============================================================================
# Runner de scripts SQL contra la BD del entorno, leyendo la URL de los .env que
# ya existen — sin declarar variables a mano ni pegar URLs en la terminal.
#
# Uso:
#   sql.sh <staging|prod|local> <archivo.sql> [args extra de psql]
#
# Ejemplos:
#   sql.sh staging corte-correlativo.sql -v producto=yunque -v confirmar=CORTE
#   sql.sh prod    scripts/sql/fix-123.sql
#
# De dónde sale la conexión (DATABASE_URL_DIRECT, puerto 5432 — NO el pooler):
#   staging → $ENV_DIR/.env.staging · prod → $ENV_DIR/.env.prod · local → $ENV_DIR/.env
#
# Env:
#   ENV_DIR   carpeta de los .env         (default: ./backend)
#   SQL_DIR   dónde buscar el .sql si no es una ruta existente (default: ./scripts/sql)
#   FORZAR=si salta la confirmación de prod (para CI)
#
# El valor de la URL nunca se imprime: solo se muestra el host de destino.
# En prod pide confirmación interactiva tecleando PROD.
# =============================================================================
set -euo pipefail

ENV_DIR="${ENV_DIR:-$PWD/backend}"
SQL_DIR="${SQL_DIR:-$PWD/scripts/sql}"

ENTORNO="${1:?uso: sql.sh <staging|prod|local> <archivo.sql> [args psql]}"
ARCHIVO="${2:?falta el archivo .sql}"
# Copia para el mensaje de error: después del `shift` no queda $2, y con `set -u`
# citarlo abortaba con "unbound variable" en vez de decir qué archivo no encontró.
PEDIDO="$ARCHIVO"
shift 2

case "$ENTORNO" in
  staging) ENVFILE="$ENV_DIR/.env.staging" ;;
  prod)    ENVFILE="$ENV_DIR/.env.prod" ;;
  local)   ENVFILE="$ENV_DIR/.env" ;;
  *) echo "entorno inválido: $ENTORNO (staging|prod|local)"; exit 2 ;;
esac
[ -f "$ENVFILE" ] || { echo "no existe $ENVFILE"; exit 2; }

# El SQL se busca en SQL_DIR si no es una ruta existente.
[ -f "$ARCHIVO" ] || ARCHIVO="$SQL_DIR/$(basename "$ARCHIVO")"
[ -f "$ARCHIVO" ] || {
  echo "no existe el .sql: $PEDIDO"
  echo "disponibles en $SQL_DIR:"
  ls -1 "$SQL_DIR"/*.sql 2>/dev/null | xargs -n1 basename | sed 's/^/  /'
  exit 2
}

command -v psql >/dev/null || { echo "psql no está instalado (brew install libpq && brew link --force libpq)"; exit 2; }

# Extraer DATABASE_URL_DIRECT sin exportar todo el .env (JWT_SECRET etc. no
# tienen por qué entrar al ambiente de este proceso).
URL="$(grep -E '^DATABASE_URL_DIRECT=' "$ENVFILE" | tail -1 | cut -d= -f2- | tr -d '"' | tr -d "'")"
if [ -z "$URL" ]; then
  echo "DATABASE_URL_DIRECT está vacío en $ENVFILE — completarlo primero (URL directa 5432, no el pooler)."
  exit 2
fi

# Solo el host, jamás credenciales.
HOST="$(printf '%s' "$URL" | sed -E 's|^[a-z]+://[^@]*@||; s|[/?].*$||')"
echo "→ entorno: $ENTORNO · destino: $HOST · sql: $(basename "$ARCHIVO")"

if [ "$ENTORNO" = "prod" ] && [ "${FORZAR:-no}" != "si" ]; then
  read -r -p "Escribe PROD para confirmar contra ese host: " CONF
  [ "$CONF" = "PROD" ] || { echo "abortado."; exit 1; }
fi

exec psql "$URL" -f "$ARCHIVO" "$@"
