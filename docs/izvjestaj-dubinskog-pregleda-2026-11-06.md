# Foldera — dubinski pregled i popravke, 6. novembar 2026.

Pregled je rađen nad `main` (`8fd98ae`, zelen na CI-ju) poslije izvještaja od
29. septembra do 1. novembra. Svi ranije prijavljeni nalazi su već popravljeni,
pa je ovaj krug tražio nove greške: najprije u fajlovima koje raniji izvještaji
nisu ni pominjali (QuickOpen, PromisedFiles, Tags, ThumbnailSource,
ImageDecodeLimits, ImageText, Panes, PreviewWindow, WrappingCommandBar,
ExplorerWindow+Views), zatim ciljanom pretragom klasa grešaka kroz cijeli kod
(force-unwrap, `DispatchQueue.main.sync`, konverzije `Double → Int`, čitanje
cijelih fajlova u memoriju, dekodiranje slika bez ograničenja).

Popravke su spojene u `main` sa grane `fix/deep-audit-2026-11-06`. Okruženje je Windows bez
Swift-a; build i testovi se provjeravaju isključivo na GitHub Actions
(`macos-26`).

## Sažetak

| # | Prioritet | Vrsta | Nalaz | Mjesto | Stanje |
| --- | --- | --- | --- | --- | --- |
| 1 | P2 | resursi | „Copy image" dekodira sliku bez ograničenja piksela, pa pada na neograničen `NSImage` | [ImageViewer.swift](../Sources/Foldera/ImageViewer.swift) `clipboardPicture`, `clipboardData` | popravljeno |
| 2 | P2 | pad | Trajanje videa iz Spotlight-a van opsega `Int` ruši aplikaciju | [PreviewPane.swift](../Sources/Foldera/PreviewPane.swift) `contentDetails` | popravljeno |
| 3 | P3 | pad | EXIF vrijeme ekspozicije čija recipročna vrijednost nije cijeli broj ruši info panel | [ImageViewer.swift](../Sources/Foldera/ImageViewer.swift) `details` | popravljeno |
| 4 | P3 | performanse | Obrisan folder se ponovo čita na svakih nekoliko sekundi, zauvijek | [Watcher.swift](../Sources/Foldera/Watcher.swift) `retryOpening` | popravljeno |
| 5 | P3 | robusnost | Jedan oštećen zapis istorije prazni cijeli prozor „Sync History" | [SyncLibrary.swift](../Sources/Foldera/SyncLibrary.swift) `summaries` | popravljeno |
| 6 | — | održavanje | Nekorišćena funkcija `Folders.hasSubfolder` | [Model.swift](../Sources/Foldera/Model.swift) | uklonjeno |

## Nalazi i popravke

### 1. „Copy image" bez ograničenja dekodiranja

**Opis.** Novembarske popravke ograničile su dekodiranje u pregledniku,
sličicama i Markdown-u (`ImageDecodeLimits`), ali ne i kopiranje slike na
clipboard (⌥⌘C u listi i u pregledniku). `clipboardPicture` je pozivao
`CGImageSourceCreateThumbnailAtIndex` bez `kCGImageSourceThumbnailMaxPixelSize`,
dakle u punoj rezoluciji, pa još jednom za rotaciju i za TIFF. Kad ImageIO ne
uspije, `clipboardData` je pokušavao `NSImage(contentsOf:)` — tačno ono
neograničeno dekodiranje koje `decodeOther` izričito zabranjuje.

**Posljedica.** PNG od 32768 × 32768 piksela (fajl od svega nekoliko MB) traži
oko 4 GB za bitmapu i još toliko za TIFF; sistem gasi aplikaciju zbog
memorije. SVG koji deklariše ogromnu veličinu imao je isti efekat preko
`tiffRepresentation`.

**Popravka.** Clipboard dobija sopstveni budžet: 100 MP i najviše 32768 px po
strani (`ImageDecodeLimits.clipboardPixels`, `clipboardDimension`). Slika
unutar budžeta ide u punoj veličini, kao i do sada; veća se dekodira umanjena.
`NSImage` rezerva ostaje samo za formate koje ImageIO ne čita (SVG), a vektor
se crta u bitmapu tačno svoje veličine (`ImageDecodeLimits.rasterized`), bez
skaliranja ekrana, unutar istog budžeta. Svi proračuni idu u `Double`, pa ni
apsurdne dimenzije ne mogu da izazovu preljev.

