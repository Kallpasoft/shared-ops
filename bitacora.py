#!/usr/bin/env python3
"""Bitácora diaria de un repo: qué se hizo cada día y qué quedó para revisar.

GitHub no sabe agrupar por día: los Projects filtran y ordenan, pero no muestran
«lo del martes», y en plan Free los Insights no guardan histórico. Esto lo arma
leyendo la API y agrupando por **día calendario de Lima** (UTC-5 fijo), que es el
día en que la gente trabajó, no el del reloj UTC.

    bitacora.py Kallpasoft/ferreteria-system                    # hoy (Lima)
    bitacora.py Kallpasoft/foody --desde 2026-09-01 --hasta 2026-09-17
    bitacora.py Kallpasoft/auto-system --dias 7
    bitacora.py Kallpasoft/{ferreteria-system,foody} --dias 1   # consolidado

Escribe Markdown a stdout: un bloque por día, y al final el estado de lo que
espera revisión (eso no es por día, es una foto de ahora).

Requiere `gh` autenticado con acceso al repo. Solo lee.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from collections import defaultdict
from datetime import date, datetime, timedelta, timezone

LIMA = timezone(timedelta(hours=-5))
# Etiquetas que marcan un issue abierto como «hay que mirarlo», por convención de
# ferreteria-system. Los otros repos todavía no las usan; no pasa nada si no existen.
LABELS_URGENTES = ("sev:critico", "sev:alto")


def gh(*args: str) -> str:
    """Corre `gh` y devuelve stdout. Un fallo acá tiene que romper: una bitácora
    a medias miente por omisión, que es peor que no tenerla."""
    return subprocess.run(
        ["gh", *args], check=True, capture_output=True, text=True
    ).stdout


def gh_json(*args: str):
    salida = gh(*args).strip()
    return json.loads(salida) if salida else []


def dia_lima(iso: str | None) -> date | None:
    """Fecha Lima de un timestamp ISO de la API (siempre UTC, con Z)."""
    if not iso:
        return None
    return datetime.fromisoformat(iso.replace("Z", "+00:00")).astimezone(LIMA).date()


def issues_de_pr(pr: dict) -> list[int]:
    return [i["number"] for i in pr.get("closingIssuesReferences") or []]


def recolectar(repo: str, desde: date, hasta: date) -> dict:
    """Todo lo que pasó en el rango, ya agrupado por día Lima."""
    # Se pide por rango de fechas UTC con margen de un día a cada lado: el día Lima
    # del 17 incluye timestamps UTC del 17 y del 18 (hasta las 05:00).
    margen_desde = (desde - timedelta(days=1)).isoformat()
    prs = gh_json(
        "pr", "list", "--repo", repo, "--state", "merged", "--limit", "500",
        "--search", f"merged:>={margen_desde}",
        "--json", "number,title,mergedAt,author,closingIssuesReferences,url",
    )
    issues = gh_json(
        "issue", "list", "--repo", repo, "--state", "closed", "--limit", "500",
        "--search", f"closed:>={margen_desde}",
        "--json", "number,title,closedAt,labels,url",
    )
    abiertos = gh_json(
        "issue", "list", "--repo", repo, "--state", "open", "--limit", "500",
        "--json", "number,title,labels,updatedAt,url",
    )
    pr_abiertos = gh_json(
        "pr", "list", "--repo", repo, "--state", "open", "--limit", "200",
        "--json", "number,title,isDraft,reviewDecision,updatedAt,url",
    )

    por_dia: dict[date, dict[str, list]] = defaultdict(
        lambda: {"prs": [], "issues": [], "tags": []}
    )
    for pr in prs:
        d = dia_lima(pr.get("mergedAt"))
        if d and desde <= d <= hasta:
            por_dia[d]["prs"].append(pr)
    for issue in issues:
        d = dia_lima(issue.get("closedAt"))
        if d and desde <= d <= hasta:
            por_dia[d]["issues"].append(issue)
    for tag in tags_con_fecha(repo):
        if desde <= tag["dia"] <= hasta:
            por_dia[tag["dia"]]["tags"].append(tag)

    return {"por_dia": por_dia, "abiertos": abiertos, "pr_abiertos": pr_abiertos}


def tags_con_fecha(repo: str, limite: int = 20) -> list[dict]:
    """Los últimos tags `v*` con la fecha del commit que apuntan.

    Un deploy a producción **es** un tag (los workflows de prod se disparan por
    `v*.*.*`), así que sin esto la bitácora no dice qué salió a producción.
    """
    salida = []
    for t in gh_json("api", f"repos/{repo}/tags", "--jq", ".[:%d]" % limite) or []:
        nombre = t.get("name", "")
        if not nombre.startswith("v"):
            continue
        sha = t.get("commit", {}).get("sha")
        if not sha:
            continue
        # La fecha del TAG, no la del commit: un tag creado hoy sobre un commit de
        # ayer es un deploy de hoy. Los tags anotados (los que usa el equipo, con
        # `git tag -a`) traen `tagger.date`; si es un tag ligero no hay objeto y
        # queda la del commit, que es lo único que existe.
        fecha = ""
        ref = gh_json("api", f"repos/{repo}/git/ref/tags/{nombre}")
        if isinstance(ref, dict) and ref.get("object", {}).get("type") == "tag":
            obj = gh_json("api", f"repos/{repo}/git/tags/{ref['object']['sha']}")
            fecha = (obj or {}).get("tagger", {}).get("date", "")
        if not fecha:
            fecha = gh("api", f"repos/{repo}/commits/{sha}", "--jq", ".commit.committer.date").strip()
        d = dia_lima(fecha)
        if d:
            salida.append({"nombre": nombre, "dia": d, "sha": sha[:7]})
    return salida


def render(repos: dict[str, dict], desde: date, hasta: date) -> str:
    """Un documento con un bloque por día. Con más de un repo, cada día lleva una
    subsección por repo: es el consolidado, y sale del mismo código que el de uno
    solo para que no puedan divergir."""
    titulo = next(iter(repos)) if len(repos) == 1 else "Kallpasoft"
    lineas = [f"# Bitácora — {titulo}", ""]
    lineas.append(f"Del {desde.isoformat()} al {hasta.isoformat()} (días de Lima). "
                  "Generada por `shared-ops/bitacora.py`; no editar a mano.")
    lineas.append("")

    dia = hasta
    while dia >= desde:
        lineas.append(f"## {dia.isoformat()}")
        lineas.append("")
        vacio = True
        for repo, datos in repos.items():
            d = datos["por_dia"].get(dia)
            if not d or not (d["prs"] or d["issues"] or d["tags"]):
                continue
            vacio = False
            if len(repos) > 1:
                lineas.append(f"### {repo.split('/')[-1]}")
                lineas.append("")
            lineas.extend(render_dia(d))
        if vacio:
            lineas.append("Sin actividad.")
            lineas.append("")
        dia -= timedelta(days=1)

    for repo, datos in repos.items():
        lineas.extend(render_pendientes(datos, repo if len(repos) > 1 else None))
    return "\n".join(lineas).rstrip() + "\n"


def render_dia(d: dict) -> list[str]:
    lineas: list[str] = []
    if d["tags"]:
        lineas.append("**Desplegado**")
        for t in sorted(d["tags"], key=lambda x: x["nombre"]):
            lineas.append(f"- [x] `{t['nombre']}` ({t['sha']})")
        lineas.append("")

    if d["issues"]:
        lineas.append("**Cerrado**")
        for i in sorted(d["issues"], key=lambda x: x["number"]):
            etiquetas = ", ".join(l["name"] for l in i.get("labels") or [])
            sufijo = f" · {etiquetas}" if etiquetas else ""
            lineas.append(f"- [x] #{i['number']} {i['title']}{sufijo}")
        lineas.append("")

    if d["prs"]:
        lineas.append("**Mergeado**")
        for p in sorted(d["prs"], key=lambda x: x["number"]):
            refs = issues_de_pr(p)
            cierra = " → " + ", ".join(f"#{n}" for n in refs) if refs else " · sin issue"
            autor = (p.get("author") or {}).get("login", "?")
            lineas.append(f"- [x] #{p['number']} {p['title']} ({autor}){cierra}")
        lineas.append("")
    return lineas


def render_pendientes(datos: dict, repo: str | None = None) -> list[str]:
    """Foto de ahora, no del día: lo que está esperando que alguien lo mire."""
    encabezado = "## Para revisar" + (f" — {repo.split('/')[-1]}" if repo else "")
    lineas = [encabezado, "",
              "Estado al momento de generar, no del día.", ""]
    hay = False

    esperando = [p for p in datos["pr_abiertos"]
                 if not p["isDraft"] and p.get("reviewDecision") in (None, "", "REVIEW_REQUIRED")]
    if esperando:
        hay = True
        lineas.append("**PRs sin revisar**")
        for p in sorted(esperando, key=lambda x: x["updatedAt"]):
            lineas.append(f"- [ ] #{p['number']} {p['title']} — sin revisión desde {p['updatedAt'][:10]}")
        lineas.append("")

    urgentes = [i for i in datos["abiertos"]
                if any(l["name"] in LABELS_URGENTES for l in i.get("labels") or [])]
    if urgentes:
        hay = True
        lineas.append("**Issues urgentes abiertos**")
        for i in sorted(urgentes, key=lambda x: x["number"]):
            sev = ", ".join(l["name"] for l in i["labels"] if l["name"] in LABELS_URGENTES)
            lineas.append(f"- [ ] #{i['number']} {i['title']} · {sev}")
        lineas.append("")

    # Lo que se hizo sin dejar rastro: un PR mergeado sin issue no aparece en ningún
    # tablero, así que es justo lo que se pierde al revisar la semana.
    sin_issue = [p for dia in datos["por_dia"].values() for p in dia["prs"] if not issues_de_pr(p)]
    if sin_issue:
        hay = True
        lineas.append("**Mergeado sin issue** (revisar si hay que documentarlo o abrirlo)")
        for p in sorted(sin_issue, key=lambda x: x["number"]):
            lineas.append(f"- [ ] #{p['number']} {p['title']}")
        lineas.append("")

    if not hay:
        lineas.append("Nada pendiente.")
        lineas.append("")
    return lineas


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("repos", nargs="+", metavar="owner/repo", help="uno o varios repos")
    ap.add_argument("--desde", help="YYYY-MM-DD (default: hoy Lima, o hoy-dias)")
    ap.add_argument("--hasta", help="YYYY-MM-DD (default: hoy Lima)")
    ap.add_argument("--dias", type=int, help="atajo: últimos N días terminando en --hasta")
    args = ap.parse_args()

    hoy = datetime.now(LIMA).date()
    hasta = date.fromisoformat(args.hasta) if args.hasta else hoy
    if args.desde:
        desde = date.fromisoformat(args.desde)
    elif args.dias:
        desde = hasta - timedelta(days=args.dias - 1)
    else:
        desde = hasta
    if desde > hasta:
        print("ERROR: --desde es posterior a --hasta", file=sys.stderr)
        return 2

    datos = {r: recolectar(r, desde, hasta) for r in args.repos}
    sys.stdout.write(render(datos, desde, hasta))
    return 0


if __name__ == "__main__":
    sys.exit(main())
