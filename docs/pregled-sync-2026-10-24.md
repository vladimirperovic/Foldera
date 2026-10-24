# Foldera — detaljan pregled sync funkcije

Pregledani su `Sync.swift`, `SyncWindow.swift`, `SyncScheduler.swift`,
`SyncLibrary.swift`, istorija, zajednički copier i postojeći regresioni
scenariji. Lokalni testovi i build nisu pokretani.

## Identitet foldera i istorija

Two way istorija sada vezuje putanje za UUID volumena i identitet oba
korijena. Zamijenjen disk ili folder i stara istorija bez identiteta ne
smiju pretvoriti nedostajući fajl u dokaz namjernog brisanja. Takva istorija
se odbacuje, snima se nova osnova i tekući plan zahtijeva ponovni Compare.
UI i jezgro blokiraju taj plan; scheduler ga bilježi kao Needs review.
Zamjena lijeve/desne strane zadržava ispravnu orijentaciju istorije.

Bez trajnog identiteta volumena stara istorija ne koristi se za propagaciju
brisanja. Trenutni posao koristi i identitet montiranog korijena; sigurnosni
fallback može ponovno kopirati fajl koji je ranije obrisan na drugoj strani.

**Dodatna greška:** izvršavanje je provjeravalo korijene samo na početku.
Sada se provjeravaju prije svake radnje i pri provjerama putanje i stvaranju
foldera. Zamjena korijena tokom kopiranja zaustavlja dalju objavu/brisanje
kada naredna provjera otkrije promjenu. Zastarjeli plan se ne nastavlja na
novom stablu. Regresioni scenario zamjenjuje lijevi korijen poslije prvog
brisanja i zahtijeva da drugi fajl ostane netaknut.

## Čitanje i poređenje

Korijen se više ne prelista prije enumeracije. `open(O_DIRECTORY)` i
enumerator razlikuju nečitljiv korijen od praznog foldera. Greške potomaka
blokiraju njih i sadržaj ispod njih. Kada čitanje metapodataka ne uspije ili
se pojave dva imena jednaka pri poređenju bez razlikovanja velikih slova,
enumerator preskače i potomke problematične stavke.

Content poređenje čita blokove od 1 MiB i poštuje Cancel. Poslije čitanja
provjerava da su oba fajla i njihovi stampovi još jednaki početnom listingu.
Isto važi za naknadne hashove fajlova iz istorije. Promjena tokom čitanja
ne smije ući u istoriju kao pouzdana jednakost. Nepouzdan rezultat blokira
stavku i traži novi Compare. Provjere trenutnih stavki koriste svjež URL,
bez oslanjanja na ranije pročitane resource values.

Date and size zadržava toleranciju dvije sekunde, radi FAT volumena.
Jednak datum i veličina nisu dokaz jednakih bajtova; Content je predviđen
za provjeru sadržaja. To je osobina izabranog režima, bez obećanja da je
jeftiniji režim ekvivalentan hashovanju.

## Plan i izvršavanje

Pregledani su Two way, Mirror, Update i obrnuti jednosmjerni plan, konflikti,
case kolizije, linkovi, izuzeci i cijeli folderi. Izuzeti ili nečitljivi
potomci sprečavaju brisanje/zamjenu njihovog foldera kao cjeline.
Prije destruktivne radnje odredište se provjerava prema Compare snimku,
uključujući potomke foldera. Povratak fajla na drugoj strani poništava
planirano brisanje. Putanje roditelja provjeravaju se radi zamjene linkom.

Zamjena prvo pravi staging. Stara verzija se sklanja tek poslije završene
kopije i ponovne provjere odredišta. Objavljivanje koristi isključivi
rename. Rollback ne smije pregaziti drugog pisca, a djelimično uklonjen
permanentni backup ne smije zamijeniti potpuno instaliranu novu verziju.
Zajednički copier dodatno provjerava izmjene izvora tokom čitanja.

**Dodatne greške:** završni Compare je prećutkivao grešku kroz `try?`, a
Cancel tokom posljednje radnje mogao je ostaviti ishod označen kao uspjeh.
Završna provjera sada prijavljuje grešku, završni Cancel označava posao kao
Stopped, a UI sa greškama kaže Finished with errors. Provjera istorije
prikazuje se odvojeno od broja nečitljivih stavki.

## Scheduler i evidencija

Pregledani su process lock između ručnog i zakazanog posla, izmjena profila
prije izvršavanja, prekid signalom, odluke koje traže pregled, ograničena
istorija i sažeci. Zakazani posao ne izvršava permanentna brisanja ili
zamjene kojima je potrebna ručna potvrda. Konflikti, nečitljive stavke,
neprovjerena istorija i veliki destruktivni planovi ostaju Needs review.

Postojeći macOS CI obuhvata debug/release i stvarne dodatne volumene.
Rezultat CI-ja treba čitati odvojeno od ovog statičkog pregleda. Nijedan
prolazak testova nije pretpostavljen na osnovu samog pregleda koda.
