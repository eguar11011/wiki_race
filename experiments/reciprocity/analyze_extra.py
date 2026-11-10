#!/usr/bin/env python3
"""Análisis complementario: solo lee results.csv y run_metadata.json. Sin red."""

import csv
import json
import os
import statistics as st
from math import sqrt

HERE = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(HERE, "results.csv"), newline="", encoding="utf-8") as handle:
    rows = list(csv.DictReader(handle))
meta = json.load(open(os.path.join(HERE, "run_metadata.json"), encoding="utf-8"))


def i(value):
    return int(value or 0)


def pct(values, q):
    values = sorted(values)
    pos = (len(values) - 1) * q
    low = int(pos)
    high = min(low + 1, len(values) - 1)
    return values[low] + (values[high] - values[low]) * (pos - low)


def stats(values):
    return (f"n={len(values)} media={st.mean(values):.3f} mediana={st.median(values):.3f} "
            f"desv={st.stdev(values):.3f} min={min(values):.3f} p10={pct(values,.1):.3f} "
            f"p25={pct(values,.25):.3f} p75={pct(values,.75):.3f} p90={pct(values,.9):.3f} max={max(values):.3f}")


def wilson(k, n, z=1.96):
    if n == 0:
        return (float("nan"), float("nan"))
    p = k / n
    d = 1 + z * z / n
    c = p + z * z / (2 * n)
    m = z * sqrt(p * (1 - p) / n + z * z / (4 * n * n))
    return ((c - m) / d, (c + m) / d)


def rank(values):
    order = sorted(range(len(values)), key=lambda x: values[x])
    ranks = [0.0] * len(values)
    pos = 0
    while pos < len(order):
        end = pos
        while end + 1 < len(order) and values[order[end + 1]] == values[order[pos]]:
            end += 1
        for k in range(pos, end + 1):
            ranks[order[k]] = (pos + end) / 2 + 1
        pos = end + 1
    return ranks


def spearman(a, b):
    x, y = rank(a), rank(b)
    mx, my = st.mean(x), st.mean(y)
    num = sum((p - mx) * (q - my) for p, q in zip(x, y))
    den = sqrt(sum((p - mx) ** 2 for p in x) * sum((q - my) ** 2 for q in y))
    return num / den


downloaded = [r for r in rows if r["latency_ms"]]
print("## Unidades")
print("filas_csv:", len(rows))
types = {}
for r in rows:
    types[r["row_type"]] = types.get(r["row_type"], 0) + 1
print("filas_por_tipo:", types)
print("descargas_registradas_csv:", len(downloaded), "metadata.downloads:", meta["downloads"])
repeated = sum(i(r["already_downloaded"]) for r in downloaded)
print("repetidas:", repeated, "unicas_derivadas:", len(downloaded) - repeated, "metadata.unique:", meta["unique_downloads"])
redirected = sum(i(r["redirected"]) for r in downloaded)
print("redirigidas:", redirected, "http_estimadas(descargas+redirigidas):", len(downloaded) + redirected, "metadata.http:", meta["http_requests"])
print("bytes_totales:", sum(i(r["bytes"]) for r in downloaded), "KB_por_descarga_mediana:", round(st.median([i(r["bytes"]) for r in downloaded]) / 1024, 1))
print("segundos:", meta["elapsed_seconds"], "ms_por_descarga_extremo_a_extremo:", round(meta["elapsed_seconds"] * 1000 / meta["downloads"], 1))
for t in sorted({r["row_type"] for r in downloaded}):
    group = [float(r["latency_ms"]) for r in downloaded if r["row_type"] == t]
    print(f"  {t}: descargas={len(group)} p50={st.median(group):.2f} p95={pct(group,.95):.2f}")
all_lat = [float(r["latency_ms"]) for r in downloaded]
print(f"latencia global p50={st.median(all_lat):.2f} p95={pct(all_lat,.95):.2f} max={max(all_lat):.2f}")

targets = {r["target_id"]: r for r in rows if r["row_type"] == "target"}
candidates = [r for r in rows if r["row_type"] == "candidate"]
pool = {r["target_title"]: r for r in rows if r["row_type"] == "selection_pool"}
print("\n## Candidatos")
print("suma_grados(C completo):", sum(i(t["out_degree"]) for t in targets.values()))
print("filas_candidate:", len(candidates), "no_examinados:", sum(1 for c in candidates if c["download_status"] == "not_examined"))
ok = [c for c in candidates if c["download_status"] == "ok"]
print("examinados_ok:", len(ok), "reciprocos:", sum(i(c["is_reciprocal"]) for c in ok))
print("candidatos_redirigidos:", sum(i(c["redirected"]) for c in ok),
      "tasa_si_redirigido:", round(sum(i(c["is_reciprocal"]) for c in ok if i(c["redirected"])) / max(1, sum(i(c["redirected"]) for c in ok)), 3),
      "tasa_si_no:", round(sum(i(c["is_reciprocal"]) for c in ok if not i(c["redirected"])) / sum(1 for c in ok if not i(c["redirected"])), 3))

