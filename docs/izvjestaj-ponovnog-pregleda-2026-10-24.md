# Foldera — ponovljeni pregled, 24. oktobar 2026.

Pregled je rađen nad osnovom `a176b72` i lokalnim popravkama iz prvog
pregleda. Obuhvaćeni su tokovi prenosa i Undo, pozadinski poslovi,
učitavanje i sortiranje foldera, watcher, pretraga, Columns, viewer i
preview, Markdown, arhive, Rename Many, serveri i sync. Posebni detaljni
pregledi su u [sync izvještaju](pregled-sync-2026-10-24.md) i
[izvještaju o veličinama](pregled-velicina-foldera-2026-10-24.md).

Ovo je statički pregled koda i promjena. Lokalni testovi, build, aplikacija
i benchmark nisu pokretani, prema zahtjevu korisnika. Novi testovi su
pripremljeni za postojeći GitHub Actions workflow na macOS-u.

## Dodatno pronađeno i popravljeno

| Problem | Posljedica i izmjena |
| --- | --- |
| Izvor se promijeni dok `copyfile` čita fajl | Provjera samo prije kopiranja nije dovoljna. Jedan fajl se provjerava poslije koordinisanog pristupa i ponovo poslije kopiranja; rekurzivni prenos provjerava i pojedinačne fajlove kroz callbackove. Promijenjen fajl prekida staging, prije objave odredišta. |
| Undo premještanja između diskova zaobilazi zaštitu izvora | `FileManager.moveItem` je mogao kopirati i zatim ukloniti izmijenjeni izvor. Undo sada koristi `TreeCopier`, snimak stabla i provjeru prije uklanjanja. Završena kopija ostaje evidentirana i pri grešci uklanjanja izvora. |
| Move snimak vidi hidrataciju placeholdera kao tuđu izmjenu | Za placeholder koji je Foldera upravo zatražila osvježava se samo njegova revizija, prije čitanja bajtova. Ostale stavke ostaju pod originalnom provjerom. |
| Limit renderovanja Markdowna dolazi poslije neograničenog čitanja | `TextFile` čita u blokovima, sa ukupnim limitom 32 MiB, uključujući fajl koji raste tokom čitanja. Prevelik dokument odbija se cijeli; djelimičan tekst se nikada ne tretira kao dokument za uređivanje ili snimanje. Render i dalje prikazuje najviše 2.000.000 UTF-8 bajtova. |
| Viewer fallback dekodira na glavnoj niti | Rezervni `decodeOther` sada radi u istom ograničenom pozadinskom redu kao bitmap decoder. UI samo preuzima pripremljenu sliku. |
| Rezervacije novih imena nisu pratile pravila volumena | Tri izvora `report.txt`, `REPORT.txt` i `Report.txt` mogla su dobiti isto stvarno odredište na volumenu bez razlikovanja velikih slova. Plan i allocator sada normalizuju rezervacije prema pravilima odredišnog foldera, uključujući spajanje u podfoldere, uz keširan upit za taj folder. |
| Pozadinski sort je čitao promjenjive UI objekte | `FileItem` je referentni tip; dodavanje izmjerene veličine foldera moglo je mijenjati polje koje sorter istovremeno čita. Sort sada koristi privatne snimke, a poslije provjere generacije i revizije samo preuređuje originalne UI instance. |

Sync i veličine foldera imaju dodatne popravke dokumentovane u zasebnim
izvještajima: identitet korijena tokom posla, stabilnost poređenja sadržaja,
prijavljivanje grešaka i prekida, invalidacija aktivnih mjerenja,
ponovljivo sabiranje, redoslijed i boje nakon brisanja, prekid završnog
sabiranja i čitanje slobodnog prostora izvan glavne niti.

## Details uz View

U komandnu traku neposredno poslije dugmeta **View** dodata je ikonica
`list.bullet`, sa opisom **Details view (⌘1)**. Jednim klikom uključuje
postojeći Details prikaz, zadržava izbor stavki i označena je dok je taj
prikaz aktivan. Postojeći Details unos u View meniju, ⌘1 i donja ikonica
ostaju povezani sa istom komandom. Dugme radi i u drugom panelu.

## Provjera i ograničenja

- `git diff --check` i pregled poziva izmijenjenih metoda.
- Ukupno 29 novih `@Test` deklaracija u `OctoberAuditTests.swift`, neke sa
  parametrima; postojeći testovi su prilagođeni cancellation argumentu.
- Novi scenariji posebno pokrivaju zamjenu korijena između dvije sync
  radnje, Cancel tokom posljednje radnje, invalidaciju mjerenja dok radi,
  ponovljeno sabiranje, ponovno uklanjanje čvora, promjenu dominantnog tipa
  i redoslijeda blokova, kao i odbijanje prevelikog tekstualnog ulaza.
- Nema izmjerenog ubrzanja. Zaštita izvora dodaje metapodatkovni rad;
  ograničenje konkurentnosti i uklanjanje ponovljenih obilazaka smanjuju
  nepotreban rad, ali rezultat zavisi od diska i stabla.
- Pozivi filesystema koji već čekaju disk ne mogu se uvijek odmah prekinuti.
- Pristup stablu i završno uklanjanje nisu atomska transakcija prema
  proizvoljnom programu koji ne učestvuje u macOS koordinaciji fajlova.

Pretraga i dalje koristi direktni obilazak. Spotlight ili poseban katalog
nisu uvedeni ovim izmjenama; to je odvojena promjena arhitekture pretrage.
