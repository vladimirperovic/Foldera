# Popravke poslije provjere — 3. oktobar 2026.

Popravke spajaju lokalni `696045d` sa promjenama do `origin/main` commita
`98f2f0e`. Sačuvani su nezavisni pane tabovi, sync profili, rasporedi i istorija,
kao i nova pravila za isključenje fajlova i foldera.

## Ispravljeno ponašanje

- **Istorija simboličkih linkova:** Two way pamti tekst njihovog zajedničkog
  odredišta u oba režima poređenja. Promjena linka uz sačuvanu veličinu i datum
  više ne opravdava brisanje jedine preostale izmijenjene kopije. Izmjene na
  obje strane ostaju konflikt; zamjena strana i ponovno učitavanje istorije
  čuvaju isti kriterijum. Stara istorija bez odredišta traži pregled dok linkovi
  ponovo ne budu jednaki. Neuspjelo čitanje odredišta blokira stavku i ne
  prepisuje ranije zajedničko stanje.
- **Gašenje:** poslije 30 sekundi otkazivanja aktivnog posla Quit se poništava
  ako posao još radi. Proces više nije prisilno završen prije čišćenja ili
  dovršetka Undo operacije.
- **Grupno preimenovanje:** jezgro odbija cijeli pripremljeni skup ako bilo
  koji red ima problem, kao što to već radi interfejs.
- **Spajanje novih sync isključenja:** sačuvani profili zadržavaju i smjer i
  isključenja; scheduler koristi isti skup isključenja kao ručni sync. Polje
  Exclude vidljivo je u novom sync prozoru i zaključano dok posao radi.
- **Izolacija testova:** tri grupe koje privremeno mijenjaju globalne putanje
  sync istorije/profila dijele serijalizovanu roditeljsku grupu. Time druga
  grupa ne može promijeniti putanju usred velikog Two way testa. Provjera
  međuprocesnog RunLock-a nalazi izvršni fajl i u debug i u release build-u.
- **Dokumentacija:** usklađeni su veličina aplikacije, snapshot opcije,
  ponašanje istorije linkova, gašenje i podrška za isključenja/rasporede.

## Provjera

| Provjera | Ishod |
| --- | --- |
| Debug paket sa CI skip-listom | 200 testova u 27 grupa; exit 0 |
| Release paket sa istom skip-listom | 200 testova u 27 grupa; exit 0 |
| RunLock poslije ispravke izbora build konfiguracije | Prolazi u obje konfiguracije |
| Zaseban case-sensitive APFS volumen | Izvedeni cross-volume Move/Undo/Redo i case-sensitive rename testovi |
| Release `build.sh` | Uspješan; aplikacija približno 2,3 MiB |
| `codesign --verify --deep --strict` | Prolazi za napravljenu i lokalno kopiranu aplikaciju |
| Sync snapshot sa profilom i isključenjima | Vizuelno provjeren; smjer, Exclude polje i plan odgovaraju profilu |

Regresije za linkove obuhvataju oba režima poređenja, obje strane,
izmjenu naspram brisanja, obje izmjene, staru istoriju bez odredišta,
zamjenu strana i uklanjanje istorije kada obje stavke nestanu.

Testiranje: macOS 27.0.1, Apple Silicon, Apple Swift 6.4. Debug je građen
direktnim SwiftPM build sistemom uz eksplicitnu CLT Testing framework putanju;
sistemski Swift build servis odbijao je pristup originalnom direktorijumu.
Release testovi i `build.sh` izvedeni su standardnim build sistemom u
privremenoj kopiji. SHA-256 poređenje potvrdilo je identičnost svih 63 ulaznih
fajlova izvora, testova, ikone, manifesta, skripti i README-ja. Linker i dalje
prijavljuje nedostajuće CLT putanje; upozorenja ne blokiraju build.

Četiri testa predaje fajlova kroz desktop file coordination ostaju isključena
CI skip-listom. Stvarni SMB, prekid mreže/odvajanje diska, pun disk, stvarni
iCloud i login/sleep/wake ciklus LaunchAgent-a nisu probani. Provjera odluke
pri isteku Quit roka ne zamjenjuje gašenje aplikacije tokom svake faze posla.
Beta upozorenje i dokumentovano ograničenje trke između posljednje provjere
putanje i operacije ostaju važeći.

Lokalni logovi, snapshot i manifest sačuvani su u ignorisanom direktorijumu
`build/claims-verification-2026-10-03`, sa prefiksom `fixed-`.