records = []
for tid, t in sorted(targets.items()):
    group = [c for c in ok if c["target_id"] == tid]
    k = sum(i(c["is_reciprocal"]) for c in group)
    n = len(group)
    title = t["target_title"]
    records.append(dict(id=tid, title=title, k=k, n=n, rate=k / n, degree=i(t["out_degree"]), tertile=i(t["tertile"]),
                        redirected=i(pool[title]["redirected"]) if title in pool else -1, low=wilson(k, n)[0], high=wilson(k, n)[1]))

print("\n## Destinos que eran redirecciones")
for r in records:
    if r["redirected"]:
        print(" ", r["id"], r["title"], "tasa", round(r["rate"], 3), "k/n", r["k"], r["n"])
print("\n## Tasa por destino")
rates = [r["rate"] for r in records]
print("todos:", stats(rates))
direct = [r for r in records if not r["redirected"]]
print("sin_destinos_redirigidos:", stats([r["rate"] for r in direct]))
print("IC_Wilson: destinos con IC95 inferior >= 0.20:", sum(1 for r in records if r["low"] >= .20), "de", len(records))
print("histograma:", {f"{b/10:.1f}-{(b+1)/10:.1f}": sum(1 for x in rates if b / 10 <= x < (b + 1) / 10) for b in range(0, 8)})
print("Spearman grado-tasa (todos):", round(spearman([r["degree"] for r in records], rates), 3),
      "(sin redirigidos):", round(spearman([r["degree"] for r in direct], [r["rate"] for r in direct]), 3))
print("Grado total:", stats([float(r["degree"]) for r in records]))
for tertile in (1, 2, 3):
    group = [r["rate"] for r in records if r["tertile"] == tertile]
    print(f"tercil {tertile}:", stats(group))
print("menor_muestra (n<100):", [(r["id"], r["n"]) for r in records if r["n"] < 100])

print("\n## Rendimiento de candidatos")
print("reciprocos_por_destino:", stats([float(r["k"]) for r in records]))
print("descargas_por_reciproco:", stats([r["n"] / r["k"] for r in records if r["k"]]))
print("destinos con >=1 reciproco entre los primeros n candidatos:")
for n in (5, 10, 25, 50, 100):
    hit = 0
    for r in records:
        if any(i(c["is_reciprocal"]) for c in ok if c["target_id"] == r["id"] and i(c["sample_seq"]) <= n):
            hit += 1
    print(f"  n={n}: {hit}/{len(records)}")
print("cobertura_muestra_por_destino (n/grado):", stats([r["n"] / r["degree"] for r in records]))

print("\n## Tasa por posicion del enlace en la pagina T (cuartil de document_index / grado)")
for quarter in range(4):
    group = []
    for c in ok:
        degree = i(targets[c["target_id"]]["out_degree"])
        if int(i(c["document_index"]) * 4 / max(degree, 1)) == quarter:
            group.append(i(c["is_reciprocal"]))
    print(f"  Q{quarter + 1}: n={len(group)} tasa={sum(group) / len(group):.3f}")

print("\n## Pares")
pairs = sorted({r["pair_id"] for r in rows if r["row_type"] == "forward"})
reciprocal_titles = {}
for c in ok:
    if i(c["is_reciprocal"]):
        reciprocal_titles.setdefault(c["target_id"], set()).add(c["candidate_title"])
print("par,T,S,S_grado,S_en_C,S_en_B,L1,encuentro_idx,saltos_encuentro,en_B_directo,hits,hit2_idx")
for pair in pairs:
    source = next(r for r in rows if r["row_type"] == "source" and r["pair_id"] == pair)
    forward = sorted((r for r in rows if r["row_type"] == "forward" and r["pair_id"] == pair), key=lambda r: i(r["document_index"]))
    target_id = source["target_id"]
    encounter = next((r for r in forward if i(r["is_reciprocal"]) or i(r["reciprocal_links_hit"])), None)
    hops = "" if encounter is None else (2 if i(encounter["is_reciprocal"]) else 3)
    hit2 = next((i(r["document_index"]) for r in forward if i(r["links_to_target"])), "")
    in_b = source["candidate_title"] in reciprocal_titles.get(target_id, set())
    print(pair, target_id, source["candidate_title"], source["link_count"], source["in_target_links"], int(in_b), len(forward),
          "" if encounter is None else encounter["document_index"], hops,
          sum(i(r["is_reciprocal"]) for r in forward), sum(1 for r in forward if i(r["reciprocal_links_hit"])), hit2, sep=",")
