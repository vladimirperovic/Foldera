# Foldera — detaljni statički pregled

Datum: 24. oktobar 2026.

**Ažuriranje poslije implementacije:** svih 13 nalaza i 8 optimizacija iz ovog
izvještaja dobilo je izmjene na lokalnoj grani `fix/audit-2026-10-24`.
Dodato je 28 regresionih testnih deklaracija sa dodatnim parametrizovanim slučajevima.
Lokalni testovi i build nisu pokretani, prema zahtjevu. Detalji, granice i stanje
provjere su u [izvještaju popravki](izvjestaj-popravki-2026-10-24.md).
Pregled ispod ostaje zapis prvobitnog stanja na navedenom commitu.

Pregledani commit: `a176b72942a5eb2fea62853b1a867f23052ea2d5` (`main`).
Izvršen je `git pull --ff-only origin main`: lokalna grana je pomjerena sa
`181d989` na `a176b72`, kroz tri commita i izmjene u 19 izvornih fajlova.
Postojeći lokalni izvještaji od 3. i 18. oktobra sačuvani su.

**Lokalni testovi, build, benchmark i aplikacija nisu pokretani, prema zahtjevu.
Izvorni kod nije mijenjan.** Nalazi ispod potiču iz čitanja aktuelnog koda,
povezanih poziva i testnih scenarija; reprodukcije su predložene probe, a ne
izvršeni testovi. Nije ponovo provjeravan status CI-ja. Za posebno značenje
`@` argumenta provjerena je i zvanična Apple dokumentacija BSD tar-a.

Pregled je podijeljen na operacije nad fajlovima/arhivama, sync/pretragu/nadzor,
preview/slike/Markdown i UI/model/komande. Raniji izvještaji korišćeni su da
se već popravljeni problemi ne prijavljuju ponovo. Ovo nije formalni dokaz
ispravnosti svih putanja niti potvrda ponašanja na stvarnom Macu, USB-u ili NAS-u.

## Nalazi po prioritetu

P1: prioritetno ispraviti zbog rizika za podatke. P2: konkretna funkcionalna,
sigurnosna ili stabilnosna greška za naredni ciklus popravki.

| # | Prioritet | Nalaz |
| --- | --- | --- |
| 1 | P1 | Move između diskova može obrisati novije izmjene izvora |
| 2 | P1 | Two way istorija može primijeniti brisanja na drugi disk/folder iste putanje |
| 3 | P2 | Asinhrono sortiranje može vratiti obrisane stavke ili nepotpunu listu |
| 4 | P2 | Otvaranje slike iz dublje kolone koristi slike početnog foldera |
| 5 | P2 | Staro mjerenje prostora može preuzeti rezultat novog mjerenja |
| 6 | P2 | Nadzor ostaje na starom folderu poslije zamjene na istoj putanji |
| 7 | P2 | Markdown formatiranje kvari URL-ove linkova |
| 8 | P2 | TAR.GZ/7z kompresija imena sa `@` može spakovati pogrešan sadržaj |
| 9 | P2 | Cancel ne prekida završnu obradu i objavu raspakovane arhive |
| 10 | P2 | Stara Copy image operacija prepisuje noviji clipboard |
| 11 | P2 | Završetak brisanja slike preskače sliku na koju je korisnik prešao |
| 12 | P2 | Ranije sačuvane serverske lozinke ostaju u UserDefaults-u |
| 13 | P2 | Velike vrijednosti brojača ruše Rename Many prije potvrde |

### 1. Move između diskova briše izvor bez provjere promjena tokom kopiranja

