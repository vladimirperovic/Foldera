# Foldera — detaljna provjera aplikacije i Folder Sync-a

Datum: 29. septembar 2026.

**Procjena: aplikacija se uspješno gradi i postojeći testovi prolaze, ali Folder Sync trenutno ima potvrđene greške koje mogu obrisati ili prepisati podatke. Prije pouzdanog rada sa važnim fajlovima potrebno je otkloniti pet nalaza prioriteta P1.** Upozorenje o nedovoljno testiranoj beta verziji u README-ju je opravdano i treba da ostane.

Ovo je izvještaj, bez popravki aplikacije. Nisu dodavane nove funkcije. Izvorni kod, postojeći testovi i README nisu mijenjani tokom provjere.

## Obuhvat i način provjere

Pregledan je commit `8845e70f161cc07598c8e495b5686ce8eb4ee18a`, zajedno sa zatečenim necommitovanim izmjenama u `README.md`, `Sync.swift`, `SyncWindow.swift` i `SyncTests.swift`. Rezultati se odnose na to stanje radnog direktorijuma, a ne samo na posljednji commit ili ranije objavljeni DMG.

Glavni fokus bili su planiranje i izvršavanje sync-a, njegova istorija, konflikti, brisanje, simbolički linkovi, izmjene između poređenja i izvršavanja i prikaz rezultata. Pregledani su i zajedničko kopiranje/premještanje, Undo/Redo, kompresija i raspakivanje, Markdown prikaz i čuvanje, pregled slika, pretraga, kolone, mjerenje prostora, tabovi, adresna traka i gašenje aplikacije.

Testiranje je rađeno na izolovanoj kopiji projekta, u privremenim folderima, na lokalnom disku: macOS 27.0, Apple Silicon, Swift 6.4. Kopija je korištena zbog ograničenja build servisa u originalnom direktorijumu. Sadržaj 39 fajlova iz projekta, uključujući izvore, testove i README, provjeren je SHA-256 potpisima u odnosu na početno stanje.

Destruktivne probe pozivaju jezgro `Sync.Job` sa trajnim brisanjem isključivo nad testnim podacima. One potvrđuju šta izvršavanje radi sa planom; ne tvrde da su zaobiđena pitanja za potvrdu u interfejsu. Podrazumijevano slanje u Trash ublažava posljedice pojedinih grešaka, ali ne ispravlja pogrešan izbor fajla ili pogrešan plan.

| Provjera | Rezultat |
| --- | --- |
| Postojeći testovi | **115 testova u 18 grupa prolazi**, uključujući 30 sync testova |
| Release build preko `build.sh` | Uspješan; `.app` napravljen bez instalacije |
| Provjera potpisa `codesign --verify --deep --strict` | Uspješna |
| Dodatne ciljane probe, debug | 13 proba: 11 ne zadovoljava očekivano bezbjedno ponašanje, 2 prolaze |
| Iste ciljane probe, release | Isti ishod: 11 neuspješnih i 2 uspješne probe |
| Markdown, duboka ugniježđenost | Debug test pada na 4.005 znakova; release prolazi na 4.005 i 20.005 znakova |

Više neuspješnih proba provjerava isti uzrok: dvije ispituju istoriju Content režima, a dvije izlazak kroz simbolički link. Neuspjesi dodatnih proba nisu padovi postojećih testova projekta. Dodatne probe sačuvane su odvojeno, u lokalnom audit materijalu.

Build nije potpuno bez upozorenja: linker prijavljuje nedostajuće CLT putanje, a jedan postojeći sync test ne koristi rezultat `perform()`. To nije spriječilo build ili izvršavanje testova.

## Pregled nalaza

P1 označava moguć gubitak podataka ili izmjenu fajlova izvan izabranog obuhvata. P2 označava pogrešne rezultate, nepouzdan interfejs, probleme oporavka ili stabilnosti.

