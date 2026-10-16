#!/usr/bin/env python3
"""Raport dla Konrada: wzór / przed / po + wynik recenzji. Użycie: raport.py <katalog_praca>"""
import html
import json
import re
import sys
from pathlib import Path

praca = Path(sys.argv[1])
zrzuty = praca / "zrzuty"
e = html.escape


def czytaj(p, domyslnie=""):
    try:
        return Path(p).read_text(encoding="utf-8")
    except OSError:
        return domyslnie


zadanie = czytaj(praca / "ZADANIE.txt").strip()
plan = czytaj(praca / "PLAN.md")
dziennik = czytaj(praca / "DZIENNIK.md")


def sekcja(tekst, nazwa):
    m = re.search(r"^##\s+" + re.escape(nazwa) + r"\s*$(.*?)(?=^##\s|\Z)", tekst, re.M | re.S)
    if not m:
        return ""
    return re.sub(r"<!--.*?-->", "", m.group(1), flags=re.S).strip()


kryteria = [l.lstrip("-* ").strip() for l in sekcja(plan, "KRYTERIA ODBIORU").splitlines() if l.strip()]
kierunek = sekcja(plan, "WZÓR I KIERUNEK")
if kierunek.lower().startswith("nie dotyczy"):
    kierunek = ""

# ranking pomysłów (jeśli był)
ranking_md = czytaj(praca / "RANKING.md")
ranking_wiersze = [w for w in re.findall(r"^\|\s*(\d+)\s*\|(.+?)\|(.+?)\|(.+?)\|\s*$", ranking_md, re.M)]
m_rek = re.search(r"^\*\*Rekomendacja do wdrożenia teraz:\*\*\s*(.+)$", ranking_md, re.M)
rekomendacja = m_rek.group(1).strip() if m_rek else ""
zakres = sekcja(plan, "ZAKRES")

naglowki = re.findall(r"^## (PLAN|KOD) – runda (\d+)/(\d+): (ZIELONE|CZERWONE)(.*)$", dziennik, re.M)
kod = [n for n in naglowki if n[0] == "KOD"]
plany = [n for n in naglowki if n[0] == "PLAN"]
if kod:
    ostatni = kod[-1]
    zielone = ostatni[3] == "ZIELONE"
    status = "Recenzja GPT: zielone światło" if zielone else "Recenzja GPT: są nierozwiązane uwagi"
else:
    zielone = None
    status = "Bez recenzji kodu"
rundy = f"Plan: {len(plany)} rund recenzji · Kod: {len(kod)} rund recenzji"

# ostatnie uwagi drobne / odrzucone z dziennika (ostatni blok KOD)
ostatni_blok = ""
if kod:
    bloki = re.split(r"(?=^## )", dziennik, flags=re.M)
    kodowe = [b for b in bloki if b.startswith("## KOD")]
    ostatni_blok = kodowe[-1] if kodowe else ""
drobne = re.findall(r"^- (R\d+-d\d+ .*)$", ostatni_blok, re.M)
podsumowanie_gpt = ""
m = re.search(r"^Recenzent: (.*)$", ostatni_blok, re.M)
if m:
    podsumowanie_gpt = m.group(1)


def wyniki(etap):
    try:
        d = json.loads(czytaj(zrzuty / etap / "wynik.json", "{}"))
        return {(p["nazwa"], p["widok"]): p for p in d.get("strony", [])}
    except json.JSONDecodeError:
        return {}


po_wyniki = wyniki("po")


def obraz(etap, plik, podpis):
    sciezka = zrzuty / etap / plik
    if not sciezka.exists():
        return f'<figure class="brak"><div>brak zrzutu</div><figcaption>{e(podpis)}</figcaption></figure>'
    rel = f"zrzuty/{etap}/{plik}"
    return (f'<figure><a href="{e(rel)}" target="_blank"><img src="{e(rel)}" loading="lazy" alt="{e(podpis)}"></a>'
            f"<figcaption>{e(podpis)}</figcaption></figure>")