**Testovi.** `copyImageKeepsAPictureWithinItsBudgetAndAFittingOneWhole`,
`copyImageDrawsAVectorAtItsOwnSizeOrWithinTheBudget`,
`aRasterImageIOCannotReadIsNotDecodedAgainByNSImage`,
`clipboardBudgetHoldsForAnySizeWithoutTrapping`.

### 2. Trajanje medija van opsega `Int`

**Opis.** Details pane čita `kMDItemDurationSeconds` iz Spotlight-a i radi
`Int(seconds.rounded())`. Spotlight prenosi ono što piše u zaglavlju fajla: MP4
sa `duration = 2^64 − 1` i `timescale = 1` daje oko 1,8 × 10¹⁹ sekundi, što je
više od `Int.max`, a beskonačno takođe prolazi `seconds > 0`.

**Posljedica.** Swift prekida proces na takvoj konverziji. Dovoljno je
selektovati oštećen ili namjerno napravljen video dok je details pane otvoren —
aplikacija pada (iz pozadinske niti, ali pad je pad cijelog procesa).

**Popravka.** `PreviewPane.runningTime(_:)` odbacuje nekonačne, nepozitivne i
vrijednosti od 10⁹ s i više (preko 31 godine), i formatira sa `%ld` umjesto
`%d`.

**Test.** `aMediaLengthNoIntegerHoldsShowsNothing`.

### 3. EXIF ekspozicija bez cjelobrojne recipročne vrijednosti

**Opis.** Info panel preglednika (I) pravi „1/250 s" kao `Int((1 / t).rounded())`.
Za `t` subnormalno malo `1 / t` je beskonačno, a za `t < 1,1 × 10⁻¹⁹` veće od
`Int.max`. Standardni EXIF RATIONAL ne može toliko da padne, ali ImageIO čita
i XMP i maker note podatke, a provjera je besplatna.

**Popravka.** `ImageFiles.exposureTime(_:)` vraća nil za vrijednosti čija
recipročna vrijednost nije konačna ili je ≥ 10⁹.

**Test.** `anExposureTimeWithoutAnIntegerReciprocalShowsNothing`.

### 4. Obrisan folder se čita iznova, zauvijek

**Opis.** Kad gledani folder nestane, `DirectoryWatcher` pokušava da ga ponovo
otvori sa rastućom pauzom (0,5 s, 1, 2, 4, pa svakih 5 s). Svaki *neuspjeli*
pokušaj je ipak javljao promjenu, pa je tab čitao folder iznova, osvježavao
listu, status i details pane, a isto se dešavalo za svaku otvorenu granu
navigacionog stabla ispod obrisanog foldera.

**Posljedica.** Beskonačno pozadinsko čitanje i osvježavanje interfejsa dok je
nestali folder na ekranu; na mrežnom disku koji je otpao to su i pozivi koji
mogu da čekaju i zauzimaju red čitanja foldera (dva mjesta za sve tabove).

**Popravka.** Prvi neuspjeh se i dalje javlja (lista pokazuje zašto folder ne
može da se otvori); ponovni pokušaji javljaju promjenu samo kad folder ponovo
postoji. Postojeći test `aWatchReconnectsAfterThePathIsTemporarilyMissing`
pokriva ponovno povezivanje.

**Test.** `aMissingFolderIsReportedOnceAndAgainOnlyWhenItIsBack`.

### 5. Jedan oštećen zapis istorije prazni „Sync History"

**Opis.** `SyncLibrary.summaries` je svaki zapis dekodirao sa `try` unutar
`map`, pa je prvi nečitljiv JSON prekidao čitanje cijele istorije. Prozor je
tada pokazivao samo poruku o grešci, bez ijednog pokretanja.

