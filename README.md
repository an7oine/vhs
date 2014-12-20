vhs.sh
======

Bash-skripti kotimaisten internet-mediasisältöjen (Areena, Ruutu, Katsomo, TV5) automaattiseen tallennukseen. Yhteensopiva Linux-, OS X- ja Cygwin-järjestelmien kanssa. Vaatii seuraavat apuohjelmat ja vähimmäisversiot: bash-3.2, php, curl, wget, Perl::XML::xpath, rtmpdump-2.4, yle-dl, ffmpeg, GPAC, AtomicParsley.

Tallennukset asetetaan hakemistossa ~/Movies/vhs/, jonne tulee kutakin tallennettavaa ohjelmaa kohden luoda tiedosto nimellä "Sarjan nimi.txt":
- Tiedoston ensimmäinen rivi voi sisältää säännöllisen lausekkeen (regexp), jolla ohjelmia haetaan ja tallennetaan. TV-sarjan tai (radio-ohjelmissa) albumin nimeksi asetetaan txt-tiedoston nimestä poimittu "Sarjan nimi".
- Tiedoston rivit toisesta rivistä alkaen tulkitaan sarjakohtaiseksi metatiedon parsimiskoodiksi, jolla on käytettävissään ympäristömuuttuja "metadata" sisältönään verkosta haettu html-sivu. Koodi voi palauttaa ei-nollan paluuarvon ohittaakseen jakson tallentamisen tai tuottaa jaksoa koskevaa metatietoa asettamalla arvoja seuraaviin muuttujiin:
  - programme (tv-sarjan tai elokuvan nimi)
  - episode (tv-jakson nimi)
  - album (levyn nimi)
  - artist (esittäjä)
  - title (kappale)
  - albumArtist (levyn esittäjä)
  - epno (jakson tai kappaleen numero)
  - snno (kauden tai cd-levyn numero)
  - date (julkaisupäivämäärä)
  - ageLimit (ikärajamerkintä)
  - desc (jakson, elokuvan tai radiotuotannon kuvaus)
  - thumb (tiedostonimi - esim. ${tmp}/vhs.jpg - ladatulle kansikuvatiedostolle).
- Tiedosto voi olla myös tyhjä, jolloin nauhoitetaan kaikki jaksot säännöllisellä hakulausekkeella txt-tiedoston nimestä poimitun "Sarjan nimen" mukaan.

Skripti pitää tietokantaa kaikista jo tallennetuista jaksoista hakemistossa ~/.vhs/. Tyhjentämällä tämän kokonaan tai osittain voi pyytää edelleen saatavilla olevien jaksojen tallentamista uudelleen.

Tallennukset tehdään iTunes-yhteensopivaan MP4-muotoon H.264-kuvalla ja AAC-äänellä, parhaalla saatavilla olevalla laadulla ja mahdollisuuksien mukaan ilman uudelleenkoodausta. Internet-lähteistä poimittu ja tiedostoon tallennettu metatieto sekä mahdolliset irralliset tekstitykset (suomeksi) näkyvät sellaisenaan iTunes-kirjastossa ja sen sisältöä toistavissa iOS- ja Apple TV -laitteissa. Tallennukset sijoitetaan hakemistoon ~/Movies/tunes/, mikäli se on olemassa ja muuten hakemiston ~/Movies/vhs/ alle lajiteltuna alihakemistoihin ohjelmittain.

Skriptillä voi hakea ohjelmia ja jaksojen lukumääriä ja asettaa ajastimia säännöllisille lausekkeille. Suoritus ilman parametrejä käy olemassa olevat tallentimet läpi ja tallentaa kaiken uuden saatavilla olevan materiaalin. Lisätietoa ajamalla esimerkiksi "./vhs.sh help".

Käyttövinkkejä:
- Automaattinen ajo kerran päivässä yhdeltä yöllä (koneen päällä ollessa) onnistuu lisäämällä omaan crontab-luetteloon seuraava rivi:

0 1 * * * [polku]/vhs.sh
- Tallennettujen ohjelmien automaattinen lisääminen omaan iTunes-kirjastoon (OS X -ympäristössä) onnistuu luomalla symbolinen linkki ~/Movies/tunes seuraavasti:

ln -s ~/Music/iTunes/iTunes\ Media/Lisää\ automaattisesti\ iTunesiin ~/Movies/tunes
