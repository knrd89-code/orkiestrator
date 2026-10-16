# Profesjonalny UI: minimum, poniżej którego nie schodzisz

Czytaj przy każdym zadaniu, które zmienia wygląd.

## Wzór
- „Podobny do X” = ten sam **klimat**: układ, gęstość, typografia, paleta, styl komponentów, mikrointerakcje. Nigdy: logo, nazwy, teksty, ilustracje, zdjęcia ani ikony marki X.
- Zanim zaczniesz, zapisz w PLAN.md (WZÓR I KIERUNEK) konkretne wartości: kolory jako tokeny (tło, powierzchnia, tekst, tekst wyciszony, akcent, błąd, sukces), krój i skala pisma, siatka odstępów, promienie, cienie.
- Brak wzoru = wybierz jeden spójny kierunek pasujący do odbiorców aplikacji i nazwij go w planie. Nie mieszaj stylów.

## System, nie pojedyncze ekrany
- Kolory, odstępy, promienie i rozmiary pisma jako zmienne (tokeny) w jednym miejscu. Zero „magicznych” wartości porozrzucanych po komponentach.
- Odstępy z jednej skali (np. 4, 8, 12, 16, 24, 32, 48, 64).
- Skala typograficzna 4–6 rozmiarów, najwyżej 2 kroje, czytelny tekst główny 15–17 px, interlinia 1.4–1.6.
- Jeden kolor akcentu na główne działania. Przycisk główny jeden na widok.

## Hierarchia i czytelność
- Na każdym ekranie od razu widać, co jest najważniejsze i co mam zrobić dalej.
- Kontrast tekstu co najmniej 4.5:1 (duży tekst 3:1). Oczy sprawdzają to automatycznie, ale gradienty i zdjęcia oceniasz sam.
- Długość linii tekstu 50–80 znaków.

## Stany
Każdy element interaktywny ma: zwykły, najechanie, fokus z klawiatury (widoczny!), wciśnięty, wyłączony. Każda lista lub widok danych ma: pusty stan z podpowiedzią, ładowanie (szkielet zamiast samego kółka), błąd z wyjściem z sytuacji.

## Telefon
- Sprawdzasz na 390 px szerokości. Zero poziomego przewijania.
- Cele dotykowe co najmniej 44×44 px.
- Nawigacja dostępna kciukiem; tabele zamieniają się w karty albo przewijają się w swoim kontenerze.

## Ruch
Subtelny i krótki (150–250 ms), z poszanowaniem ustawienia „ogranicz ruch”. Animacja ma tłumaczyć zmianę, nie zdobić.

## Treść
- Teksty interfejsu po polsku, konkretne: „Zapisz opinię” zamiast „Zatwierdź”.
- Zero lorem ipsum i zero wymyślonych danych udających prawdziwe.

## Samokontrola przed oddaniem
1. `oczy po` i obejrzyj każdy zrzut (Read na .png), obok zrzutu wzoru.
2. Zapytaj siebie: czy ktoś, kto zna wzór, rozpozna klimat? Czy coś wygląda „domyślnie”, jak nieostylowany komponent?
3. Popraw, zrób zrzuty jeszcze raz. Dopiero potem `kod`.
