"""Chequeo mínimo: grafo sano → 0; multi-head y id duplicado → 1."""
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "check_migrations.py"


def _mig(d: Path, name: str, rev: str, down):
    (d / f"{name}.py").write_text(f'revision = "{rev}"\ndown_revision = {down!r}\n', encoding="utf-8")


def _run(d: Path) -> int:
    return subprocess.run([sys.executable, str(SCRIPT), str(d)], capture_output=True).returncode


class Test(unittest.TestCase):
    def test_grafo_sano(self):
        with tempfile.TemporaryDirectory() as t:
            d = Path(t); _mig(d, "a", "a1", None); _mig(d, "b", "b2", "a1")
            self.assertEqual(_run(d), 0)

    def test_multi_head(self):
        with tempfile.TemporaryDirectory() as t:
            d = Path(t); _mig(d, "a", "a1", None); _mig(d, "b", "b2", "a1"); _mig(d, "c", "c3", "a1")
            self.assertEqual(_run(d), 1)

    def test_id_duplicado(self):
        with tempfile.TemporaryDirectory() as t:
            d = Path(t); _mig(d, "a", "a1", None); _mig(d, "b", "b2", "a1"); _mig(d, "b_bis", "b2", "a1")
            self.assertEqual(_run(d), 1)

    def test_merge_con_tupla_no_es_raiz(self):
        with tempfile.TemporaryDirectory() as t:
            d = Path(t); _mig(d, "a", "a1", None); _mig(d, "b", "b2", "a1"); _mig(d, "c", "c3", "a1")
            (d / "m.py").write_text('revision = "m4"\ndown_revision = (\n    "b2",\n    "c3",\n)\n', encoding="utf-8")
            self.assertEqual(_run(d), 0)


if __name__ == "__main__":
    unittest.main()
