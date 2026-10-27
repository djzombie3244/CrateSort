<p align="center">
  <img src="Resources/AppIcon.png" width="160" alt="Ikona CrateSort">
</p>

<h1 align="center">CrateSort</h1>

<p align="center">
  <b>Katalog muzyki dla DJ-a na macOS</b> — szybkie szukanie utworów w trakcie imprezy<br>
  po gatunku, stylu, tempie i tonacji, z przeciąganiem prosto do Traktora.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-13%2B-black?logo=apple" alt="macOS 13+">
  <img src="https://img.shields.io/badge/Swift-5.9-orange?logo=swift" alt="Swift 5.9">
  <img src="https://img.shields.io/badge/SwiftUI-AppKit-blue" alt="SwiftUI + AppKit">
  <img src="https://img.shields.io/badge/licencja-MIT-green" alt="MIT">
</p>

---

## Po co to jest

Na imprezie nie ma czasu na przekopywanie folderów. CrateSort skanuje Twoje dyski i pendrive'y,
porządkuje utwory w kategorie i pozwala w kilka sekund zawęzić listę, np. do *Tech House, 124–125 BPM, 8A*.
Znaleziony utwór przeciągasz na deck albo playlistę w Traktorze.

## Funkcje

- **Kategorie** w panelu bocznym i w menu: **Gatunek**, **Styl**, **Tempo** (przedziały BPM), **Tonacja** (Camelot), **Dyski**, **Foldery**.
  Kategorie z różnych grup się łączą, a liczniki pokazują, ile utworów zostanie po kliknięciu.
- **Wyszukiwarka** (⌘F): wykonawca, tytuł, gatunek, styl, tonacja (`8A`), nazwa pliku, bez polskich znaków.
- **Dopasowanie tempa**: wpisz BPM albo kliknij dwukrotnie utwór, a zobaczysz utwory w podobnym tempie (±2–8%, opcjonalnie pół/podwójne).
- **Przeciągnij i upuść** jednego lub wielu utworów do Traktora (działa jak przeciąganie z Findera).
- **Podgląd pod spacją** (Quick Look), strzałkami przełączasz utwory.
- **Pamięć dysków**: każdy dysk jest zapamiętany osobno (po UUID). Po odłączeniu jego utwory się chowają,
  po podłączeniu wracają, a sprawdzane są tylko nowe i zmienione pliki. Nowy dysk z muzyką → pytanie „Dodać?”.
- **Szybka analiza BPM**, gdy brakuje go w tagach (30 s ze środka utworu, filtr niskich tonów + przeszukiwanie siatki tempa).
- **Zapis BPM do pliku MP3** (ramka ID3 `TBPM`), tylko gdy plik nie ma BPM. Dźwięk, okładka, inne tagi
  i data modyfikacji zostają bez zmian. Można wyłączyć.
- **Ręczne poprawki** gatunku, stylu i BPM (zapisywane tylko w bibliotece CrateSort).
- **Duża czcionka listy** do 18 pt, czytelna w ciemnym klubie.

Obsługiwane formaty: MP3, WAV, AIFF, FLAC, M4A/AAC/ALAC.
Tagi: ID3v2.2–2.4 i ID3v1, Vorbis comments (FLAC), RIFF INFO i chunk `id3 ` (WAV/AIFF), metadane iTunes (M4A).

## Instalacja

Potrzebny macOS 13+ oraz Xcode lub Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/djzombie3244/CrateSort.git
cd CrateSort
./build-app.sh
```

Skrypt kompiluje aplikację, dodaje ikonę i instaluje `CrateSort.app` w folderze **Aplikacje**
(albo w `~/Applications`, gdy brak uprawnień). Aktualizacja to `git pull && ./build-app.sh`,
a biblioteka zostaje bez zmian. `./build-app.sh --no-install` tylko buduje aplikację w folderze projektu.

## Skróty

| Skrót | Działanie |
|---|---|
| ⌘O | Dodaj folder lub dysk |
| ⌘R | Sprawdź nowe pliki na podłączonych dyskach |
| ⌘F | Szukaj |
| Spacja | Podgląd (Quick Look) |
| Dwuklik / ⌘T | Utwory w podobnym tempie |
| ⌘E | Edytuj zaznaczone |
| Esc / ⌘0 | Wyczyść filtry / wszystkie utwory |
| ⌘, | Ustawienia |

## Skąd biorą się kategorie

| Kategoria | Źródło |
|---|---|
| Gatunek | tag Genre (pierwsza wartość). Warianty pisowni są ujednolicane (tech-house → Tech House, dnb → Drum & Bass) |
| Styl | tag Grouping, a gdy pusty, druga wartość z Genre |
| Tempo | tag BPM, a gdy brak, analiza dźwięku (szary BPM na liście) |
| Tonacja | tag Key (`Am`, `8A`, Open Key `1m` z Traktora) albo Camelot w komentarzu (Mixed In Key) |
| Dyski / Foldery | położenie pliku |

## Dane

- Biblioteka: `~/Library/Application Support/CrateSort/Volumes/<id-dysku>.json`, osobny plik dla każdego dysku.
- Pliki muzyczne zostają tam, gdzie są. Jedyna zmiana w plikach to opcjonalne dopisanie wykrytego BPM do MP3 bez tempa.

## Budowa projektu

```
Sources/CrateSort/
├── CrateSortApp.swift     – punkt wejścia, menu
├── LibraryStore.swift     – biblioteka, skanowanie, filtry, dyski, zapis
├── Volumes.swift          – rozpoznawanie dysków (UUID, ścieżki względne)
├── Analysis.swift         – wyszukiwanie plików, odczyt utworu, analiza BPM
├── TagReader.swift        – parsery ID3 / FLAC / WAV / AIFF + AVFoundation
├── TagWriter.swift        – bezpieczny zapis TBPM do MP3
├── Categories.swift       – normalizacja gatunków, przedziały tempa, Camelot
├── TrackTableView.swift   – lista (NSTableView): sortowanie, drag & drop, Quick Look
├── Views.swift            – panel boczny, filtry, ustawienia, edycja
└── Models.swift
```

## English

**CrateSort** is a native macOS music catalog for DJs. It scans folders and USB drives, groups tracks by genre,
style, tempo and key (Camelot), remembers each drive by UUID, fills in missing BPM with a quick audio analysis
(optionally writing it to MP3 tags), and lets you drag tracks straight into Traktor. Build with `./build-app.sh`
(requires macOS 13+ and Xcode or Command Line Tools).

## Licencja

MIT, zobacz [LICENSE](LICENSE).
