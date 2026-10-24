# Foldera — implementacija popravki od 24. oktobra 2026.

Osnova: `a176b72942a5eb2fea62853b1a867f23052ea2d5`.
Lokalna grana: `fix/audit-2026-10-24`.

Implementirane su izmjene za svih **13 nalaza i 8 optimizacija** iz
[izvještaja pregleda](izvjestaj-provjere-2026-10-24.md).
Nastavak pregleda i dodatne popravke opisani su u
[ponovljenom pregledu](izvjestaj-ponovnog-pregleda-2026-10-24.md), sa
zasebnim izvještajima za sync i veličine foldera. Postojeća dva lokalna
izvještaja od 3. i 18. oktobra ostala su sačuvana.

**Prema zahtjevu nisu pokretani lokalni testovi, build, aplikacija ni benchmark.**
Izvršeni su pregled diff-a, provjera poziva izmijenjenih metoda i
`git diff --check`. Ovo potvrđuje stanje izmjena i odsustvo whitespace
grešaka; ne predstavlja potvrdu kompilacije ili prolaska testova na macOS-u.

## Popravke

| Nalaz | Implementirana promjena | Glavna mjesta |
| --- | --- | --- |
| 1. Izmijenjeni izvor tokom Move-a | Za Move koji koristi kopiranje snima se revizija cijelog izvornog stabla poslije koordinisanog pristupa. Prije uklanjanja radi se koordinisan upis i ponovna provjera svih stavki. Izmjena, zamjena korijena, dodavanje ili uklanjanje člana zadržavaju izvor; završena kopija ostaje u Undo evidenciji. | [Transfer.swift](../Sources/Foldera/Transfer.swift), [FileOps.swift](../Sources/Foldera/FileOps.swift) |
| 2. Pogrešna Two way istorija | Istorija sadrži UUID volumena i identitet oba korijena. Zamijenjen korijen ili stara istorija bez identiteta odbacuju prethodne pretpostavke o brisanju i traže novi Compare. Sačuvana je zamjena lijeve/desne strane. UI, scheduler i jezgro odbijaju izvršavanje tekućeg plana koji zahtijeva novi pregled. | [Sync.swift](../Sources/Foldera/Sync.swift), [SyncWindow.swift](../Sources/Foldera/SyncWindow.swift) |
| 3. Zastarjeli sort | Svaka izmjena niza `items` mijenja njegovu reviziju. Pozadinski sort smije objaviti rezultat samo ako i revizija odgovara njegovom snimku. | [ExplorerWindow.swift](../Sources/Foldera/ExplorerWindow.swift), [komande](../Sources/Foldera/ExplorerWindow+Commands.swift) |
| 4. Slika iz dublje kolone | Galerija koristi sadržaj odabrane kolone i uvijek sadrži eksplicitno izabranu sliku. Za duboku Disk usage sliku prvo se otvara sama slika, a njeni susjedi mogu stići u pozadini. | [Columns.swift](../Sources/Foldera/Columns.swift), [komande](../Sources/Foldera/ExplorerWindow+Commands.swift) |
| 5. Staro mjerenje | Completion provjerava identitet aktivnog scannera. Otkazan scanner ne može upisati keš niti potrošiti callbackove novog; postoji i završna provjera otkazivanja u samom skeniranju. | [ExplorerWindow.swift](../Sources/Foldera/ExplorerWindow.swift), [DiskUsage.swift](../Sources/Foldera/DiskUsage.swift) |
| 6. Zamijenjen inode foldera | Rename/delete/revoke zatvaraju stari descriptor i ponovo otvaraju praćenu putanju. Ako privremeno nedostaje, ponavljanje koristi razmake od 0,5 do najviše 5 sekundi. Stop uklanja i odložene pokušaje. | [Watcher.swift](../Sources/Foldera/Watcher.swift) |
| 7. Markdown href | Generisani linkovi zaštićeni su prije emphasis prolaza. Tekst linka i dalje podržava formatiranje i code spanove; adresa i title ostaju sačuvani. | [Markdown.swift](../Sources/Foldera/Markdown.swift) |
| 8. BSD tar `@` | Svi operandi imena fajlova dobijaju `./`, tako da početno `@` ili `-` ostaje dio imena. | [Archive.swift](../Sources/Foldera/Archive.swift) |
| 9. Završni Cancel | Quarantine obilazak provjerava token između stavki. Postoje provjere poslije završnog progress callbacka i neposredno prije objave ekstrakcije, uključujući otvaranje arhive kao foldera. | [Unpack.swift](../Sources/Foldera/Unpack.swift), [Archive.swift](../Sources/Foldera/Archive.swift) |
| 10. Clipboard redoslijed | Copy image isporučuje podatke samo ako se clipboard nije promijenio. Copy, Copy path i zatvaranje viewer-a poništavaju raniji posao pripreme slike. | [ImageViewer.swift](../Sources/Foldera/ImageViewer.swift) |
| 11. Navigacija tokom brisanja | Poslije brisanja čuva se identitet slike koja je trenutno na ekranu, uz njenu novu poziciju u galeriji. Ne resetuju se zoom/rotacija preživjele slike zbog pomjeranja indeksa. | [ImageViewer.swift](../Sources/Foldera/ImageViewer.swift) |
| 12. Stare serverske lozinke | Sanitizovani recents upisuju se nazad u preferences. Migracija se poziva i pri pokretanju aplikacije, bez potrebe da se ponovo otvori Connect ili pokrene mount. | [Servers.swift](../Sources/Foldera/Servers.swift), [AppDelegate.swift](../Sources/Foldera/AppDelegate.swift) |
| 13. Rename Many overflow | Množenje i sabiranje brojača koriste reporting-overflow operacije. Nevažeća vrijednost je problem reda i onemogućava potvrdu umjesto pada procesa. | [BatchRename.swift](../Sources/Foldera/BatchRename.swift) |

