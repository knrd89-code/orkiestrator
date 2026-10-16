#!/bin/bash
# Testy silnika orkiestratora z atrapą Codexa. Offline, kilka sekund, nic poza katalogiem tymczasowym.
# Użycie: bash testy/test-silnika.sh      Kod wyjścia: 0 = wszystko przeszło, 1 = co najmniej jeden błąd.
#
# Izolacja: własne HOME i konfiguracja gita, ORK_TRYB=lokalnie (bez push i API GitHuba),
# kopia kitu (limity zmieniamy w kopii ustawienia.conf), atrapa `codex` na początku PATH.

set -u

ZRODLO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/ork-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT

export HOME="$T/home" ORK_TRYB=lokalnie ORK_PONOW_S=0 ATRAPA="$T/atrapa"
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
export PATH="$T/bin:$PATH"
unset OPENAI_API_KEY CLAUDE_CODE_REMOTE ORK_NARZEDZIA
mkdir -p "$HOME" "$ATRAPA/kolejka" "$T/bin" "$T/kit"
git config --global user.name "Test" && git config --global user.email "test@example.invalid"
git config --global init.defaultBranch main && git config --global commit.gpgsign false

(cd "$ZRODLO" && tar --exclude=.git --exclude=.orkiestrator -cf - .) | (cd "$T/kit" && tar -xf -)
SILNIK="$T/kit/silnik.sh"
cp "$T/kit/ustawienia.conf" "$T/ustawienia.oryginal"

# ---------------------------------------------------------------- atrapa Codexa
cat > "$T/bin/codex" <<'ATRAPA_EOF'
#!/bin/bash
# Kolejka odpowiedzi: pliki w $ATRAPA/kolejka, brane po kolei. Treść: JSON werdyktu,
# "BLAD <tekst>" (wypisz tekst, kod 1) albo "SPIJ <s>" (uśpij, potem werdykt OK).
case "${1:-}" in
  login) exit 0 ;;
  --version) echo "codex-cli 0.0.0-atrapa"; exit 0 ;;
  exec) ;;
  *) exit 0 ;;
esac
printf '%s\n' "$*" >> "$ATRAPA/wywolania"
n=$(( $(cat "$ATRAPA/licznik" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$ATRAPA/licznik"
shift
wynik="" katalog="." skip=0
while [ $# -gt 0 ]; do
  case "$1" in
    -o) wynik="$2"; shift ;;
    -C) katalog="$2"; shift ;;
    --skip-git-repo-check) skip=1 ;;
  esac
  shift
done
echo "session id: 0199a429-5004-7401-a503-000000000502"
# Jak prawdziwy Codex: cały prompt trafia do dziennika (słowa z niego nie mogą udawać błędów).
echo "user"; cat
# Jak prawdziwy Codex: poza repozytorium git bez flagi odmawia pracy.
if [ "$skip" = 0 ] && ! git -C "$katalog" rev-parse --git-dir >/dev/null 2>&1; then
  echo "Not inside a trusted directory and --skip-git-repo-check was not specified."; exit 1
fi
plik="$(ls "$ATRAPA/kolejka" | head -1)"
tresc='{"werdykt":"OK","podsumowanie":"atrapa: ok","uwagi":[]}'
if [ -n "$plik" ]; then tresc="$(cat "$ATRAPA/kolejka/$plik")"; rm -f "$ATRAPA/kolejka/$plik"; fi
case "$tresc" in
  "BLAD "*) echo "ERROR: ${tresc#BLAD }"; exit 1 ;;
  "SPIJ "*) sleep "${tresc#SPIJ }"; tresc='{"werdykt":"OK","podsumowanie":"atrapa: ok","uwagi":[]}' ;;
esac
printf '%s\n' "$tresc" > "$wynik"
ATRAPA_EOF
chmod +x "$T/bin/codex"

