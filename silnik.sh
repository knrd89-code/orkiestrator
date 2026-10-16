#!/bin/bash
# Orkiestrator: autopilot dla Claude Code z niezależną recenzją GPT (Codex) i oczami (zrzuty ekranu).
# Działa lokalnie (Mac) i w chmurze (sesje Claude Code na claude.ai/code, także z telefonu).
#
# Użycie (z katalogu projektu; SILNIK = ścieżka do tego pliku):
#   bash SILNIK przygotuj                          instaluje brakujące narzędzia, sprawdza sieć i logowanie
#   bash SILNIK zaloguj                            logowanie Codexa (w chmurze: kod do wpisania na telefonie)
#   bash SILNIK start "opis zadania"               osobna gałąź + punkt powrotu
#   bash SILNIK ranking                            niezależny ranking pomysłów przez GPT
#   bash SILNIK oczy wzor ADRES [ADRES]            zrzuty stron-wzorów
#   bash SILNIK oczy przed|po                      zrzuty aplikacji (strony z .orkiestrator/STRONY.txt)
#   bash SILNIK plan                               recenzja planu przez GPT
#   bash SILNIK kod                                testy + oczy + recenzja zmian przez GPT
#   bash SILNIK raport                             raport (lokalnie: strona; w chmurze: PR na GitHubie)
#   bash SILNIK przyjmij                           Konrad akceptuje (w chmurze: scalenie PR = publikacja)
#   bash SILNIK cofnij                             Konrad odrzuca: powrót do stanu sprzed zadania
#   bash SILNIK zatwierdz                          Konrad przyjmuje plan mimo uwag (tylko na jego polecenie)
#   bash SILNIK dodaj-runde plan|kod               +1 runda recenzji (tylko na polecenie Konrada)
#   bash SILNIK status | test
#
# Kody wyjścia:
#   0  zielone          10 czerwone (uwagi do obsłużenia)       20 STOP, decyduje Konrad
#   30 błąd techniczny, recenzja się NIE odbyła                 40 niespełniony warunek wstępny
#
# Wymaga: git, python3, perl, node/npm. Codex i Playwright instaluje sam (przygotuj) w ~/.orkiestrator.

set -u

blad() { echo "BŁĄD: $1"; exit "${2:-40}"; }

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SILNIK="$KIT/silnik.sh"
NARZ="${ORK_NARZEDZIA:-$HOME/.orkiestrator/narzedzia}"
export PATH="$NARZ/node_modules/.bin:$PATH"
SCHEMAT="$KIT/schematy/werdykt.json"

case "${ORK_TRYB:-}" in
  chmura) CHMURA=1 ;;
  lokalnie) CHMURA=0 ;;
  *) if [ "${CLAUDE_CODE_REMOTE:-}" = "true" ]; then CHMURA=1; else CHMURA=0; fi ;;
esac

[ -f "$KIT/ustawienia.conf" ] || blad "Brak $KIT/ustawienia.conf. Silnik jest niekompletny." 30
# shellcheck disable=SC1090
. "$KIT/ustawienia.conf"

wejdz_do_repo() {
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || blad "To nie jest repozytorium git. Otwórz projekt (folder z repozytorium) i spróbuj ponownie." 40
  cd "$ROOT" || blad "Nie mogę wejść do katalogu projektu." 30
  PRACA=".orkiestrator"
  DZIENNIK="$PRACA/DZIENNIK.md"
  ZRZUTY="$PRACA/zrzuty"
  # Folder roboczy nigdy nie trafia do repozytorium (wykluczenie lokalne, bez zmiany .gitignore).
  local ex
  ex="$(git rev-parse --git-path info/exclude)"
  mkdir -p "$(dirname "$ex")"
  grep -qxF ".orkiestrator/" "$ex" 2>/dev/null || echo ".orkiestrator/" >> "$ex"
}

teraz() { date '+%Y-%m-%d %H:%M'; }
loguj() { printf '%s\n' "$1" >> "$DZIENNIK"; }
z_limitem() { local s="$1"; shift; perl -e 'alarm shift @ARGV; exec @ARGV or die "exec: $!\n"' "$s" "$@"; }
plik_wartosc() { [ -f "$1" ] && cat "$1" || echo ""; }

wymagaj_codex() {
  command -v codex >/dev/null 2>&1 || blad "Brak programu codex. Uruchom: bash $SILNIK przygotuj" 30
  if ! codex login status >/dev/null 2>&1; then
    if [ -n "${OPENAI_API_KEY:-}" ] && printenv OPENAI_API_KEY | codex login --with-api-key >/dev/null 2>&1; then
      return 0
    fi
    blad "Codex nie jest zalogowany. Uruchom: bash $SILNIK zaloguj" 30
  fi
}

wymagaj_zadania() {
  [ -f "$PRACA/BAZA" ] || blad "Brak aktywnego zadania. Najpierw: bash $SILNIK start \"opis\"" 40
  [ -f "$PRACA/ZAKONCZONE" ] && blad "Zadanie jest już zakończone ($(cat "$PRACA/ZAKONCZONE")). Nowe zadanie: start." 40
  BAZA="$(cat "$PRACA/BAZA")"
  GALAZ="$(cat "$PRACA/GALAZ")"
  ORYG="$(cat "$PRACA/ORYG")"
}

na_galezi_zadania() {
  [ "$(git rev-parse --abbrev-ref HEAD)" = "$GALAZ" ] || blad "Jesteś na gałęzi $(git rev-parse --abbrev-ref HEAD), a zadanie jest na $GALAZ. Przełącz się: git switch $GALAZ" 40
}

dodatkowe() { if [ -f "$PRACA/DODATKOWE-$1" ]; then wc -l < "$PRACA/DODATKOWE-$1" | tr -d ' '; else echo 0; fi; }
licz_rundy() { ls "$PRACA"/werdykt-"$1"-*.json 2>/dev/null | wc -l | tr -d ' '; }
test_cmd() { grep -E '^TEST_CMD:' "$PRACA/PLAN.md" | head -1 | sed 's/^TEST_CMD:[[:space:]]*//; s/[[:space:]]*$//'; }

sprawdz_odpowiedzi() {
  local plik_id="$PRACA/krytyczne-$1-$2.txt" brak="" uid
  [ -s "$plik_id" ] || return 0
  [ -f "$PRACA/ODPOWIEDZI.md" ] || blad "Poprzednia runda miała uwagi krytyczne, a nie ma $PRACA/ODPOWIEDZI.md. Opisz tam każdą: POPRAWIONE – co / ODRZUCAM – kontrargument." 40
  while IFS= read -r uid; do
    [ -z "$uid" ] && continue
    grep -Eq -- "(^|[^0-9A-Za-z])${uid}([^0-9]|\$)" "$PRACA/ODPOWIEDZI.md" || brak="$brak $uid"
  done < "$plik_id"
  [ -z "$brak" ] || blad "W ODPOWIEDZI.md brakuje odpowiedzi na uwagi:$brak." 40
}