**Posljedica.** Zapis oštećen pri punom disku, ručno izmijenjen ili ostavljen
od druge verzije aplikacije sakriva svih ostalih do 500 zapisa, uključujući
one koji traže pregled („Needs review").

**Popravka.** Nečitljiv zapis se preskače; ostali se prikazuju normalno.
Detalji pojedinačnog zapisa (`SyncLibrary.record`) i dalje javljaju grešku za
baš taj zapis.

**Test.** `oneUnreadableRunDoesNotHideTheRestOfTheHistory`.

## Pregledano bez nalaza

- **QuickOpen, PromisedFiles, Tags, ThumbnailSource, ImageText, Panes,
  PreviewWindow, WrappingCommandBar, ExplorerWindow+Views, TypeSelection.**
  Ispravno vlasništvo nad deskriptorima i zatvaranjima, otkazivanje i
  generacije rezultata su dosljedni.
- **Transfer i TreeCopier.** Kopija u privatni staging, `RENAME_EXCL` pri
  objavljivanju, provjera revizije izvora pri premještanju, čuvanje Undo
  zapisa i kad uklanjanje izvora ne uspije.
- **Undo.** Identitet stavke (uređaj, inode, vrsta) prije vraćanja; spori
  koraci u pozadini uz blokadu ponovnog Undo-a.
- **Unpack i Archive.** libarchive sa `SECURE_SYMLINKS` i `SECURE_NODOTDOT`,
  ručna provjera putanja i hard linkova, karantin se prenosi na sve
  raspakovano, `zip`/`tar` dobijaju imena sa `./`.
- **Checksum.** Ograničenja od 16 MiB, 64 KiB po redu i milion unosa, provjera
  da se lista nije mijenjala tokom čitanja.
- **Tabs, Sidebar, AddressBar, Columns, Properties, Servers, SyncScheduler,
  AppDelegate.** Bez novih grešaka.

## Svjesno ostavljeno (nije popravljano)

- **Obrnuta kosa crta u pretrazi sa `*`/`?`.** `FolderSearch.matcher` predaje
  upit `NSPredicate` operatoru `LIKE`, koji `\` vjerovatno tretira kao escape.
  Ime sa obrnutom kosom crtom se tada ne nalazi očekivano, a nije provjereno
  šta radi upit koji se završava sa `\`. Bez Mac-a ovo nije moglo da se
  provjeri; proba: pretraga `*\` i `back\slash*` u folderu sa takvim imenima.
- **Sortiranje velikih foldera.** `localizedStandardCompare` po paru Swift
  stringova je najskuplji dio sortiranja od 100.000 stavki. Moguće ubrzanje
  (jednom napravljen `NSString` po stavci) traži mjerenje na Mac-u prije
  izmjene.
- **„New folder" pod istim imenom iz dvije aplikacije u istom trenutku.**
  `mkdir` tada javi grešku umjesto da uzme sljedeće slobodno ime. Prozor je
  mikrosekundni; nije vrijedno složenosti.
- **Prevlačenje foldera na Trash u navigacionom stablu** ne vraća tab koji
  baš taj folder prikazuje na roditeljski folder (meni „Move to Trash" to
  radi). Lista se ipak osvježi preko watcher-a.

## Provjera

- CI (`macos-26`, run 42243335701): build i svih 408 testova zeleno u debug i
  release konfiguraciji, uključujući 9 novih testova i postojeći
  `aWatchReconnectsAfterThePathIsTemporarilyMissing`.
- `readingTheKeptThumbnailIsFarQuickerThanDecoding` (FastPictureTests) je
  usput stabilizovan. Sabirao je pojedinačna mjerenja vremena dok paralelno
  rade drugi suite-ovi, pa je padao na zauzetom runner-u (dvaput u debug-u na
  ovoj grani, ranije u run-u 39974020724), iako se kod koji mjeri nije
  mijenjao. Sada uzima najbrži od tri pokušaja, uz isti zahtjev „3× brže".
  Izmjereno: sličica iz fajla 1,6–5 ms, dekodiranje 51–90 ms.

## Ograničenja

- Nema lokalnog build-a ni pokretanja aplikacije; sve izmjene provjerava CI
  (`swift build` + `./test.sh` u debug i release konfiguraciji).
- Ponašanje SVG-a i ImageIO-a provjereno je kroz testove na CI runner-u, ne
  na korisnikovom Mac-u.