| # | Prioritet | Nalaz | Dokaz |
| --- | --- | --- | --- |
| 1 | P1 | Zastarjelo brisanje u Two way može kroz dva sync-a ukloniti obje kopije | Ponovljeno nad testnim fajlovima |
| 2 | P1 | Content istorija pamti samo veličinu i datum, pa gubi izmjene i konflikte | Dvije ciljane probe |
| 3 | P1 | Izmijenjeni cilj poslije Compare može biti prepisan bez prijave greške | Ciljana proba; dodatni vremenski prozor utvrđen u kodu |
| 4 | P1 | Zamjena podfoldera simboličkim linkom preusmjerava upis i brisanje izvan sync foldera | Odvojeno ponovljeni upis i brisanje |
| 5 | P1 | Neuspjela kompresija može obrisati fajl koji je drugi proces napravio | Ponovljeno nad testnim fajlom |
| 6 | P2 | Markdown parser nema ograničenje dubine; debug varijanta pada | Pad procesa i dijagnostika; ograničenje release provjere navedeno |
| 7 | P2 | Različiti simbolički linkovi mogu biti proglašeni jednakim u Content režimu | Ciljana proba |
| 8 | P2 | Kopiranje cijelog foldera prenosi i fajlove isključene iz Compare | Ciljana proba |
| 9 | P2 | Undo odbija preimenovanje koje mijenja samo velika/mala slova | Stvarno preimenovanje i provjera uslova u Undo kodu |
| 10 | P2 | Upozorenje o nepotpunom mjerenju nestaje pri otvaranju podfoldera iz keša | Ciljana proba |
| 11 | P2 | Režim sync-a i način brisanja ostaju promjenljivi dok posao radi | Utvrđeno u kodu interfejsa |
| 12 | P2 | Normalno gašenje aplikacije ne čeka aktivne operacije nad fajlovima | Utvrđeno u životnom ciklusu aplikacije |
| 13 | P2 | Kolone, pretraga i Properties prikrivaju greške čitanja | Utvrđeno u obradi rezultata i grešaka |

## Nalazi koji mogu izgubiti podatke

### 1. Two way ne provjerava da li je ponovo nastala kopija čije odsustvo opravdava brisanje

**Mjesto:** [Sync.swift:802](/Users/vladimirperovic/Documents/github/foldera/Sources/Foldera/Sync.swift:802), odluka o brisanju [Sync.swift:444](/Users/vladimirperovic/Documents/github/foldera/Sources/Foldera/Sync.swift:444).

`delete()` provjerava da li se cilj promijenio, ali ne provjerava drugu stranu. Ako je fajl na drugoj strani vraćen poslije Compare, stari nalog za brisanje i dalje se izvršava.

Ponovljeni scenario:

1. Lijevo i desno postoji isti `a.txt`; poređenje zapamti zajedničko stanje.
2. Lijeva kopija se obriše. Compare pravilno predlaže brisanje desne.
3. Prije Synchronize lijeva kopija se vrati, sa ranijim sadržajem i datumom.
4. Synchronize ipak obriše desnu kopiju.
5. Sljedeći Compare tumači sadašnje odsustvo desne kao brisanje koje treba prenijeti lijevo.
6. Drugi Synchronize obriše i lijevu kopiju.

U probi su poslije drugog izvršavanja **obje kopije nedostajale**. Pri trajnom brisanju nema oporavka kroz Trash ili Undo.

**Preporuka:** pred svaku destruktivnu operaciju ponovo provjeriti obje strane, uključujući očekivano odsustvo fajla. Vraćen fajl mora poništiti stari nalog i zahtijevati novo poređenje. Provjera samog cilja nije dovoljna.

### 2. Content režim ne čuva istoriju sadržaja

**Mjesto:** [Sync.swift:68](/Users/vladimirperovic/Documents/github/foldera/Sources/Foldera/Sync.swift:68), [Sync.swift:434](/Users/vladimirperovic/Documents/github/foldera/Sources/Foldera/Sync.swift:434), zapis istorije [Sync.swift:876](/Users/vladimirperovic/Documents/github/foldera/Sources/Foldera/Sync.swift:876).

Content poređenje čita bajtove dvije sadašnje kopije. Međutim, za odgovor na pitanje „ko se promijenio u odnosu na prethodno zajedničko stanje” koristi `Item.matches`, odnosno veličinu i datum uz toleranciju od dvije sekunde. U istoriji nema otiska sadržaja.

Potvrđena su dva problema:

- Poslije jednakih kopija `old`, lijeva postane `NEW`, iste dužine i sa sačuvanim datumom, a desna bude obrisana. **Content/Two way predlaže i izvršava brisanje lijeve, jedine preostale izmijenjene kopije.**
- Poslije jednakih kopija lijeva postane `AAA` uz sačuvan datum, a desna `BBB` uz noviji datum. Iako su obje izmijenjene, plan **nema konflikt** i predlaže prepisivanje lijeve desnom.

