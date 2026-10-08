#!/usr/bin/env bash
# deploy-role.sh y secret-patch.sh contra un `aws`/`gh` falsos en el PATH (sin AWS real).
# El fake sirve fixtures de $FAKE y anota cada llamada en $FAKE/calls.log.
set -euo pipefail
D="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
FAKE="$T/fake"; mkdir -p "$FAKE" "$T/bin"; export FAKE
cat > "$T/bin/aws" <<'X'
#!/usr/bin/env bash
echo "$*" >> "$FAKE/calls.log"
case "$*" in
  *"iam get-role-policy"*) [ -f "$FAKE/inline.json" ] && cat "$FAKE/inline.json" || { echo NoSuchEntity >&2; exit 254; } ;;
  *"iam get-role"*) [ -f "$FAKE/role.json" ] && cat "$FAKE/role.json" || { echo NoSuchEntity >&2; exit 254; } ;;
  *"sts get-caller-identity"*) echo 123456789012 ;;
  *"get-open-id-connect-provider"*) [ -f "$FAKE/noprov" ] && exit 254 || echo '{}' ;;
  *"create-role"*) echo arn:aws:iam::123456789012:role/nuevo ;;
  *"get-secret-value"*) [ -f "$FAKE/secret.json" ] && cat "$FAKE/secret.json" || { echo ResourceNotFoundException >&2; exit 254; } ;;
esac
X
printf '#!/usr/bin/env bash\necho "100	200"\n' > "$T/bin/gh"
chmod +x "$T/bin/aws" "$T/bin/gh"; export PATH="$T/bin:$PATH"
reset() { rm -f "$FAKE"/*; }
rc() { set +e; "$@" > "$T/out" 2>&1; R=$?; set -e; }
chk() { [ "$R" -eq "$1" ] || { echo "FALLO: $2 (exit $R, esperado $1)"; cat "$T/out"; exit 1; }; echo "ok: $2"; }
grep_() { grep -q -- "$1" "$T/out" || { echo "FALLO: falta '$1' en la salida"; cat "$T/out"; exit 1; }; }
nogrep() { ! grep -q -- "$1" "$2" || { echo "FALLO: '$1' aparece en $2"; exit 1; }; }

POL="$T/pol.json"; echo '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"s3:*","Resource":"*"}]}' > "$POL"
DR="$D/deploy-role.sh"

# --- deploy-role ---
reset; rc bash "$DR" --rol r;                                  chk 1 "deploy-role sin --policy-file"
reset; rc bash "$DR" --policy-file "$POL";                     chk 1 "deploy-role sin --rol"
reset; rc bash "$DR" --rol r --policy-file "$POL" --repo o/n;  chk 1 "deploy-role --repo sin --environments"
reset; rc bash "$DR" --rol r --policy-file "$POL";             chk 1 "deploy-role: rol inexistente sin --repo"
reset; echo '{"Version":"2012-10-17","Statement":[]}' > "$FAKE/inline.json"
echo '{"Role":{"Arn":"arn:aws:iam::123456789012:role/r","AssumeRolePolicyDocument":{}}}' > "$FAKE/role.json"
rc bash "$DR" --rol r --policy-file "$POL"; chk 2 "deploy-role dry-run con diff"; grep_ 's3:\*'
nogrep put-role-policy "$FAKE/calls.log"; echo "ok: dry-run no escribe"
cp "$POL" "$FAKE/inline.json"
rc bash "$DR" --rol r --policy-file "$POL"; chk 0 "deploy-role en sincronía"
[ "$(tail -n1 "$T/out")" = "arn:aws:iam::123456789012:role/r" ] && echo "ok: ARN en la última línea"
rc bash "$DR" --rol r --policy-file "$POL" --repo o/n --environments a,b; chk 2 "deploy-role trust distinto"
rc bash "$DR" --rol r --policy-file "$POL" --repo o/n --environments a,b --apply; chk 0 "deploy-role --apply actualiza trust"
grep -q update-assume-role-policy "$FAKE/calls.log" && echo "ok: update-assume-role-policy"
touch "$FAKE/noprov"; rc bash "$DR" --rol r --policy-file "$POL" --repo o/n --environments a; chk 1 "deploy-role falla sin OIDC provider"
reset; rc bash "$DR" --rol nuevo --policy-file "$POL" --repo o/n --environments a,b --apply; chk 0 "deploy-role crea el rol"
grep -q create-role "$FAKE/calls.log" && grep -q put-role-policy "$FAKE/calls.log" && echo "ok: create-role + put-role-policy"
[ "$(tail -n1 "$T/out")" = "arn:aws:iam::123456789012:role/nuevo" ] && echo "ok: ARN del rol creado"

# --- secret-patch ---
SP="$D/secret-patch.sh"; PATCH="$T/patch.json"
echo '{"a":"PATCH-A","b":"PATCH-B-DISTINTO","c":"PATCH-C"}' > "$PATCH"
reset; echo '{"a":"PATCH-A","b":"VIEJO-SECRETO","z":"INTACTA"}' > "$FAKE/secret.json"
rc bash "$SP" s --from-file "$PATCH"; chk 2 "secret-patch dry-run: cambios pendientes"
grep_ nueva; grep_ igual; grep_ conflicto
nogrep PATCH- "$T/out"; nogrep VIEJO "$T/out"; echo "ok: no imprime valores"
rc bash "$SP" s --from-file "$PATCH" --apply; chk 2 "secret-patch --apply deja conflicto sin resolver"
grep -q put-secret-value "$FAKE/calls.log" && echo "ok: escribió las nuevas"
nogrep PATCH- "$FAKE/calls.log"; nogrep VIEJO "$FAKE/calls.log"; echo "ok: valores fuera del argv"
rc bash "$SP" s --from-file "$PATCH" --overwrite; chk 2 "secret-patch --overwrite dry-run"; grep_ "se sobrescribe"
echo '{"x":1}' > "$T/mal.json"; rc bash "$SP" s --from-file "$T/mal.json"; chk 1 "secret-patch rechaza patch no plano"
echo '{"a":"PATCH-A"}' > "$T/igual.json"; rc bash "$SP" s --from-file "$T/igual.json"; chk 0 "secret-patch sin cambios"
rm "$FAKE/secret.json"
rc bash "$SP" s --from-file "$PATCH"; chk 1 "secret-patch exige --create"
rc bash "$SP" s --from-file "$PATCH" --create --apply; chk 0 "secret-patch --create --apply"
grep -q create-secret "$FAKE/calls.log" && echo "ok: create-secret"
