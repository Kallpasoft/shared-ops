#!/usr/bin/env python3
"""Test de `bitacora.py` sin red: el agrupado por día Lima y el render.

Lo que protege es la frontera del día. Un PR mergeado a las 02:00 UTC del 18 es
trabajo del 17 en Lima, y si eso se corre un día la bitácora deja de coincidir con
lo que la gente recuerda haber hecho.

    python3 tests/test_bitacora.py
"""
import sys
import unittest
from datetime import date
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import bitacora  # noqa: E402


class TestDiaLima(unittest.TestCase):
    def test_medianoche_utc_es_el_dia_anterior_en_lima(self):
        self.assertEqual(bitacora.dia_lima("2026-09-18T02:00:00Z"), date(2026, 9, 17))

    def test_frontera_exacta_de_las_05_utc(self):
        self.assertEqual(bitacora.dia_lima("2026-09-18T04:59:59Z"), date(2026, 9, 17))
        self.assertEqual(bitacora.dia_lima("2026-09-18T05:00:00Z"), date(2026, 9, 18))

    def test_sin_fecha(self):
        self.assertIsNone(bitacora.dia_lima(None))


def _dia(prs=(), issues=(), tags=()):
    return {"prs": list(prs), "issues": list(issues), "tags": list(tags)}


PR_CON_ISSUE = {"number": 10, "title": "arregla algo", "author": {"login": "ana"},
                "closingIssuesReferences": [{"number": 7}]}
PR_SIN_ISSUE = {"number": 11, "title": "limpieza", "author": {"login": "ana"},
                "closingIssuesReferences": []}


class TestRender(unittest.TestCase):
    def test_un_dia_lista_deploy_cierre_y_merge(self):
        salida = "\n".join(bitacora.render_dia(_dia(
            prs=[PR_CON_ISSUE],
            issues=[{"number": 7, "title": "el bug", "labels": [{"name": "bug"}]}],
            tags=[{"nombre": "v1.2.0", "dia": date(2026, 9, 17), "sha": "abc1234"}],
        )))
        self.assertIn("**Desplegado**", salida)
        self.assertIn("`v1.2.0` (abc1234)", salida)
        self.assertIn("- [x] #7 el bug · bug", salida)
        self.assertIn("- [x] #10 arregla algo (ana) → #7", salida)

    def test_dia_sin_nada_dice_sin_actividad(self):
        datos = {"por_dia": {}, "abiertos": [], "pr_abiertos": []}
        salida = bitacora.render({"Kallpasoft/x": datos}, date(2026, 9, 14), date(2026, 9, 14))
        self.assertIn("## 2026-09-14", salida)
        self.assertIn("Sin actividad.", salida)

    def test_dias_en_orden_inverso(self):
        datos = {"por_dia": {}, "abiertos": [], "pr_abiertos": []}
        salida = bitacora.render({"Kallpasoft/x": datos}, date(2026, 9, 15), date(2026, 9, 17))
        self.assertLess(salida.index("## 2026-09-17"), salida.index("## 2026-09-15"))

    def test_consolidado_separa_por_repo(self):
        uno = {"por_dia": {date(2026, 9, 17): _dia(prs=[PR_CON_ISSUE])}, "abiertos": [], "pr_abiertos": []}
        otro = {"por_dia": {date(2026, 9, 17): _dia(prs=[PR_SIN_ISSUE])}, "abiertos": [], "pr_abiertos": []}
        salida = bitacora.render({"Kallpasoft/uno": uno, "Kallpasoft/otro": otro},
                                 date(2026, 9, 17), date(2026, 9, 17))
        self.assertIn("### uno", salida)
        self.assertIn("### otro", salida)
        self.assertIn("# Bitácora — Kallpasoft", salida)


class TestPendientes(unittest.TestCase):
    def test_pr_sin_revision_y_draft_excluido(self):
        datos = {"por_dia": {}, "abiertos": [], "pr_abiertos": [
            {"number": 1, "title": "espera", "isDraft": False, "reviewDecision": None, "updatedAt": "2026-09-01T00:00:00Z"},
            {"number": 2, "title": "borrador", "isDraft": True, "reviewDecision": None, "updatedAt": "2026-09-01T00:00:00Z"},
            {"number": 3, "title": "ya aprobado", "isDraft": False, "reviewDecision": "APPROVED", "updatedAt": "2026-09-01T00:00:00Z"},
        ]}
        salida = "\n".join(bitacora.render_pendientes(datos))
        self.assertIn("- [ ] #1 espera", salida)
        self.assertNotIn("#2 borrador", salida)
        self.assertNotIn("#3 ya aprobado", salida)

    def test_merge_sin_issue_queda_para_revisar(self):
        datos = {"por_dia": {date(2026, 9, 17): _dia(prs=[PR_CON_ISSUE, PR_SIN_ISSUE])},
                 "abiertos": [], "pr_abiertos": []}
        salida = "\n".join(bitacora.render_pendientes(datos))
        self.assertIn("- [ ] #11 limpieza", salida)
        self.assertNotIn("#10 arregla algo", salida)

    def test_solo_issues_urgentes(self):
        datos = {"por_dia": {}, "pr_abiertos": [], "abiertos": [
            {"number": 5, "title": "urgente", "labels": [{"name": "sev:critico"}], "updatedAt": "2026-09-01T00:00:00Z"},
            {"number": 6, "title": "normal", "labels": [{"name": "bug"}], "updatedAt": "2026-09-01T00:00:00Z"},
        ]}
        salida = "\n".join(bitacora.render_pendientes(datos))
        self.assertIn("- [ ] #5 urgente · sev:critico", salida)
        self.assertNotIn("#6 normal", salida)

    def test_nada_pendiente(self):
        datos = {"por_dia": {}, "abiertos": [], "pr_abiertos": []}
        self.assertIn("Nada pendiente.", "\n".join(bitacora.render_pendientes(datos)))


if __name__ == "__main__":
    unittest.main(verbosity=2)