Dodatno, poslije posla `Job.perform()` radi provjeru u režimu Date and size i upisuje istoriju prije nego što prozor pokrene novo Content poređenje ([Sync.swift:748](/Users/vladimirperovic/Documents/github/foldera/Sources/Foldera/Sync.swift:748)). Time slabiji kriterijum može proglasiti sadržajno različite fajlove zajedničkim stanjem.

**Preporuka:** za Content istoriju sačuvati pouzdan otisak sadržaja i vrstu stavke. Ne donositi odluke o brisanju/prepisivanju na osnovu istorije slabije od izabranog poređenja. Postojeće istorije bez tih podataka tretirati konzervativno, a završnu provjeru izvršavati istim kriterijumom kao početnu.

### 3. Zaštita od promjena poslije Compare ne štiti sadržaj cilja

**Mjesto:** [Sync.swift:777](/Users/vladimirperovic/Documents/github/foldera/Sources/Foldera/Sync.swift:777), [Sync.swift:817](/Users/vladimirperovic/Documents/github/foldera/Sources/Foldera/Sync.swift:817).

Za fajl `unchanged()` vraća `true` čim se poklope veličina i približan datum. To radi i kada je izabran Content režim.

U probi je Content/Mirror plan pripremljen za lijevi `NEW` i desni `old`. Poslije Compare desni fajl izmijenjen je u `EDI`, uz datum pomjeren za jednu sekundu. Synchronize ga je prepisao sa `NEW`, a lista grešaka ostala je prazna.

Postoji i drugi vremenski prozor: cilj se provjerava **prije** kopiranja izvora u privremeni fajl, a uklanja tek poslije kopiranja. Promjena nastala tokom dužeg kopiranja nema novu provjeru neposredno prije uklanjanja. Taj drugi slučaj utvrđen je čitanjem koda, bez zasebne vremenski zavisne reprodukcije. Izvor takođe nije dosljedno provjeren u odnosu na pregledani plan.

**Preporuka:** odvojiti približnu jednakost za korisničko poređenje od stroge provjere pred izmjenu. Provjeravati identitet i sadržaj relevantnih fajlova, pa ponovo validirati cilj neposredno prije zamjene. Za samu zamjenu koristiti odgovarajuću koordinaciju i atomsku operaciju; niz običnih provjera putanja sam po sebi ostavlja trku.

### 4. Simbolički link u roditeljskoj putanji omogućava upis i brisanje izvan izabranih foldera

**Mjesto:** [Sync.swift:753](/Users/vladimirperovic/Documents/github/foldera/Sources/Foldera/Sync.swift:753), [Sync.swift:851](/Users/vladimirperovic/Documents/github/foldera/Sources/Foldera/Sync.swift:851), početna provjera [Sync.swift:701](/Users/vladimirperovic/Documents/github/foldera/Sources/Foldera/Sync.swift:701).

Korijeni se razrješavaju na početku Compare. Izvršavanje kasnije sklapa putanje dodavanjem imena i ne potvrđuje da roditeljski direktorijumi i dalje vode unutar istih korijena. `makeFolders()` prestaje provjeravati čim nađe nešto što postoji, uključujući naknadno postavljeni link.

Dvije probe:

- Compare predloži kopiranje u `R/sub/new.txt`. Prije izvršavanja `R/sub` zamijeni se linkom na testni `outside`. Novi fajl završi u `outside/new.txt`.
- Mirror predloži brisanje `R/sub/extra.txt`. `R/sub` se zatim zamijeni linkom na `outside`, gdje postoji odgovarajući fajl. Izvršavanje obriše **`outside/extra.txt`**.

Oba posla završe bez prijavljenog problema. `outside` je u probama bio bezbjedan privremeni direktorijum, ali izvan oba izabrana sync foldera.

**Preporuka:** vezati operacije za provjerene identitete direktorijuma i onemogućiti praćenje neočekivanih roditeljskih linkova. Ponovno poređenje stringova putanja nije dovoljna zaštita od zamjene između provjere i upisa. Zaštitu sprovesti u jezgru operacija, uz provjeru zamijenjenog ili ponovo montiranog korijena.