def kontrola(nazwa, widok):
    p = po_wyniki.get((nazwa, widok))
    if not p:
        return ""
    problemy = []
    if p.get("blad"):
        problemy.append("nie załadowała się")
    if p.get("poziomyScroll"):
        problemy.append("poziomy scroll")
    if p.get("bledyStrony"):
        problemy.append(f"błędy JavaScript: {len(p['bledyStrony'])}")
    if p.get("niskiKontrastLiczba"):
        problemy.append(f"niski kontrast: {p['niskiKontrastLiczba']}")
    if not problemy:
        return '<span class="ok">✓ kontrola automatyczna bez uwag</span>'
    return '<span class="uw">⚠ ' + e(", ".join(problemy)) + "</span>"


# --- wzory
wzory_html = ""
if (zrzuty / "wzor").exists():
    nazwy = sorted({p.name.rsplit("-", 1)[0] for p in (zrzuty / "wzor").glob("*.png")})
    adresy = {}
    for l in czytaj(praca / "wzory.txt").splitlines():
        if l.strip():
            n, _, u = l.partition(" ")
            adresy[n] = u.strip()
    for n in nazwy:
        wzory_html += (f'<div class="para"><h3>{e(adresy.get(n, n))}</h3><div class="rzad wzor">'
                       f'{obraz("wzor", n + "-komputer.png", "komputer")}{obraz("wzor", n + "-telefon.png", "telefon")}</div></div>')

# --- strony aplikacji
strony = []
for l in czytaj(praca / "STRONY.txt").splitlines():
    l = l.strip()
    if l and not l.startswith("#"):
        nazwa = re.sub(r"[^a-zA-Z0-9_-]", "-", l.split()[0])
        strony.append(nazwa)

porownania = ""
for n in strony:
    porownania += f'<section class="strona"><h3>{e(n)}</h3>'
    for widok, etykieta in (("komputer", "Komputer"), ("telefon", "Telefon")):
        porownania += (f'<div class="widok"><div class="widok-tyt">{etykieta} {kontrola(n, widok)}</div>'
                       f'<div class="rzad {"waski" if widok == "telefon" else ""}">'
                       f'{obraz("przed", f"{n}-{widok}.png", "przed")}{obraz("po", f"{n}-{widok}.png", "po")}</div></div>')
    porownania += "</section>"

ranking_html = ""
if ranking_wiersze:
    wiersze = "".join(
        f"<tr><td>{e(a)}</td><td>{e(b.strip())}</td><td>{e(c.strip())}</td><td>{e(d.strip())}</td></tr>"
        for a, b, c, d in ranking_wiersze)
    ranking_html = (f'<div class="karta"><p><b>Rekomendacja:</b> {e(rekomendacja)}</p>'
                    f'<p><b>Wdrożone teraz:</b> {e(zakres)}</p>'
                    f'<table><thead><tr><th>#</th><th>Pomysł</th><th>Bot</th><th>GPT</th></tr></thead><tbody>{wiersze}</tbody></table>'
                    f'<p class="cichy">Reszta czeka w zapasie. Szczegóły i uzasadnienia: RANKING.md.</p></div>')

klasa_statusu = "zielone" if zielone else ("czerwone" if zielone is False else "neutral")
krit_html = "".join(f"<li>{e(k)}</li>" for k in kryteria) or "<li>brak</li>"
drobne_html = "".join(f"<li>{e(d)}</li>" for d in drobne)