Mjesta: [Transfer.swift:302](https://github.com/vladimirperovic/Foldera/blob/a176b72942a5eb2fea62853b1a867f23052ea2d5/Sources/Foldera/Transfer.swift#L302),
[Replace grana:360](https://github.com/vladimirperovic/Foldera/blob/a176b72942a5eb2fea62853b1a867f23052ea2d5/Sources/Foldera/Transfer.swift#L360),
[granica koordinisanog čitanja:459](https://github.com/vladimirperovic/Foldera/blob/a176b72942a5eb2fea62853b1a867f23052ea2d5/Sources/Foldera/Transfer.swift#L459).

Poslije uspješne kopije poziva se `removeItem(step.from)`. Uslov
`copier.errors.isEmpty` znači da kopiranje nije prijavilo grešku; ne znači
da izvor još odgovara kopiji. Za izvor se ne čuva niti provjerava revizija.
`NSFileCoordinator` pokriva `copyNow`, a ne cijeli postupak do uklanjanja
izvora; obični pisci ne moraju koristiti tu koordinaciju.

**Scenario:** premjestiti veliki projekat na spor USB/NAS. Poslije kopiranja
`a.txt`, dok se ostali fajlovi još prenose, editor snimi novu verziju `a.txt`
ili napravi fajl u već obrađenom podfolderu. Završno brisanje uklanja i te
neprenesene podatke. Undo ima samo stariju odredišnu kopiju. Isto važi za
Move + Replace između diskova; ovaj nalaz se ne odnosi na obični rename na
istom disku.

**Ispravka:** uklanjanje vezati za provjeren identitet i nepromijenjeno stanje
cijelog prenesenog izvora, uz odgovarajuću koordinaciju završne faze. Ako se
izvor promijenio, zadržati ga i prijaviti nepotpun Move. Provjera samo datuma
korijenskog foldera ne otkriva sve izmjene potomaka.

**Predložena proba:** kontrolisano izmijeniti ranije kopirani član i dodati
novi fajl prije završetka velike kopije, kroz obje Move grane. Postojeće
provjere izmjene odredišta ne pokrivaju ovaj izvorni tok.

### 2. Two way istorija ne razlikuje drugi folder ili disk na istoj putanji

Mjesta: [Sync.swift:845](https://github.com/vladimirperovic/Foldera/blob/a176b72942a5eb2fea62853b1a867f23052ea2d5/Sources/Foldera/Sync.swift#L845),
[odluka o brisanju:651](https://github.com/vladimirperovic/Foldera/blob/a176b72942a5eb2fea62853b1a867f23052ea2d5/Sources/Foldera/Sync.swift#L651),
[provjera pri izvršavanju:970](https://github.com/vladimirperovic/Foldera/blob/a176b72942a5eb2fea62853b1a867f23052ea2d5/Sources/Foldera/Sync.swift#L970).

`Memory` čuva putanje i zajedničko stanje fajlova. `load` prihvata istoriju
po podudaranju putanja, bez trajnog identiteta volumena i korijena. Provjera
u `Job.perform` štiti od zamjene poslije tekućeg Compare-a, ali ne od zamjene
između prethodnog i tekućeg sync-a.

**Scenario:** uskladiti 100 fajlova, zatim zamijeniti desni folder/disk drugim
na istoj putanji sa 99 jednakih fajlova. Novi Compare učita prethodnu istoriju
i za preostali neizmijenjeni fajl lijevo predloži `deleteLeft`, kao da je
namjerno obrisan desno. Za 1/100 ne aktivira se zaštita od masovnog brisanja
na linijama 517–520. U Trash režimu postoji mogućnost oporavka, a raspored
može automatski izvršiti ovo pogrešno brisanje. Permanent režim zahtijeva
ručnu potvrdu; scheduler takva brisanja zaustavlja radi pregleda
([SyncScheduler.swift:29](https://github.com/vladimirperovic/Foldera/blob/a176b72942a5eb2fea62853b1a867f23052ea2d5/Sources/Foldera/SyncScheduler.swift#L29),
[SyncWindow.swift:869](https://github.com/vladimirperovic/Foldera/blob/a176b72942a5eb2fea62853b1a867f23052ea2d5/Sources/Foldera/SyncWindow.swift#L869)).
Ako korisnik potvrdi pogrešan plan, gubitak može biti trajan.

**Ispravka:** trajnu istoriju vezati za identitete oba volumena i korijenska
foldera. Pri promjeni identiteta zaustaviti automatsko prenošenje brisanja i
tražiti pregled novog para. Predvidjeti migraciju stare istorije i zamjenu
lijeve/desne strane.

**Predložena proba:** zamjena prije novog Compare-a. Postojeći
`anotherFolderInTheSamePlaceStopsTheSync` u
[SyncTests.swift:685](https://github.com/vladimirperovic/Foldera/blob/a176b72942a5eb2fea62853b1a867f23052ea2d5/Tests/FolderaTests/SyncTests.swift#L685)
provjerava zamjenu poslije Compare-a, što je drugačiji redoslijed.

### 3. Pozadinsko sortiranje objavljuje zastarjeli snimak liste

Mjesto: [ExplorerWindow+Commands.swift:813](https://github.com/vladimirperovic/Foldera/blob/a176b72942a5eb2fea62853b1a867f23052ea2d5/Sources/Foldera/ExplorerWindow+Commands.swift#L813).
Povezano: [showSoFar:873](https://github.com/vladimirperovic/Foldera/blob/a176b72942a5eb2fea62853b1a867f23052ea2d5/Sources/Foldera/ExplorerWindow.swift#L873),
[drop:945](https://github.com/vladimirperovic/Foldera/blob/a176b72942a5eb2fea62853b1a867f23052ea2d5/Sources/Foldera/ExplorerWindow.swift#L945),
[apply:987](https://github.com/vladimirperovic/Foldera/blob/a176b72942a5eb2fea62853b1a867f23052ea2d5/Sources/Foldera/ExplorerWindow.swift#L987).

`resort` uhvati `items`, a pri objavi provjeri samo generaciju učitavanja,
generaciju sortiranja i izabrani redoslijed. U međuvremenu `drop`, djelimično
listanje i konačni `apply` mogu promijeniti `items` bez promjene tih generacija.

**Scenario:** sortiranje uhvati djelimičnu listu velikog foldera; konačna
lista stigne prije završetka tog sortiranja; zatim stari sort zamijeni cijelu
listu djelimičnim snimkom. Pošto je čitanje završeno, ne mora uslijediti novi
rezultat koji bi je popravio. Slično, obrisana stavka može ponovo biti
prikazana ako sort stigne prije odloženog reload-a. Zaštita `justRemoved`
postoji u listanju, ali ne i u ovoj objavi.

**Ispravka/proba:** uvesti reviziju sadržaja liste ili poništavati sort pri
svakoj zamjeni/uklanjanju stavki. Kontrolisano promijeniti listu između
pokretanja i objave sorta; provjeriti pun skup i identitet selekcije.

### 4. Viewer bira slike iz pogrešnog nivoa Columns/Disk usage prikaza

Mjesto: [ExplorerWindow+Commands.swift:117](https://github.com/vladimirperovic/Foldera/blob/a176b72942a5eb2fea62853b1a867f23052ea2d5/Sources/Foldera/ExplorerWindow+Commands.swift#L117).
Povezano: [Columns.swift:174](https://github.com/vladimirperovic/Foldera/blob/a176b72942a5eb2fea62853b1a867f23052ea2d5/Sources/Foldera/Columns.swift#L174),
[selectedItems:1242](https://github.com/vladimirperovic/Foldera/blob/a176b72942a5eb2fea62853b1a867f23052ea2d5/Sources/Foldera/ExplorerWindow.swift#L1242).

Za jednu izabranu sliku `openInViewer` gradi galeriju iz `items`, odnosno
početnog foldera. Selekcija u dubljoj koloni dolazi iz njenog podfoldera;
Disk usage takođe može imati odabranu sliku dublje u stablu.

**Scenario:** početni folder sadrži `a.jpg` i podfolder `child/b.jpg`. U Columns
otvoriti child i izabrati b.jpg. Pretraga njenog ključa u root slikama ne
uspije, koristi se indeks 0 i otvara a.jpg. Ako root nema slika, `ImageViewer.show`
prekida na praznom nizu, a komanda ipak vrati da je slika obrađena.

**Ispravka/proba:** uzeti galeriju aktivne kolone ili izabrane slike; uvijek
obezbijediti prisustvo eksplicitno izabrane slike prije otvaranja. Provjeriti
root sa slikom i bez nje, kao i komandu nad dubokom Disk usage slikom.

### 5. Stari scanner može potrošiti callbackove novog mjerenja

Mjesta: [ExplorerWindow.swift:1717](https://github.com/vladimirperovic/Foldera/blob/a176b72942a5eb2fea62853b1a867f23052ea2d5/Sources/Foldera/ExplorerWindow.swift#L1717),
[DiskUsage.swift:257](https://github.com/vladimirperovic/Foldera/blob/a176b72942a5eb2fea62853b1a867f23052ea2d5/Sources/Foldera/DiskUsage.swift#L257).

`measure(force: true)` otkaže stari scanner i započne novi za istu lokaciju.
Completion provjerava samo lokaciju, bez identiteta scannera. Stari rezultat
može već čekati glavnu nit ili računati `top.total()`, poslije posljednje
provjere cancellation zastavice.

**Posljedica:** stari callback može upisati zastarjelo stablo u keš, postaviti
`measuring = nil` i isprazniti `waitingForUsage`, uključujući callbackove novog
mjerenja. Noviji rezultat potom nema callback koji bi osvježio treemap.

**Ispravka/proba:** provjeriti `usageScanner === scanner` ili generaciju i
ponovo provjeriti cancellation prije vraćanja rezultata. Zadržati prvi
completion, pokrenuti F5, pa pustiti completione tim redom. Timer na liniji
1706 već pokazuje odgovarajuću provjeru identiteta.

### 6. Watcher se ne veže za novi direktorijum iste putanje

Mjesto: [Watcher.swift:46](https://github.com/vladimirperovic/Foldera/blob/a176b72942a5eb2fea62853b1a867f23052ea2d5/Sources/Foldera/Watcher.swift#L46).

Descriptor se otvara jednom. Handler prima rename/delete događaje, ali ne
razlikuje njihov tip i samo zakazuje `onChange`; ne otvara ponovo praćenu
putanju. `ExplorerTab.reload` i F5 učitavaju listu bez ponovnog `watch` poziva.

**Scenario:** otvoriti A, izvana ga preimenovati u A-old i napraviti novi A.
Prvo osvježavanje može pokazati novi A, ali descriptor i dalje prati A-old.
Kasnija dodavanja/brisanja u novom A ne osvježavaju prikaz automatski.

**Ispravka/proba:** pri rename/delete/revoke ponovo provjeriti identitet i
vezati nadzor za postojeću putanju. Pokriti i interval u kojem putanja još ne
postoji, zatim provjeriti više uzastopnih promjena u novom folderu.

### 7. Markdown emphasis regex mijenja HTML atribute linkova

Mjesto: [Markdown.swift:302](https://github.com/vladimirperovic/Foldera/blob/a176b72942a5eb2fea62853b1a867f23052ea2d5/Sources/Foldera/Markdown.swift#L302).

Link se prvo pretvori u `<a href="…">`, pa regex-i za bold/italic/strike
obrađuju cijeli dobijeni HTML. Slike i code spanovi su zaštićeni kroz `keep`,
ali linkovi nisu.

**Scenario:** `[download](https://example.com/file__old__v2.zip)` pretvara dio
URL-a `__old__` u `<strong>old</strong>` unutar href atributa. Prikazan link
zato vodi na pogrešnu adresu. Problem važi i za lokalne putanje sa takvim
imenima. Ovo je nalaz o neispravnoj adresi, bez tvrdnje o izvršavanju skripti.

**Ispravka/proba:** formatirati samo tekst linka, a generisani link i njegove
atribute zaštititi prije narednih prolaza. Pokriti obične i automatske linkove
sa `__`, `*` i `~~`, uz očuvanje dozvoljenog formatiranja naslova linka.

### 8. Imena sa `@` imaju posebno značenje za BSD tar

Mjesto: [Archive.swift:139](https://github.com/vladimirperovic/Foldera/blob/a176b72942a5eb2fea62853b1a867f23052ea2d5/Sources/Foldera/Archive.swift#L139).

Imenima sa početnim `-` dodaje se `./`; ostala se predaju nepromijenjena.
BSD tar operand `@report.tar` tumači kao uvoz članova iz arhive `report.tar`.
To dokumentuje [Apple-ov bsdtar manual](https://github.com/apple-oss-distributions/libarchive/blob/main/libarchive/tar/bsdtar.1).

**Scenario:** izabrati stvarni fajl `@report.tar` za TAR.GZ ili 7z kompresiju,
uz postojeći `report.tar` u istom folderu. Umjesto izabranog fajla u rezultat
mogu ući članovi drugog arhiva. Ako drugi arhiv ne postoji, kompresija pada.

**Ispravka/proba:** svim operandima fajlova dodati `./`, uz posebne argumente
opcija. Provjeriti nazive sa `@` i `-` kroz oba formata i sadržaj nastale
arhive, ne samo izlazni status procesa. Nije izvršena lokalna tar proba.

### 9. Cancel tokom prenošenja quarantine atributa ne zaustavlja objavu

Mjesta: [Unpack.swift:98](https://github.com/vladimirperovic/Foldera/blob/a176b72942a5eb2fea62853b1a867f23052ea2d5/Sources/Foldera/Unpack.swift#L98),
[mark:121](https://github.com/vladimirperovic/Foldera/blob/a176b72942a5eb2fea62853b1a867f23052ea2d5/Sources/Foldera/Unpack.swift#L121),
[objava:163](https://github.com/vladimirperovic/Foldera/blob/a176b72942a5eb2fea62853b1a867f23052ea2d5/Sources/Foldera/Archive.swift#L163).

Poslije raspakivanja arhive `mark` rekurzivno postavlja quarantine atribut.
Ne provjerava cancellation zastavicu, a ni prije vraćanja uspjeha i
`settle` objave ne postoji nova provjera.

**Scenario:** downloadovana arhiva sa mnogo sitnih fajlova na sporom disku
završi decompression; korisnik pritisne Cancel tokom obilaska metapodataka.
Operacija nastavi i objavi raspakovani folder uprkos zahtjevu za prekid.

**Ispravka/proba:** omogućiti prekid završnog obilaska i provjeru prije
objave; nepotpuno pripremljen staging očistiti postojećom putanjom za grešku.
Probe trebaju razlikovati Cancel tokom decompression-a i tokom `mark` faze.

### 10. Copy image posao kasnije prepisuje noviju Copy komandu

Mjesto: [ImageViewer.swift:1048](https://github.com/vladimirperovic/Foldera/blob/a176b72942a5eb2fea62853b1a867f23052ea2d5/Sources/Foldera/ImageViewer.swift#L1048).

**Scenario:** pokrenuti Copy image velike slike, zatim prije završetka Copy
as path ili obični Copy. Druga komanda odmah popuni clipboard, ali prvi posao
kasnije bez provjere pozove `writeClipboard` i prepiše noviji sadržaj TIFF-om.
`copy` i `copyPath` ne poništavaju `copying`; rezultat ne provjerava ni
`NSPasteboard.changeCount`. Isto načelno važi za Copy u drugoj aplikaciji.

**Ispravka/proba:** sačuvati clipboard changeCount pri zahtjevu i odbaciti
zastarjelu isporuku; povezati lokalne Copy komande zajedničkom generacijom.
Zadržati pripremu slike, izvršiti noviji Copy, pa pustiti stari completion.

### 11. Asinhrono brisanje koristi indeks koji više ne označava istu sliku

Mjesto: [ImageViewer.swift:1217](https://github.com/vladimirperovic/Foldera/blob/a176b72942a5eb2fea62853b1a867f23052ea2d5/Sources/Foldera/ImageViewer.swift#L1217).

**Scenario:** u `[A, B, C]` pokrenuti brisanje A i, dok recycle traje, preći na
B. Po završetku lista postane `[B, C]`, ali ostaje numerički `index == 1`, pa
`go(to:)` pređe na C. Navigacija/slideshow nisu blokirani dok traje recycle.

**Ispravka/proba:** prije promjene niza sačuvati ključ trenutno prikazane
slike i obnoviti njenu poziciju ako je preživjela. Susjeda birati samo ako
je obrisana upravo prikazana slika. Provjeriti navigaciju i slideshow tokom
odloženog završetka brisanja.

### 12. Sanitizacija recents ne uklanja već zapisanu lozinku

Mjesto: [Servers.swift:19](https://github.com/vladimirperovic/Foldera/blob/a176b72942a5eb2fea62853b1a867f23052ea2d5/Sources/Foldera/Servers.swift#L19).

Novi setter pravilno izbacuje password iz novih zapisa. Getter samo vrati
sanitizovanu kopiju niza; ne prepiše staru vrijednost u `UserDefaults`.

**Scenario:** ranija verzija je zapamtila `smb://user:secret@nas/share`.
Poslije nadogradnje Connect dijalog skriva lozinku, ali originalni podatak
ostaje sačuvan u preferences dok korisnik ponovo ne pokrene mount koji
poziva setter. Samo pokretanje aplikacije/čitanje recents ne uklanja zapis.

**Ispravka/proba:** jednokratna migracija sanitizovanog niza nazad u trajno
skladište. U pripremljene testne defaults upisati stari oblik, izvršiti
migraciju i pročitati sirovi ključ; nije dovoljno provjeriti samo getter.
Nisu čitane stvarne korisnikove lozinke ili preferences tokom ovog pregleda.

### 13. Brojač za Rename Many nema zaštitu od integer overflow-a

Mjesta: [BatchRename.swift:48](https://github.com/vladimirperovic/Foldera/blob/a176b72942a5eb2fea62853b1a867f23052ea2d5/Sources/Foldera/BatchRename.swift#L48),
[unos:379](https://github.com/vladimirperovic/Foldera/blob/a176b72942a5eb2fea62853b1a867f23052ea2d5/Sources/Foldera/BatchRename.swift#L379).

`start` i `step` prihvataju cijeli opseg `Int`, a `start + index * step` koristi
običnu provjeravanu Swift aritmetiku. `update()` se poziva pri svakoj izmjeni
teksta, prije klika na Rename. Brojač se računa čak i ako šablon nema `[C]`.

**Scenario:** sa najmanje dva izabrana fajla zalijepiti `9223372036854775807`
u početnu vrijednost uz step 1. Račun za drugi fajl prelazi `Int.max` i ruši
proces. Slično se može preliti množenje velikog step-a.

**Ispravka/proba:** koristiti checked/reporting-overflow račun i pokazati
validacionu grešku; provjeriti oba kraja opsega i negativne korake. Postojeći
testovi pravila provjeravaju uobičajene brojače, ne ove granice. Ovo je rijedak
ulazni slučaj, ali posljedica je pad cijele aplikacije.

## Prilike za optimizaciju

Ovo su zaključci o strukturi rada i složenosti. Nisu mjereni FPS, vrijeme
izvršavanja, propusnost ni stvarna zauzetost memorije.

| Prioritet | Mjesto | Sadašnji trošak | Predložena promjena i kasnije mjerenje |
| --- | --- | --- | --- |
| Visok | [Transfer.swift:530](https://github.com/vladimirperovic/Foldera/blob/a176b72942a5eb2fea62853b1a867f23052ea2d5/Sources/Foldera/Transfer.swift#L530) | Svako koordinisano čitanje zakazuje GCD posao koji prvo spava 250 ms, pa tek onda provjerava da li je čitanje odavno završeno. | Odloženi otkazivi timer ili zajednički watchdog po transferu. Za 10.000 brzih čitanja kod zakazuje ukupno 2.500 sekundi spavanja radnika; to je zbir iz koda, ne trajanje operacije. Mjeriti broj worker-a, red i vrijeme prenosa malih fajlova. |
| Visok | [Transfer.swift:83](https://github.com/vladimirperovic/Foldera/blob/a176b72942a5eb2fea62853b1a867f23052ea2d5/Sources/Foldera/Transfer.swift#L83), [FileOps.swift:90](https://github.com/vladimirperovic/Foldera/blob/a176b72942a5eb2fea62853b1a867f23052ea2d5/Sources/Foldera/FileOps.swift#L90) | Svaki naredni istoimeni izvor ponovo traži slobodan sufiks od 2; `exists` se poziva prije `taken.contains`. N istoimenih rezultata pretrage daje O(N²) provjera. | Pamtiti naredni sufiks po folderu/osnovnom imenu/ekstenziji i prvo provjeravati rezervisana imena. Oko 10.000 istih imena može tražiti oko 50 miliona kandidat provjera; broj je teorijski, bez benchmarka. |
| Visok | [ExplorerWindow.swift:832](https://github.com/vladimirperovic/Foldera/blob/a176b72942a5eb2fea62853b1a867f23052ea2d5/Sources/Foldera/ExplorerWindow.swift#L832), [Model.swift:352](https://github.com/vladimirperovic/Foldera/blob/a176b72942a5eb2fea62853b1a867f23052ea2d5/Sources/Foldera/Model.swift#L352) | Napuštena listanja nastavljaju enumeraciju, pravljenje snimaka i sortiranje; generacija odbacuje samo rezultat. Brza navigacija na sporom disku ostavlja suvišan rad. | Ograničen red, token za prekid između stavki i prije snapshot/sort faze. Mjeriti broj aktivnih listanja i broj pročitanih stavki nakon napuštanja foldera. |
| Visok | [Markdown.swift:523](https://github.com/vladimirperovic/Foldera/blob/a176b72942a5eb2fea62853b1a867f23052ea2d5/Sources/Foldera/Markdown.swift#L523) | Svaka lokalna slika dobija globalni background posao i cijeli `Data(contentsOf:)`; stop uklanja samo callback. | Ograničiti istovremena čitanja i veličinu podataka, otkazivati prije otvaranja. Provjeriti downsampling gdje je primjeren. Mjeriti vršnu memoriju za dokument sa mnogo velikih fotografija. |
| Srednji | [ImageViewer.swift:966](https://github.com/vladimirperovic/Foldera/blob/a176b72942a5eb2fea62853b1a867f23052ea2d5/Sources/Foldera/ImageViewer.swift#L966), [fillInfo:999](https://github.com/vladimirperovic/Foldera/blob/a176b72942a5eb2fea62853b1a867f23052ea2d5/Sources/Foldera/ImageViewer.swift#L999) | Promjena slike i otvaranje Info panela još mogu sinhrono čitati disk/metapodatke na glavnoj niti. | Metapodatke čitati u pozadini i objaviti uz URL/generaciju; ispitati odziv na sporo odgovarajućem SMB disku. |
| Srednji | [Markdown.swift:257](https://github.com/vladimirperovic/Foldera/blob/a176b72942a5eb2fea62853b1a867f23052ea2d5/Sources/Foldera/Markdown.swift#L257), [BackgroundTask.swift:35](https://github.com/vladimirperovic/Foldera/blob/a176b72942a5eb2fea62853b1a867f23052ea2d5/Sources/Foldera/BackgroundTask.swift#L35) | Novo ograničenje regex rada je po liniji. Napušten dokument i dalje može obrađivati mnogo linija jer nema prekida unutar parsera. | Provjera cancellation između blokova/linija i budžet cijelog dokumenta. Mjeriti koliko brzo novi mali README dobije worker nakon napuštanja velikih dokumenata. |
| Srednji | [Sync.swift:325](https://github.com/vladimirperovic/Foldera/blob/a176b72942a5eb2fea62853b1a867f23052ea2d5/Sources/Foldera/Sync.swift#L325) | Prvo se učita i odbaci lista svih imena u korijenu, pa enumerator ponovo obilazi isti korijen. Prvi prolaz nema prekid između stavki. | Jedan obilazak koji čuva razliku između nečitljivog i praznog foldera. Mjeriti broj disk poziva i trajanje Compare-a za široki SMB/exFAT korijen. |
| Srednji | [DiskUsage.swift:316](https://github.com/vladimirperovic/Foldera/blob/a176b72942a5eb2fea62853b1a867f23052ea2d5/Sources/Foldera/DiskUsage.swift#L316) | `worstRatio` računa min/max cijelog rastućeg reda za svakog kandidata: O(k²) agregiranja unutar reda od k elemenata. | Inkrementalni min/max ili krajevi već sortiranog reda. Mjeriti layout i resize vremena na velikom treemap-u. |

## Redoslijed narednih koraka

1. Zaštititi uklanjanje izvora tokom Move-a i identitet trajne Two way istorije.
2. Dodati revizije/identitete pri objavi sorta i mjerenja; popraviti watcher rearm.
3. Popraviti pogrešan izbor slike, Markdown href obradu, BSD tar operande,
   završni Cancel i redoslijed asinhronih clipboard/viewer operacija.
4. Migrirati stare serverske recents i zaštititi aritmetiku Rename Many.
5. Optimizovati watchdog, izbor slobodnih imena i otkazivanje napuštenih poslova;
   zatim mjeriti UI, memoriju i preostale prolaze kroz direktorijume.

Sve predložene probe ostale su neizvršene. Završno Git stanje prije dodavanja
ovog izvještaja potvrdilo je isti HEAD i origin/main; jedine lokalne stavke
bila su dva postojeća izvještaja. Ovaj novi izvještaj je jedina izmjena
napravljena tokom pregleda, pored traženog fast-forward ažuriranja maina.
