# Foldera — dubinska provjera i ispravke, 5. oktobar 2026.

Polazna verzija je `a5ed15d` sa grane `main`. Prvobitni nalazi su ponovo
provjereni prije izmjena: dodatne reprodukcione probe ponovile su četiri
greške, iako je tadašnjih 204 redovna testa prolazilo. Završna verzija
prolazi **221 test u 29 grupa**, u debug i release konfiguraciji.

## Potvrđene greške i rješenja

| Problem | Ispravka | Provjera |
| --- | --- | --- |
| Kopiranje u isti stvarni folder preko druge putanje, npr. roditeljskog simboličkog linka, moglo je ponuditi zamjenu samog izvora. | Poredi se identitet roditeljskih foldera. Copy pravi `- Copy`, Move ne radi ništa; izvršavanje dodatno odbija isti izvor i odredište. | Copy/Move preko simboličkog linka i ručno pripremljen plan sa istim izvorom i odredištem. |
| Drugi program napravi odredišni fajl dok se čeka izvor; kopiranje ga pogrešno prijavi kao svoj rezultat i zabilježi za Undo. | `TreeCopier` radi unutar privatnog privremenog foldera. Gotov rezultat dobija konačno ime isključivim `renamex_np(RENAME_EXCL)`. Neuspjeh čisti samo vlastiti privremeni prostor. | Kontrolisano kreiranje tuđeg odredišta tokom čekanja placeholder-a; sadržaj ostaje isti, lista Undo promjena je prazna. |
| Replace premjesti postojeći fajl u Trash prije nego što nova kopija uspije. | Kopija se priprema prije zamjene; otkazivanje i greške ostavljaju stari fajl na mjestu. Odredište se ponovo provjerava po identitetu i metapodacima. | Nestali izvor, Cancel, izmijenjeno odredište tokom pripreme i odredišni simbolički link. |
| Stablo foldera trajno pamti djecu i odluku da je folder prazan. | Otvorene grane prate promjene, F5 osvježava stablo, a ponovno otvaranje poništava zastarjeli keš. Identitet postojećih čvorova se čuva. | Dodavanje podfoldera u otvorenu praznu granu, uklanjanje, F5 i očuvanje otvorene grane. |

Premještanje sa zamjenom na istom disku ostaje preimenovanje: ne pravi se
nepotrebna kopija i čuvaju se hard linkovi. Izvor se prvo koordinisano
pripremi. Ako preimenovanje ne uspije nakon pomjeranja starog odredišta,
staro odredište se vraća kada je njegovo ime slobodno. Ako je drugi pisac
već zauzeo ime, sačuvana Trash putanja ulazi u Undo, bez prepisivanja
novog fajla. Provjereni su neuspjelo preimenovanje zbog dozvola,
hard linkovi i Undo/Redo zamjene na istom i između različitih diskova.

Ako je kopija napravljena, a uklanjanje izvora pri Move operaciji zakaže,
napravljena kopija sada ipak ostaje evidentirana za Undo.

## Odziv i pozadinsko učitavanje

- Čitanje Markdown fajla u panelu pregleda, parsiranje Markdown-a i
  priprema HTML tijela za zamjenu rade u pozadini. Novi zahtjev poništava
  zastarjeli rezultat; zatvaranje pregleda/editor prozora prekida čekajući rad.
- Nabrajanje podfoldera u stablu i adresnoj traci, uključujući Tab
  dopunjavanje, više se ne radi na glavnoj niti. Meni dok čeka prikazuje
  `Loading…`. Zakasnelo dopunjavanje ne mijenja noviji unos.
- Dekodiranje bitmap slika i učitavanje pune rezolucije dijele red sa
  najviše dva aktivna posla. Poslovi izvan trenutne slike i susjeda se
  otkazuju, a njihovi zakasneli rezultati ne vraćaju odbačene slike u keš.
- Otvaranje deskriptora za praćenje foldera radi u ograničenom redu u
  pozadini. Zatvoren tab ne može ponovo dobiti stari watcher ili callback.