strona = f"""<!doctype html>
<html lang="pl"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Raport zadania</title>
<style>
:root{{--tlo:#f6f6f4;--karta:#fff;--tekst:#1c1c1a;--cichy:#6b6b66;--linia:#e4e4df;--ziel:#1f7a4d;--czer:#b3261e;--akc:#3b5bdb}}
@media (prefers-color-scheme:dark){{:root{{--tlo:#141413;--karta:#1e1e1c;--tekst:#ecece8;--cichy:#9b9b95;--linia:#2e2e2b;--ziel:#4cc38a;--czer:#ff6b62;--akc:#8ca2ff}}}}
*{{box-sizing:border-box}}body{{margin:0;background:var(--tlo);color:var(--tekst);font:15px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}}
main{{max-width:1240px;margin:0 auto;padding:32px 16px 80px}}
h1{{font-size:26px;margin:0 0 6px;letter-spacing:-.01em}}h2{{font-size:18px;margin:40px 0 14px}}h3{{font-size:15px;margin:0 0 10px;color:var(--cichy);font-weight:600}}
.status{{display:inline-block;padding:6px 12px;border-radius:999px;font-weight:600;font-size:14px;margin:10px 0}}
.zielone{{background:color-mix(in srgb,var(--ziel) 15%,transparent);color:var(--ziel)}}.czerwone{{background:color-mix(in srgb,var(--czer) 15%,transparent);color:var(--czer)}}.neutral{{background:var(--linia)}}
.cichy{{color:var(--cichy);font-size:14px}}
.decyzja{{background:var(--karta);border:1px solid var(--linia);border-left:4px solid var(--akc);border-radius:12px;padding:18px 20px;margin:24px 0}}
.decyzja b{{display:block;margin-bottom:6px}}.decyzja code{{background:var(--tlo);padding:2px 7px;border-radius:6px}}
.karta{{background:var(--karta);border:1px solid var(--linia);border-radius:12px;padding:16px 20px}}
.karta ul{{margin:6px 0;padding-left:20px}}
.para,.strona{{background:var(--karta);border:1px solid var(--linia);border-radius:12px;padding:16px;margin-bottom:16px}}
.rzad{{display:grid;grid-template-columns:1fr 1fr;gap:14px}}.rzad.waski{{grid-template-columns:repeat(2,minmax(0,320px))}}
.rzad.wzor{{grid-template-columns:2fr 1fr}}
table{{width:100%;border-collapse:collapse;font-size:14px;margin:8px 0}}th,td{{text-align:left;padding:6px 8px;border-bottom:1px solid var(--linia)}}th{{color:var(--cichy);font-weight:600}}
.widok{{margin-top:12px}}.widok-tyt{{font-weight:600;margin-bottom:8px;display:flex;gap:12px;align-items:center;flex-wrap:wrap}}
figure{{margin:0}}figure img{{width:100%;max-height:560px;object-fit:cover;object-position:top;border:1px solid var(--linia);border-radius:8px;display:block}}
figcaption{{font-size:12px;color:var(--cichy);margin-top:4px;text-transform:uppercase;letter-spacing:.06em}}
.brak div{{height:160px;border:1px dashed var(--linia);border-radius:8px;display:grid;place-items:center;color:var(--cichy)}}
.ok{{color:var(--ziel);font-weight:500;font-size:13px}}.uw{{color:var(--czer);font-weight:500;font-size:13px}}
@media (max-width:640px){{.rzad,.rzad.waski{{grid-template-columns:1fr}}}}
</style></head><body><main>
<p class="cichy">Raport zadania</p>
<h1>{e(zadanie)}</h1>
<span class="status {klasa_statusu}">{e(status)}</span>
<div class="cichy">{e(rundy)}</div>
{f'<p>{e(podsumowanie_gpt)}</p>' if podsumowanie_gpt else ''}

<div class="decyzja"><b>Twoja decyzja, napisz w Claude Code jedno z trzech:</b>
<code>zostaw</code> · <code>cofnij</code> · <code>popraw: …</code> (co konkretnie zmienić)</div>

<h2>Po czym miało być widać, że gotowe</h2>
<div class="karta"><ul>{krit_html}</ul>
{f'<p class="cichy">Do rozważenia (nie blokowało):</p><ul>{drobne_html}</ul>' if drobne_html else ''}</div>

{f'<h2>Ranking pomysłów</h2>{ranking_html}' if ranking_html else ''}
{f'<h2>Kierunek</h2><div class="karta" style="white-space:pre-wrap">{e(kierunek)}</div>' if kierunek else ''}
{f'<h2>Wzór</h2>{wzory_html}' if wzory_html else ''}
{f'<h2>Przed i po</h2>{porownania}' if porownania else ''}
<p class="cichy" style="margin-top:40px">Pełna historia: DZIENNIK.md w tym samym folderze.</p>
</main></body></html>"""

(praca / "RAPORT.html").write_text(strona, encoding="utf-8")
print(f"Raport zapisany: {praca / 'RAPORT.html'}")