obrazy() {
  # obrazy MAKS katalog... -> lista plików png rozdzielona przecinkami (najwyżej MAKS)
  local maks="$1"; shift
  local lista="" n=0 f d
  for d in "$@"; do
    [ -d "$d" ] || continue
    for f in "$d"/*.png; do
      [ -f "$f" ] || continue
      [ "$n" -ge "$maks" ] && break 2
      if [ -z "$lista" ]; then lista="$f"; else lista="$lista,$f"; fi
      n=$((n + 1))
    done
  done
  printf '%s' "$lista"
}

intencja() {
  # wkleja INTENCJA.md do pakietu dla recenzenta
  if [ -f "$PRACA/INTENCJA.md" ]; then echo ""; echo "# INTENCJA KONRADA (ustalona w rozmowie)"; cat "$PRACA/INTENCJA.md"; fi
}

wymagaj_intencji() {
  [ -f "$PRACA/INTENCJA.md" ] || blad "Brak $PRACA/INTENCJA.md." 40
  grep -q 'WYPEŁNIJ' "$PRACA/INTENCJA.md" && blad "INTENCJA.md nie jest wypełniona. Najpierw ustal z Konradem, o co chodzi (pytania pomocnicze), i zapisz to." 40
  return 0
}

obrazy_stron() {
  # obrazy_stron MAKS katalog -> zrzuty w kolejności z STRONY.txt (najważniejsze pierwsze)
  local maks="$1" d="$2" lista="" n=0 nazwa reszta f w
  [ -d "$d" ] && [ -f "$PRACA/STRONY.txt" ] || { printf ''; return 0; }
  while read -r nazwa reszta; do
    case "$nazwa" in ''|\#*) continue ;; esac
    nazwa="$(printf '%s' "$nazwa" | sed 's/[^a-zA-Z0-9_-]/-/g')"
    for w in komputer telefon; do
      f="$d/$nazwa-$w.png"
      [ -f "$f" ] || continue
      [ "$n" -ge "$maks" ] && break 2
      if [ -z "$lista" ]; then lista="$f"; else lista="$lista,$f"; fi
      n=$((n + 1))
    done
  done < "$PRACA/STRONY.txt"
  printf '%s' "$lista"
}

polacz() { if [ -n "$1" ] && [ -n "$2" ]; then printf '%s,%s' "$1" "$2"; else printf '%s%s' "$1" "$2"; fi; }

blad_przejsciowy() {
  # blad_przejsciowy log -> 0 gdy dziennik Codexa wygląda na chwilową awarię (sieć, przeciążenie),
  # a nie na trwały problem (limit konta, logowanie). Trwałe mają pierwszeństwo.
  # Kody HTTP tylko jako osobne liczby, żeby nie łapać fragmentów identyfikatorów sesji (UUID).
  local k='(^|[^0-9a-fA-F-])' p='([^0-9a-fA-F-]|$)'
  grep -Eqi "usage limit|quota|${k}401${p}|unauthori[sz]ed|not logged in|login" "$1" && return 1
  grep -Eqi "${k}(429|500|502|503|504)${p}|rate.?limit|too many requests|overloaded|stream (disconnected|error)|connection (reset|refused|closed)|econnreset|etimedout|temporarily unavailable" "$1"
}

uruchom_codex() {
  # uruchom_codex pakiet wynik log [obrazy_przecinkami] [schemat]
  # CODEX_DODATKOWE: dodatkowe argumenty codex exec (ustawia tylko polecenie test).
  local pakiet="$1" wynik="$2" log="$3" img="${4:-}" schemat="${5:-$SCHEMAT}" rc proba
  set -- exec -s read-only -C "$ROOT" --color never --ephemeral --output-schema "$schemat" -o "$wynik"
  [ -n "${MODEL:-}" ] && set -- "$@" -m "$MODEL"
  [ -n "$img" ] && set -- "$@" -i "$img"
  # shellcheck disable=SC2086
  [ -n "${CODEX_DODATKOWE:-}" ] && set -- "$@" $CODEX_DODATKOWE
  for proba in 1 2; do
    rm -f "$wynik"
    z_limitem "$LIMIT_RECENZJI_S" codex "$@" - < "$pakiet" > "$log" 2>&1
    rc=$?
    [ "$rc" -eq 0 ] && [ -s "$wynik" ] && break
    # Jedno ponowienie, tylko przy chwilowej awarii. Przekroczony czas (142) nie jest ponawiany.
    [ "$proba" -eq 1 ] && [ "$rc" -ne 142 ] && blad_przejsciowy "$log" || break
    mv "$log" "$log.proba1"
    echo "Chwilowy błąd połączenia z GPT (kod $rc). Ponawiam za ${ORK_PONOW_S:-15} s..."
    loguj ""
    loguj "- $(teraz): chwilowy błąd Codexa (kod $rc), ponowienie. Pierwsza próba: $log.proba1"
    sleep "${ORK_PONOW_S:-15}"
  done
  if [ "$rc" -ne 0 ] || [ ! -s "$wynik" ]; then
    rm -f "$wynik"
    echo "BŁĄD TECHNICZNY: Codex nie zwrócił werdyktu (kod $rc). Ostatnie linie dziennika Codexa:"
    tail -n 15 "$log"
    echo ""
    echo "Recenzja się NIE odbyła. Nie kontynuuj i nie udawaj, że przeszła. Zgłoś to Konradowi."
    loguj ""
    loguj "## BŁĄD TECHNICZNY recenzji ($(teraz)), kod $rc. Szczegóły: $log"
    exit 30
  fi
}

ocen() {
  local faza="$1" runda="$2" max="$3" rc
  python3 "$KIT/narzedzia/ocena.py" "$PRACA/werdykt-$faza-$runda.json" "$faza" "$runda" "$max" \
    "$PRACA/krytyczne-$faza-$runda.txt" "$DZIENNIK"
  rc=$?
  if [ "$rc" -eq 30 ]; then
    mv "$PRACA/werdykt-$faza-$runda.json" "$PRACA/nieczytelny-$faza-$runda.json" 2>/dev/null
    exit 30
  fi
  [ -f "$PRACA/ODPOWIEDZI.md" ] && mv "$PRACA/ODPOWIEDZI.md" "$PRACA/odpowiedzi-$faza-$((runda - 1)).md"
  if [ "$rc" -eq 0 ] && [ "$faza" = "plan" ]; then
    git hash-object "$PRACA/PLAN.md" > "$PRACA/PLAN_ZIELONY"
  fi
  if [ "$rc" -eq 10 ] && [ "$runda" -ge "$max" ]; then exit 20; fi
  exit "$rc"
}

sprawdz_sekrety() {
  # Nie wolno zapisać w historii plików z hasłami i kluczami, które nie są w .gitignore.
  local podejrzane
  podejrzane="$(git status --porcelain --untracked-files=all | grep '^??' | sed 's/^...//' | grep -Ei '(^|/)(\.env($|\.)|[^/]*\.(pem|key|p12|pfx)$|[^/]*(credentials|service-account)[^/]*\.json$|id_rsa)' | grep -Evi '\.env\.(example|sample|template)$')"
  if [ -n "$podejrzane" ]; then
    echo "BŁĄD: Te pliki wyglądają na hasła lub klucze i nie są w .gitignore:"
    printf '%s\n' "$podejrzane" | sed 's/^/  - /'
    echo "Nie zapisuję ich w historii. Dopisz je do .gitignore i uruchom polecenie ponownie."
    exit 40
  fi
}

zapisz_prace() {
  # commit wszystkiego na gałęzi zadania, jeśli są zmiany
  sprawdz_sekrety
  git add -A >/dev/null 2>&1
  if ! git diff --cached --quiet; then
    git commit -q -m "$1" || blad "Nie udało się zapisać zmian (commit)." 30
  fi
}

# ---------------------------------------------------------------- chmura i GitHub

wypchnij() {
  # W chmurze praca istnieje tylko w maszynie wirtualnej, dopóki nie trafi na GitHuba.
  # Wysyłamy WYŁĄCZNIE gałąź zadania (nigdy główną), co najwyżej uruchamia podgląd na Vercelu.
  [ "$CHMURA" = 1 ] || return 0
  if git push -q -u origin "$GALAZ" >/dev/null 2>&1; then
    return 0
  fi
  echo "UWAGA: nie udało się wysłać gałęzi $GALAZ na GitHuba. Praca jest tylko w tej sesji."
  return 0
}

repo_slug() {
  # owner/repo z adresu origin (działa też dla adresów pośrednika w chmurze)
  git remote get-url origin 2>/dev/null | sed -E 's#\.git$##; s#/+$##' | awk -F'[/:]' '{print $(NF-1)"/"$NF}'
}

gh_api() {
  command -v gh >/dev/null 2>&1 || return 127
  gh api "$@" 2>>"$PRACA/github.log"
}

galaz_bazowa() {
  # gałąź, do której idzie PR: gałąź Konrada, jeśli istnieje na GitHubie, inaczej domyślna gałąź repozytorium
  if git ls-remote --exit-code --heads origin "$ORYG" >/dev/null 2>&1; then
    echo "$ORYG"; return 0
  fi
  local d
  d="$(gh_api "repos/$(repo_slug)" --jq .default_branch)"
  [ -n "$d" ] && { echo "$d"; return 0; }
  d="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"
  echo "${d:-main}"
}

pr_numer() {
  # numer otwartego PR dla gałęzi zadania (zapamiętany albo wyszukany)
  if [ -s "$PRACA/PR" ]; then cat "$PRACA/PR"; return 0; fi
  local slug owner n
  slug="$(repo_slug)"; owner="${slug%%/*}"
  n="$(gh_api "repos/$slug/pulls?head=$owner:$GALAZ&state=open" --jq '.[0].number // empty')"
  [ -n "$n" ] && echo "$n" > "$PRACA/PR"
  printf '%s' "$n"
}

# ---------------------------------------------------------------- polecenia

cmd_start() {
  local opis="${1:-}" oryg slug galaz
  [ -n "$opis" ] || blad "Podaj opis zadania: bash $SILNIK start \"opis\"" 40
  git rev-parse --verify HEAD >/dev/null 2>&1 || blad "Repozytorium nie ma jeszcze żadnego commita." 40
  if [ -f "$PRACA/BAZA" ] && [ ! -f "$PRACA/ZAKONCZONE" ]; then
    blad "Poprzednie zadanie ($(cat "$PRACA/ZADANIE.txt")) nie jest zamknięte. Zapytaj Konrada: przyjąć czy cofnąć?" 40
  fi
  wymagaj_codex
  oryg="$(git rev-parse --abbrev-ref HEAD)"
  [ "$oryg" = "HEAD" ] && blad "Repozytorium nie jest na żadnej gałęzi (detached HEAD)." 40
  case "$oryg" in orkiestrator/*) blad "Jesteś na gałęzi innego zadania ($oryg). Najpierw je zamknij." 40 ;; esac

  mkdir -p "$PRACA"
  if [ -f "$PRACA/BAZA" ]; then
    local arch
    arch="$PRACA/archiwum/$(date '+%Y%m%d-%H%M%S')"
    mkdir -p "$arch"
    find "$PRACA" -maxdepth 1 -mindepth 1 ! -name archiwum -exec mv {} "$arch"/ \;
  fi

  slug="$(printf '%s' "$opis" | python3 -c 'import sys,unicodedata,re; t=sys.stdin.read().lower().replace("ł","l"); t=unicodedata.normalize("NFKD",t).encode("ascii","ignore").decode(); print(re.sub(r"[^a-z0-9]+","-",t).strip("-")[:32].strip("-") or "zadanie")')"
  sprawdz_sekrety
  case "$oryg" in
    claude/*)
      # Sesja w chmurze ma już własną gałąź roboczą: pracujemy na niej, a PR idzie do domyślnej gałęzi.
      galaz="$oryg"
      oryg="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"
      if [ -z "$oryg" ]; then
        local s; s="$(repo_slug)"
        oryg="$(gh_api "repos/$s" --jq .default_branch)"
      fi
      oryg="${oryg:-main}"
      ;;
    *)
      galaz="orkiestrator/$(date '+%m%d-%H%M')-$slug"
      git switch -q -c "$galaz" || blad "Nie udało się utworzyć gałęzi $galaz." 30
      ;;
  esac

  if [ -n "$(git status --porcelain)" ]; then
    git add -A && git commit -q -m "orkiestrator: niezapisane zmiany sprzed zadania" || blad "Nie udało się zapisać punktu startowego." 30
    git rev-parse HEAD > "$PRACA/WIP"
  fi

  git rev-parse HEAD > "$PRACA/BAZA"
  printf '%s\n' "$oryg" > "$PRACA/ORYG"
  printf '%s\n' "$galaz" > "$PRACA/GALAZ"
  printf '%s\n' "$opis" > "$PRACA/ZADANIE.txt"
  cp "$KIT/szablony/PLAN.md" "$PRACA/PLAN.md"
  cp "$KIT/szablony/INTENCJA.md" "$PRACA/INTENCJA.md"
  {
    echo "# Dziennik zadania"
    echo ""
    echo "**Zadanie:** $opis"
    echo "**Start:** $(teraz). Gałąź robocza: $galaz (gałąź Konrada: $oryg)."
  } > "$DZIENNIK"
  echo "OK. Pracujesz na osobnej gałęzi $galaz. Gałąź Konrada ($oryg) jest nietknięta."
  [ -f "$PRACA/WIP" ] && echo "Niezapisane zmiany Konrada zabezpieczone; przy cofnięciu wrócą na swoje miejsce."
  echo "Dalej: INTENCJA.md, rozpoznanie, (POMYSLY.md + ranking), (oczy), PLAN.md, plan."
}

cmd_oczy() {
  local etap="${1:-}" lista cel flaga=""
  [ $# -gt 0 ] && shift
  [ -f "$PRACA/BAZA" ] || blad "Brak aktywnego zadania." 40
  command -v node >/dev/null 2>&1 || blad "Brak programu node." 30
  [ -d "$NARZ/node_modules/playwright" ] || blad "Oczy nie są zainstalowane (Playwright). Uruchom: bash $SILNIK przygotuj" 30
  case "$etap" in
    wzor)
      [ $# -gt 0 ] || blad "Podaj adresy wzorów: bash $SILNIK oczy wzor https://... [https://...]" 40
      lista="$PRACA/wzory.txt"; : > "$lista"
      local i=1 u
      for u in "$@"; do echo "wzor$i $u" >> "$lista"; i=$((i + 1)); done
      flaga="--wzor"
      ;;
    przed|po)
      lista="$PRACA/STRONY.txt"
      [ -s "$lista" ] || blad "Brak $ROOT/$lista. Wpisz tam strony aplikacji, jedna na linię: 'nazwa adres', np. 'start http://localhost:3000'. Aplikacja musi być uruchomiona." 40
      ;;
    *) blad "Etap: wzor, przed albo po." 40 ;;
  esac
  cel="$ZRZUTY/$etap"
  rm -rf "$cel"; mkdir -p "$cel"
  echo "Robię zrzuty ($etap)..."
  ORK_NARZ="$NARZ" z_limitem 300 node "$KIT/narzedzia/oczy.mjs" "$cel" "$lista" $flaga
  local rc=$?
  [ "$rc" -eq 2 ] && blad "Oczy nie są zainstalowane (Playwright). Uruchom: bash $SILNIK przygotuj" 30
  if [ "$rc" -ne 0 ]; then
    if [ "$etap" = "wzor" ] && [ "$CHMURA" = 1 ]; then
      blad "Zrzuty wzoru się nie udały (kod $rc). W chmurze to zwykle brak pełnego dostępu do internetu w środowisku. Poproś Konrada o zrzut ekranu wzoru albo o włączenie pełnego dostępu (README, sekcja Chmura)." 30
    fi
    blad "Zrzuty się nie udały (kod $rc). Sprawdź, czy strona działa pod podanym adresem." 30
  fi
  echo "Zrzuty w $cel. Obejrzyj je (Read na plikach .png), zanim zdecydujesz, że jest dobrze."
  [ -f "$DZIENNIK" ] && loguj "" && loguj "- $(teraz): zrzuty $etap"
  return 0
}

bramka_oczu() {
  # bramka_oczu -> 0 gdy brak twardych problemów w zrzutach "po"
  python3 - "$ZRZUTY/po/wynik.json" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
twarde = []
for p in d["strony"]:
    g = f'{p["nazwa"]} [{p["widok"]}]'
    if p.get("blad"): twarde.append(f"{g}: strona się nie załadowała ({p['blad']})")
    if (p.get("status") or 0) >= 400: twarde.append(f"{g}: kod HTTP {p['status']}")
    if p.get("bledyStrony"): twarde.append(f"{g}: błędy JavaScript: {'; '.join(p['bledyStrony'][:2])}")
    if p["widok"] == "telefon" and p.get("poziomyScroll"): twarde.append(f"{g}: poziomy scroll na telefonie ({'; '.join(p.get('wystajace', [])[:3])})")
for t in twarde: print("- " + t)
sys.exit(1 if twarde else 0)
EOF
}

cmd_plan() {
  wymagaj_zadania; na_galezi_zadania; wymagaj_codex
  local plan="$PRACA/PLAN.md"
  wymagaj_intencji
  grep -q 'WYPEŁNIJ' "$plan" && blad "PLAN.md ma niewypełnione sekcje (znaczniki WYPEŁNIJ)." 40
  grep -Eq 'K1[[:space:]]*:' "$plan" || blad "PLAN.md nie ma kryteriów odbioru (K1: ...)." 40
  [ -n "$(test_cmd)" ] || blad "PLAN.md nie ma linii TEST_CMD: (komenda albo 'brak')." 40
  if [ -f "$PRACA/PLAN_ZIELONY" ] && [ "$(cat "$PRACA/PLAN_ZIELONY")" = "$(git hash-object "$plan")" ]; then
    echo "Ten plan już przeszedł recenzję. Nie ma czego sprawdzać ponownie."; exit 0
  fi

  local zrobione runda img
  MAX_RUND_PLANU=$((MAX_RUND_PLANU + $(dodatkowe plan)))
  zrobione="$(licz_rundy plan)"; runda=$((zrobione + 1))
  if [ "$runda" -gt "$MAX_RUND_PLANU" ]; then
    echo "STOP: wyczerpany limit $MAX_RUND_PLANU rund recenzji planu. Konrad może przyjąć plan (zatwierdz) albo dać dodatkową rundę."
    exit 20
  fi
  [ "$zrobione" -gt 0 ] && sprawdz_odpowiedzi plan "$zrobione"

  img="$(polacz "$(obrazy 2 "$ZRZUTY/wzor")" "$(obrazy_stron 2 "$ZRZUTY/przed")")"
  local pakiet="$PRACA/pakiet-plan-$runda.md"
  {
    cat "$KIT/prompty/recenzent-planu.md"
    echo ""; echo "# ZADANIE (słowami Konrada)"; cat "$PRACA/ZADANIE.txt"
    intencja
    [ -f "$PRACA/RANKING.md" ] && { echo ""; echo "# RANKING POMYSŁÓW (wybór do wdrożenia powinien z niego wynikać)"; cat "$PRACA/RANKING.md"; }
    echo ""; echo "# PLAN DO OCENY"; cat "$plan"
    if [ -n "$img" ]; then
      echo ""; echo "# DOŁĄCZONE ZRZUTY EKRANU"
      echo "Kolejność: $(printf '%s' "$img" | tr ',' '\n' | sed 's#.*/zrzuty/##' | tr '\n' ' ')"
      echo "('wzor' = strona-wzór, 'przed' = aplikacja przed zmianami)"
    fi
    if [ "$zrobione" -gt 0 ]; then
      echo ""; echo "# TWÓJ POPRZEDNI WERDYKT (runda $zrobione)"; cat "$PRACA/werdykt-plan-$zrobione.json"
      [ -f "$PRACA/ODPOWIEDZI.md" ] && { echo ""; echo "# ODPOWIEDZI WYKONAWCY (stanowisko wykonawcy, nie dowód)"; cat "$PRACA/ODPOWIEDZI.md"; }
    fi
  } > "$pakiet"

  echo "Recenzja planu, runda $runda/$MAX_RUND_PLANU..."
  uruchom_codex "$pakiet" "$PRACA/werdykt-plan-$runda.json" "$PRACA/codex-plan-$runda.log" "$img"
  ocen plan "$runda" "$MAX_RUND_PLANU"
}