### 5. Čišćenje neuspjele kompresije može obrisati fajl koji taj posao nije napravio

**Mjesto:** izbor imena [Archive.swift:27](/Users/vladimirperovic/Documents/github/foldera/Sources/Foldera/Archive.swift:27), uklanjanje izlaza [Archive.swift:96](/Users/vladimirperovic/Documents/github/foldera/Sources/Foldera/Archive.swift:96).

Izlazno ime bira se unaprijed preko `freeURL`, ali se ne rezerviše. Ako drugi posao ili program u međuvremenu napravi fajl na tom mjestu, alat dobija njegovo ime kao izlaz. Kod neuspjeha ili otkazivanja Foldera bezuslovno uklanja tu putanju.

U probi je poslije pravljenja compression posla, a prije njegovog pokretanja, na izlaznu putanju upisan poseban tekstualni fajl. ZIP alat se završio kodom 3; Foldera je zatim obrisala taj fajl.

**Preporuka:** kompresovati u jedinstven privremeni izlaz koji pripada poslu. Po uspjehu ga premjestiti na konačno ime operacijom koja ne prepisuje postojeći fajl. Čišćenje smije uklanjati samo izlaz za koji posao ima potvrđeno vlasništvo.

## Ostale greške i nelogičnosti

### 6. Markdown parser nema ograničenje rekurzije

**Mjesto:** [Markdown.swift:98](/Users/vladimirperovic/Documents/github/foldera/Sources/Foldera/Markdown.swift:98), renderovanje [Markdown.swift:352](/Users/vladimirperovic/Documents/github/foldera/Sources/Foldera/Markdown.swift:352).

Svaki nivo blockquote-a ponovo poziva `blocks()`, bez ograničenja dubine. Tekst od 4.000 uzastopnih znakova `>` i nastavka ` text` srušio je debug test proces. Dijagnostika navodi `SIGSEGV`, pristup Stack Guard oblasti i ponovljene pozive `Markdown.blocks`.

**Granica dokaza:** release testovi sa 4.000 i 20.000 nivoa prošli su. Dakle, nije potvrđen pad produkcijske aplikacije na istom malom primjeru i ne treba tvrditi da jeste. Potvrđeni su pad debug konfiguracije i neograničena rekurzija; najveća bezbjedna dubina release parsera nije ustanovljena. Ako isti problem izazove pad aplikacije tokom rada, ugroženi su i nesačuvani tekstovi.

**Preporuka:** postaviti ograničenje dubine sa jasnim, bezbjednim prikazom preostalog teksta ili preći na obradu bez rekurzije. Obradu većeg dokumenta izmjestiti sa glavne niti.

### 7. Content režim ne razlikuje različita odredišta simboličkih linkova

**Mjesto:** [Sync.swift:192](/Users/vladimirperovic/Documents/github/foldera/Sources/Foldera/Sync.swift:192), model stavke [Sync.swift:47](/Users/vladimirperovic/Documents/github/foldera/Sources/Foldera/Sync.swift:47).

Linkovi se izuzimaju iz poređenja bajtova, a zatim porede samo veličinom i datumom. Njihovo odredište nije dio modela. Link `L/link → one` i link `R/link → two`, iste dužine i bliskih datuma, u Content/Mirror probi dali su **nula promjena i jedan jednak fajl**.

**Preporuka:** posebno čuvati vrstu stavke i tekst odredišta linka. Porediti sam link, bez čitanja fajla na koji vodi. Običan fajl i simbolički link ne treba proglasiti jednakim na osnovu iste veličine i datuma.

### 8. Pravila za ignorisanje važe za skeniranje, ali ne i za kopiranje cijelog foldera

**Mjesto:** [Sync.swift:236](/Users/vladimirperovic/Documents/github/foldera/Sources/Foldera/Sync.swift:236), [Sync.swift:769](/Users/vladimirperovic/Documents/github/foldera/Sources/Foldera/Sync.swift:769), [Transfer.swift:335](/Users/vladimirperovic/Documents/github/foldera/Sources/Foldera/Transfer.swift:335).

Kada cijeli folder postoji samo na jednoj strani, plan ga sažima u jedan red. Izvršavanje koristi opšte rekurzivno kopiranje, koje ne zna za sync isključenja.

