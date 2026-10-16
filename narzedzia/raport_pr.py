#!/usr/bin/env python3
"""Treść PR na GitHubie jako raport dla Konrada (tryb chmury).

Użycie: raport_pr.py <katalog_pracy> <bazowy_adres_obrazków lub "">
Wypisuje Markdown na standardowe wyjście.
"""
import json
import re
import sys
from pathlib import Path

praca = Path(sys.argv[1])
obrazki = sys.argv[2].rstrip("/") if len(sys.argv) > 2 else ""
zrzuty = praca / "zrzuty"


def czytaj(p, domyslnie=""):
    try:
        return Path(p).read_text(encoding="utf-8")
    except OSError:
        return domyslnie


def sekcja(tekst, nazwa):
    m = re.search(r"^##\s+" + re.escape(nazwa) + r"\s*$(.*?)(?=^##\s|\Z)", tekst, re.M | re.S)
    if not m:
        return ""
    return re.sub(r"<!--.*?-->", "", m.group(1), flags=re.S).strip()


zadanie = czytaj(praca / "ZADANIE.txt").strip()
plan = czytaj(praca / "PLAN.md")
dziennik = czytaj(praca / "DZIENNIK.md")
ranking = czytaj(praca / "RANKING.md")

kryteria = [l.lstrip("-* ").strip() for l in sekcja(plan, "KRYTERIA ODBIORU").splitlines() if l.strip()]
zakres = sekcja(plan, "ZAKRES")
poza = sekcja(plan, "POZA ZAKRESEM")
kierunek = sekcja(plan, "WZÓR I KIERUNEK")
if kierunek.lower().startswith("nie dotyczy"):
    kierunek = ""

naglowki = re.findall(r"^## (PLAN|KOD) – runda (\d+)/(\d+): (ZIELONE|CZERWONE)", dziennik, re.M)
kod = [n for n in naglowki if n[0] == "KOD"]
plany = [n for n in naglowki if n[0] == "PLAN"]
if kod and kod[-1][3] == "ZIELONE":
    status = "✅ Recenzja GPT: zielone światło"
elif kod:
    status = "⚠️ Recenzja GPT: są nierozwiązane uwagi (decyzja należy do Ciebie)"
else:
    status = "Bez recenzji kodu"

bloki = re.split(r"(?=^## )", dziennik, flags=re.M)
kodowe = [b for b in bloki if b.startswith("## KOD")]
ostatni = kodowe[-1] if kodowe else ""
m = re.search(r"^Recenzent: (.*)$", ostatni, re.M)
gpt = m.group(1).strip() if m else ""
drobne = re.findall(r"^- (R\d+-d\d+ .*)$", ostatni, re.M)

out = []
out.append(f"## {zadanie}")
out.append("")
out.append(f"**{status}** · plan: {len(plany)} rund recenzji · kod: {len(kod)} rund recenzji")
if gpt:
    out.append("")
    out.append(f"> GPT: {gpt}")
out.append("")
out.append("### Twoja decyzja")
out.append("Napisz w sesji Claude Code jedno z trzech:")
out.append("- **zostaw** – scalam ten PR. Jeśli projekt jest połączony z Vercelem, zmiany trafią na produkcję za 1–2 minuty.")
out.append("- **cofnij** – zamykam PR, nic nie trafia do głównej gałęzi.")
out.append("- **popraw: …** – co konkretnie zmienić.")
out.append("")
out.append("Podgląd na żywo: link w komentarzu Vercela poniżej (jeśli projekt jest z nim połączony).")
out.append("")
out.append("### Po czym miało być widać, że gotowe")
for k in kryteria or ["brak"]:
    out.append(f"- {k}")
if drobne:
    out.append("")
    out.append("<details><summary>Uwagi drobne (nie blokowały)</summary>")
    out.append("")
    for d in drobne:
        out.append(f"- {d}")
    out.append("")
    out.append("</details>")

if ranking:
    out.append("")
    out.append("### Ranking pomysłów")
    m = re.search(r"^\*\*Rekomendacja do wdrożenia teraz:\*\*\s*(.+)$", ranking, re.M)
    if m:
        out.append(f"**Rekomendacja:** {m.group(1).strip()}")
    if zakres:
        out.append(f"**Wdrożone teraz:** {zakres}")
    tabela = re.findall(r"^\|.*\|\s*$", ranking, re.M)
    if tabela:
        out.append("")
        out.extend(tabela)
    if poza:
        out.append("")
        out.append(f"**W zapasie:** {poza}")

if kierunek:
    out.append("")
    out.append("### Kierunek")
    out.append(kierunek)


def img(etap, plik, alt):
    if not obrazki or not (zrzuty / etap / plik).exists():
        return "–"
    return f'<img src="{obrazki}/{etap}/{plik}?raw=true" alt="{alt}" width="100%">'


if obrazki and (zrzuty / "wzor").exists():
    out.append("")
    out.append("### Wzór")
    nazwy = sorted({p.name.rsplit("-", 1)[0] for p in (zrzuty / "wzor").glob("*.png")})
    for n in nazwy:
        out.append("")
        out.append("| Komputer | Telefon |")
        out.append("|---|---|")
        out.append(f"| {img('wzor', n + '-komputer.png', 'wzór komputer')} | {img('wzor', n + '-telefon.png', 'wzór telefon')} |")

strony = []
for l in czytaj(praca / "STRONY.txt").splitlines():
    l = l.strip()
    if l and not l.startswith("#"):
        strony.append(re.sub(r"[^a-zA-Z0-9_-]", "-", l.split()[0]))

if obrazki and strony:
    try:
        po_wyniki = json.loads(czytaj(zrzuty / "po" / "wynik.json", "{}"))
        po = {(p["nazwa"], p["widok"]): p for p in po_wyniki.get("strony", [])}
    except json.JSONDecodeError:
        po = {}
    out.append("")
    out.append("### Przed i po")
    for n in strony:
        for widok, etykieta in (("komputer", "Komputer"), ("telefon", "Telefon")):
            p = po.get((n, widok), {})
            uwagi = []
            if p.get("poziomyScroll"):
                uwagi.append("poziomy scroll")
            if p.get("bledyStrony"):
                uwagi.append("błędy JavaScript")
            if p.get("niskiKontrastLiczba"):
                uwagi.append(f"niski kontrast: {p['niskiKontrastLiczba']}")
            znak = ("⚠️ " + ", ".join(uwagi)) if uwagi else ("✓ kontrola automatyczna bez uwag" if p else "")
            out.append("")
            out.append(f"**{n} · {etykieta}** {znak}")
            out.append("")
            out.append("| Przed | Po |")
            out.append("|---|---|")
            out.append(f"| {img('przed', f'{n}-{widok}.png', 'przed')} | {img('po', f'{n}-{widok}.png', 'po')} |")

out.append("")
out.append("---")
out.append("_Raport orkiestratora. Pełna historia rund recenzji jest w dzienniku sesji._")
print("\n".join(out))