cmd_ranking() {
  wymagaj_zadania; na_galezi_zadania; wymagaj_codex; wymagaj_intencji
  local pom="$PRACA/POMYSLY.md"
  [ -f "$pom" ] || { cp "$KIT/szablony/POMYSLY.md" "$pom"; blad "Utworzyłem $pom z szablonu. Wypełnij go kandydatami (4-10) i uruchom ranking ponownie." 40; }
  grep -q 'WYPEŁNIJ\|Przykładowa nazwa' "$pom" && blad "POMYSLY.md zawiera szablon (WYPEŁNIJ / przykład). Usuń go i wpisz prawdziwe pomysły." 40
  [ -f "$PRACA/RANKING.md" ] && blad "Ranking już jest ($PRACA/RANKING.md). Drugi ranking tylko na polecenie Konrada (usuń wtedy RANKING.md)." 40
  # wstępna kontrola formatu, zanim zapłacimy za GPT
  python3 "$KIT/narzedzia/ranking.py" "$pom" /dev/null /dev/null /dev/null >/dev/null 2>&1
  [ $? -eq 40 ] && { python3 "$KIT/narzedzia/ranking.py" "$pom" /dev/null /dev/null /dev/null; exit 40; }

  local pakiet="$PRACA/pakiet-ranking.md" slepa="$PRACA/pomysly-bez-ocen.md"
  # GPT dostaje pomysły BEZ ocen wykonawcy, żeby się nimi nie sugerował
  grep -Ev '^(Wartość|Dopasowanie|Koszt|Ryzyko)[[:space:]]*:' "$pom" | sed -E 's/Wartość:.*$//' > "$slepa"
  {
    cat "$KIT/prompty/recenzent-rankingu.md"
    echo ""; echo "# ZADANIE (słowami Konrada)"; cat "$PRACA/ZADANIE.txt"
    intencja
    echo ""; echo "# POMYSŁY DO OCENY"; cat "$slepa"
  } > "$pakiet"
  echo "GPT układa własny ranking pomysłów..."
  uruchom_codex "$pakiet" "$PRACA/ranking-gpt.json" "$PRACA/codex-ranking.log" "" "$KIT/schematy/ranking.json"
  python3 "$KIT/narzedzia/ranking.py" "$pom" "$PRACA/ranking-gpt.json" "$PRACA/RANKING.md" "$DZIENNIK"
  exit $?
}