Proba sa novim folderom koji sadrži `document.txt`, `.DS_Store` i `.recovery.foldera-sync` kopirala je sva tri fajla. Posljednja dva nisu bila uključena u normalno poređenje. Tako se prenose i djelimični fajlovi koje sync namjerno isključuje, a količina stvarno kopiranih podataka može odstupati od plana.

**Preporuka:** koristiti isti skup dozvoljenih stavki i pri planiranju i pri izvršavanju. Prikaz foldera kao jednog reda može ostati, ali ne smije zaobići pravila kopiranja.

### 9. Promjena velikih/malih slova u nazivu nije ispravno podržana kroz Undo

**Mjesto:** [Undo.swift:112](/Users/vladimirperovic/Documents/github/foldera/Sources/Foldera/Undo.swift:112).

Na testiranom disku koji ne razlikuje velika i mala slova, `readme.md → README.md` uspije. Međutim, stara i nova putanja tada obje označavaju isti fajl. Undo provjera `!FileOps.exists(from)` zaključi da je stara lokacija zauzeta i odbije vraćanje.

Proba je izvršila stvarno preimenovanje, provjerila zapisano ime u folderu i reprodukovala uslove pod kojima Undo odbija operaciju. Sam modalni Undo dijalog nije pokretan.

**Preporuka:** razlikovati koliziju sa drugim fajlom od dva naziva istog objekta. Za povratno preimenovanje primijeniti istu zaštitu od prepisivanja i podršku za promjenu veličine slova kao kod početne operacije.

### 10. Disk usage gubi oznaku nepotpunosti u podfolderima

**Mjesto:** [DiskUsage.swift:188](/Users/vladimirperovic/Documents/github/foldera/Sources/Foldera/DiskUsage.swift:188), čitanje keša [DiskUsage.swift:200](/Users/vladimirperovic/Documents/github/foldera/Sources/Foldera/DiskUsage.swift:200), prikaz upozorenja [DiskUsage.swift:451](/Users/vladimirperovic/Documents/github/foldera/Sources/Foldera/DiskUsage.swift:451).

Broj nečitljivih stavki zapisuje se samo u vrh skeniranog stabla. Ako se zatim kroz keš otvori podfolder, njegova oznaka `unreadable` ostaje nula.

U probi je folderu sa fajlom uklonjena dozvola čitanja. Roditeljski rezultat prijavio je jednu nečitljivu stavku, dok je isti nečitljivi podfolder iz keša imao **0 bajtova i 0 upozorenja**. Time nepoznata veličina izgleda kao potvrđena nula.

**Preporuka:** čuvati nepotpunost na odgovarajućem čvoru i propagirati je roditeljima. Prikaz nule razlikovati od nemogućnosti mjerenja.

### 11. Kontrole prikazuju promijenjene postavke dok stari sync posao nastavlja rad

**Mjesto:** [SyncWindow.swift:530](/Users/vladimirperovic/Documents/github/foldera/Sources/Foldera/SyncWindow.swift:530), hvatanje postavki posla [SyncWindow.swift:443](/Users/vladimirperovic/Documents/github/foldera/Sources/Foldera/SyncWindow.swift:443).

`updateControls()` tokom rada isključuje izbor foldera i tip poređenja, ali ne isključuje izbor Two way/Mirror/Update ni Trash/permanent. Job već ima kopiju redova i vrijednost `permanently`; promjena kontrole ne mijenja posao koji radi. Promjena režima pritom ponovo planira redove na ekranu.

Primjer posljedice: interfejs može pokazivati Update i Trash dok ranije pokrenuti Mirror posao nastavlja sa trajnim brisanjem po prethodno potvrđenom planu. Ovo je nalaz iz koda; nije izvođen zaseban test klikanja za vrijeme destruktivnog rada.

**Preporuka:** zaključati sve postavke koje određuju ponašanje aktivnog posla i tokom rada prikazivati njegove stvarne, sačuvane postavke.

### 12. Quit ne koordinira završetak aktivnih operacija

**Mjesto:** [AppDelegate.swift:57](/Users/vladimirperovic/Documents/github/foldera/Sources/Foldera/AppDelegate.swift:57), završno evidentiranje sync-a [SyncWindow.swift:460](/Users/vladimirperovic/Documents/github/foldera/Sources/Foldera/SyncWindow.swift:460).

