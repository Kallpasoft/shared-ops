#!/usr/bin/env node
// Auditoría SEO on-page por crawler: recorre las URLs del sitemap y revisa lo que se puede
// ver en el HTML servido (sin Search Console). Solo stdlib de Node >= 18.
//
//   node seo-auditoria.mjs <https://sitio> [--out <dir>]
//
// Escribe <dir>/resultado.json (problemas por tipo) y <dir>/paginas.json (datos por URL).
// Sale con 0 (sin problemas), 2 (hay problemas) o 1 (error).
import fs from "node:fs";
import path from "node:path";
const args = process.argv.slice(2);
const BASE = (args.find((a) => /^https?:\/\//.test(a)) ?? "").replace(/\/$/, "");
const OUT = args.includes("--out") ? args[args.indexOf("--out") + 1] : ".";
if (!BASE) { console.error("uso: seo-auditoria.mjs <https://sitio> [--out <dir>]"); process.exit(1); }
const host = new URL(BASE).host;
const UA = "Mozilla/5.0 (compatible; KallpaSEOAudit/1.0)";
const get = (u, redirect = "manual") => fetch(u, { redirect, headers: { "user-agent": UA } });
const strip = (s) => s.replace(/<script[\s\S]*?<\/script>|<style[\s\S]*?<\/style>/gi, " ").replace(/<[^>]+>/g, " ").replace(/&[a-z#0-9]+;/gi, " ").replace(/\s+/g, " ").trim();
const attr = (tag, a) => (tag.match(new RegExp(`\\b${a}\\s*=\\s*"([^"]*)"`, "i")) || [])[1];

const sm = await (await get(BASE + "/sitemap.xml", "follow")).text();
const urls = [...sm.matchAll(/<loc>([^<]+)<\/loc>/g)].map((m) => m[1].trim());
const pages = {}, linksTo = {}, statusCache = {};

async function status(u) {
  if (statusCache[u]) return statusCache[u];
  let hops = 0, cur = u, codes = [];
  while (hops < 6) { const r = await get(cur); codes.push(r.status); if (r.status >= 300 && r.status < 400) { cur = new URL(r.headers.get("location"), cur).href; hops++; } else break; }
  return (statusCache[u] = { codes, final: cur });
}

const pool = async (items, n, fn) => { const q = [...items]; await Promise.all(Array.from({ length: n }, async () => { while (q.length) await fn(q.shift()); })); };

await pool(urls, 8, async (u) => {
  const r = await get(u);
  const p = { url: u, status: r.status, xrobots: r.headers.get("x-robots-tag") };
  pages[u] = p;
  if (r.status !== 200) { p.location = r.headers.get("location"); return; }
  const h = await r.text();
  const head = h.split(/<\/head>/i)[0];
  p.titles = [...head.matchAll(/<title[^>]*>([\s\S]*?)<\/title>/gi)].map((m) => strip(m[1]));
  const metas = [...head.matchAll(/<meta\b[^>]*>/gi)].map((m) => m[0]);
  p.desc = metas.filter((m) => /name="description"/i.test(m)).map((m) => attr(m, "content"));
  p.robots = metas.filter((m) => /name="robots"/i.test(m)).map((m) => attr(m, "content"));
  p.canon = [...h.matchAll(/<link\b[^>]*rel="canonical"[^>]*>/gi)].map((m) => attr(m[0], "href"));
  p.h1 = (h.match(/<h1\b/gi) || []).length;
  const imgs = [...h.matchAll(/<img\b[^>]*>/gi)].map((m) => m[0]);
  p.imgs = imgs.length; p.imgSinAlt = imgs.filter((t) => attr(t, "alt") == null).length;
  const ld = [...h.matchAll(/<script[^>]*application\/ld\+json[^>]*>([\s\S]*?)<\/script>/gi)].map((m) => m[1]);
  p.ldTypes = []; p.ldAutor = false; p.ldError = 0; // ldAutor: algún nodo con `author`
  for (const j of ld) { try { const walk = (o) => { if (Array.isArray(o)) return o.forEach(walk); if (o && typeof o === "object") { if (o["@type"]) p.ldTypes.push([].concat(o["@type"]).join("|")); if (o.author) p.ldAutor = true; Object.values(o).forEach(walk); } }; walk(JSON.parse(j)); } catch { p.ldError++; } }
  const body = h.split(/<body[^>]*>/i)[1] || "";
  p.palabras = strip(body.replace(/<(header|footer|nav)\b[\s\S]*?<\/\1>/gi, " ")).split(" ").length;
  p.links = [...new Set([...body.matchAll(/<a\b[^>]*href="([^"#]+)/gi)].map((m) => { try { return new URL(m[1], u).href.replace(/#.*$/, ""); } catch { return null; } }).filter((x) => x && new URL(x).host === host))];
  for (const l of p.links) (linksTo[l] ??= new Set()).add(u);
});

// estado de cada enlace interno
const allLinks = [...new Set(Object.values(pages).flatMap((p) => p.links || []))];
await pool(allLinks, 8, status);

const norm = (u) => u.replace(/\/$/, "");
const out = { total: urls.length, problemas: {} };
const add = (k, v) => (out.problemas[k] ??= []).push(v);
const titles = {}, descs = {};
for (const p of Object.values(pages)) {
  if (p.status !== 200) { add("sitemap_no_200", `${p.url} → ${p.status} ${p.location ?? ""}`); continue; }
  if (p.xrobots && /noindex/i.test(p.xrobots)) add("noindex_header", p.url);
  if (p.robots.some((r) => /noindex/i.test(r))) add("noindex_meta", p.url);
  if (p.canon.length !== 1) add("canonical_cantidad", `${p.url} (${p.canon.length})`);
  else if (norm(p.canon[0]) !== norm(p.url)) add("canonical_no_propia", `${p.url} → ${p.canon[0]}`);
  if (p.titles.length !== 1) add("title_cantidad", `${p.url} (${p.titles.length})`);
  const t = p.titles[0] ?? ""; if (t.length > 65 || t.length < 25) add("title_largo", `${t.length} · ${p.url} · ${t}`);
  (titles[t] ??= []).push(p.url);
  const d = p.desc[0] ?? ""; if (!d) add("desc_falta", p.url); else if (d.length > 160 || d.length < 70) add("desc_largo", `${d.length} · ${p.url}`);
  (descs[d] ??= []).push(p.url);
  if (p.h1 !== 1) add("h1_cantidad", `${p.url} (${p.h1})`);
  if (p.imgSinAlt) add("img_sin_alt", `${p.url} (${p.imgSinAlt}/${p.imgs})`);
  if (p.ldError) add("jsonld_invalido", p.url);
  if (!p.ldTypes.length) add("jsonld_falta", p.url);
  if (p.ldTypes.some((t) => /Article/.test(t)) && !p.ldAutor) add("articulo_sin_autor", p.url);
  if (p.palabras < 300) add("contenido_corto", `${p.palabras} · ${p.url}`);
  if (/[A-Z_]|[^\x00-\x7f]|\?/.test(new URL(p.url).pathname + new URL(p.url).search)) add("url_sucia", p.url);
  for (const l of p.links) { const s = statusCache[l]; if (!s) continue; const last = s.codes.at(-1);
    if (last >= 400) add("enlace_roto", `${p.url} → ${l} (${last})`);
    else if (s.codes.length > 1) add(s.codes.length > 2 ? "enlace_cadena" : "enlace_a_redireccion", `${p.url} → ${l} (${s.codes.join("→")})`);
    if (s.codes.some((c) => c === 302 || c === 307)) add("redireccion_temporal", `${l} (${s.codes.join("→")})`); }
}
for (const [t, us] of Object.entries(titles)) if (us.length > 1) add("title_duplicado", `${t} ×${us.length}`);
for (const [d, us] of Object.entries(descs)) if (d && us.length > 1) add("desc_duplicada", `${d.slice(0, 60)}… ×${us.length}`);
for (const u of urls) if (norm(u) !== norm(BASE) && !(linksTo[u]?.size || linksTo[norm(u)]?.size || linksTo[u + "/"]?.size)) add("huerfana", u);
const entrantes = urls.map((u) => [linksTo[u]?.size ?? 0, u]).sort((a, b) => a[0] - b[0]);
out.menos_enlazadas = entrantes.slice(0, 12).map(([n, u]) => `${n} · ${u}`);
for (const k in out.problemas) out.problemas[k] = [...new Set(out.problemas[k])];
// variantes de host: cada una debe llegar a BASE en un solo 301/308
const apex = host.replace(/^www\./, "");
for (const v of [`http://${apex}/`, `http://www.${apex}/`, `https://www.${apex}/`, `https://${apex}/`]) {
  if (norm(v) === norm(BASE)) continue;
  try { const s = await status(v); out[`host ${v}`] = s.codes.join("→") + " " + s.final;
    if (s.codes.length > 2 || ![301, 308].includes(s.codes[0])) add("host_cadena", `${v} (${s.codes.join("→")})`);
  } catch { /* el host no resuelve: no es un problema de esta auditoría */ }
}
const rob = await (await get(BASE + "/robots.txt", "follow")).text();
out.robots_ia = ["GPTBot", "OAI-SearchBot", "ChatGPT-User", "PerplexityBot", "Google-Extended", "ClaudeBot"].map((b) => `${b}: ${new RegExp(`User-agent:\\s*${b}[\\s\\S]*?Disallow:\\s*/\\s`, "i").test(rob) ? "BLOQUEADO" : "ok"}`);
out.llms_txt = (await get(BASE + "/llms.txt")).status;
fs.mkdirSync(OUT, { recursive: true });
fs.writeFileSync(path.join(OUT, "paginas.json"), JSON.stringify(pages, null, 1));
fs.writeFileSync(path.join(OUT, "resultado.json"), JSON.stringify(out, null, 1));
const res = Object.fromEntries(Object.entries(out.problemas).map(([k, v]) => [k, v.length]));
console.log(JSON.stringify({ total: out.total, conteo: res, hosts: Object.fromEntries(Object.entries(out).filter(([k]) => k.startsWith("host"))), robots_ia: out.robots_ia, llms: out.llms_txt }, null, 1));
process.exit(Object.keys(res).length ? 2 : 0);