cmd_zatwierdz() {
  wymagaj_zadania
  [ "$(licz_rundy plan)" -gt 0 ] || blad "Plan nie przeszedł jeszcze żadnej recenzji." 40
  git hash-object "$PRACA/PLAN.md" > "$PRACA/PLAN_ZIELONY"
  loguj ""; loguj "## Konrad przyjął plan mimo uwag recenzenta ($(teraz))"
  echo "OK. Plan przyjęty decyzją Konrada."
}

cmd_kod() {
  wymagaj_zadania; na_galezi_zadania; wymagaj_codex
  [ -f "$PRACA/PLAN_ZIELONY" ] || blad "Plan nie przeszedł recenzji. Najpierw: bash $SILNIK plan" 40
  [ "$(cat "$PRACA/PLAN_ZIELONY")" = "$(git hash-object "$PRACA/PLAN.md")" ] || blad "PLAN.md zmienił się po recenzji. Uruchom plan ponownie." 40

  local zrobione runda
  MAX_RUND_KODU=$((MAX_RUND_KODU + $(dodatkowe kod)))
  zrobione="$(licz_rundy kod)"; runda=$((zrobione + 1))
  if [ "$runda" -gt "$MAX_RUND_KODU" ]; then
    echo "STOP: wyczerpany limit $MAX_RUND_KODU rund recenzji kodu. Konrad decyduje: przyjąć, cofnąć albo dać dodatkową rundę."
    exit 20
  fi
  [ "$zrobione" -gt 0 ] && sprawdz_odpowiedzi kod "$zrobione"

  zapisz_prace "orkiestrator: praca w toku (runda $runda)"
  wypchnij
  [ -n "$(git diff "$BAZA" --name-only -- . ":(exclude).orkiestrator-raport")" ] || blad "Brak zmian w kodzie względem punktu startowego." 40

  czerwone_bez_gpt() {
    # czerwone_bez_gpt "powód" plik_szczegółów
    printf '{"werdykt":"POPRAWKI","podsumowanie":"%s Recenzja GPT pominięta.","uwagi":[]}\n' "$1" > "$PRACA/werdykt-kod-$runda.json"
    : > "$PRACA/krytyczne-kod-$runda.txt"
    { echo ""; echo "## KOD – runda $runda/$MAX_RUND_KODU: CZERWONE ($1)"; echo "_$(teraz)_"; echo ""; cat "$2"; } >> "$DZIENNIK"
    echo "CZERWONE: $1"; tail -n 30 "$2"; echo ""
    [ -f "$PRACA/ODPOWIEDZI.md" ] && mv "$PRACA/ODPOWIEDZI.md" "$PRACA/odpowiedzi-kod-$zrobione.md"
    if [ "$runda" -ge "$MAX_RUND_KODU" ]; then echo "BRAMKA: STOP. Ostatnia runda. Pokaż Konradowi stan i czekaj."; exit 20; fi
    echo "BRAMKA: zamknięta. Napraw (nie osłabiaj testów) i uruchom kod ponownie."; exit 10
  }

  # --- testy (uruchamia skrypt, nie wykonawca)
  local tcmd test_wynik="$PRACA/testy-$runda.log" test_rc=0
  tcmd="$(test_cmd)"
  if [ "$tcmd" = "brak" ] || [ -z "$tcmd" ]; then
    echo "Brak testów automatycznych w planie (TEST_CMD: brak)." > "$test_wynik"
  else
    echo "Uruchamiam testy: $tcmd"
    z_limitem "$LIMIT_TESTU_S" /bin/sh -c "$tcmd" > "$test_wynik" 2>&1
    test_rc=$?
    [ "$test_rc" -ne 0 ] && czerwone_bez_gpt "Testy nie przeszły (kod $test_rc)." "$test_wynik"
  fi

  # --- oczy (jeśli zadanie ma strony do obejrzenia)
  local oczy_info="$PRACA/oczy-$runda.txt"
  : > "$oczy_info"
  if [ -s "$PRACA/STRONY.txt" ]; then
    ( cmd_oczy po ) > "$oczy_info" 2>&1 || czerwone_bez_gpt "Zrzuty aplikacji się nie udały." "$oczy_info"
    if ! bramka_oczu > "$PRACA/oczy-twarde-$runda.txt"; then
      czerwone_bez_gpt "Automatyczna kontrola wyglądu wykryła twarde błędy." "$PRACA/oczy-twarde-$runda.txt"
    fi
  fi

  # --- pakiet dla recenzenta
  local pakiet="$PRACA/pakiet-kod-$runda.md" diff_plik="$PRACA/zmiany-$runda.diff" limit_b img
  git diff "$BAZA" -- . ":(exclude).orkiestrator-raport" ":(exclude)package-lock.json" ":(exclude)pnpm-lock.yaml" ":(exclude)yarn.lock" > "$diff_plik"
  limit_b=$((MAX_DIFF_KB * 1024))
  img="$(polacz "$(obrazy 2 "$ZRZUTY/wzor")" "$(obrazy_stron 6 "$ZRZUTY/po")")"
  {
    cat "$KIT/prompty/recenzent-kodu.md"
    echo ""; echo "# ZADANIE (słowami Konrada)"; cat "$PRACA/ZADANIE.txt"
    intencja
    echo ""; echo "# PLAN Z KRYTERIAMI ODBIORU"; cat "$PRACA/PLAN.md"
    echo ""; echo "# WYNIK TESTÓW (uruchomione przez skrypt, kod wyjścia: $test_rc)"; tail -n 80 "$test_wynik"
    if [ -s "$oczy_info" ]; then
      echo ""; echo "# AUTOMATYCZNA KONTROLA WYGLĄDU (zrzuty 'po')"; grep -v '^Robię\|^Zrzuty w' "$oczy_info"
    fi
    if [ -n "$img" ]; then
      echo ""; echo "# DOŁĄCZONE ZRZUTY EKRANU"
      echo "Kolejność: $(printf '%s' "$img" | tr ',' '\n' | sed 's#.*/zrzuty/##' | tr '\n' ' ')"
      echo "('wzor' = strona-wzór, 'po' = aplikacja po zmianach)"
    fi
    echo ""; echo "# LISTA ZMIENIONYCH PLIKÓW"; git diff "$BAZA" --stat -- . ":(exclude).orkiestrator-raport"
    if [ "$zrobione" -gt 0 ]; then
      echo ""; echo "# TWÓJ POPRZEDNI WERDYKT (runda $zrobione)"; cat "$PRACA/werdykt-kod-$zrobione.json"
      [ -f "$PRACA/ODPOWIEDZI.md" ] && { echo ""; echo "# ODPOWIEDZI WYKONAWCY (stanowisko wykonawcy, nie dowód)"; cat "$PRACA/ODPOWIEDZI.md"; }
    fi
    echo ""; echo "# ZMIANY WZGLĘDEM STANU SPRZED ZADANIA"
    if [ "$(wc -c < "$diff_plik" | tr -d ' ')" -gt "$limit_b" ]; then
      head -c "$limit_b" "$diff_plik"; echo ""
      echo "[DIFF UCIĘTY po ${MAX_DIFF_KB} KB. Resztę przeczytaj z plików w repozytorium.]"
    else
      cat "$diff_plik"
    fi
  } > "$pakiet"

  echo "Recenzja kodu, runda $runda/$MAX_RUND_KODU. GPT czyta zmiany i ogląda zrzuty..."
  uruchom_codex "$pakiet" "$PRACA/werdykt-kod-$runda.json" "$PRACA/codex-kod-$runda.log" "$img"
  ocen kod "$runda" "$MAX_RUND_KODU"
}