`applicationShouldTerminate` provjerava Markdown izmjene, ali ne čeka aktivni sync, kopiranje ili kompresiju. Prekid procesa ne prolazi nužno kroz uobičajene putanje otkazivanja, čišćenja i bilježenja Undo promjena.

Posljedice mogu biti djelimično kopirani novi fajlovi, zaostali privremeni fajlovi i nedovršen posao bez zabilježene mogućnosti vraćanja. Ovo je nalaz iz koda životnog ciklusa; aplikacija sa stvarnim korisničkim poslovima nije nasilno zatvarana radi probe.

**Preporuka:** registrovati aktivne poslove i pri Quit ponuditi čekanje ili kontrolisano otkazivanje, zatim sačekati čišćenje i evidentiranje rezultata. Podržati odloženo gašenje kroz postojeći AppKit mehanizam.

### 13. Greške čitanja u drugim prikazima izgledaju kao potpuni rezultati

**Mjesto:** [Columns.swift:16](/Users/vladimirperovic/Documents/github/foldera/Sources/Foldera/Columns.swift:16), [Search.swift:154](/Users/vladimirperovic/Documents/github/foldera/Sources/Foldera/Search.swift:154), [Properties.swift:183](/Users/vladimirperovic/Documents/github/foldera/Sources/Foldera/Properties.swift:183).

- Kolone pretvaraju grešku pri listanju foldera u prazan niz i keširaju ga. Nečitljiv folder tako izgleda prazno.
- Pretraga ignoriše greške prolaska kroz foldere. Završni signal prenosi samo informaciju o limitu broja rezultata, ne i o preskočenim nečitljivim granama.
- Properties ignoriše greške enumeracije i završava prikaz veličine i broja fajlova kao da je mjerenje potpuno.

Ovo je potvrđeno čitanjem konkretnih putanja obrade, bez zasebnog automatizovanog testa svakog prozora.

**Preporuka:** dosljedno razlikovati prazan rezultat od nepotpunog ili neuspjelog čitanja. Prenijeti stanje greške do prikaza i omogućiti ponovno čitanje umjesto keširanja greške kao praznog foldera.

## Prostor za optimizovanje

| Mjesto | Zapažanje | Preporuka |
| --- | --- | --- |
| Planiranje sync-a | `replan()` poziva kompletni `Sync.plan` na glavnoj niti. Sintetički plan sa 100.000 fajlova trajao je oko 0,71 s u debug i 0,29 s u release konfiguraciji; to nije mjerenje skeniranja diska. | Planirati u pozadini, uz identifikator aktuelnog poređenja i odbacivanje zastarjelog rezultata. Posebno izmjeriti memoriju i odziv sa dubokim stablima. |
| Završetak Content sync-a | Jezgro prvo radi novo Date and size skeniranje oba stabla; prozor zatim ponavlja skeniranje u Content režimu. | Jedna završna provjera sa odgovarajućim kriterijumom i jedna pouzdana izmjena istorije. Ovo ujedno uklanja dio problema #2. |
| Prikaz kolona | `NSBrowser` delegat direktno poziva listanje i sortiranje foldera ([Columns.swift:141](/Users/vladimirperovic/Documents/github/foldera/Sources/Foldera/Columns.swift:141)). Sporo čitanje zauzima glavnu nit. | Uvesti asinhrono učitavanje sa stanjem učitavanja/greške, kao što osnovna lista već radi. Trajanje na stvarnom sporom SMB dijeljenju nije mjereno. |
| Markdown tokom uređivanja | Za isti dokument `show()` prvo pravi HTML za JavaScript, pa `Markdown.page()` ponovo parsira isti tekst radi pune stranice ([Markdown.swift:353](/Users/vladimirperovic/Documents/github/foldera/Sources/Foldera/Markdown.swift:353)). | Parsirati jednom, koristiti isti rezultat na oba mjesta i odbacivati zastarjele rezultate bržeg kucanja. |

Prioritet optimizacija je odziv interfejsa i uklanjanje duplog rada. Paralelizaciju više destruktivnih operacija ne bih uvodio prije ispravne provjere stanja, putanja i istorije.

## README i dosljednost opisa

Upozorenje na početku README-ja jasno kaže da je beta nedovoljno testirana, da radi sa fajlovima, da može izazvati nepovratan gubitak i da je korištenje na sopstvenu odgovornost. To odgovara rezultatima ove provjere.

