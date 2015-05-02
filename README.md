vhs.sh
======

Bash-skripti kotimaisten internet-mediasisältöjen (Areena, Ruutu, {Katsomo}¹, TV5) automaattiseen tallennukseen. Yhteensopiva Linux-, OS X- ja Cygwin-järjestelmien kanssa. Vaatii seuraavat apuohjelmat ja vähimmäisversiot: bash-3.2, php, curl, Perl::XML::xpath, rtmpdump-2.4, yle-dl-2.7.0, ffmpeg-1.2.10, GPAC, AtomicParsley-0.9.5.

 ¹ ei toimi enää Mobiilikatsomon sulkemisen johdosta

Tallennukset asetetaan hakemistossa ~/Movies/vhs/, jonne tulee kutakin tallennettavaa ohjelmaa kohden luoda tiedosto nimellä "Sarjan nimi.txt":
- Tiedoston ensimmäinen rivi voi sisältää säännöllisen lausekkeen (regexp), jolla ohjelmia haetaan ja tallennetaan. TV-sarjan (tai radio-ohjelmissa albumin) nimeksi asetetaan silloinkin txt-tiedoston nimestä poimittu "Sarjan nimi".
- Tiedoston rivit toisesta rivistä alkaen tulkitaan sarjakohtaiseksi metatiedon parsimiskoodiksi, jolla on käytettävissään ohjelmalähteestä riippuen mm. muuttujat 'html_metadata' ja 'metadata' sisältönään verkosta haettu html- ja xml-sivu. Koodi voi palauttaa ei-nollan paluuarvon ohittaakseen jakson tallentamisen tai tuottaa jaksoa koskevaa metatietoa lukemalla ja kirjoittamalla seuraavien muuttujien arvoja:
  - programme (tv-sarjan, elokuvan tai radio-ohjelman nimi)
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
  - comment (vapaamuotoinen kommentti)
- Tiedosto voi olla myös tyhjä, jolloin nauhoitetaan kaikki jaksot säännöllisellä hakulausekkeella txt-tiedoston nimestä poimitun "Sarjan nimen" mukaan.

Skripti pitää tietokantaa kaikista jo tallennetuista jaksoista hakemistossa ~/.vhs/. Tyhjentämällä tämän kokonaan tai osittain voi pyytää edelleen saatavilla olevien jaksojen tallentamista uudelleen. Käyttäjä voi myös luoda em. hakemistoon tiedoston 'profile' asetusparametrien asettamista varten, tiedoston 'meta.sh' oman metatiedon tuottamiseen nauhoitustiedostoon tallentamista varten sekä tiedoston 'finish.sh' nauhoitustiedostojen loppusijoitusta varten.

Tiedostossa 'meta.sh' on mahdollista myös tuottaa itse tallennusmedia sopivasta ulkoisesta ohjelmalähteestä (vdr, tvheadend tms.). Lopputulos tulee tällöin sijoittaa MP4-muodossa muuttujan $product osoittamaan tiedostoon. MTV Katsomon mobiiliversion sulkeutumisen (1/2015) myötä ulkoinen tallentaminen (lähinnä DVB) on tällä hetkellä ainoa tapa hyödyntää tätä skriptiä MTV:n levittämien ohjelmien tallentamisessa.

Tallennukset tehdään iTunes-yhteensopivaan MP4-muotoon H.264-kuvalla ja AAC-äänellä, parhaalla saatavilla olevalla laadulla ja mahdollisuuksien mukaan ilman uudelleenkoodausta. Internet-lähteistä poimittu ja tiedostoon tallennettu metatieto sekä mahdolliset irralliset tekstitykset (suomeksi) näkyvät sellaisenaan iTunes-kirjastossa ja sen sisältöä toistavissa iOS- ja Apple TV -laitteissa.

Valmiit tallennukset sijoitetaan hakemistoon ~/Movies/tunes/, mikäli se on olemassa ja muuten hakemiston ~/Movies/vhs/ alle lajiteltuna alihakemistoihin ohjelmittain. Valmiiden tiedostojen loppusijoituksen voi tehdä myös omalla skriptillä, joka sijoitetaan tiedostoon ~/.vhs/finish.sh (ks. ylempänä) ja joka saa parametrikseen tuotetun tallennustiedoston nimen (väliaikaisine) polkuineen. finish.sh voi myös vain käsitellä tiedostoa paikallaan, jolloin se sijoitetaan automaattisesti yllä kuvatun mukaisesti.

Skriptillä voi hakea ohjelmia ja jaksojen lukumääriä ja asettaa ajastimia säännöllisille lausekkeille. Suoritus ilman parametrejä käy olemassa olevat tallentimet läpi ja tallentaa kaiken uuden saatavilla olevan materiaalin. Lisätietoa ajamalla esimerkiksi "./vhs.sh h".

Käyttövinkkejä:
- Automaattinen ajo kerran päivässä yhdeltä yöllä (koneen päällä ollessa) onnistuu OS X- tai Linux-ympäristössä lisäämällä omaan crontab-luetteloon seuraava rivi:

0 1 * * * [polku]/vhs.sh
- Tallennettujen ohjelmien automaattinen lisääminen omaan iTunes-kirjastoon (OS X -ympäristössä) onnistuu luomalla symbolinen linkki ~/Movies/tunes seuraavasti:

ln -s ~/Music/iTunes/iTunes\ Media/Lisää\ automaattisesti\ iTunesiin ~/Movies/tunes