cmd_raport() {
  wymagaj_zadania
  python3 "$KIT/narzedzia/raport.py" "$PRACA" >/dev/null || blad "Nie udało się zbudować raportu." 30
  if [ "$CHMURA" = 1 ]; then
    raport_chmura
  else
    if command -v open >/dev/null 2>&1 && open "$PRACA/RAPORT.html" >/dev/null 2>&1; then
      echo "Raport otwarty w przeglądarce: $ROOT/$PRACA/RAPORT.html"
    else
      echo "Raport: $ROOT/$PRACA/RAPORT.html"
    fi
  fi
}

raport_chmura() {
  na_galezi_zadania
  local slug baza sha="" n url body_json
  slug="$(repo_slug)"
  [ -n "$slug" ] || blad "Nie rozpoznaję repozytorium na GitHubie (origin)." 30
  zapisz_prace "orkiestrator: stan do raportu"

  # Zrzuty: zapisujemy je w jednym commicie i od razu usuwamy w następnym.
  # Obrazki w PR odwołują się do tamtego commita, a do głównej gałęzi nic z nich nie trafi.
  if ls "$ZRZUTY"/*/*.png >/dev/null 2>&1; then
    rm -rf .orkiestrator-raport
    local etap
    for etap in wzor przed po; do
      [ -d "$ZRZUTY/$etap" ] || continue
      mkdir -p ".orkiestrator-raport/$etap"
      cp "$ZRZUTY/$etap"/*.png ".orkiestrator-raport/$etap/" 2>/dev/null
    done
    git add -f .orkiestrator-raport >/dev/null 2>&1
    git commit -q -m "orkiestrator: zrzuty do raportu (usuwane w następnym commicie)" && sha="$(git rev-parse HEAD)"
    git rm -rq .orkiestrator-raport >/dev/null 2>&1
    git commit -q -m "orkiestrator: sprzątanie zrzutów" >/dev/null 2>&1
    rm -rf .orkiestrator-raport
  fi
  git push -q -u origin "$GALAZ" >/dev/null 2>&1 || blad "Nie udało się wysłać gałęzi $GALAZ na GitHuba." 30

  local obrazki=""
  [ -n "$sha" ] && obrazki="https://github.com/$slug/blob/$sha/.orkiestrator-raport"
  python3 "$KIT/narzedzia/raport_pr.py" "$PRACA" "$obrazki" > "$PRACA/RAPORT_PR.md" || blad "Nie udało się zbudować treści raportu." 30

  baza="$(galaz_bazowa)"
  printf '%s\n' "$baza" > "$PRACA/BAZA_PR"
  body_json="$PRACA/pr.json"
  python3 - "$PRACA/RAPORT_PR.md" "$(head -1 "$PRACA/ZADANIE.txt")" "$GALAZ" "$baza" > "$body_json" <<'EOF'
import json, sys
body = open(sys.argv[1], encoding="utf-8").read()
print(json.dumps({"title": "orkiestrator: " + sys.argv[2][:90], "body": body, "head": sys.argv[3], "base": sys.argv[4]}))
EOF

  n="$(pr_numer)"
  if [ -n "$n" ]; then
    url="$(gh_api -X PATCH "repos/$slug/pulls/$n" --input "$body_json" --jq .html_url)"
  else
    url="$(gh_api -X POST "repos/$slug/pulls" --input "$body_json" --jq '.html_url')"
    n="$(printf '%s' "$url" | sed -E 's#.*/pull/([0-9]+).*#\1#')"
    [ -n "$url" ] && printf '%s\n' "$n" > "$PRACA/PR"
  fi

  if [ -z "$url" ]; then
    echo "UWAGA: nie udało się utworzyć PR przez API GitHuba (szczegóły: $ROOT/$PRACA/github.log)."
    echo "Gałąź $GALAZ jest na GitHubie. Treść raportu: $ROOT/$PRACA/RAPORT_PR.md"
    echo "Utwórz PR wbudowanym przyciskiem sesji (Create PR) i wklej tę treść jako opis."
    exit 30
  fi
  printf '%s\n' "$url" > "$PRACA/PR_URL"
  loguj ""; loguj "## Raport: $url ($(teraz))"
  echo "OK. Raport (PR): $url"
  echo "Baza PR: $baza. Podgląd na żywo pojawi się w PR jako komentarz Vercela, jeśli projekt jest z nim połączony."
}

