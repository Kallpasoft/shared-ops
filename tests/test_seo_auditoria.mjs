// Prueba de seo-auditoria.mjs contra un sitio de ejemplo servido en localhost.
// Corre con: node tests/test_seo_auditoria.mjs
import http from "node:http";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import assert from "node:assert/strict";


const pagina = ({ titulo, h1 = 1, extra = "", links = [] }) => `<!doctype html><html><head><title>${titulo}</title>
<meta name="description" content="${"Descripción de prueba con largo suficiente para no salir marcada como corta por el auditor. ".slice(0, 120)}">
<link rel="canonical" href="BASE${extra.includes("canon-mal") ? "/otra" : "SELF"}">${extra.includes("noindex") ? '<meta name="robots" content="noindex">' : ""}
<script type="application/ld+json">{"@type":"Article"${extra.includes("autor") ? ',"author":{"@type":"Person","name":"X"}' : ""}}</script></head>
<body>${"<h1>t</h1>".repeat(h1)}<p>${"palabra ".repeat(400)}</p><img src="a.png" alt=""><img src="b.png">
${links.map((l) => `<a href="${l}">l</a>`).join("")}</body></html>`;

const rutas = {
  "/": { titulo: "Inicio del sitio de prueba con título", extra: "autor", links: ["/bien", "/mal", "/roto", "/viejo"] },
  "/bien": { titulo: "Página bien hecha del sitio de prueba", extra: "autor", links: ["/"] },
  "/mal": { titulo: "Página con problemas del sitio de prueba", h1: 2, extra: "noindex canon-mal", links: ["/"] },
};
const server = http.createServer((req, res) => {
  const base = `http://127.0.0.1:${server.address().port}`;
  if (req.url === "/sitemap.xml") return res.end(`<urlset>${Object.keys(rutas).map((r) => `<loc>${base}${r}</loc>`).join("")}</urlset>`);
  if (req.url === "/robots.txt") return res.end("User-agent: GPTBot\nDisallow: /\n");
  if (req.url === "/viejo") { res.writeHead(302, { location: "/bien" }); return res.end(); }
  const r = rutas[req.url];
  if (!r) { res.writeHead(404); return res.end(); }
  res.setHeader("content-type", "text/html");
  res.end(pagina(r).replace("BASE", base).replace("SELF", req.url === "/" ? "" : req.url));
});
await new Promise((ok) => server.listen(0, "127.0.0.1", ok));
const base = `http://127.0.0.1:${server.address().port}`;
const out = fs.mkdtempSync(path.join(os.tmpdir(), "seo-"));
const script = new URL("../seo-auditoria.mjs", import.meta.url).pathname;
// Un hijo síncrono bloquearía el servidor de este mismo proceso: se corre asíncrono.
const { spawn } = await import("node:child_process");
const code = await new Promise((ok) => spawn(process.execPath, [script, base, "--out", out], { stdio: "ignore" }).on("exit", ok));
server.close();

const r = JSON.parse(fs.readFileSync(path.join(out, "resultado.json"), "utf8"));
const p = r.problemas;
assert.equal(code, 2, "con problemas sale 2");
assert.equal(r.total, 3);
assert.deepEqual(p.noindex_meta, [`${base}/mal`]);
assert.equal(p.h1_cantidad.length, 1);
assert.match(p.canonical_no_propia[0], /\/mal/);
assert.ok(p.enlace_roto.some((x) => x.includes("/roto")));
assert.ok(p.redireccion_temporal.some((x) => x.includes("/viejo")));
assert.ok(p.articulo_sin_autor.includes(`${base}/mal`));
assert.equal(p.img_sin_alt.length, 3, "alt ausente sí, alt vacío (decorativa) no");
assert.ok(!p.huerfana, "todas reciben enlaces");
assert.ok(r.robots_ia.includes("GPTBot: BLOQUEADO"));
console.log("ok");
