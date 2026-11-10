#!/usr/bin/env python3
"""Experimento acotado de reciprocidad de enlaces sobre el Kiwix local.

Uso (Python 3.9+, solo biblioteca estándar):

    python3 run_experiment.py selftest   # sin red
    python3 run_experiment.py run        # GET secuencial a 127.0.0.1:8080
    python3 run_experiment.py analyze    # recalcula los indicadores de results.csv

Solo hace peticiones GET a http://127.0.0.1:8080. No usa internet, no toca Docker
y solo escribe dentro de esta carpeta. `run` se niega a sobrescribir resultados.
No forma parte de ningún crawler: es una medición para una decisión de diseño.
"""

import csv
import http.client
import json
import os
import random
import statistics
import sys
import time
from html.parser import HTMLParser
from urllib.parse import quote, unquote, urljoin, urlsplit

HOST = "127.0.0.1"
PORT = 8080
BASE = f"http://{HOST}:{PORT}"
BOOK = "wikipedia_en_top_nopic"
PREFIX = f"/content/{BOOK}/"

SEED = 4218
HUB_SAMPLE = 12          # enlaces de la portada usados para formar el pool
PER_HUB_SAMPLE = 12      # enlaces tomados de cada uno de esos artículos
POOL_SIZE = 90           # artículos del pool cuyo grado de salida se mide
TARGETS_PER_TERTILE = 10 # 30 destinos estratificados por grado de salida
CANDIDATE_SAMPLE = 100   # candidatos examinados por destino
PAIRS = 15               # pares S-T para el análisis de la búsqueda directa
L1_CAP = 80              # enlaces de S descargados en cada par
MAX_DOWNLOADS = 5000     # tope duro de descargas
MAX_HTTP_REQUESTS = 6000 # tope duro de peticiones HTTP, con redirecciones y reintentos
MAX_SECONDS = 1500       # tope duro de tiempo
PAUSE_SECONDS = 0.005    # pausa entre peticiones; concurrencia 1
TIMEOUT_SECONDS = 10

HERE = os.path.dirname(os.path.abspath(__file__))
RESULTS = os.path.join(HERE, "results.csv")
METADATA = os.path.join(HERE, "run_metadata.json")

FIELDS = [
    "row_type", "pair_id", "target_id", "target_title", "candidate_id",
    "candidate_title", "sample_seq", "document_index", "download_status",
    "http_status", "redirected", "bytes", "latency_ms", "parse_ok", "link_count",
    "out_degree", "candidates_sampled", "tertile", "is_reciprocal", "in_target_links",
    "links_to_target", "reciprocal_links_hit", "already_downloaded",
]

RESOURCE_EXT = (".avif", ".css", ".eot", ".gif", ".ico", ".jpeg", ".jpg", ".js", ".json",
                ".mp3", ".mp4", ".ogg", ".ogv", ".pdf", ".png", ".svg", ".ttf", ".webm",
                ".webp", ".woff", ".woff2", ".xml")
NAMESPACES = {"file", "image", "category", "special", "help", "template", "talk", "user",
              "user_talk", "wikipedia", "wikipedia_talk", "portal", "mediawiki", "draft",
              "timedtext", "module", "book", "media"}