cmd_przyjmij() {
  wymagaj_zadania; na_galezi_zadania
  local opis; opis="$(head -1 "$PRACA/ZADANIE.txt")"
  zapisz_prace "orkiestrator: $opis"
  if [ "$CHMURA" = 1 ]; then
    local slug n baza wynik
    slug="$(repo_slug)"
    n="$(pr_numer)"
    [ -n "$n" ] || blad "Nie ma PR dla tego zadania. Najpierw: bash $SILNIK raport" 40
    git push -q origin "$GALAZ" >/dev/null 2>&1 || blad "Nie udało się wysłać ostatnich zmian na GitHuba." 30
    baza="$(cat "$PRACA/BAZA_PR" 2>/dev/null || galaz_bazowa)"
    wynik="$(gh_api -X PUT "repos/$slug/pulls/$n/merge" -f merge_method=squash -f commit_title="orkiestrator: $opis" --jq .merged)"
    if [ "$wynik" != "true" ]; then
      blad "GitHub nie scalił PR #$n (konflikt albo blokada gałęzi). Nic nie zostało zmienione. Szczegóły: $ROOT/$PRACA/github.log" 30
    fi
    git fetch -q origin "$baza" >/dev/null 2>&1
    git switch -q "$baza" 2>/dev/null || git switch -q -c "$baza" --track "origin/$baza" 2>/dev/null
    git pull -q --ff-only >/dev/null 2>&1
    printf '%s przyjęte (PR #%s scalony do %s)\n' "$(teraz)" "$n" "$baza" > "$PRACA/ZAKONCZONE"
    loguj ""; loguj "## PRZYJĘTE przez Konrada ($(teraz)). PR #$n scalony do $baza."
    echo "OK. PR #$n scalony do $baza."
    echo "Jeśli projekt jest połączony z Vercelem, wersja produkcyjna odświeży się za 1–2 minuty."
    echo "Cofnięcie w razie czego: przycisk Revert w tym PR na GitHubie."
    return 0
  fi
  git switch -q "$ORYG" || blad "Nie udało się przełączyć na gałąź $ORYG." 30
  if ! git merge -q --no-ff "$GALAZ" -m "orkiestrator: $opis"; then
    git merge --abort >/dev/null 2>&1
    git switch -q "$GALAZ"
    blad "Zmiany kolidują z tym, co jest na gałęzi $ORYG. Nic nie zostało zmienione. Trzeba to rozwiązać ręcznie (Claude Code może pomóc)." 30
  fi
  printf '%s przyjęte\n' "$(teraz)" > "$PRACA/ZAKONCZONE"
  loguj ""; loguj "## PRZYJĘTE przez Konrada ($(teraz)). Zmiany są na gałęzi $ORYG. Nic nie zostało wysłane na serwer."
  echo "OK. Zmiany są na gałęzi $ORYG (bez wysyłania na serwer)."
  [ -f "$PRACA/WIP" ] && echo "Niezapisane zmiany Konrada sprzed zadania też zostały zapisane w historii."
  echo "Cofnięcie w razie czego: git revert -m 1 HEAD"
}

