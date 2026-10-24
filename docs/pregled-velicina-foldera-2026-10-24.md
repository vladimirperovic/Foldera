# Foldera — detaljan pregled veličina foldera

Pregledani su scanner, UsageNode, UsageCache, treemap geometrija i crtanje,
Folder sizes kolona, sortiranje, navigacija, F5, brisanje i zatvaranje taba.
Lokalni testovi, aplikacija i mjerenja performansi nisu pokretani.

## Šta veličina predstavlja

Scanner sabira prijavljenu zauzetu veličinu fajlova. Na APFS/HFS koristi
ukupnu alociranu veličinu kada je dostupna; na stranim volumenima izbjegava
skupe upite za resource fork i paket, uz fallback na veličinu podataka.
Linkovi se ne obilaze kao ciljni folderi. Drugi montirani volumeni i
`/System/Volumes` izostavljaju se iz obilaska. Mali fajlovi grupišu se po
folderu i vrsti; veliki dobijaju poseban blok.

Nečitljive stavke su označene, pa je zbir djelimično čitljivog foldera
donja granica. Zbir po putanjama nije mjerenje jedinstvenih fizičkih blokova:
hard linkovi, APFS klonovi i kompresija mogu se razlikovati od promjene
slobodnog prostora na disku. Slobodan prostor prikazuje se kao zaseban podatak.

## Životni ciklus mjerenja

Prvi pregled je dodao provjeru identiteta aktivnog scannera. Novi pregled
je pokazao da to nije dovoljno: invalidacija cachea dok isti scanner radi
dozvoljavala je da njegov zastarjeli rezultat ponovo napuni cache.

Aktivno mjerenje sada dobija slabije referenciran cache token. Promjena u
njegovom stablu ili iznad njega poništava token; nepovezan folder ga ne
poništava. Zastarjeli rezultat se odbacuje i mjerenje ponavlja, uz očuvanje
postojećih čekalaca, bez gomilanja novih callbackova. Navigacija i zatvaranje
taba otkazuju i scanner i njegov pozadinski posao. Nil rezultat razrješava
stanje mjerenja umjesto beskonačnog Measuring statusa.

Skeniranja koriste zajednički red sa najviše dva aktivna posla. Ponavljanje
F5 ne pokreće neograničen broj obilazaka. Poziv koji već čeka spor disk može
zadržati svoje mjesto dok se ne vrati; Cancel važi između takvih poziva.

Direktorijumski watcher prati folder na ekranu, bez obećanja rekurzivnog
praćenja svake spoljne izmjene duboko u keširanom stablu. **F5** uvijek
traži novo mjerenje. Keš je snimak za sesiju, ne trajna baza filesystema.

## Sabiranje i brisanje

Rekurzivno završno sabiranje zamijenjeno je iterativnim prolazom odozdo
nagore. Time se ne troši call stack za svaki nivo foldera, a Cancel se
provjerava i tokom završnog sabiranja. I legenda sada obilazi iterativno.

Otkriveno je da ponovljeni `total()` ponovo dodaje već sabrane nečitljive
potomke. Posebno se pamti prethodni doprinos potomaka, pa je ponovljeno
sabiranje iste strukture stabilno.

Brisanje sada prvo potvrđuje članstvo čvora u roditelju. Već uklonjen čvor
ne oduzima veličinu drugi put. Precizno se umanjuju zbir, broj fajlova i
nečitljivih stavki svih predaka, poništava se njihov cache dominantne vrste
i ponovo uređuje redoslijed. To popravlja zastarjelu boju i redoslijed
blokova poslije brisanja velikog potomka.

## Raspored i odziv prikaza

Treemap održava minimum, maksimum i zbir rastućeg reda inkrementalno,
umjesto ponavljanja min/max obilaska za svakog kandidata. Geometrijski
testovi već provjeravaju površinu, granice i odsustvo preklapanja.
Prikaz crta najviše tri nivoa, a dublji folder otvara iz izmjerenog stabla.

Upit za slobodan prostor bio je sinhron pri postavljanju stabla i brisanju.
Sada ide kroz ograničen pozadinski red; stari odgovor ne može popuniti
novi prikaz. Folder sizes kolona dijeli isto mjerenje sa treemapom i šalje
ponovno sortiranje ako je aktivan sort po veličini. Odgovor starog sortiranja
se odbacuje i kada se skup stavki promijenio tokom rada.

Novi regresioni scenariji pokrivaju invalidaciju tokom mjerenja, preklopljene
force scanove, ponovljeno sabiranje i uklanjanje, promjenu dominantne vrste,
redoslijed predaka i prekinuto sabiranje. Pripremljeni su za macOS CI;
lokalno nisu izvršavani i ubrzanje nije numerički mjereno.
