# shared-ops

Scripts de operación que ya se necesitaban en más de un producto de Kallpasoft: guardas de
deploy, acceso a la BD de un entorno, configuración de GitHub Environments y revisión del grafo
de migraciones. **Sin lógica de negocio ni datos de clientes**: es el límite que fija
`/00-strategy/decisions-log.md § 2026-08-23` para los paquetes compartidos, y así tiene que seguir.

**Lo usan:** `ferreteria-system` · `foody` · `auto-system` · `kallpasoft-systems`

## Por qué existe

La auditoría de scripts del 2026-09-16 (`/02-code/products/tasks/auditoria-scripts-2026-09-16.md`)
encontró estos cuatro problemas resueltos una vez en un repo y ausentes, o resueltos peor, en los
demás. Regla de dos de `/02-code/CLAUDE.md`: a la segunda vez se extrae, no se copia.

| Script | Resuelve | Origen | Antes, en los otros repos |
|---|---|---|---|
| `verificar-origen-deploy.sh` | Que un deploy a prod no borre lo que prod ya tiene: el commit debe estar en `main` y contener el tag anterior | auto-system, del incidente 2026-09-12 (v0.14.0 borró la búsqueda por DNI/RUC) | ferretería lo tenía embebido en `deploy-front.sh`; foody y central, nada |
| `sql.sh` | Correr un `.sql` contra staging/prod leyendo `DATABASE_URL_DIRECT` del `.env` del entorno, mostrando solo el host y exigiendo teclear `PROD` | ferreteria-system (`services/facturacion/scripts/sql.sh`), base de 20 scripts de facturación | foody leía el secret con boto3 en cada script; auto pegaba la URL a mano |
| `setup-github-env.sh` | Sembrar y auditar Variables/Secrets de un GitHub Environment desde un manifiesto versionado, con diff, detección de drift contra los workflows y resolución de outputs de CloudFormation y certs ACM | ferreteria-system | auto y central tenían un script imperativo con los valores hardcodeados y sin diff |
| `check_migrations.py` | Detectar multi-head, id duplicado, padre fantasma, huérfana y raíz extra en Alembic, con AST y solo stdlib, en segundos y antes de instalar dependencias | foody | los demás solo veían el multi-head, y después de `pip install` |

## Novedades en v0.2.0 (sin publicar)

| Script | Resuelve | Origen |
|---|---|---|
| `deploy-role.sh` | Rol OIDC de deploy bajo control de versiones: diff de la política inline y de la trust policy contra AWS, y creación del rol si falta (#2) | auto-system (`infra/scripts/deploy-role.sh`); segundo uso: kallpy |
| `secret-patch.sh` | Fusionar claves en un secret de Secrets Manager sin pisar el resto, sin imprimir valores (#3) | ferreteria-system (`update-cookie-secret.sh`); segundo uso: foody |

```bash
deploy-role.sh --rol <rol> --policy-file infra/policies/deploy-role.json \
  [--policy-name cdk-deploy] [--repo <owner/name> --environments <a,b>] [--region R] [--profile P] [--apply]
secret-patch.sh <secret-id> --from-file <patch.json> [--region R] [--profile P] [--create] [--apply] [--overwrite]
```

Los dos son **dry-run por defecto** y salen con **0** (en sincronía / aplicado), **2** (hay diferencias
o conflictos pendientes) o **1** (error).

- `deploy-role.sh`: `put-role-policy` reemplaza la política entera, así que el diff (claves y arrays
  normalizados) muestra como eliminación cualquier permiso agregado a mano. Con `--repo` + `--environments`
  también verifica la trust policy (`aud`, `repository_id`, `repository_owner_id` leídos con `gh api`, y un
  `sub` `repo:<owner/name>:environment:<env>` por environment) y con `--apply` crea o corrige el rol. El OIDC
  provider no se crea: si falta, falla. La última línea de stdout es el ARN del rol.
- `secret-patch.sh`: el patch es un objeto JSON plano de strings. Por defecto solo agrega claves nuevas; una
  clave con valor distinto es **conflicto** y no se toca salvo `--overwrite`. Solo imprime nombres de clave
  (`nueva`, `igual`, `conflicto`, `se sobrescribe`), nunca valores. `--create` permite crear el secret.

Wrapper de cinco líneas en cada producto (ruta que sus docs ya citan, p. ej. `infra/scripts/deploy-role.sh`):

```bash
#!/usr/bin/env bash
set -euo pipefail
SHARED_OPS="${SHARED_OPS:-$HOME/kallpasoft/02-code/shared-components/ops}"
RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec "$SHARED_OPS/deploy-role.sh" --rol <rol> --policy-file "$RAIZ/infra/policies/deploy-role.json" \
  --repo <owner/name> --environments <staging,production> "$@"
```

## Uso en CI

```yaml
- uses: actions/checkout@v4
  with:
    fetch-depth: 0            # el guard de origen necesita historial y tags
- uses: actions/checkout@v4
  with:
    repository: Kallpasoft/shared-ops
    ref: v0.1.0
    path: .shared-ops
- name: Guard origen del deploy
  run: bash .shared-ops/verificar-origen-deploy.sh
- name: Conciliar grafo de migraciones
  run: python3 ../.shared-ops/check_migrations.py migrations/versions   # con working-directory: backend
```

## Uso local

Clon en `/02-code/shared-components/ops` (o donde diga `SHARED_OPS`). Cada repo consumidor deja
un wrapper de pocas líneas en la ruta que sus docs ya citan, que fija `ENV_DIR`/`SQL_DIR` y delega
aquí. Ejemplos:

```bash
# desde la raíz del repo consumidor
sql.sh prod scripts/sql/fix.sql            # ENV_DIR=./backend, SQL_DIR=./scripts/sql
setup-github-env.sh staging                # dry-run contra infra/environments/staging.json
setup-github-env.sh prod --apply
python3 check_migrations.py backend/migrations/versions --nuevo
```

Variables: `verificar-origen-deploy.sh` acepta `RAMA_PRINCIPAL`, `PATRON_TAG`, `REMOTO`;
`sql.sh` acepta `ENV_DIR`, `SQL_DIR`, `FORZAR=si`; `setup-github-env.sh` acepta `REPO_ROOT`,
`ENV_DIR`; `check_migrations.py` acepta la carpeta como argumento o `ALEMBIC_VERSIONS`.

## Chequeos

```bash
python3 tests/test_check_migrations.py
bash tests/test_verificar_origen.sh
bash tests/test_deploy_role_secret_patch.sh   # aws/gh falsos en el PATH, sin AWS real
```

## Publicar una versión

Semver. Subir el tag anotado con lo que cambia y por qué (`git tag -a vX.Y.Z -m ...`), y que cada
consumidor mueva su `ref:` cuando quiera el cambio. Nada se actualiza solo, a propósito.
