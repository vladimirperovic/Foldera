# Foldera — testiranje na Macu, 3. oktobar 2026.

Povučen je `origin/main`; početni commit bio je
`24c3e9f8331a858eb0ea2537955572dd5ba36638`, bez lokalnih izmjena.
Kompletan paket prolazi na ovom Macu u debug i release konfiguraciji:
**204 testa u 27 grupa, bez CI skip-liste**. Provjera uključuje četiri
file-coordination testa koja su ranije preskočena, kao i dodatni,
case-sensitive APFS volumen.

## Okruženje i način rada

- macOS 27.0.1 (26A434), Apple Silicon arm64, Apple Swift 6.4.
- Command Line Tools: `/Library/Developer/CommandLineTools`.
- Montiran je privremeni APFS volumen `FolderaMacTest-20261003`, veličine
  512 MiB, koji razlikuje velika i mala slova; odmontiran je poslije provjere.
- Swift build servis nije mogao pristupiti radnom direktorijumu u
  `Documents`. Testovi i `build.sh` izvedeni su u privremenoj kopiji u
  `/private/tmp/foldera-mac-verification-20261003`. SHA-256 provjera svih
  72 kopirana ulazna fajla potvrdila je identičnost sa projektom, uključujući
  završnu ispravku adresne trake.
- Operacije nad fajlovima izvođene su nad privremenim testnim podacima.

Komande za oba testna paketa, bez `--skip`:

```sh
FOLDERA_TEST_VOLUME=/Volumes/FolderaMacTest-20261003 ./test.sh
FOLDERA_TEST_VOLUME=/Volumes/FolderaMacTest-20261003 ./test.sh -c release
./build.sh
codesign --verify --deep --strict --verbose=2 build/Foldera.app
```

## Rezultati

| Provjera | Ishod |
| --- | --- |
| Kompletan debug paket poslije ispravke | 204/204, 27 grupa, exit 0 |
| Kompletan release paket poslije ispravke | 204/204, 27 grupa, exit 0 |
| Predaja placeholder fajla preko `NSFileCoordinator`, Copy i Move | Prolazi |
| Placeholder unutar foldera, odmah ili sa zakašnjenjem | Prolazi |
| Ponovni zahtjev aplikaciji koja kasni sa predajom | Prolazi |
| Prikaz čekanja pri sporoj predaji fajla | Prolazi |
| Case-sensitive rename kolizija | Prolazi na testnom APFS volumenu |
| Move sa zamjenom, Undo i Redo između različitih volumena | Prolazi |
| Sync režimi, istorija sadržaja/linkova, zastarjeli planovi i isključenja | Prolazi u kompletnom paketu |
| Sync profili, rasporedi, istorija i međuprocesni RunLock | Prolazi u obje konfiguracije |
| Nezavisni tabovi oba panela, otvaranje Sync prozora iz toolbar-a | Prolazi |
| Arhive, tekst/Markdown, slike/OCR, pretraga i Quick Open | Prolazi u kompletnom paketu |
| Release `.app` i stroga provjera potpisa | Uspješno, približno 2,3 MiB |
| Update sync kroz zapakovanu release aplikaciju | Bajtovi svih izvornih fajlova odgovaraju odredištu; link i fajl koji postoji samo na desnoj strani sačuvani |
| Instalirana aplikacija u `/Applications` | Potpis provjeren; izvršni fajl identičan provjerenom buildu; pokretanje i snapshot dva panela prolaze |

## Vizuelna provjera i ispravka

Pregledani su snapshot-i zapakovane release aplikacije: Details sa Markdown
pregledom, Columns, Large icons, Disk usage, pregled slike, dva panela sa
nezavisnim tabovima na širini 1200, po 30 tabova na minimalnoj širini 1080
u tamnom režimu, Sync/Mirror i Sync/Update u suprotnom smjeru.

Na minimalnoj širini prozora sa dva panela posljednji dio putanje mogao je
crtati izvan adresne trake, preko polja za pretragu. `AddressBar` sada
ograničava crtanje na sopstvene granice. Nakon te ispravke ponovljeni su
oba kompletna testna paketa, release build i snapshot provjere.

Quick Open je provjeren automatizovanim testovima. Običan snapshot glavnog
prozora ne obuhvata njegov zasebni panel i nije dokaz izgleda tog panela.

## Granice provjere

Ovo je provjera lokalnog Mac okruženja i postojećih regresija. Stvarni SMB,
prekid mreže ili odvajanje diska tokom rada, pun disk, stvarni iCloud
placeholder-i, login/sleep/wake ciklus LaunchAgent-a i gašenje tokom svake
faze operacije nisu provjereni. Desktop testovi koriste simulirani
`NSFilePresenter`; ne predstavljaju probu stvarne Windows App sesije.

Linker prijavljuje postojeća upozorenja o nedostajućim CLT putanjama; testni
izbor debug/release konfiguracije prijavljuje granu koja se neće izvršiti.
Ta upozorenja nisu blokirala build ili testove. Beta upozorenje ostaje.

## Lokalni materijal

Logovi, SHA-256 manifest, skripte za provjeru, testni podaci i snapshot-i
sačuvani su u ignorisanom direktorijumu `build/mac-verification-2026-10-03`.

Instaliran je Foldera 0.2.0 beta, build `202610031958`, u
`/Applications/Foldera.app`. SHA-256 instaliranog izvršnog fajla je
`d72c1c4d44b13e98743739f7ef9f8311cb47828e5af498b1349b8bbf7882f716`,
identičan izvršnom fajlu u provjerenom `.app` buildu. Prethodna aplikacija
sačuvana je kao `build/mac-verification-2026-10-03/Foldera-before.app`.
