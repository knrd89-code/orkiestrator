# Orkiestrator

Mówisz, czego chcesz. Bot dopytuje, szuka, wybiera, robi i pokazuje efekt. Ty decydujesz raz, na końcu.

```
/zrob nowe funkcje dla rodziców w Pan Pomocniku
/zrob UI w klimacie linear.app
/zrob eksport opinii do PDF
```

Działa w chmurze (claude.ai/code, także z telefonu) i lokalnie na Macu. To repozytorium jest silnikiem. Skill `zrob` na koncie Claude sam go pobiera na początku każdej sesji.

## Jak przebiega zadanie

1. **Rozmowa.** Mglista prośba: kilka pytań z odpowiedziami do kliknięcia i „rozumiem to tak…”. Jasna: od razu do roboty.
2. **Osobna gałąź.** Główna gałąź jest nietknięta, dopóki nie powiesz „zostaw”.
3. **Rozpoznanie.** Kod, konkurencja, dobre praktyki. Przy wyglądzie zrzuty wzoru i aplikacji na komputerze i telefonie.
4. **Ranking** przy prośbach typu „nowe funkcje”. Bot ocenia pomysły, GPT ocenia je niezależnie. Wchodzą tylko te, które wygrywają w obu rankingach.
5. **Plan** z kryteriami „gotowe, gdy…”. GPT go sprawdza.
6. **Robota** z samokontrolą na zrzutach.
7. **Recenzja.** Silnik sam uruchamia testy, robi zrzuty i łapie twarde błędy. GPT ogląda kod i zrzuty.
8. **Raport.** Lokalnie strona w przeglądarce, w chmurze PR na GitHubie ze zrzutami przed/po. Piszesz: **zostaw**, **cofnij** albo **popraw: …**

W chmurze „zostaw” scala PR. Projekt połączony z Vercelem trafia wtedy na produkcję.

## Konfiguracja chmury (raz)

1. **Skill.** Zapisz skill `zrob` na swoim koncie Claude. Sesje w chmurze i Claude Code na Macu wczytują go same.
2. **Dostęp do sieci.** W claude.ai/code otwórz ustawienia środowiska i ustaw **Dostęp do sieci: Pełny (Full)**. GPT (serwery OpenAI) i zrzuty stron-wzorów tego potrzebują.
3. **Skrypt startowy (opcjonalnie, przyspiesza sesje).** W tym samym oknie, pole *Setup script*:
   ```bash
   npm install -g @openai/codex
   mkdir -p ~/.orkiestrator/narzedzia && cd ~/.orkiestrator/narzedzia && npm init -y >/dev/null && npm install playwright && npx playwright install --with-deps chromium
   ```
   Bez tego silnik doinstaluje wszystko sam, tylko o minutę wolniej.
4. **Logowanie do GPT.** Do wyboru:
   - **Subskrypcja ChatGPT (bez dopłat):** w każdej nowej sesji bot poda kod. Otwierasz link na telefonie, logujesz się do ChatGPT i wpisujesz kod. Zajmuje to 20 sekund.
   - **Klucz API OpenAI (zero klikania, płatne według zużycia):** dodaj `OPENAI_API_KEY=...` w zmiennych środowiska. Nie wklejaj klucza w rozmowę.
5. **Aplikacja widoczna dla bota (opcjonalnie).** Jeśli aplikacja potrzebuje kluczy do startu (baza danych itp.), dodaj je jako zmienne środowiska. Bez nich bot zrobi zadanie bez zrzutów aplikacji i powie Ci o tym w raporcie.

## Bezpieczniki

| Ryzyko | Co go blokuje |
|---|---|
| Bot źle zrozumiał intencję | Pytania na start i „rozumiem to tak…”. Bez zapisanej intencji plan nie ruszy. |
| Modne pomysły zamiast potrzebnych | Ranking według Twojego celu i ślepa druga opinia GPT. Każdy pomysł musi mieć źródło. |
| GPT ocenia opis zamiast pracy | Silnik sam wycina zmiany, uruchamia testy i robi zrzuty. |
| GPT zasypuje drobiazgami | Blokują tylko uwagi krytyczne z konkretnym dowodem. |
| Kłótnia modeli do rana | Limit rund, potem STOP i decyzja należy do Ciebie. |
| „Podobny do X” zamienia się w plagiat | Bot bierze klimat, układ i typografię. Nigdy logo, tekstów ani grafik. |
| Zepsuta apka | Osobna gałąź i PR. „Cofnij” zamyka PR, do głównej gałęzi nic nie trafia. |
| Hasła w historii zmian | Pliki z kluczami poza .gitignore blokują zapis. |
| Publikacja bez Twojej zgody | Do głównej gałęzi trafia tylko to, przy czym napiszesz „zostaw”. |
| Śmieci w projekcie | Pliki robocze leżą w `.orkiestrator/`, wykluczonym z gita. Zrzuty do raportu nie trafiają do głównej gałęzi. |

## Pliki

- `silnik.sh`: wszystkie kroki (`przygotuj`, `zaloguj`, `start`, `ranking`, `oczy`, `plan`, `kod`, `raport`, `przyjmij`, `cofnij`).
- `prompty/`: instrukcje dla recenzenta GPT.
- `wiedza/`: jak prowadzić rozmowę, szukać pomysłów i robić profesjonalny UI.
- `ustawienia.conf`: limity rund, czasy i poziom rozumowania recenzenta GPT (osobno dla rankingu, planu i kodu).
- `skill/zrob/SKILL.md`: kopia skilla.
- `testy/test-silnika.sh`: testy bramek i ponowień z atrapą GPT (offline, kilka sekund): `bash testy/test-silnika.sh`.