cmd_cofnij() {
  wymagaj_zadania
  [ "$(git rev-parse --abbrev-ref HEAD)" = "$GALAZ" ] && zapisz_prace "orkiestrator: stan odrzucony przez Konrada"
  if [ "$CHMURA" = 1 ]; then
    local n; n="$(pr_numer)"
    if [ -n "$n" ]; then
      gh_api -X PATCH "repos/$(repo_slug)/pulls/$n" -f state=closed >/dev/null \
        && echo "PR #$n zamknięty bez scalania." \
        || echo "UWAGA: nie udało się zamknąć PR #$n. Zamknij go na GitHubie (nic nie trafiło do głównej gałęzi)."
    fi
    wypchnij
  fi
  git switch -q "$ORYG" 2>/dev/null || git switch -q "$(galaz_bazowa)" 2>/dev/null || blad "Nie udało się przełączyć na gałąź $ORYG." 30
  if [ -f "$PRACA/WIP" ]; then
    git cherry-pick -n "$(cat "$PRACA/WIP")" >/dev/null 2>&1 && git reset -q \
      || blad "Nie udało się przywrócić niezapisanych zmian. Są bezpieczne w commicie $(cut -c1-7 < "$PRACA/WIP") na gałęzi $GALAZ." 30
    echo "Niezapisane zmiany Konrada wróciły na swoje miejsce."
  fi
  printf '%s cofnięte\n' "$(teraz)" > "$PRACA/ZAKONCZONE"
  loguj ""; loguj "## COFNIĘTE przez Konrada ($(teraz)). Gałąź $GALAZ zostaje jako archiwum."
  echo "OK. Wszystko jak przed zadaniem. Odrzucona wersja zostaje w archiwum na gałęzi $GALAZ."
}

cmd_dodaj_runde() {
  wymagaj_zadania
  local faza="${1:-}"
  [ "$faza" = "plan" ] || [ "$faza" = "kod" ] || blad "Podaj fazę: dodaj-runde plan|kod" 40
  printf '%s\n' "$(teraz)" >> "$PRACA/DODATKOWE-$faza"
  loguj ""; loguj "## Konrad przyznał dodatkową rundę recenzji: $faza ($(teraz))"
  echo "OK. Dodatkowa runda ($faza) przyznana przez Konrada."
}

cmd_status() {
  [ -f "$PRACA/BAZA" ] || { echo "Brak aktywnego zadania."; exit 0; }
  echo "Tryb: $([ "$CHMURA" = 1 ] && echo chmura || echo lokalnie)"
  echo "Zadanie: $(cat "$PRACA/ZADANIE.txt")"
  echo "Gałąź robocza: $(cat "$PRACA/GALAZ") (Konrada: $(cat "$PRACA/ORYG")), teraz na: $(git rev-parse --abbrev-ref HEAD)"
  echo "Rundy planu: $(licz_rundy plan), rundy kodu: $(licz_rundy kod)"
  [ -f "$PRACA/PLAN_ZIELONY" ] && echo "Plan: po recenzji" || echo "Plan: przed recenzją"
  [ -f "$PRACA/PR_URL" ] && echo "Raport: $(cat "$PRACA/PR_URL")"
  [ -f "$PRACA/ZAKONCZONE" ] && echo "Stan: $(cat "$PRACA/ZAKONCZONE")"
  exit 0
}

# ---------------------------------------------------------------- przygotowanie i logowanie

bez_kolorow() { perl -pe 's/\e\[[0-9;?]*[A-Za-z]//g; s/\r//g'; }

siec_openai() {
  # 0 = serwery OpenAI osiągalne (bez klucza odpowiadają 401), 1 = zablokowane
  local kod
  kod="$(curl -sS -o /dev/null -m 15 -w '%{http_code}' https://api.openai.com/v1/models 2>/dev/null)"
  [ "$kod" = "401" ] || [ "$kod" = "200" ]
}

