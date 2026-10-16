# Rozmowa na start i szukanie pomysłów

## Kiedy pytać
Pytasz tylko wtedy, gdy od odpowiedzi zależy, **co** budujesz, a nie jak. Sprawdź najpierw w kodzie, CLAUDE.md i STAN.md wszystko, co da się sprawdzić samemu. Konrad nie jest programistą: nie pytaj o technologię, biblioteki ani strukturę plików. To Twoja działka.

Typowe luki warte pytania:
- dla kogo jest zmiana (on sam, pracownicy, rodzice, klienci),
- jaki problem ma rozwiązać, czyli co go dziś uwiera,
- czego na pewno nie chce, a co jest święte i nie wolno tego ruszać,
- gdzie są granice: czas, pieniądze, dane osobowe.

## Jak pytać
- Narzędzie do pytań wielokrotnego wyboru (AskUserQuestion), jeśli jest dostępne: 1–4 pytania naraz, każde z 2–4 konkretnymi odpowiedziami, z pierwszą oznaczoną jako zalecana. Konrad zawsze może dopisać własną.
- Odpowiedzi mają być konkretne, np. „Rodzice dzieci z poradni”, a nie „Inni użytkownicy”.
- Najwyżej dwie tury pytań. Potem bierzesz najrozsądniejsze założenie i zapisujesz je w INTENCJA.md.
- Naprowadzaj, jeśli widzisz, że Konrad prosi o rozwiązanie, a nie o efekt. Przykład: „Chcesz czatu z AI w apce. Czy chodzi o to, żeby rodzice szybciej dostawali odpowiedzi? Jeśli tak, to tańsze może być FAQ z wyszukiwarką.” Podaj opcję, nie wykład.

## Potwierdzenie
Po pytaniach napisz jeden akapit: „Rozumiem to tak: …” (cel, dla kogo, co uznamy za sukces, czego nie ruszamy). Czekaj na „tak” albo korektę. Bez pytań wystarczy jedno zdanie „Rozumiem to tak: …” i od razu ruszasz.

## Szukanie pomysłów (gdy prośba jest otwarta)
Otwarta prośba to np. „nowe funkcje”, „co dodać”, „ulepsz apkę”. Konkretna prośba („dodaj eksport do PDF”) nie wymaga rankingu.

Źródła, w tej kolejności:
1. **Kod i dane aplikacji**: co jest w połowie zrobione, co się powtarza, gdzie użytkownik robi coś ręcznie, czego brakuje w oczywistym przepływie.
2. **Konkurencja**: 2–4 konkretne aplikacje z tej samej dziedziny (wyszukiwarka). Co mają, czego tu brakuje, i czy to w ogóle pasuje do celu Konrada.
3. **Sprawdzone praktyki** dla tego typu aplikacji: dostępność, bezpieczeństwo, wydajność, wdrażanie nowego użytkownika.

Każdy pomysł w POMYSLY.md ma źródło. Pomysł bez źródła to wymysł i nie wchodzi do rankingu. Oceniasz uczciwie, a koszt i ryzyko liczą się tak samo jak efekt „wow”.

## Wybór
Po `ranking` wdrażasz rekomendację: pomysły z pierwszej trójki obu rankingów, najwyżej 3 naraz. Gdy rankingi się rozjechały albo GPT zgłosił poważne ostrzeżenie (prawo, dane osobowe), pokaż Konradowi 2–3 zdania i zapytaj o wybór jednym pytaniem. W przeciwnym razie napisz mu jedną linią, co wybrałeś i dlaczego, i ruszaj bez czekania.