# ---------------------------------------------------------------- pomocnicze
BLEDY=0 SCENARIUSZ=""
OK='{"werdykt":"OK","podsumowanie":"atrapa: ok","uwagi":[]}'
KRYT='{"werdykt":"POPRAWKI","podsumowanie":"atrapa: uwaga","uwagi":[{"waga":"krytyczna","plik":"a.txt","miejsce":"linia 1","problem":"zła treść","dowod":"gdy ktoś otworzy a.txt, to zobaczy X, bo w linii 1 jest X","kryterium":"K1","propozycja":"popraw"}]}'
KRYT_BEZ_DOWODU='{"werdykt":"POPRAWKI","podsumowanie":"atrapa: uwaga","uwagi":[{"waga":"krytyczna","plik":"a.txt","miejsce":"linia 1","problem":"coś nie tak","dowod":"bo tak","kryterium":"K1","propozycja":"popraw"}]}'

scenariusz() { SCENARIUSZ="$1"; echo "• $1"; }
porazka() { echo "  ✗ [$SCENARIUSZ] $1"; BLEDY=$((BLEDY + 1)); }
sprawdz() { if eval "$2"; then echo "  ✓ $1"; else porazka "$1"; fi; }
wywolania() { cat "$ATRAPA/licznik" 2>/dev/null || echo 0; }
w_kolejce() { local n; n=$(( $(cat "$ATRAPA/nr" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$ATRAPA/nr"; printf '%s\n' "$1" > "$ATRAPA/kolejka/$(printf '%04d' "$n")"; }
ustaw() { cp "$T/ustawienia.oryginal" "$T/kit/ustawienia.conf"; [ $# -eq 2 ] && perl -pi -e "s/^$1=.*/$1=$2/" "$T/kit/ustawienia.conf"; }

oczekuj() {
  # oczekuj KOD opis polecenie... -> uruchamia polecenie silnika i sprawdza kod wyjścia
  local ocz="$1" opis="$2" rc; shift 2
  bash "$SILNIK" "$@" > "$T/ostatni.log" 2>&1; rc=$?
  if [ "$rc" -eq "$ocz" ]; then echo "  ✓ $opis (kod $rc)"; else
    porazka "$opis: oczekiwano kodu $ocz, jest $rc"; tail -n 15 "$T/ostatni.log" | sed 's/^/      /'
  fi
}

nowe_repo() {
  ustaw; rm -f "$ATRAPA/kolejka/"*
  R="$T/repo-$1"; mkdir -p "$R" && cd "$R" || exit 1
  git init -q && echo "start" > a.txt && git add a.txt && git commit -q -m "start"
}

wypelnij_zadanie() {
  # wypelnij_zadanie TEST_CMD -> intencja i plan bez znaczników szablonu
  printf '# INTENCJA\nTest silnika.\n' > .orkiestrator/INTENCJA.md
  printf '# PLAN\n## KRYTERIA ODBIORU\n- K1: a.txt ma nową treść | Sprawdzenie: cat\n## TESTY\nTEST_CMD: %s\n' "$1" > .orkiestrator/PLAN.md
}

zadanie_po_planie() {
  # nowe repo, start, plan zatwierdzony; $2 = TEST_CMD
  nowe_repo "$1"
  bash "$SILNIK" start "zadanie $1" > /dev/null 2>&1 || porazka "start nie przeszedł"
  wypelnij_zadanie "$2"; w_kolejce "$OK"
  bash "$SILNIK" plan > /dev/null 2>&1 || porazka "plan nie przeszedł"
}

# ---------------------------------------------------------------- scenariusze
scenariusz "Ścieżka szczęśliwa i bramki (K6, K2, K9)"
nowe_repo sciezka
oczekuj 0 "start" start "zadanie testowe"
sprawdz "gałąź zadania orkiestrator/…" '[[ "$(git rev-parse --abbrev-ref HEAD)" == orkiestrator/* ]]'
przed=$(wywolania)
oczekuj 40 "plan z niewypełnioną intencją" plan
sprawdz "bez wywołania GPT" '[ "$(wywolania)" = "$przed" ]'
wypelnij_zadanie brak; w_kolejce "$OK"
oczekuj 0 "plan z werdyktem OK" plan
oczekuj 40 "kod bez zmian w kodzie" kod
echo "nowa treść" > a.txt; w_kolejce "$KRYT"
oczekuj 10 "kod z uwagą krytyczną z dowodem" kod
sprawdz "krytyczne-kod-1.txt zawiera R1-1" 'grep -qx "R1-1" .orkiestrator/krytyczne-kod-1.txt'
oczekuj 40 "kod bez ODPOWIEDZI.md" kod
echo "R1-1: POPRAWIONE – poprawiona treść" > .orkiestrator/ODPOWIEDZI.md; w_kolejce "$OK"
oczekuj 0 "kod z odpowiedziami i werdyktem OK" kod
sprawdz "recenzje bez --skip-git-repo-check" '! grep -q -- "--skip-git-repo-check" "$ATRAPA/wywolania"'
oczekuj 0 "przyjmij" przyjmij
sprawdz "z powrotem na main" '[ "$(git rev-parse --abbrev-ref HEAD)" = main ]'
sprawdz "zmiana jest na main" 'grep -qx "nowa treść" a.txt'

scenariusz "Cofnięcie (K9)"
zadanie_po_planie cofnij brak
echo "odrzucona treść" > a.txt; w_kolejce "$OK"
oczekuj 0 "kod" kod
oczekuj 0 "cofnij" cofnij
sprawdz "z powrotem na main" '[ "$(git rev-parse --abbrev-ref HEAD)" = main ]'
sprawdz "main bez zmian zadania" 'grep -qx "start" a.txt && [ "$(git rev-list --count main)" = 1 ]'

scenariusz "Odsiewanie uwag bez dowodu (K7)"
zadanie_po_planie odsiew brak
echo "nowa treść" > a.txt; w_kolejce "$KRYT_BEZ_DOWODU"
oczekuj 0 "uwaga krytyczna z dowodem „bo tak” odsiana" kod

scenariusz "Limit rund kodu (K7)"
zadanie_po_planie limit brak
ustaw MAX_RUND_KODU 2
echo "nowa treść" > a.txt; w_kolejce "$KRYT"
oczekuj 10 "runda 1/2 czerwona" kod
echo "R1-1: ODRZUCAM – to nie błąd" > .orkiestrator/ODPOWIEDZI.md; w_kolejce "$KRYT"
oczekuj 20 "runda 2/2 czerwona = STOP" kod

scenariusz "Hasła i nieudane testy (K8)"
zadanie_po_planie sekrety false
echo "nowa treść" > a.txt; echo "KLUCZ=tajny" > .env
oczekuj 40 "nieśledzony .env blokuje zapis" kod
sprawdz ".env nie trafił do historii" '! git log --all --name-only --format= | grep -qx ".env"'
rm -f .env; przed=$(wywolania)
oczekuj 10 "nieudane testy (TEST_CMD: false)" kod
sprawdz "bez wywołania GPT" '[ "$(wywolania)" = "$przed" ]'

scenariusz "Ponowienie przy chwilowym błędzie (K3, K5)"
nowe_repo ponow
bash "$SILNIK" start "ponowienie" > /dev/null 2>&1; wypelnij_zadanie brak
w_kolejce "BLAD stream disconnected before completion: error sending request"; w_kolejce "$OK"
przed=$(wywolania)
oczekuj 0 "plan po jednym ponowieniu" plan
sprawdz "dokładnie 2 wywołania GPT" '[ "$(wywolania)" = $((przed + 2)) ]'
sprawdz "wpis o ponowieniu w dzienniku" 'grep -q "chwilowy błąd Codexa (kod 1), ponowienie" .orkiestrator/DZIENNIK.md'
sprawdz "dziennik pierwszej próby zachowany" '[ -f .orkiestrator/codex-plan-1.log.proba1 ]'
sprawdz "runda nie zużyta" '[ -f .orkiestrator/werdykt-plan-1.json ] && [ ! -f .orkiestrator/werdykt-plan-2.json ]'

scenariusz "Ponowienie mimo zacytowanego w treści recenzji „ERROR: login failed, usage limit, 401”"
nowe_repo ponow-tresc
bash "$SILNIK" start "ponowienie z treścią" > /dev/null 2>&1; wypelnij_zadanie brak
printf '# INTENCJA\nNaprawić login. Komunikat: usage limit, kod 401, quota.\nERROR: login failed, usage limit, 401, quota\n' > .orkiestrator/INTENCJA.md
w_kolejce "BLAD stream disconnected before completion: error sending request"; w_kolejce "$OK"; przed=$(wywolania)
oczekuj 0 "plan po ponowieniu" plan
sprawdz "dokładnie 2 wywołania GPT" '[ "$(wywolania)" = $((przed + 2)) ]'

scenariusz "Bez ponowienia: błąd trwały, dwa błędy z rzędu, przekroczony czas (K4)"
nowe_repo trwale
bash "$SILNIK" start "trwałe błędy" > /dev/null 2>&1; wypelnij_zadanie brak
w_kolejce "BLAD You've hit your usage limit. Try again later."; przed=$(wywolania)
oczekuj 30 "limit konta" plan
sprawdz "dokładnie 1 wywołanie" '[ "$(wywolania)" = $((przed + 1)) ]'
w_kolejce "BLAD stream disconnected"; w_kolejce "BLAD stream disconnected"; przed=$(wywolania)
oczekuj 30 "dwa chwilowe błędy z rzędu" plan
sprawdz "dokładnie 2 wywołania" '[ "$(wywolania)" = $((przed + 2)) ]'
ustaw LIMIT_RECENZJI_S 1; w_kolejce "SPIJ 5"; przed=$(wywolania)
oczekuj 30 "przekroczony czas recenzji" plan
sprawdz "dokładnie 1 wywołanie" '[ "$(wywolania)" = $((przed + 1)) ]'
sprawdz "żaden werdykt nie powstał" '! ls .orkiestrator/werdykt-plan-*.json >/dev/null 2>&1'
ustaw

ostatnie() { tail -n 1 "$ATRAPA/wywolania"; }
RANKING_GPT='{"podsumowanie":"atrapa","ranking":[{"id":"F1","ocena":8,"uzasadnienie":"a"},{"id":"F2","ocena":5,"uzasadnienie":"b"}],"brakujace_pomysly":[],"ostrzezenia":[]}'

scenariusz "Poziom rozumowania recenzenta"
nowe_repo wysilek
bash "$SILNIK" start "wysiłek" > /dev/null 2>&1; wypelnij_zadanie brak
printf '# POMYSŁY\n\n## F1: Jeden\nOpis: a.\nSkąd: kod aplikacji.\nWartość: 5 | Dopasowanie: 5 | Koszt: 5 | Ryzyko: 5\n\n## F2: Dwa\nOpis: b.\nSkąd: kod aplikacji.\nWartość: 2 | Dopasowanie: 2 | Koszt: 2 | Ryzyko: 2\n' > .orkiestrator/POMYSLY.md
w_kolejce "$RANKING_GPT"
oczekuj 0 "ranking" ranking
sprawdz "ranking: low" 'ostatnie | grep -qF "model_reasoning_effort=\"low\""'
w_kolejce "$OK"
oczekuj 0 "plan" plan
sprawdz "plan: medium" 'ostatnie | grep -qF "model_reasoning_effort=\"medium\""'
echo "nowa treść" > a.txt; w_kolejce "$OK"
oczekuj 0 "kod" kod
sprawdz "kod: high" 'ostatnie | grep -qF "model_reasoning_effort=\"high\""'

nowe_repo wysilek-ustawienia
bash "$SILNIK" start "ustawienia wysiłku" > /dev/null 2>&1; wypelnij_zadanie brak
ustaw WYSILEK_PLANU '""'; w_kolejce "$OK"
oczekuj 0 "plan z pustym ustawieniem" plan
sprawdz "puste = bez flagi (domyślny Codexa)" '! ostatnie | grep -q "model_reasoning_effort"'
rm -f .orkiestrator/PLAN_ZIELONY .orkiestrator/werdykt-plan-*.json
ustaw WYSILEK_PLANU turbo; przed=$(wywolania)
oczekuj 40 "nieznany poziom" plan
sprawdz "bez wywołania GPT" '[ "$(wywolania)" = "$przed" ]'
ustaw; perl -ni -e 'print unless /^WYSILEK_/' "$T/kit/ustawienia.conf"; w_kolejce "$OK"
oczekuj 0 "stary plik ustawień bez nowych kluczy" plan
sprawdz "domyślnie medium dla planu" 'ostatnie | grep -qF "model_reasoning_effort=\"medium\""'
ustaw

scenariusz "Powiązanie gałęzi z serwerem w chmurze"
# Atrapa gita, która przy push gubi -u: tak zachowywał się push w chmurze (powiązanie nie zapisane).
mkdir -p "$T/bin-git"; PRAWDZIWY_GIT="$(command -v git)"
cat > "$T/bin-git/git" <<EOF
#!/bin/bash
if [ "\${1:-}" = push ]; then a=(); for x in "\$@"; do [ "\$x" = -u ] || a+=("\$x"); done; exec "$PRAWDZIWY_GIT" "\${a[@]}"; fi
exec "$PRAWDZIWY_GIT" "\$@"
EOF
chmod +x "$T/bin-git/git"
nowe_repo chmura
git init -q --bare "$T/origin-chmura.git" && git remote add origin "$T/origin-chmura.git" && git push -q origin main
# Jak klon w chmurze: pobieranie zmapowane tylko dla main.
git config remote.origin.fetch "+refs/heads/main:refs/remotes/origin/main" && git fetch -q origin
bash "$SILNIK" start "chmura" > /dev/null 2>&1; wypelnij_zadanie brak; w_kolejce "$OK"
bash "$SILNIK" plan > /dev/null 2>&1
echo "nowa treść" > a.txt; w_kolejce "$OK"
STARY_PATH="$PATH"; export ORK_TRYB=chmura PATH="$T/bin-git:$PATH"
oczekuj 0 "kod (wysyła gałąź)" kod
export ORK_TRYB=lokalnie PATH="$STARY_PATH"
G="$(git rev-parse --abbrev-ref HEAD)"
sprawdz "gałąź jest na serwerze z ostatnim commitem" '[ "$(git --git-dir="$T/origin-chmura.git" rev-parse "refs/heads/$G")" = "$(git rev-parse HEAD)" ]'
sprawdz "gałąź powiązana z origin/$G" '[ "$(git rev-parse --abbrev-ref --symbolic-full-name "@{u}" 2>/dev/null)" = "origin/$G" ]'
sprawdz "git status nie widzi niewysłanych commitów" 'git status -sb | head -1 | grep -qF "...origin/$G" && ! git status -sb | head -1 | grep -q ahead'
sprawdz "komunikaty push w github.log" 'grep -q "git push $G" .orkiestrator/github.log'

scenariusz "Polecenie test poza repozytorium (K1)"
cd "$T" || exit 1
sprawdz "atrapa odrzuca pracę poza gitem bez flagi" '! codex exec -C "$HOME" -o "$T/x.json" < /dev/null > /dev/null 2>&1'
w_kolejce "$OK"
oczekuj 0 "silnik test" test
sprawdz "odpowiedź GPT wypisana" 'grep -q "OK. GPT odpowiada" "$T/ostatni.log"'
sprawdz "test użył --skip-git-repo-check" 'tail -n 1 "$ATRAPA/wywolania" | grep -q -- "--skip-git-repo-check"'

echo ""
if [ "$BLEDY" -eq 0 ]; then echo "WSZYSTKIE TESTY PRZESZŁY"; exit 0; fi
echo "BŁĘDY: $BLEDY"; exit 1