Pojedine tvrdnje u opisu sync-a trenutno su jače od stvarnih garancija:

| Tvrdnja | Utvrđena granica |
| --- | --- |
| Sve što se promijenilo poslije Compare ostaje netaknuto | Nalazi #1, #3 i #4 pokazuju izuzetke |
| Izmjene na obje strane predstavljaju konflikt | Nalaz #2 pokazuje da Content istorija propušta izmjenu sa sačuvanim datumom |
| Compare content utvrđuje jednakost po bajtovima | Linkovi se porede drugačije, a istorija ne čuva sadržaj (#2, #7) |
| `.DS_Store` i `._` fajlovi nikad se ne prenose | Kopiranje cijelog foldera zaobilazi isključenja; proba je potvrdila prenos `.DS_Store` i privremenog sync fajla (#8) |
| Zamjena i brisanje više od pola fajlova traži potvrdu | Kod dodatno traži najmanje 10 pogođenih fajlova; potpuno brisanje ima odvojenu provjeru ([Sync.swift:359](/Users/vladimirperovic/Documents/github/foldera/Sources/Foldera/Sync.swift:359)) |

Opis treba uskladiti sa stvarnim granicama dok se greške ne poprave. Opšte beta upozorenje ne nadomješta preciznost pojedinačnih tvrdnji.

## Šta postojeći testovi dobro pokrivaju

Postojeći paket obuhvata osnovne Two way/Mirror/Update scenarije, prenošenje uobičajenih izmjena i brisanja, zamjenu strana, obično poređenje sadržaja, nečitljive foldere, nove fajlove dodate duboko u folder nakon Compare, konflikt fajl–folder, otkazivanje i zapis zamjene za Undo.

Raniji regresioni testovi pokrivaju zaštitu od prepisivanja pri preimenovanju, čuvanje tekstualnih izmjena i detekciju spoljašnjih izmjena, zaštitu otvorenih arhiva, objedinjavanje foldera, Undo redoslijed, invalidaciju izmjerenih veličina, mnogo dijagnostičkog izlaza kompresije, mrežne adrese i veliki broj tabova. U ovom pokretanju ti testovi nisu prijavili regresiju.

Problem je u nepokrivenim kombinacijama: Content + istorija + sačuvan datum, vraćanje odsutne strane poslije Compare, promijenjeni roditeljski link, isključenja unutar zbirnog kopiranja foldera i konkurentno stvaranje izlaznog fajla arhive.

## Preporučeni redoslijed daljeg rada

1. Popraviti #1–#4 zajedno sa regresionim testovima za gubitak podataka i izlazak iz sync korijena.
2. Popraviti vlasništvo nad izlazom kompresije (#5).
3. Uskladiti tretman linkova i ignorisanih fajlova, pa otkloniti Undo, upozorenja o nepotpunim rezultatima i kontrole aktivnog posla.
4. Dodati koordinisano gašenje i granicu dubine Markdown parsera.
5. Tek zatim optimizovati planiranje i završna skeniranja i ponovo provjeriti cijelu aplikaciju.

Prije zaključka da je verzija dovoljno pouzdana potrebne su i provjere koje ovaj pregled nije izveo: stvarni SMB bez Trash-a, prekid mreže i odvajanje diska tokom rada, disk bez slobodnog prostora, različiti fajl sistemi i zasebni volumeni, iCloud/placeholders, ACL/xattr/resource fork sadržaj, dva istovremena posla nad preklopljenim folderima i gašenje aplikacije u svakoj fazi operacije. Opcioni testovi koji zavise od `FOLDERA_TEST_VOLUME` u ovom pokretanju nisu vježbali zaseban volumen.

Pošto aplikacija sada ima željene funkcije, preporuka je usmjeriti naredni ciklus na ove popravke i provjeru oporavka. Prolazak postojećih testova i uspješan build ne predstavljaju potvrdu da je sync trenutno bezbjedan za jedine kopije važnih podataka.

## Lokalni dokazni materijal

Logovi, izdvojene probe i manifest pregledanih fajlova nalaze se u [build/audit-2026-09-29](/Users/vladimirperovic/Documents/github/foldera/build/audit-2026-09-29). To je lokalni direktorijum isključen iz Git-a. Probe nisu ubačene u redovni paket testova aplikacije.
