#!/usr/bin/env python3
"""Conciliación del grafo de migraciones Alembic — solo stdlib, sin instalar nada.

Uso (desde backend/, o donde esté la carpeta de versiones):

    python3 check_migrations.py [migrations/versions]           # auditar el grafo
    python3 check_migrations.py [migrations/versions] --nuevo   # id libre + down_revision para una migración nueva

La carpeta también puede venir en ALEMBIC_VERSIONS; por defecto ./migrations/versions.

Detecta los cinco problemas que rompen distinto:

  · multi-head          → `alembic upgrade head` falla y nadie despliega
  · id duplicado        → Alembic aplica solo una; la otra no corre NUNCA
  · padre fantasma      → down_revision apunta a una revisión que no está en el repo
  · huérfana            → está en el repo pero no se alcanza desde el head
  · raíz extra          → dos down_revision=None son dos historias paralelas

Se parsea con AST (no regex): en los merges `down_revision` es una tupla
multilínea y una regex de una línea la lee como None, haciendo pasar un merge
por una raíz nueva.

Sale con código 1 si encuentra cualquiera de los cinco problemas.
"""
from __future__ import annotations

import ast
import os
import sys
import uuid
from pathlib import Path

_args = [a for a in sys.argv[1:] if not a.startswith("--")]
VERSIONS = Path(_args[0] if _args else os.environ.get("ALEMBIC_VERSIONS", "migrations/versions"))


def _parse(path: Path):
    """(revision, down_revision) de un archivo de migración, vía AST.

    Soporta `revision = "x"` (Assign) y `revision: str = "x"` (AnnAssign),
    y down_revision como str, None o tupla/lista (merges).
    """
    tree = ast.parse(path.read_text(encoding="utf-8"))
    rev = None
    down = "MISSING"
    for node in tree.body:
        if isinstance(node, ast.Assign):
            targets = [getattr(t, "id", None) for t in node.targets]
            value = node.value
        elif isinstance(node, ast.AnnAssign):
            targets = [getattr(node.target, "id", None)]
            value = node.value
        else:
            continue
        try:
            v = ast.literal_eval(value)
        except (ValueError, SyntaxError):
            continue
        if "revision" in targets and "down_revision" not in targets:
            rev = v
        if "down_revision" in targets:
            down = v
    return rev, down


def cargar():
    if not VERSIONS.is_dir():
        sys.exit(f"No existe la carpeta de versiones: {VERSIONS}")
    revs: dict[str, str] = {}   # revision -> archivo
    downs: dict[str, object] = {}
    duplicados: list[tuple[str, str, str]] = []
    for f in sorted(VERSIONS.glob("*.py")):
        rev, down = _parse(f)
        if rev is None:
            continue  # script suelto sin revision (no es una migración)
        if rev in revs:
            duplicados.append((rev, revs[rev], f.name))
            continue
        revs[rev] = f.name
        downs[rev] = down
    return revs, downs, duplicados


def padres(down) -> list[str]:
    if down in (None, "MISSING"):
        return []
    if isinstance(down, (tuple, list)):
        return list(down)
    return [down]


def auditar() -> int:
    revs, downs, duplicados = cargar()

    hijos: set[str] = set()
    fantasmas: list[tuple[str, str]] = []
    for rev, down in downs.items():
        for p in padres(down):
            hijos.add(p)
            if p not in revs:
                fantasmas.append((rev, p))

    heads = [r for r in revs if r not in hijos]
    raices = [r for r, d in downs.items() if d is None]

    alcanzables: set[str] = set()
    pila = list(heads)
    while pila:
        r = pila.pop()
        if r in alcanzables or r not in revs:
            continue
        alcanzables.add(r)
        pila.extend(padres(downs[r]))
    huerfanas = [r for r in revs if r not in alcanzables]

    mal_prefijo = [
        (r, f) for r, f in revs.items() if not f.startswith(r.split("@")[0][:12])
    ]

    print(f"Migraciones: {len(revs)}")
    print(f"Heads ({len(heads)}): " + ", ".join(f"{h} ({revs[h]})" for h in heads))
    print(f"Raíces ({len(raices)}): " + ", ".join(raices))

    problemas = 0
    if len(heads) != 1:
        problemas += 1
        print("✗ MULTI-HEAD: reapunta el down_revision de tu migración al head nuevo "
              "(alembic merge heads solo si ambas cabezas ya están en main).")
    if duplicados:
        problemas += 1
        for rev, a, b in duplicados:
            print(f"✗ ID DUPLICADO {rev}: {a} y {b} — Alembic aplicará solo una.")
    if fantasmas:
        problemas += 1
        for rev, p in fantasmas:
            print(f"✗ PADRE FANTASMA: {rev} ({revs[rev]}) apunta a {p}, que no existe.")
    if len(raices) != 1:
        problemas += 1
        print(f"✗ RAÍZ EXTRA: hay {len(raices)} down_revision=None; debe haber exactamente 1.")
    if huerfanas:
        problemas += 1
        for r in huerfanas:
            print(f"✗ HUÉRFANA: {r} ({revs[r]}) no se alcanza desde ningún head; no se aplicará.")
    if mal_prefijo:
        # aviso, no error: el prefijo del archivo debería ser su revision
        for r, f in mal_prefijo:
            print(f"⚠ prefijo ≠ revision: {f} declara {r}")

    if problemas == 0:
        print("✓ grafo sano")
        return 0
    return 1


def nuevo() -> int:
    revs, downs, duplicados = cargar()
    if duplicados or not revs:
        print("Primero arregla el grafo (corre sin --nuevo).")
        return 1
    hijos = {p for d in downs.values() for p in padres(d)}
    heads = [r for r in revs if r not in hijos]
    if len(heads) != 1:
        print(f"Hay {len(heads)} heads; concílialos antes de crear una migración nueva.")
        return 1
    rid = uuid.uuid4().hex[:12]
    while rid in revs:  # paranoia barata
        rid = uuid.uuid4().hex[:12]
    print("── Para tu migracion nueva ──")
    print(f'revision = "{rid}"')
    print(f'down_revision = "{heads[0]}"')
    return 0


if __name__ == "__main__":
    sys.exit(nuevo() if "--nuevo" in sys.argv[1:] else auditar())
