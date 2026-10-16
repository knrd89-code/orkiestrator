#!/usr/bin/env python3
"""Ocena werdyktu recenzenta: odsiewa uwagi bez dowodu, liczy krytyczne, ustala bramkę.

Użycie: ocena.py <werdykt.json> <faza: plan|kod> <runda> <max_rund> <plik_id_krytycznych> <dziennik.md>
Kody wyjścia: 0 = zielone, 10 = czerwone, 30 = werdykt nieczytelny.
"""
import json
import sys
from datetime import datetime

MAX_DROBNYCH = 5
MIN_DLUGOSC_DOWODU = 15


def main():
    sciezka, faza, runda, max_rund, plik_id, dziennik = sys.argv[1:7]
    runda, max_rund = int(runda), int(max_rund)
    prefiks = ("P" if faza == "plan" else "R") + str(runda)

    try:
        with open(sciezka, encoding="utf-8") as f:
            dane = json.load(f)
        uwagi = dane.get("uwagi", [])
        if not isinstance(uwagi, list):
            raise ValueError("pole 'uwagi' nie jest listą")
    except Exception as e:  # noqa: BLE001
        print(f"BŁĄD TECHNICZNY: werdykt recenzenta jest nieczytelny ({e}).")
        print("Recenzja się NIE odbyła. Nie kontynuuj pracy, zgłoś to Konradowi.")
        return 30

    krytyczne, drobne, odrzucone = [], [], []
    for u in uwagi:
        if not isinstance(u, dict):
            continue
        dowod = str(u.get("dowod", "")).strip()
        plik = str(u.get("plik", "")).strip()
        miejsce = str(u.get("miejsce", "")).strip()
        powod = None
        if len(dowod) < MIN_DLUGOSC_DOWODU:
            powod = "brak konkretnego dowodu"
        elif faza == "kod" and not plik:
            powod = "brak wskazania pliku"
        elif faza == "plan" and not (plik or miejsce):
            powod = "brak wskazania miejsca w planie"
        if powod:
            odrzucone.append((u, powod))
        elif u.get("waga") == "krytyczna":
            krytyczne.append(u)
        else:
            drobne.append(u)

    ponad_limit = max(0, len(drobne) - MAX_DROBNYCH)
    drobne = drobne[:MAX_DROBNYCH]

    zielone = len(krytyczne) == 0
    ostatnia = runda >= max_rund

    linie = []
    naglowek = "ZIELONE" if zielone else "CZERWONE"
    linie.append(f"## {faza.upper()} – runda {runda}/{max_rund}: {naglowek}")
    linie.append(f"_{datetime.now().strftime('%Y-%m-%d %H:%M')}_")
    linie.append("")
    pods = str(dane.get("podsumowanie", "")).strip()
    if pods:
        linie.append(f"Recenzent: {pods}")
        linie.append("")

    ids = []
    if krytyczne:
        linie.append("### Uwagi krytyczne (blokują)")
        for i, u in enumerate(krytyczne, 1):
            uid = f"{prefiks}-{i}"
            ids.append(uid)
            gdzie = " / ".join(x for x in [u.get("plik", ""), u.get("miejsce", "")] if x)
            linie.append(f"- **{uid}** [{gdzie}] {u.get('problem', '')}")
            linie.append(f"  - Dowód: {u.get('dowod', '')}")
            if u.get("kryterium"):
                linie.append(f"  - Narusza: {u.get('kryterium')}")
            if u.get("propozycja"):
                linie.append(f"  - Propozycja: {u.get('propozycja')}")
        linie.append("")

    if drobne:
        linie.append("### Uwagi drobne (nie blokują)")
        for i, u in enumerate(drobne, 1):
            gdzie = " / ".join(x for x in [u.get("plik", ""), u.get("miejsce", "")] if x)
            linie.append(f"- {prefiks}-d{i} [{gdzie}] {u.get('problem', '')} → {u.get('propozycja', '')}")
        linie.append("")

    if odrzucone or ponad_limit:
        linie.append("### Odsiane automatycznie")
        for u, powod in odrzucone:
            linie.append(f"- ({powod}) {u.get('problem', '')}")
        if ponad_limit:
            linie.append(f"- {ponad_limit} drobnych uwag ponad limit {MAX_DROBNYCH}")
        linie.append("")

    if zielone:
        linie.append("BRAMKA: przechodzi.")
    elif ostatnia:
        linie.append("BRAMKA: STOP. To była ostatnia dozwolona runda. Nie poprawiaj dalej sam:")
        linie.append("pokaż Konradowi sporne uwagi, swoje stanowisko i rekomendację, i czekaj na decyzję.")
    else:
        linie.append("BRAMKA: zamknięta. Popraw albo odrzuć z uzasadnieniem KAŻDĄ uwagę krytyczną,")
        linie.append(f"zapisz to w .orkiestrator/ODPOWIEDZI.md (identyfikatory: {', '.join(ids)}),")
        linie.append("potem uruchom kolejną rundę.")

    tekst = "\n".join(linie)
    print(tekst)

    with open(plik_id, "w", encoding="utf-8") as f:
        f.write("\n".join(ids) + ("\n" if ids else ""))
    with open(dziennik, "a", encoding="utf-8") as f:
        f.write("\n" + tekst + "\n")

    return 0 if zielone else 10


if __name__ == "__main__":
    sys.exit(main())