- Usklađivanje osvježenih čvorova stabla koristi mapu identiteta umjesto
  pretraživanja cijele prethodne liste za svaki novi čvor.

Novi testovi provjeravaju odbacivanje zastarjelog rezultata, otkazivanje
već zakazanog UI callback-a, ograničenje paralelnog rada i zaustavljanje
watcher-a dok je otvaranje još u toku. Tokom razvoja dodatni test je
otkrio petlju izazvanu obavještenjima `NSOutlineView` pri osvježavanju;
petlja je ispravljena prije završnih prolaza.

## Završni testovi

Okruženje: macOS 27.0.1 (26A434), Apple Silicon, Swift 6.4 / Command Line
Tools. Napravljen je zaseban privremeni case-sensitive APFS disk od
512 MiB. Oba puna prolaza koriste taj disk, bez preskakanja testova:

```sh
FOLDERA_TEST_VOLUME=/private/tmp/foldera-fixes-volume ./test.sh
FOLDERA_TEST_VOLUME=/private/tmp/foldera-fixes-volume ./test.sh -c release
```

| Paket | Rezultat |
| --- | --- |
| Debug | 221/221, 29 grupa |
| Release | 221/221, 29 grupa |
| Nove regresije | 17 test funkcija, uključujući parametrizovane Copy/Move slučajeve |
| Isti izvori | SHA-256 provjera svih 65 ulaznih fajlova u test kopiji i radnom projektu |
| Release aplikacija | `./build.sh`, približno 2,3 MiB; `codesign --verify --deep --strict` prolazi |

Pored novih regresija, puni paket obuhvata Sync režime i zastarjele
planove, isključenja, istoriju, rasporede i međuprocesni RunLock;
arhive i zaštitu putanja; tekst/Markdown, slike/OCR; pretragu, Quick Open,
nezavisne tabove dva panela i Undo/Redo. Testovi predaje placeholder-a
koriste simulirani `NSFilePresenter`.

Swift build servis nema pristup radnom direktorijumu u `Documents`, pa
su identični izvori testirani i izgrađeni u
`/private/tmp/foldera-fixes-20261005`. Logovi i manifest čuvaju se lokalno
u ignorisanom `build/deep-review-2026-10-05`.

## Provjera interfejsa

U zasebnoj test aplikaciji, nad privremenim podacima, provjereni su
otvaranje menija podfoldera, dopunjavanje putanje tasterom Tab i Markdown
pregled sa tabelom, listom zadataka i blokom koda. Test aplikacija koristi
sopstveni bundle identifikator.

Pregledani su i snimci završnog release builda: Markdown panel, dva
panela sa po 12 tabova pri širini 1080 u tamnoj temi, pregled slike i
Sync/Update poređenje. Nisu primijećena preklapanja kontrola ni prazni
prikazi nastali prelaskom na pozadinsko učitavanje.

## Granice nalaza

Ovo nije dokaz da u aplikaciji nema drugih grešaka. Nisu provjereni
stvarni SMB prekidi, odvajanje diska tokom operacije, pun disk, stvarni
iCloud/File Provider placeholder-i, login/sleep/wake ciklusi ni svaka
moguća tačka pada procesa.

Replace sa Trash oporavkom nije transakcija otporna na prekid napajanja.
Između posljednje provjere i promjene fajla i dalje postoji mali prostor
za upis drugog procesa; proizvoljne istovremene izmjene izvora nisu
isključene ovim testovima. Privremeni folder poslije pada procesa može
ostati na disku; Sync ga ignoriše.

Nisu svi pozivi datotečnom sistemu uklonjeni sa glavne niti. Planiranje
velikih spajanja foldera, pojedini upiti za ikone/metapodatke, eksplicitno
otvaranje i snimanje teksta u editoru i rezervni `NSImage` put za vektorske
formate ostaju kandidati za zasebno profilisanje. Ograničen broj poslova
ne može prekinuti već započeti sistemski poziv na nedostupnom serveru.

Postojeća beta oznaka i upozorenje o rezervnim kopijama ostaju opravdani.
