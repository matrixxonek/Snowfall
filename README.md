# ❄️ Snowfall

Efekty pogodowe na pulpicie macOS: śnieg osiadający na oknach, liście, sakura, deszcz spływający po szybach i świetliki. Można też lepić bałwany.

Aplikacja działa z paska menu, a kliknięcia przechodzą przez efekty do okien pod spodem.

## Funkcje

- **5 efektów:** śnieg, liście, sakura, deszcz, świetliki; trzy poziomy intensywności
- **Zaspy na oknach:** śnieg osiada na górnych krawędziach okien (z zaokrąglonymi rogami) i na dole ekranu; spada, gdy ruszysz oknem
- **Interakcja z kursorem:** płatki się rozsuwają, liście dają się rozrzucić, a świetliki zlatują się do kursora, który stoi w miejscu
- **Podmuchy wiatru** co jakiś czas zwiewają zaspy i liście (albo ręcznie z menu)
- **Lepienie bałwanów:** w trybie lepienia toczysz kule po zaspach, a ułożone jedna na drugiej zamieniają się w bałwana
- **Wiele monitorów:** płatki przelatują między ekranami
- **Ustawianie tapety** z menu
- Mniej cząstek w trybie niskiego zużycia energii; pauza przy uśpionym ekranie i w aplikacjach pełnoekranowych

## Wymagania

- macOS 14 (Sonoma) lub nowszy, Apple silicon albo Intel
- Do budowania ze źródeł: Xcode albo Command Line Tools (`xcode-select --install`)

## Instalacja

### Opcja A: gotowa aplikacja

1. Wejdź w zakładkę **Releases** (albo **Actions** → ostatni build → *Artifacts*) i pobierz `Snowfall.zip`.
2. Rozpakuj go i przenieś `Snowfall.app` do folderu **Aplikacje**.
3. Aplikacja nie jest podpisana certyfikatem Apple, więc przy pierwszym uruchomieniu macOS ją zablokuje. Wpisz w Terminalu:
   ```
   xattr -cr /Applications/Snowfall.app
   open /Applications/Snowfall.app
   ```

### Opcja B: budowanie ze źródeł

```
git clone <adres-repo>
cd snowfall
bash make-app.sh
mv Snowfall.app /Applications/
open /Applications/Snowfall.app
```

Do szybkiego testu bez budowania `.app` wystarczy `swift run`.

### Uruchamianie przy starcie systemu

Ustawienia systemowe → Ogólne → Elementy logowania → „+” → Snowfall.

## Obsługa

Wszystko jest w menu pod ikoną płatka śniegu w pasku menu:

| Akcja | Jak |
|---|---|
| Włącz / wyłącz efekty | menu → *Włączone* |
| Zmień efekt | menu → Śnieg / Liście / Sakura / Deszcz / Świetliki |
| Intensywność | menu → *Intensywność* |
| Podmuch wiatru | menu → *Podmuch wiatru* |
| Tryb lepienia | **⌥-** (Option + minus) albo menu |
| Ustaw tapetę | menu → *Ustaw tapetę…* |
| Wyjście | menu → *Zakończ* |

**Lepienie:** włącz tryb lepienia skrótem ⌥-. Kliknij i przeciągaj, żeby utworzyć kulę; toczona po zaspie rośnie. Puść ją, żeby spadła, a mniejszą kulę połóż na większej, żeby powstał bałwan. Uwaga: w trybie lepienia kliknięcia **nie** przechodzą do okien, więc wyłącz go tym samym skrótem.

## Uwagi

- Rysowanie odbywa się na CPU (Core Graphics), więc przy dużej intensywności na kilku monitorach Mac może się grzać.
- Pobieranie pozycji okien nie wymaga uprawnień do nagrywania ekranu (aplikacja nie czyta treści okien, tylko ich położenie).
- Jeśli macOS nie rozpoznaje skrótu ⌥-, sprawdź, czy inna aplikacja go nie zajmuje.

## Odinstalowanie

```
killall Snowfall
rm -rf /Applications/Snowfall.app
```
