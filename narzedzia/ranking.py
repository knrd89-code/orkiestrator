#!/usr/bin/env python3
"""Łączy ranking wykonawcy (POMYSLY.md) z niezależnym rankingiem GPT.

Użycie: ranking.py <POMYSLY.md> <ranking-gpt.json> <RANKING.md> <DZIENNIK.md>
Kody: 0 = ok, 30 = nieczytelne dane, 40 = błędny format POMYSLY.md
"""
import json
import re
import sys
from datetime import datetime

WAGI = {"Wartość": 3, "Dopasowanie": 2, "Koszt": 1, "Ryzyko": 1}
MAKS = 5 * sum(WAGI.values())


def wczytaj_pomysly(tekst):
    pomysly = []
    bloki = re.split(r"(?=^## F\d+:)", tekst, flags=re.M)
    for b in bloki:
        m = re.match(r"^## (F\d+):\s*(.+)$", b, re.M)
        if not m:
            continue
        pid, nazwa = m.group(1), m.group(2).strip()
        oceny = {}
        for klucz in WAGI:
            mm = re.search(klucz + r"\s*:\s*([1-5])", b)
            if not mm:
                raise ValueError(f"{pid}: brak oceny '{klucz}' (1-5)")
            oceny[klucz] = int(mm.group(1))
        skad = re.search(r"^Skąd:\s*(.+)$", b, re.M)
        if not skad or len(skad.group(1).strip()) < 4:
            raise ValueError(f"{pid}: brak źródła pomysłu (linia 'Skąd:')")
        wynik = sum(oceny[k] * w for k, w in WAGI.items())
        pomysly.append({"id": pid, "nazwa": nazwa, "oceny": oceny, "wynik": wynik})
    return pomysly


def main():
    sciezka_p, sciezka_g, wyjscie, dziennik = sys.argv[1:5]
    try:
        pomysly = wczytaj_pomysly(open(sciezka_p, encoding="utf-8").read())
    except ValueError as e:
        print(f"BŁĄD: POMYSLY.md ma zły format: {e}")
        return 40
    if len(pomysly) < 2:
        print("BŁĄD: w POMYSLY.md muszą być co najmniej 2 pomysły w formacie '## F1: nazwa'.")
        return 40

    try:
        gpt = json.load(open(sciezka_g, encoding="utf-8"))
        ranking_gpt = [r for r in gpt["ranking"] if isinstance(r, dict)]
    except Exception as e:  # noqa: BLE001
        print(f"BŁĄD TECHNICZNY: ranking GPT jest nieczytelny ({e}).")
        return 30

    ids = [p["id"] for p in pomysly]
    claude_kolejnosc = [p["id"] for p in sorted(pomysly, key=lambda p: -p["wynik"])]
    gpt_kolejnosc = []
    for r in sorted(ranking_gpt, key=lambda r: -int(r.get("ocena", 0))):
        if r.get("id") in ids and r["id"] not in gpt_kolejnosc:
            gpt_kolejnosc.append(r["id"])
    for pid in ids:  # pominięte przez GPT na koniec
        if pid not in gpt_kolejnosc:
            gpt_kolejnosc.append(pid)

    poz_c = {pid: i + 1 for i, pid in enumerate(claude_kolejnosc)}
    poz_g = {pid: i + 1 for i, pid in enumerate(gpt_kolejnosc)}
    po_id = {p["id"]: p for p in pomysly}
    uzas = {r.get("id"): r.get("uzasadnienie", "") for r in ranking_gpt}
    ocena_g = {r.get("id"): r.get("ocena", "") for r in ranking_gpt}

    laczny = sorted(ids, key=lambda pid: ((poz_c[pid] + poz_g[pid]) / 2, -po_id[pid]["wynik"]))
    def ocena_gpt(pid):
        try:
            return int(ocena_g.get(pid, 0))
        except (TypeError, ValueError):
            return 0

    # do wdrożenia: pierwsza trójka obu rankingów ORAZ przyzwoita ocena u obu (nie "najlepszy z kiepskich")
    zgodne = [pid for pid in laczny
              if poz_c[pid] <= 3 and poz_g[pid] <= 3
              and ocena_gpt(pid) >= 6 and po_id[pid]["wynik"] >= 0.6 * MAKS][:3]
    rekomendacja = zgodne or laczny[:1]

    linie = [f"# RANKING ({datetime.now().strftime('%Y-%m-%d %H:%M')})", ""]
    linie.append("| Miejsce | Pomysł | Wykonawca (pkt / miejsce) | GPT (ocena / miejsce) |")
    linie.append("|---|---|---|---|")
    for i, pid in enumerate(laczny, 1):
        p = po_id[pid]
        linie.append(f"| {i} | {pid}: {p['nazwa']} | {p['wynik']}/{MAKS} · {poz_c[pid]}. | {ocena_g.get(pid, '–')}/10 · {poz_g[pid]}. |")
    linie.append("")
    opisy = ", ".join("%s (%s)" % (pid, po_id[pid]["nazwa"]) for pid in rekomendacja)
    linie.append("**Rekomendacja do wdrożenia teraz:** " + opisy)
    if not zgodne:
        linie.append("_Żaden pomysł nie jest jednocześnie w czołówce obu rankingów z dobrą oceną. Rekomendacja = pierwszy w łącznym rankingu. Zapytaj Konrada, zanim zaczniesz._")
    linie.append("")
    linie.append("## Uzasadnienia GPT")
    for pid in gpt_kolejnosc:
        if uzas.get(pid):
            linie.append(f"- {pid}: {uzas[pid]}")
    if gpt.get("brakujace_pomysly"):
        linie.append("")
        linie.append("## Pomysły, których według GPT brakuje")
        for b in gpt["brakujace_pomysly"]:
            linie.append(f"- {b.get('nazwa', '')}: {b.get('uzasadnienie', '')}")
    if gpt.get("ostrzezenia"):
        linie.append("")
        linie.append("## Ostrzeżenia GPT")
        for o in gpt["ostrzezenia"]:
            linie.append(f"- {o}")
    if gpt.get("podsumowanie"):
        linie.append("")
        linie.append(f"GPT: {gpt['podsumowanie']}")

    tekst = "\n".join(linie)
    open(wyjscie, "w", encoding="utf-8").write(tekst + "\n")
    with open(dziennik, "a", encoding="utf-8") as f:
        f.write("\n## RANKING POMYSŁÓW\n" + "\n".join(linie[2:]) + "\n")
    print(tekst)
    print("")
    print("Dalej: wpisz wybrane pomysły do PLAN.md (sekcja ZAKRES), resztę do POZA ZAKRESEM jako zapas.")
    print("Wybór inny niż rekomendacja wymaga uzasadnienia w PLAN.md.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