## Optimizacije

1. **Transfer watchdog:** GCD posao sa obaveznim spavanjem zamijenjen je
   otkazivim timerom. Timer se ukida čim koordinacija dobije pristup.
2. **Keep Both/Copy imena:** planer pamti naredni sufiks po folderu, osnovnom
   imenu i ekstenziji. Rezervisana imena provjeravaju se prije disk poziva.
3. **Napuštena listanja:** čitanja direktorijuma koriste red sa najviše dva
   radnika i token otkazivanja koji se provjerava tokom enumeracije i prije
   objavljivanja/sortiranja. Navigacija, nova pretraga i zatvaranje prekidaju
   prethodni posao. Postojeći testni čitači prilagođeni su novom potpisu.
4. **Markdown slike:** najviše dva posla ostaju aktivna do isporuke WebKit-u.
   Original se čita u blokovima, uz token i granicu od 32 MiB. Veći rasteri
   dobijaju PNG pregled sa najviše 2048 piksela po dužoj strani; veliki SVG
   iznad granice se ne učitava cijeli.
5. **Viewer metapodaci:** veličina fajla i Info podaci čitaju se na posebnom
   ograničenom redu. Objavljuju se uz provjeru aktuelne slike i generacije,
   a napušteni poslovi se poništavaju.
6. **Markdown dokument:** renderer provjerava prekid između blokova/linija,
   ima ukupni vremenski budžet od dvije sekunde i granicu od 2.000.000 UTF-8
   bajtova za preview. Skraćen preview je označen u prikazu. Izvorni dokument
   i sadržaj editora nisu skraćeni.
7. **Sync korijen:** uklonjen je prvi puni prolaz kroz imena. Čitljivost i
   vrsta korijena provjeravaju se jednim `open` pozivom; sadržaj se enumerira
   jednom. Greške korijena i dalje ne predstavljaju prazan folder.
8. **Treemap:** min/max rastućeg reda održavaju se inkrementalno; svaki novi
   kandidat ne obilazi ponovo cijeli red.

Ubrzanje i potrošnja memorije nisu mjereni. Provjera izvora pri Move-u dodaje
dva obilaska metapodataka; to je trošak uvedene zaštite, a ne tvrdnja da je
svaka operacija sada brža.

## Regresioni scenariji i granice provjere

U [OctoberAuditTests.swift](../Tests/FolderaTests/OctoberAuditTests.swift)
dodato je 29 testnih deklaracija, dio sa parametrima. Obuhvataju izmjenu,
dodavanje, uklanjanje i zamjenu izvora, nepraćenje linkova, ispravno uklanjanje
nepromijenjenog izvora, sva tri formata arhive sa posebnim imenima, otkazanu
ekstrakciju, href i formatirani naslov linka, granice brojača, migraciju
preferences, veličinu/otkazivanje/slikovni fallback, budžet Markdowna,
prekid enumeracije, rezervaciju imena, staru i zamijenjenu sync istoriju,
nepostojeći korijen, zastarjeli sort, preklopljena mjerenja, ponovno vezivanje
watcher-a, duboku galeriju, prekid aktivnog background posla, clipboard i
navigaciju tokom brisanja.

Postojeći testovi za treemap geometriju ostaju relevantni za izmijenjeno
računanje min/max, a postojeće Move/Replace/Undo i disk-failure regresije
za zajednički prenos. Ni novi ni postojeći testovi nisu izvršeni u ovom radu.

Na volumenu bez pouzdanog trajnog identiteta Foldera namjerno ne koristi
staru istoriju za zaključak da je nestanak fajla namjerno brisanje. Takvo
poređenje može ponovo kopirati nedostajući fajl, umjesto propagacije brisanja.

Provjera izvora i `NSFileCoordinator` pokrivaju prijavljeni scenario izmjene
tokom kopiranja. Obilazak i uklanjanje stabla nisu atomska filesystem
transakcija prema proizvoljnom piscu koji ne učestvuje u koordinaciji.
I/O poziv koji već čeka odgovor diska ne može se trenutno prekinuti; tokeni
zaustavljaju naredne korake, a ograničeni redovi sprečavaju neograničeno
pokretanje dodatnog rada.

## Pretraga i indeks

Pretraga nije prebačena na novu bazu tokom ovih popravki. macOS već nudi
Spotlight indeks i [NSMetadataQuery](https://developer.apple.com/documentation/foundation/nsmetadataquery).
Preporučeni naredni korak je brza Spotlight pretraga uz postojeći direktni
obilazak kao mogućnost provjere potpunog sadržaja. Vlastiti katalog ima više
smisla za odspojene diskove i odabrane NAS lokacije, uz održavanje izmjena i
brisanja. Spotlight može izostaviti korisnički isključene ili neindeksirane
lokacije, prema [Apple dokumentaciji](https://developer.apple.com/library/archive/documentation/Carbon/Conceptual/SpotlightQuery/Concepts/QueryingMetadata.html).