class LinkParser(HTMLParser):
    """Equivalente a Floki.attribute("a", "href"): solo <a> con href."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.hrefs = []

    def handle_starttag(self, tag, attrs):
        if tag == "a":
            for name, value in attrs:
                if name == "href" and value is not None:
                    self.hrefs.append(value)
                    break


def canonical(url):
    """Reproduce Verifier.canonical/1: decodifica la ruta y quita la barra final."""
    u = urlsplit(url)
    path = unquote(u.path, errors="replace").rstrip("/")
    port = ""
    if u.port and not ((u.scheme == "http" and u.port == 80) or (u.scheme == "https" and u.port == 443)):
        port = f":{u.port}"
    return f"{u.scheme}://{u.hostname}{port}{path}"


def resolve(href, base):
    """Reproduce Verifier.resolve/2 con urljoin en lugar de URI.merge."""
    if href.startswith(("#", "javascript:", "mailto:")):
        return None
    try:
        return canonical(urljoin(base, href))
    except ValueError:
        return None


def is_article(canon):
    prefix = BASE + PREFIX
    if not canon.startswith(prefix):
        return False
    title = canon[len(prefix):]
    if not title:
        return False
    lowered = title.lower()
    if lowered.split(":", 1)[0] in NAMESPACES:
        return False
    if lowered.endswith(RESOURCE_EXT):
        return False
    return True


def extract(body, base_url):
    """Devuelve la lista ordenada y sin repetidos de artículos enlazados."""
    parser = LinkParser()
    parser.feed(body.decode("utf-8", errors="replace"))
    parser.close()
    seen = {}
    for href in parser.hrefs:
        canon = resolve(href, base_url)
        if canon and is_article(canon) and canon not in seen:
            seen[canon] = True
    return list(seen)


def title_of(canon):
    return canon[len(BASE + PREFIX):]


def request_url(canon):
    return BASE + PREFIX + quote(title_of(canon), safe="/:@!$&'()*+,;=-._~")


class Budget(Exception):
    pass


class Client:
    def __init__(self):
        self.conn = None
        self.downloads = 0
        self.http_requests = 0
        self.started = time.monotonic()
        self.seen = set()

    def _connection(self):
        if self.conn is None:
            self.conn = http.client.HTTPConnection(HOST, PORT, timeout=TIMEOUT_SECONDS)
        return self.conn

    def _once(self, path):
        for attempt in (1, 2):
            if self.http_requests >= MAX_HTTP_REQUESTS or time.monotonic() - self.started > MAX_SECONDS:
                raise Budget()
            self.http_requests += 1
            try:
                conn = self._connection()
                conn.request("GET", path, headers={"Connection": "keep-alive"})
                response = conn.getresponse()
                body = response.read()
                return response.status, response.getheader("Location"), body
            except (http.client.HTTPException, OSError):
                if self.conn is not None:
                    self.conn.close()
                self.conn = None
                if attempt == 2:
                    raise

    def fetch(self, url):
        """Un GET con redirecciones, contado como una descarga. Base = URL pedida."""
        if urlsplit(url).hostname != HOST or urlsplit(url).port != PORT:
            raise ValueError(f"Destino no permitido: {url}")
        if self.downloads >= MAX_DOWNLOADS or time.monotonic() - self.started > MAX_SECONDS:
            raise Budget()
        self.downloads += 1
        if self.downloads % 200 == 0:
            print(f"  descargas={self.downloads} t={time.monotonic() - self.started:.0f}s", flush=True)
        already = 1 if url in self.seen else 0
        self.seen.add(url)
        started = time.perf_counter()
        result = {"already_downloaded": already, "redirected": 0, "http_status": "",
                  "bytes": 0, "download_status": "ok", "links": [], "parse_ok": 0}
        try:
            path = urlsplit(url).path
            status, location, body = self._once(path)
            hops = 0
            while status in (301, 302, 303, 307, 308) and location and hops < 5:
                hops += 1
                result["redirected"] = 1
                path = urlsplit(urljoin(BASE + path, location)).path
                status, location, body = self._once(path)
            result["http_status"] = status
            result["bytes"] = len(body)
            if status != 200:
                result["download_status"] = "http_error"
            elif not body:
                result["download_status"] = "empty"
        except (http.client.HTTPException, OSError, ValueError) as error:
            result["download_status"] = "network_error:" + type(error).__name__
            body = b""
        result["latency_ms"] = round((time.perf_counter() - started) * 1000, 2)
        if result["download_status"] == "ok":
            try:
                result["links"] = extract(body, url)
                result["parse_ok"] = 1
            except Exception as error:  # el experimento nunca debe abortar por una página
                result["download_status"] = "parse_error:" + type(error).__name__
        time.sleep(PAUSE_SECONDS)
        return result


def row(row_type, result=None, **extra):
    data = {field: "" for field in FIELDS}
    data["row_type"] = row_type
    if result is not None:
        for key in ("download_status", "http_status", "redirected", "bytes", "latency_ms",
                    "parse_ok", "already_downloaded"):
            data[key] = result.get(key, "")
        data["link_count"] = len(result.get("links", []))
    data.update(extra)
    return data


def select_targets(client, writer):
    rng = random.Random(SEED)
    main_url = BASE + f"/content/{BOOK}"
    main = client.fetch(main_url.rstrip("/") + "/")
    writer.writerow(row("selection_main", main, target_title="(portada)"))
    if len(main["links"]) < HUB_SAMPLE:
        raise SystemExit(f"Portada con solo {len(main['links'])} enlaces de artículo; se detiene.")
    pool = []
    for link in rng.sample(sorted(main["links"]), HUB_SAMPLE):
        hub = client.fetch(request_url(link))
        writer.writerow(row("selection_hub", hub, target_title=title_of(link)))
        links = sorted(hub["links"])
        pool.extend(rng.sample(links, min(PER_HUB_SAMPLE, len(links))))
    pool = sorted(set(pool))
    rng.shuffle(pool)
    measured = []
    for link in pool[:POOL_SIZE]:
        page = client.fetch(request_url(link))
        writer.writerow(row("selection_pool", page, target_title=title_of(link),
                            out_degree=len(page["links"])))
        if page["download_status"] == "ok" and page["links"]:
            measured.append((len(page["links"]), link, page["links"]))
    measured.sort(key=lambda item: (item[0], item[1]))
    third = len(measured) // 3
    tertiles = [measured[:third], measured[third:2 * third], measured[2 * third:]]
    chosen = []
    for index, tier in enumerate(tertiles, 1):
        for item in rng.sample(tier, min(TARGETS_PER_TERTILE, len(tier))):
            chosen.append((index, item))
    rng.shuffle(chosen)
    remaining = [item for item in measured if item[1] not in {c[1][1] for c in chosen}]
    return chosen, remaining


def examine_target(client, writer, target_id, tertile, target, links):
    canon_links = [link for link in links if link != target]
    rng = random.Random(f"{SEED}:{target}")
    order = sorted(canon_links)
    rng.shuffle(order)
    sampled = order[:CANDIDATE_SAMPLE]
    position = {link: index for index, link in enumerate(canon_links)}
    reciprocal = set()
    examined = 0
    title = title_of(target)
    for seq, candidate in enumerate(sampled, 1):
        page = client.fetch(request_url(candidate))
        examined += 1
        is_reciprocal = 1 if page["download_status"] == "ok" and target in set(page["links"]) else 0
        if is_reciprocal:
            reciprocal.add(candidate)
        writer.writerow(row("candidate", page, target_id=target_id, target_title=title,
                            candidate_id=f"{target_id}-{seq}", candidate_title=title_of(candidate),
                            sample_seq=seq, document_index=position[candidate],
                            is_reciprocal=is_reciprocal, tertile=tertile))
    for seq, candidate in enumerate(order[CANDIDATE_SAMPLE:], CANDIDATE_SAMPLE + 1):
        writer.writerow(row("candidate", None, target_id=target_id, target_title=title,
                            candidate_id=f"{target_id}-{seq}", candidate_title=title_of(candidate),
                            sample_seq=seq, document_index=position[candidate],
                            download_status="not_examined", tertile=tertile))
    writer.writerow(row("target", None, target_id=target_id, target_title=title, tertile=tertile,
                        out_degree=len(canon_links), candidates_sampled=examined))
    return reciprocal, set(canon_links)


def examine_pair(client, writer, pair_id, target_id, source, target, reciprocal, target_links):
    start = client.fetch(request_url(source))
    writer.writerow(row("source", start, pair_id=pair_id, target_id=target_id,
                        target_title=title_of(target), candidate_title=title_of(source),
                        links_to_target=1 if target in set(start["links"]) else 0,
                        in_target_links=1 if source in target_links else 0))
    first_level = [link for link in start["links"] if link != source][:L1_CAP]
    for index, link in enumerate(first_level, 1):
        page = client.fetch(request_url(link))
        links = set(page["links"])
        writer.writerow(row("forward", page, pair_id=pair_id, target_id=target_id,
                            target_title=title_of(target), candidate_title=title_of(link),
                            document_index=index,
                            in_target_links=1 if link in target_links else 0,
                            is_reciprocal=1 if link in reciprocal else 0,
                            links_to_target=1 if target in links else 0,
                            reciprocal_links_hit=len(links & reciprocal)))


def run():
    if os.path.exists(RESULTS):
        raise SystemExit("results.csv ya existe; no se sobrescribe. Muévelo para repetir.")
    client = Client()
    stopped_by = "completed"
    targets_done = pairs_done = 0
    with open(RESULTS, "x", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=FIELDS)
        writer.writeheader()
        try:
            chosen, remaining = select_targets(client, writer)
            print(f"Destinos elegidos: {len(chosen)}", flush=True)
            rng = random.Random(f"{SEED}:pairs")
            sources = sorted(item[1] for item in remaining)
            for number, (tertile, (_, target, links)) in enumerate(chosen, 1):
                target_id = f"T{number:02d}"
                reciprocal, target_links = examine_target(client, writer, target_id, tertile, target, links)
                targets_done += 1
                handle.flush()
                if number <= PAIRS and sources:
                    source = rng.choice([s for s in sources if s != target])
                    examine_pair(client, writer, f"P{number:02d}", target_id, source, target,
                                 reciprocal, target_links)
                    pairs_done += 1
                    handle.flush()
                print(f"{target_id} {title_of(target)[:40]}: recíprocos={len(reciprocal)}", flush=True)
        except Budget:
            stopped_by = "budget"
    metadata = {
        "seed": SEED, "book": BOOK, "base": BASE, "pool_size": POOL_SIZE,
        "targets_per_tertile": TARGETS_PER_TERTILE, "candidate_sample": CANDIDATE_SAMPLE,
        "pairs": PAIRS, "l1_cap": L1_CAP, "max_downloads": MAX_DOWNLOADS,
        "max_seconds": MAX_SECONDS, "pause_seconds": PAUSE_SECONDS, "concurrency": 1,
        "timeout_seconds": TIMEOUT_SECONDS, "downloads": client.downloads,
        "max_http_requests": MAX_HTTP_REQUESTS, "http_requests": client.http_requests,
        "unique_downloads": len(client.seen), "targets_done": targets_done,
        "pairs_done": pairs_done, "stopped_by": stopped_by,
        "elapsed_seconds": round(time.monotonic() - client.started, 1),
        "python": sys.version.split()[0],
    }
    with open(METADATA, "x", encoding="utf-8") as handle:
        json.dump(metadata, handle, indent=2, ensure_ascii=False)
    print(json.dumps(metadata, indent=2, ensure_ascii=False))


# ---------- análisis: solo lee results.csv ----------

def percentile(values, q):
    values = sorted(values)
    if not values:
        return float("nan")
    index = (len(values) - 1) * q
    low = int(index)
    high = min(low + 1, len(values) - 1)
    return values[low] + (values[high] - values[low]) * (index - low)


def describe(values):
    if not values:
        return "n=0"
    return (f"n={len(values)} min={min(values):.3g} p25={percentile(values, .25):.3g} "
            f"mediana={statistics.median(values):.3g} media={statistics.mean(values):.3g} "
            f"p75={percentile(values, .75):.3g} p90={percentile(values, .9):.3g} max={max(values):.3g}")


def bootstrap_median(values, repetitions=2000):
    rng = random.Random(SEED)
    medians = sorted(statistics.median(rng.choices(values, k=len(values))) for _ in range(repetitions))
    return percentile(medians, .025), percentile(medians, .975)


def analyze():
    with open(RESULTS, newline="", encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))
    downloaded = [r for r in rows if r["latency_ms"]]
    print("## Descargas")
    print(f"filas={len(rows)} descargas={len(downloaded)} bytes={sum(int(r['bytes'] or 0) for r in downloaded)}")
    latencies = [float(r["latency_ms"]) for r in downloaded]
    print("latencia_ms:", describe(latencies), f"p95={percentile(latencies, .95):.3g}")
    status = {}
    for r in downloaded:
        status[r["download_status"]] = status.get(r["download_status"], 0) + 1
    print("estados:", status, "redirigidas:", sum(int(r["redirected"] or 0) for r in downloaded),
          "repetidas:", sum(int(r["already_downloaded"] or 0) for r in downloaded))
    targets = {r["target_id"]: r for r in rows if r["row_type"] == "target"}
    candidates = [r for r in rows if r["row_type"] == "candidate"]
    print("\n## Grado de salida de los destinos")
    degrees = [int(r["out_degree"]) for r in targets.values()]
    print(describe(degrees))
    print("\n## Reciprocidad por destino (denominador: candidatos descargados con éxito)")
    per_target = []
    print("target,titulo,tertil,grado,examinados,exitosos,reciprocos,tasa,no_examinados")
    for target_id in sorted(targets):
        group = [c for c in candidates if c["target_id"] == target_id]
        examined = [c for c in group if c["download_status"] != "not_examined"]
        ok = [c for c in examined if c["download_status"] == "ok"]
        reciprocal = sum(int(c["is_reciprocal"] or 0) for c in ok)
        rate = reciprocal / len(ok) if ok else float("nan")
        per_target.append((target_id, rate, reciprocal, len(ok), int(targets[target_id]["out_degree"]),
                           int(targets[target_id]["tertile"])))
        print(f"{target_id},{targets[target_id]['target_title']},{targets[target_id]['tertile']},"
              f"{targets[target_id]['out_degree']},{len(examined)},{len(ok)},{reciprocal},{rate:.3f},"
              f"{len(group) - len(examined)}")
    rates = [p[1] for p in per_target if p[3]]
    print("\ntasa_por_destino:", describe(rates), "IC95_mediana(bootstrap):", tuple(round(v, 3) for v in bootstrap_median(rates)))
    counts = [p[2] for p in per_target]
    print("reciprocos_por_destino:", describe(counts))
    total_ok = sum(p[3] for p in per_target)
    print(f"tasa_agregada_muestra={sum(counts) / total_ok:.3f} (reciprocos={sum(counts)} / exitosos={total_ok})")
    print("destinos con >=1, >=5, >=10, >=20 recíprocos:", [sum(1 for c in counts if c >= n) for n in (1, 5, 10, 20)], "de", len(counts))
    costs = [p[3] / p[2] for p in per_target if p[2]]
    print("descargas_por_reciproco (destinos con al menos uno):", describe(costs))
    for tertile in (1, 2, 3):
        print(f"tertil {tertile}: tasa", describe([p[1] for p in per_target if p[5] == tertile and p[3]]))
    print("\n## Sensibilidad al tamaño de muestra (primeros n candidatos del orden aleatorio)")
    for n in (10, 25, 50, 75, 100):
        values = []
        for target_id in targets:
            group = [c for c in candidates if c["target_id"] == target_id and c["download_status"] == "ok" and int(c["sample_seq"]) <= n]
            if group:
                values.append(sum(int(c["is_reciprocal"]) for c in group) / len(group))
        print(f"n={n}:", describe(values))
    print("\n## Pares S-T (coste en descargas, limitado a los primeros enlaces de S)")
    pair_ids = sorted({r["pair_id"] for r in rows if r["row_type"] == "forward"})
    print("par,destino,L1,L1_en_C,salto_directo,bfs_2,prioridad_2,encuentro,candidatos,coste_A_encuentro")
    bfs, priority, meet = [], [], []
    for pair_id in pair_ids:
        forward = sorted((r for r in rows if r["row_type"] == "forward" and r["pair_id"] == pair_id), key=lambda r: int(r["document_index"]))
        source = next(r for r in rows if r["row_type"] == "source" and r["pair_id"] == pair_id)
        target_id = source["target_id"]
        examined = int(targets[target_id]["candidates_sampled"])
        hit = next((i for i, r in enumerate(forward, 1) if int(r["links_to_target"] or 0)), None)
        ordered = sorted(forward, key=lambda r: -int(r["in_target_links"] or 0))
        prioritized = next((i for i, r in enumerate(ordered, 1) if int(r["links_to_target"] or 0)), None)
        encounter = next((i for i, r in enumerate(forward, 1) if int(r["is_reciprocal"] or 0) or int(r["reciprocal_links_hit"] or 0)), None)
        direct = int(source["links_to_target"] or 0)
        cost = "" if encounter is None else 2 + examined + encounter
        print(f"{pair_id},{target_id},{len(forward)},{sum(int(r['in_target_links'] or 0) for r in forward)},{direct},{hit},{prioritized},{encounter},{examined},{cost}")
        if hit is not None:
            bfs.append(1 + hit)
        if prioritized is not None:
            priority.append(2 + prioritized)
        if encounter is not None:
            meet.append(cost)
    print("bfs_2 (S + L1 hasta llegar a T):", describe(bfs))
    print("prioridad_2 (T + S + L1 con L1∩C primero):", describe(priority))
    print("encuentro_A (T + S + candidatos + L1 hasta tocar B):", describe(meet))
    print(f"pares con ruta 2 saltos={len(bfs)}, con encuentro={len(meet)}, de {len(pair_ids)}")


def selftest():
    page = (b'<html><body><a href="Foo_bar">a</a><a href="Foo_bar#x">b</a>'
            b'<a href="#top">c</a><a href="javascript:x()">d</a><area href="Nope">'
            b'<a href="./Caf%C3%A9">e</a><a href="File:X.png">f</a><a href="Category:Y">g</a>'
            b'<a href="http://other.example/z">h</a><a>sin</a><A HREF="Mayus">i</A></body></html>')
    base = BASE + PREFIX + "Page"
    links = [title_of(link) for link in extract(page, base)]
    assert links == ["Foo_bar", "Café", "Mayus"], links
    assert canonical("http://h:8080/a%20b/?q=1#f") == "http://h:8080/a b"
    assert canonical("http://h:80/a/") == "http://h/a"
    assert resolve("#x", base) is None
    assert resolve("mailto:a@b", base) is None
    assert is_article(BASE + PREFIX + "Tiger") and not is_article(BASE + PREFIX + "Help:Foo")
    assert not is_article(BASE + "/content/otro/Tiger") and not is_article(BASE + PREFIX + "a.png")
    assert title_of(canonical(request_url(BASE + PREFIX + "Café (x)"))) == "Café (x)"
    first = random.Random(f"{SEED}:x").sample(range(100), 5)
    assert first == random.Random(f"{SEED}:x").sample(range(100), 5)
    assert abs(percentile([1, 2, 3, 4], .5) - 2.5) < 1e-9
    client = Client()
    for bad in ("http://example.org/x", "http://127.0.0.1:9999/x", "https://en.wikipedia.org:8080/x"):
        try:
            client.fetch(bad)
            raise AssertionError(bad)
        except ValueError:
            pass
    assert client.downloads == 0 and client.http_requests == 0
    capped = Client()
    capped.downloads = MAX_DOWNLOADS
    try:
        capped.fetch(BASE + PREFIX + "Tiger")
        raise AssertionError("sin tope de descargas")
    except Budget:
        pass
    capped = Client()
    capped.http_requests = MAX_HTTP_REQUESTS
    try:
        capped._once("/content/x")
        raise AssertionError("sin tope de peticiones")
    except Budget:
        pass
    late = Client()
    late.started -= MAX_SECONDS + 1
    try:
        late.fetch(BASE + PREFIX + "Tiger")
        raise AssertionError("sin tope de tiempo")
    except Budget:
        pass
    print("selftest OK")


if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    if command == "run":
        run()
    elif command == "analyze":
        analyze()
    elif command == "selftest":
        selftest()
    else:
        raise SystemExit(__doc__)