cmd_przygotuj() {
  local gotowe=1 brak=""
  echo "Przygotowanie orkiestratora ($([ "$CHMURA" = 1 ] && echo chmura || echo lokalnie))"
  for prog in git python3 perl node npm curl; do
    command -v "$prog" >/dev/null 2>&1 || brak="$brak $prog"
  done
  [ -z "$brak" ] || blad "Brakuje programów:$brak. Na Macu: zainstaluj Node.js LTS (nodejs.org) i narzędzia Xcode (xcode-select --install)." 30
  echo "  ✓ podstawowe programy"

  mkdir -p "$NARZ"
  [ -f "$NARZ/package.json" ] || printf '{"name":"orkiestrator-narzedzia","private":true}\n' > "$NARZ/package.json"

  if ! command -v codex >/dev/null 2>&1; then
    echo "  • instaluję Codex (GPT)..."
    npm install --prefix "$NARZ" --no-audit --no-fund --silent @openai/codex >/dev/null 2>&1 \
      || blad "Nie udało się zainstalować Codexa (npm install @openai/codex)." 30
  fi
  echo "  ✓ Codex $(codex --version 2>/dev/null | head -1 | sed 's/^codex-cli //')"

  if [ ! -d "$NARZ/node_modules/playwright" ]; then
    echo "  • instaluję Playwright (zrzuty ekranu)..."
    npm install --prefix "$NARZ" --no-audit --no-fund --silent playwright >/dev/null 2>&1 \
      || { echo "  ✗ nie udało się zainstalować Playwright; zrzuty ekranu będą niedostępne"; }
  fi
  if [ -d "$NARZ/node_modules/playwright" ]; then
    if ORK_NARZ="$NARZ" node "$KIT/narzedzia/oczy.mjs" --sprawdz >/dev/null 2>&1; then
      echo "  ✓ oczy (przeglądarka do zrzutów)"
    else
      echo "  • pobieram przeglądarkę do zrzutów..."
      local deps=""
      [ "$(uname)" = "Linux" ] && [ "$(id -u)" = "0" ] && deps="--with-deps"
      ( cd "$NARZ" && z_limitem 600 ./node_modules/.bin/playwright install $deps chromium >/dev/null 2>&1 )
      if ORK_NARZ="$NARZ" node "$KIT/narzedzia/oczy.mjs" --sprawdz >/dev/null 2>&1; then
        echo "  ✓ oczy (przeglądarka do zrzutów)"
      else
        echo "  ✗ przeglądarka do zrzutów nie działa; bot zrobi zadanie bez zrzutów ekranu"
      fi
    fi
  fi

  if siec_openai; then
    echo "  ✓ dostęp do serwerów OpenAI"
  else
    gotowe=0
    echo "  ✗ BRAK dostępu do serwerów OpenAI"
    if [ "$CHMURA" = 1 ]; then
      echo "    Konrad musi raz zmienić ustawienia środowiska w Claude Code (claude.ai/code):"
      echo "    ikona środowiska → Edytuj → Dostęp do sieci: Pełny (Full) → Zapisz. Potem: przygotuj ponownie."
    else
      echo "    Sprawdź połączenie z internetem."
    fi
  fi

  if codex login status >/dev/null 2>&1; then
    echo "  ✓ Codex zalogowany"
  elif [ -n "${OPENAI_API_KEY:-}" ] && printenv OPENAI_API_KEY | codex login --with-api-key >/dev/null 2>&1; then
    echo "  ✓ Codex zalogowany kluczem API (rozliczenie według zużycia)"
  else
    gotowe=0
    echo "  ✗ Codex niezalogowany → uruchom: bash $SILNIK zaloguj"
  fi

  echo ""
  if [ "$gotowe" = 1 ]; then echo "GOTOWE. Można pracować."; exit 0; fi
  echo "NIEGOTOWE. Wykonaj kroki oznaczone ✗ i uruchom przygotuj ponownie."
  exit 30
}

cmd_zaloguj() {
  command -v codex >/dev/null 2>&1 || blad "Brak programu codex. Najpierw: bash $SILNIK przygotuj" 30
  if codex login status >/dev/null 2>&1; then echo "OK. Codex jest już zalogowany."; exit 0; fi
  if [ -n "${OPENAI_API_KEY:-}" ] && printenv OPENAI_API_KEY | codex login --with-api-key >/dev/null 2>&1; then
    echo "OK. Codex zalogowany kluczem API."; exit 0
  fi
  siec_openai || blad "Brak dostępu do serwerów OpenAI. Najpierw: bash $SILNIK przygotuj (pokaże, co zmienić)." 30

  local log="$HOME/.orkiestrator/logowanie.log" pidf="$HOME/.orkiestrator/logowanie.pid" polecenie
  mkdir -p "$HOME/.orkiestrator"
  # poprzednia, niedokończona próba logowania
  if [ -s "$pidf" ]; then kill "$(cat "$pidf")" >/dev/null 2>&1; rm -f "$pidf"; fi
  : > "$log"
  if [ "$CHMURA" = 1 ] || [ "$(uname)" != "Darwin" ]; then
    polecenie="codex login --device-auth"
  else
    polecenie="codex login"
  fi
  # Codex wypisuje kod tylko do terminala, więc uruchamiamy go z pseudo-terminalem w tle.
  if [ "$(uname)" = "Darwin" ]; then
    nohup script -q /dev/null $polecenie > "$log" 2>&1 &
  else
    nohup script -qfec "$polecenie" /dev/null > "$log" 2>&1 &
  fi
  echo $! > "$pidf"

  local i adres kod
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    sleep 1
    adres="$(bez_kolorow < "$log" | grep -Eo 'https://[^ ]+' | head -1)"
    kod="$(bez_kolorow < "$log" | grep -Eo '\b[A-Z0-9]{4}-[A-Z0-9]{4,6}\b' | head -1)"
    if [ -n "$kod" ] || { [ "$polecenie" = "codex login" ] && [ -n "$adres" ]; }; then break; fi
    codex login status >/dev/null 2>&1 && { echo "OK. Codex zalogowany."; exit 0; }
  done

  if [ -n "$kod" ]; then
    echo "LOGOWANIE CODEXA – przekaż Konradowi dokładnie to:"
    echo "  1. Otwórz na telefonie lub komputerze: $adres"
    echo "  2. Zaloguj się kontem ChatGPT i wpisz kod: $kod (ważny 15 minut)"
    echo "  3. Napisz „gotowe”."
    echo "Potem sprawdź: bash $SILNIK przygotuj"
    exit 0
  fi
  if [ "$polecenie" = "codex login" ] && [ -n "$adres" ]; then
    echo "Otworzyła się przeglądarka z logowaniem do ChatGPT. Jeśli nie, otwórz: $adres"
    echo "Po zalogowaniu sprawdź: bash $SILNIK przygotuj"
    exit 0
  fi
  echo "BŁĄD: Codex nie pokazał kodu logowania. Ostatnie linie:"
  bez_kolorow < "$log" | tail -n 8
  exit 30
}

cmd_test() {
  wymagaj_codex
  local tmp="$HOME/.orkiestrator/test-polaczenia"; mkdir -p "$HOME/.orkiestrator"
  PRACA="$HOME/.orkiestrator"; DZIENNIK="$PRACA/test-dziennik.md"; ROOT="$HOME/.orkiestrator"
  printf '%s\n' "Test połączenia. Niczego nie czytaj i nie uruchamiaj. Zwróć werdykt OK, pustą listę uwag i podsumowanie: test udany." > "$tmp.md"
  # ~/.orkiestrator nie jest repozytorium git, a Codex bez tej flagi odmawia pracy poza nim.
  ( cd "$ROOT" && CODEX_DODATKOWE="--skip-git-repo-check" uruchom_codex "$tmp.md" "$tmp.json" "$tmp.log" ) || exit 30
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["werdykt"] in ("OK","POPRAWKI"); print("OK. GPT odpowiada:", d.get("podsumowanie",""))' "$tmp.json" \
    || blad "Codex odpowiedział, ale nie w wymaganym formacie. Szczegóły: $tmp.log" 30
}

polecenie="${1:-}"
[ $# -gt 0 ] && shift
case "$polecenie" in
  przygotuj) cmd_przygotuj ;;
  zaloguj) cmd_zaloguj ;;
  test) cmd_test ;;
  start|oczy|ranking|plan|zatwierdz|kod|raport|przyjmij|cofnij|dodaj-runde|status) wejdz_do_repo ;;
  *) sed -n '2,25p' "$0"; exit 40 ;;
esac
case "$polecenie" in
  start) cmd_start "$@" ;;
  oczy) cmd_oczy "$@" ;;
  ranking) cmd_ranking ;;
  plan) cmd_plan ;;
  zatwierdz) cmd_zatwierdz ;;
  kod) cmd_kod ;;
  raport) cmd_raport ;;
  przyjmij) cmd_przyjmij ;;
  cofnij) cmd_cofnij ;;
  dodaj-runde) cmd_dodaj_runde "$@" ;;
  status) cmd_status ;;
esac
