#!/bin/bash

script_version=1.3

#######
# ASETUKSET

# tietokanta kaikista jo tallennetuista jaksoista pidetään täällä (luodaan ellei olemassa)
lib="${HOME}/.vhs"

# tallentimet (ja väliaikaistiedostot) sijoitetaan tänne (luodaan ellei olemassa)
vhs="${HOME}/Movies/vhs"

# valmiit tiedostot sijoitetaan tänne, jos olemassa
fine="${HOME}/Movies/tunes"

# tekstitykset haetaan tällä kielellä
sublang="fin"

# automaattitallentajien tiedostopääte
vhsext=".txt"

# alkuasetus-, metatiedon asetus- ja viimeistelyskripti
profile_script="${lib}/profile"
meta_script="${lib}/meta.sh"
finish_script="${lib}/finish.sh"

# käyttäjäagentit, bash-liput
OSX_agent="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_10_2) AppleWebKit/600.3.10 (KHTML, like Gecko) Version/8.0.3 Safari/600.3.10"
iOS_agent="Mozilla/5.0 (iPad; CPU OS 6_0 like Mac OS X) AppleWebKit/536.26 (KHTML, like Gecko) Version/6.0 Mobile/10A5355d Safari/8536.25"
shopt -s extglob
shopt -s nullglob
shopt -s nocasematch


#######
# VÄLIAIKAINEN TYÖHAKEMISTO

tmp="$( mkdir -p "${vhs}"; mktemp -d "${vhs}/.vhs.XXXX" )"
cd "${tmp}"
mkdir "${tmp}/cache"
trap "( cd -; rm -r \"${tmp}\" ) &>/dev/null" EXIT
trap "( cd -; rm -r \"${tmp}\" ) &>/dev/null" INT

# Cygwin-paikkaus
[[ "$( uname )" =~ cygwin ]] && tmp="$( cygpath -m "$tmp" )"

# Anna käyttäjän määritellä tarvittaessa lisää asetuksia ja apufunktioita
[ -e "${profile_script}" ] && . "${profile_script}"


#######
# ULKOISET APUOHJELMAT

function check-version {
	current_version=$1
	minimum_version=$2
	[ "$( echo $current_version$'\n'$minimum_version |sort -g |head -n1 )" = $minimum_version ]
}

function dependencies {
	deps="$( (
	check-version $BASH_VERSION 3.2 || echo -n "bash-3.2 "
	which php &>/dev/null || echo -n "php "
    which curl &>/dev/null || echo -n "curl "
    which xpath &>/dev/null || echo -n "xpath "
    which yle-dl &>/dev/null || echo -n "yle-dl "
    which MP4Box &>/dev/null || echo -n "gpac "
    ( which rtmpdump &>/dev/null && check-version $( rtmpdump 2>&1 | sed -n 's/^RTMPDump v//p' ) 2.4 ) \
     || echo -n "rtmpdump-2.4 "
    ( which ffmpeg &>/dev/null && check-version $( ffmpeg -version | awk '/^ffmpeg version /{print $3}' ) 1.2.10 ) \
     || echo -n "ffmpeg-1.2.10 "
    ( which AtomicParsley &>/dev/null && check-version $( AtomicParsley -version |awk '{print $3}' ) 0.9.5 ) \
     || echo -n "AtomicParsley-0.9.5 "
	) )"
	[ -z "$deps" ] && return 0
	echo "* Puuttuvat apuohjelmat: $deps" >&2
	exit 1
}


#######
# SISÄISET APUOHJELMAT (VAKIOSYÖTE-VAKIOTULOSTE)

function remove-rating {
	read programme_withrating
	echo "${programme_withrating%% (+([SK[:digit:]]))}"
}
function escape-regex {
	sed 's/[(){}\[^]/\\&/g; s/]/\\&/g'
}
function match-any-regex {
	programme="$1"
	tr '|' '\n' | while read regex
	 do [[ "$programme" =~ $regex ]] && break
	done
}
function dec-html {
	# muunnetaan html-koodatut erikoismerkit oletusmerkistöön
	php -R 'echo html_entity_decode($argn, ENT_QUOTES)."\n";'
}
function get-xml-field {
	path="$1"
	field="$2"
	xpath "$path" 2>/dev/null | sed 's#.*'"$field"'="\([^"]*\)".*#\1#'
}
function get-xml-content {
	path="$1"
	xpath "$path" 2>/dev/null | sed 's/<[^<]*>//g'
}
function ttml-to-srt {
	# suodatetaan pelkät tekstit, kukin omalle rivilleen
	# sen jälkeen numeroidaan tekstit, muunnetaan aikakoodit srt-muotoon ja jaetaan kukin 2-3 riville
	sed -n '\#<p begin=.*>.*<br/># {N;s/\n//;}; /^<p/ p' |\
	sed '=; s#<p begin=.\([0-9:.]*\). end=.\([0-9:.]*\).>\(.*\)</p>.*#\1 --> \2\
\3\
#; s#\([0-9:]\{8\}\)[.]\([0-9]\{3\}\)#\1,\2#g; s#<br/>#\
#g'
}
function txtime-to-epoch {
	read txtime
	[ -n "$txtime" ] || return
	if [ "$( uname )" = "Darwin" ]
	 then date -j -f '%d.%m.%Y %H:%M:%S' "${txtime}" "+%s" # Mac OS X
	 else date -d "$( sed 's#\(..\)[.]\(..\)[.]\(....\)#\3-\2-\1#' <<<"$txtime" )" "+%s" # Linux / Cygwin
	fi
}
function epoch-to-utc {
	read epoch
	[ -n "$epoch" ] || return
	if [ "$( uname )" = "Darwin" ]
	 then date -j -u -r "$epoch" "+%Y-%m-%dT%H:%M:%SZ" # Mac OS X
	 else date -u -d "@$epoch" "+%Y-%m-%dT%H:%M:%SZ" # Linux / Cygwin
	fi
}
function epoch-to-touch {
	read epoch
	[ -n "$epoch" ] || return
	if [ "$( uname )" = "Darwin" ]
	 then date -j -r "$epoch" "+%Y%m%d%H%M.%S" # Mac OS X
	 else date -d "@$epoch" "+%Y%m%d%H%M.%S" # Linux / Cygwin
	fi
}
function tv-rating {
	read age
	age="${age//[A-Za-z]}"
	[ -n "$age" ] || return
	if [ $age -lt 4 ]; then echo "fi-tv|0+|100|"
	elif [ $age -lt 9 ]; then echo "fi-tv|4+|150|"
	elif [ $age -lt 12 ]; then echo "fi-tv|9+|250|"
	elif [ $age -lt 17 ]; then echo "fi-tv|12+|300|"
	else echo "fi-tv|17+|400|"
	fi
}
function movie-rating {
	read age
	age="${age//[A-Za-z]}"
	[ -n "$age" ] || return
	if [ $age -lt 7 ]; then echo "fi-movie|S/T|100|"
	elif [ $age -lt 12 ]; then echo "fi-movie|K-7|200|"
	elif [ $age -lt 16 ]; then echo "fi-movie|K-12|300|"
	elif [ $age -lt 18 ]; then echo "fi-movie|K-16|350|"
	else echo "fi-movie|K-18|400|"
	fi
}
function season-number {
	local description_text r
	read description_text
	r='([0-9]{1,})[.]* [tuotanto]*kau[sdt]'; [[ "$description_text" =~ $r ]] && echo ${BASH_REMATCH[1]} && return 0
	r='ensimmäi[^ ]* [tuotanto]*kau[sdt]'; [[ "$description_text" =~ $r ]] && echo 1 && return 0
	r='toi[^ ]* [tuotanto]*kau[sdt]'; [[ "$description_text" =~ $r ]] && echo 2 && return 0
	r='kolma[^ ]* [tuotanto]*kau[sdt]'; [[ "$description_text" =~ $r ]] && echo 3 && return 0
	r='neljä[^ ]* [tuotanto]*kau[sdt]'; [[ "$description_text" =~ $r ]] && echo 4 && return 0
	r='viide[^ ]* [tuotanto]*kau[sdt]'; [[ "$description_text" =~ $r ]] && echo 5 && return 0
	r='kuude[^ ]* [tuotanto]*kau[sdt]'; [[ "$description_text" =~ $r ]] && echo 6 && return 0
	r='seitsemä[^ ]* [tuotanto]*kau[sdt]'; [[ "$description_text" =~ $r ]] && echo 7 && return 0
	r='kahdeksa[^ ]* [tuotanto]*kau[sdt]'; [[ "$description_text" =~ $r ]] && echo 8 && return 0
	r='yhdeksä[^ ]* [tuotanto]*kau[sdt]'; [[ "$description_text" =~ $r ]] && echo 9 && return 0
}


########
# TALLENNUKSEN APURUTIINIT

function cached-get {
	user_agent="$1"
	url="$2"

	cache="${tmp}/cache/${url//[^A-Za-z0-9]/-}"
	cat "$cache" 2>/dev/null && return 0

	curl -L -s -A "${user_agent}" "${url}" | tee "$cache"
}
function segment-downloader {
	prefix="$1"
	postfix="$2"
	begin="$3"

	# hae kaikki videosegmentit, lopeta viimeisen ei-tyhjän jälkeen
	for seg in $( seq ${begin} 9999 )
	 do
		# lataa segmentit mobiiliagentilla (Katsomo)
		curl -L -s -A "${iOS_agent}" "${prefix}${seg}${postfix}" -o "${tmp}/segment.ts"
		# hylkää tekstimuotoiset (puuttuvaa videotiedostoa ilmaisevat) dokumentit (TV5)
		[ -n "$( file "${tmp}/segment.ts" | grep 'HTML document text' )" ] && rm "${tmp}/segment.ts" && break
		cat "${tmp}/segment.ts" 2>/dev/null || break
		rm "${tmp}/segment.ts"
	done
}
function meta-worker {
	input="$1"
	subtitles="$2"

	# muodosta tulostiedostolle järkevä nimi
	if [ -n "${artist}" ]
	 then output="${artist} - ${album} - ${title}"
	elif [ -n "${album}" ]
	 then output="${album} - ${title}"
	elif [ -n "${episode}" ]
	 then output="${episode}"
    elif [ -n "${epno}" ]
	 then output="${programme} - osa ${epno}"
	 else output="${programme}"
    fi
	output="${tmp}/${output//\//-}"

	# käytä samaa tarkenninta kuin lähdetiedostossa (m4v tai m4a)
	out_ext="${input##*.}"

	# tutki, onko videokuvan pystysuuntainen tarkkuus vähintään 720p ja aseta HD-videomerkintä sen mukaisesti
	hdvideo=false
	[ "$( ffmpeg -i "${input}" 2>&1 | sed -n '/Video: h264/s/.*[0-9]x\([0-9]\{1,\}\).*/\1/p' )" -ge 720 ] 2>/dev/null && hdvideo=true
	
	# lisää tekstitykset jos ne on annettu, muutoin käytä syötettä sellaisenaan
    if [ -n "$subtitles" ]
     then MP4Box -add "${subtitles}:lang=${sublang}:hdlr=sbtl" -out "${output}.${out_ext}" "${input}" &>/dev/null || return 2
     else mv "${input}" "${output}.${out_ext}"
    fi

	[ -s "$thumb" ] || thumb="REMOVE_ALL"

	if [ "${out_ext}" = m4v ]
	 then
		# anna metatiedot videotiedostolle
		if [ -n "${epno}" -o -n "${episode}" ]
		 # metatiedot TV-sarjan mukaisesti
		 then AtomicParsley "${output}.m4v" \
--stik "TV Show" \
--TVShowName "$programme" \
--TVEpisode "$episode" \
--TVEpisodeNum "$epno" \
--TVSeasonNum "$snno" \
--year "$( epoch-to-utc <<<"$epoch" )" \
--purchaseDate "timestamp" \
--Rating "$( tv-rating <<<"$agelimit" )" \
--longdesc "$desc" \
--description "$desc" \
--artwork "$thumb" \
--hdvideo "$hdvideo" \
--comment "$comment" \
--overWrite &>/dev/null
		 # metatiedot elokuvan mukaisesti
		 else AtomicParsley "${output}.m4v" \
--stik value=9 \
--title "${programme#Elokuva: }" \
--year "$( epoch-to-utc <<<"$epoch" )" \
--purchaseDate "timestamp" \
--Rating "$( movie-rating <<<"$agelimit" )" \
--longdesc "$desc" \
--description "$desc" \
--artwork "$thumb" \
--hdvideo "$hdvideo" \
--comment "$comment" \
--overWrite &>/dev/null
		fi
	 else
		# anna metatiedot audiotiedostolle
		AtomicParsley "${output}.m4a" \
--stik value=1 \
--album "$album" \
--title "$title" \
--artist "$artist" \
--albumArtist "$albumArtist" \
--tracknum "$epno" \
--disk "$snno" \
--year "$( epoch-to-utc <<<"$epoch" )" \
--purchaseDate "timestamp" \
--longdesc "$desc" \
--description "$desc" \
--artwork "$thumb" \
--comment "$comment" \
--overWrite &>/dev/null
	fi
    [ $? -eq 0 ] || return 3
    
	# aseta julkaisuajankohta tulostiedoston aikaleimaksi
	touch -t "$( epoch-to-touch <<<"$epoch" )" "${output}.${out_ext}"

	# poista lähtötiedostot ja aja finish-skripti ja/tai siirrä tulos fine- tai ohjelmakohtaiseen hakemistoon
	rm "${input}" "${subtitles}" &>/dev/null
	if [ -x "${finish_script}" ]
	 then . "${finish_script}" "${output}.${out_ext}"
	fi
	if [ -e "${output}.${out_ext}" ]
	 then if [ -d "${fine}" ]
		 then mv "${output}.${out_ext}" "${fine}/"
		 else mkdir -p "${vhs}/${programme}/" && mv "${output}.${out_ext}" "${vhs}/${programme}/"
		fi
	fi
	[ $? -eq 0 ] || return 1
}


#######
# YLE AREENA

function areena-programmes {
	curl -L -s http://areena.yle.fi/tv/a-o |\
	sed -n '/<a.*href="http:\/\/areena.yle.fi\/tv\/[^"]*".*>/ N; s#.*<a.*href="http://areena.yle.fi/tv/\([^"]*\)".*>.*<span class=".*">\([^<]\{1,\}\)</span>.*#areena-tv \1 \2#p'
	curl -L -s http://areena.yle.fi/radio/a-o |\
	sed -n '/<a.*href="http:\/\/areena.yle.fi\/radio\/[^"]*".*>/ N; s#.*<a.*href="http://areena.yle.fi/radio/\([^"]*\)".*>.*<span class=".*">\([^<]\{1,\}\)</span>.*#areena-r \1 \2#p'
}
function areena-episodes {
	type="$1" # "tv" tai "radio"
	link="$2"
	# vain yhden jakson sisältävät ohjelmalinkit (elokuvat tai konsertit) toimivat jakson linkkeinä sellaisenaan, tällöin search.rss-sivua ei löydy
	curl -L --fail -s "http://areena.yle.fi/api/search.rss?id=${link}" |\
	sed -n '/rss/ d; s#.*<link>\(.*\)</link>.*#\1#p'
	[ "${PIPESTATUS[0]}" -eq 0 ] || echo "http://areena.yle.fi/${type}/${link}"
}
function areena-episode-string {
	link="$1"
	metadata="$( cached-get "${OSX_agent}" "${link}" )"
	epno="$( sed -n '/episodeNumber:/ s/.*'\''\(.*\)'\''.*/\1/p' <<<"$metadata" )"
	desc="$( sed -n 's/.*title:.*desc: '\''\(.*\) *'\'',.*/\1/p' <<<"$metadata" )"
	title="$( sed -n 's/.*title: *'\''\([^'\'']*\) *'\'',.*/\1/p' <<<"$metadata" )"
	echo "Osa ${epno}: ${title}. ${desc}"
}
function areena-worker {
    link="$1"
    programme="$2"
	custom_parser="$3"

	metadata="$( cached-get "${OSX_agent}" "${link}" )"

	# poimitaan areenan käyttämä sisäinen id-tunnus parsimisskriptien käyttöön
	areena_clipid="$( sed -n '/AREENA.clip = {/,/}/ s/.*id: '\''\([0-9a-z]*\)'\''.*/\1/p' <<<"$metadata" )"
	type="$( sed -n '/type:/ s/.*'\''\(.*\)'\''.*/\1/p' <<<"$metadata" )" # "audio" tai "video"

	desc="$( sed -n 's/title:.*desc: '\''\(.*\) *'\'',.*/\1/p' <<<"$metadata" |sed 's/^[ \t]*//' )"
	epno="$( sed -n '/episodeNumber:/ s/.*'\''\(.*\)'\''.*/\1/p' <<<"$metadata" )"
	# yritetään tulkita jakson kuvauksessa numeroin tai sanallisesti ilmaistu kauden numero
	snno="$( season-number <<<"$desc" )"

	epoch="$( sed -n '/broadcasted:/ s/.*'\''\(.*\)'\''.*/\1/p' <<<"$metadata" | sed 's#\([0-9]*\)/\([0-9]*\)/\([0-9]*\)#\3.\2.\1#' | txtime-to-epoch )"
	agelimit="$( sed -n 's#.*class="restriction age-\([0-9]*\) masterTooltip".*#\1#p' <<<"$metadata" )"

	thumb="$( sed -n 's#.*<div id="areena_player" class="wrapper main player"  style="background-image: url(\(http://.*.jpg\));">.*#\1#p' <<<"$metadata" )"
	[ -n "${thumb}" ] || thumb="$( sed -n 's#.*<meta property="og:image" content="\(http://.*\)_[0-9]*.jpg" />.*#\1_720.jpg#p' <<<"$metadata" )"
	[ -n "${thumb}" ] && curl -L -s -o "${tmp}/vhs.jpg" "${thumb}" && thumb="${tmp}/vhs.jpg"

	if [ "$type" = "audio" ]
	 then product="${tmp}/vhs.m4a"
		# aseta radio-ohjelman nimi albumin nimeksi
		album="$programme"
		# aseta radio-ohjelman jakson nimi raidan nimeksi
		title="$( sed -n '/title:/ s/.*'\''\(.*\)'\''.*/\1/p' <<<"$metadata" )"
		# etsi sopiva AAC-koodekki ja aseta mp3-ääni koodattavaksi aac-muotoon
		if [ -n "$( ffmpeg -codecs 2>/dev/null |grep libfaac )" ]; then audio_recode="-acodec libfaac"
		elif [ -n "$( ffmpeg -codecs 2>/dev/null |grep libfdk_aac )" ]; then audio_recode="-acodec libfdk_aac"
		elif [ -n "$( ffmpeg -codecs 2>/dev/null |grep libvo_aacenc )" ]; then audio_recode="-acodec libvo_aacenc"
		else echo "* FFmpeg-yhteensopivaa AAC-koodekkia (libfaac/libfdk_aac/libvo_aacenc) ei löydy" >&2; exit 2;
		fi
	 else product="${tmp}/vhs.m4v"
	fi

	# suoritetaan käyttäjän oma sekä tallentimessa annettu parsimiskoodi
	[ -x "${meta_script}" ] && ( . "${meta_script}" || return 100 )
	. $custom_parser || return 100
	echo

	# käytä väliaikaista .flv-tiedostoa
	yle-dl -q "$link" -o "${tmp}/vhs.flv" &>/dev/null || return 10
	ffmpeg -i "${tmp}/vhs.flv" -c copy $audio_recode "$product" -y -v quiet || return 20
	rm "${tmp}/vhs.flv"

	# ota halutun kieliset tekstit talteen ja poista muut
	subtitles="$( ls "${tmp}/vhs.${sublang}.srt" 2>/dev/null )"
	find "${tmp}/" -name vhs.\*.srt -not -name "vhs.${sublang}.srt" -delete

	meta-worker "$product" "${subtitles}"
}


###########
# NELONEN RUUTU

function ruutu-programmes {
	curl -L -s http://www.ruutu.fi/ohjelmat |\
	sed -n 's#.*<a.*href="/ohjelmat/\([^"]*\)".*>\([^<]\{1,\}\)</a>.*#ruutu \1 \2#p'
}
function ruutu-episodes {
	link="$1"
	# suodatetaan pois jaksot, joiden kuvauksessa (19 riviä ennen linkkiä) mainitaan 'ruutuplus'
	curl -L -s "http://www.ruutu.fi/ohjelmat/${link}" |\
	sed '/<div class="ruutuplus">/ { n;n;n;n;n;n;n;n;n;n;n;n;n;n;n;n;n;n;n;d; }' |\
	sed -n 's#.*<a href="\(/ohjelmat/'"${link}"'/[^?"]*\)">.*#http://www.ruutu.fi\1#p'
}
function ruutu-episode-string {
	link="$1"
	html_metadata="$( cached-get "${OSX_agent}" "${link}" | dec-html )"
	epid="$( sed -n 's/.*data-media-id=\"\([0-9]*\)\".*/\1/p' <<<"$html_metadata" )"
	metadata="$( cached-get "${OSX_agent}" "http://gatling.ruutu.fi/media-xml-cache?id=${epid}" | iconv -f ISO-8859-1 | dec-html )"
	episode="$( sed -n 's#<meta property=\"og:title\" content=\"\(.*\)\" />#\1#p' <<<"$html_metadata" )"
	desc="$( get-xml-field //Playerdata/Behavior/Program description <<<"$metadata" )"
	echo "${episode}. ${desc}"
}
function ruutu-worker {
	link="$1"
	programme="$2"
	custom_parser="$3"

	html_metadata="$( cached-get "${OSX_agent}" "${link}" | dec-html )"
	og_title="$( sed -n 's#<meta property=\"og:title\" content=\"\(.*\)\" />#\1#p' <<<"$html_metadata" )"
	epno="$( sed -n 's/.* - Kausi [0-9]* - Jakso \([0-9]*\) - .*/\1/p' <<<"$og_title" )"
	snno="$( sed -n 's/.* - Kausi \([0-9]*\) - Jakso [0-9]* - .*/\1/p' <<<"$og_title" )"
	episode="$( sed -n 's/.* - Kausi [0-9]* - Jakso [0-9]* - \(.*\)/\1/p' <<<"$og_title" )"

	epid="$( sed -n 's/.*data-media-id=\"\([0-9]*\)\".*/\1/p' <<<"$html_metadata" )"
	metadata="$( cached-get "${OSX_agent}" "http://gatling.ruutu.fi/media-xml-cache?id=${epid}" | iconv -f ISO-8859-1 | dec-html )"

	source="$( get-xml-content //Playerdata/Clip/MediaFiles/MediaFile <<<"$metadata" )"
	[ -n "$source" ] || return 10

	desc="$( get-xml-field //Playerdata/Behavior/Program description <<<"$metadata" )"
	epoch="$( get-xml-field //Playerdata/Behavior/Program start_time <<<"$metadata" | sed 's#$#:00#' | txtime-to-epoch )"
	agelimit="$( get-xml-content //Playerdata/Clip/AgeLimit <<<"$metadata" )"

	thumb="$( get-xml-field //Playerdata/Behavior/Startpicture href <<<"$metadata" )"
	[ -n "${thumb}" ] && curl -L -s -o "${tmp}/vhs.jpg" "${thumb}" && thumb="${tmp}/vhs.jpg"

	# suoritetaan käyttäjän oma sekä tallentimessa annettu parsimiskoodi
	[ -x "${meta_script}" ] && ( . "${meta_script}" || return 100 )
	. $custom_parser || return 100
	echo

	# lataa flv-muotoinen aineisto ja muunna lennossa mp4-muotoon
	rtmpdump --live -r "$source" --quiet -o - |ffmpeg -i - -c copy "${tmp}/vhs.m4v" -y -v quiet || return 20

	meta-worker "${tmp}/vhs.m4v" "${subtitles}"
}


#########
# MTV KATSOMO

function katsomo-programmes {
	curl -L -s "http://www.katsomo.fi/#" |\
	iconv -f ISO-8859-1 |\
	sed -n 's#.*<a.*href="http://www.katsomo.fi/?treeId=\([^"]*\)".*>\([^<]\{1,\}\)<.*#katsomo \1 \2#p'
}
function katsomo-episodes {
	link="$1"
	# suodatetaan pois maksulliset (muut kuin "play-link") jaksot
	curl -L -s "http://www.katsomo.fi/?treeId=${link}" |\
	iconv -f ISO-8859-1 |\
	sed -n 's#.*<a href="\(/?progId=[^"]*\)".*class="play-link".*>.*#http://www.katsomo.fi\1#p'
}
function katsomo-episode-string {
	link="$1"
	html_metadata="$( cached-get "${OSX_agent}" "${link}" | iconv -f ISO-8859-1 |\
sed -n '\#<a class="title" href="/?progId='${link#*/?progId=}'">#,/<span class="hidden title-hidden">/p' )"
	metadata="$( cached-get "${OSX_agent}" "${link/\?/sumo/sl/playback.do?}" | iconv -f ISO-8859-1 | dec-html )"
	epno="$( sed -n '/<div class="season-info" style="display:none;">/ {;n;s#.*[Jj]akso[: ]*\([0-9]*\).*#\1#p;}' <<<"$html_metadata" )"
	episode="$( get-xml-content //Playback/MatchId <<<"$metadata" )"
	desc="$( get-xml-content //Playback/Description <<<"$metadata" )"
	echo "Osa ${epno}: ${episode}. ${desc}"
}
function katsomo-worker {
	link="$1"
	programme="$2"
	custom_parser="$3"

	# hae kauden ja jakson numero www.katsomo.fi-sivun kautta
	html_metadata="$( cached-get "${OSX_agent}" "${link}" | iconv -f ISO-8859-1 |\
sed -n '\#<a class="title" href="/?progId='${link#*/?progId=}'">#,/<span class="hidden title-hidden">/p' )"
	snno="$( sed -n '/<div class="season-info" style="display:none;">/ {;n;s#.*[Kkv][au][uo]si[: ]*\([0-9]*\).*#\1#p;}' <<<"$html_metadata" )"
	epno="$( sed -n '/<div class="season-info" style="display:none;">/ {;n;s#.*[Jj]akso[: ]*\([0-9]*\).*#\1#p;}' <<<"$html_metadata" )"

	# hae muut metatiedot /sumo/sl/playback.do-osoitteen xml-dokumentista
	metadata="$( cached-get "${OSX_agent}" "${link/\?/sumo/sl/playback.do?}" | iconv -f ISO-8859-1 | dec-html )"

	episode="$( get-xml-content //Playback/MatchId <<<"$metadata" )"
	desc="$( get-xml-content //Playback/Description <<<"$metadata" )"
	epoch="$( get-xml-content //Playback/TxTime <<<"$metadata" | txtime-to-epoch )"
	agelimit="$( get-xml-content //Playback/AgeRating <<<"$metadata" )"

	# jos jakson nimenä on pelkkä ohjelman nimi, kirjaa lähetysaika jakson nimeksi
	[[ "$episode" =~ "$programme" ]] && episode="$( epoch-to-touch <<<"$epoch" )"

	thumb="$( get-xml-content //Playback/ImageUrl <<<"$metadata" )"
	[ -n "${thumb}" ] && curl -L -s -o "${tmp}/vhs.jpg" "${thumb}" && thumb="${tmp}/vhs.jpg"

	sublink="$( get-xml-content //Playback/Subtitles/Subtitle <<<"$metadata" | sed 's#.*\(http://[^"]*\)".*#\1#' )"
	if [ -n "$sublink" ]
	 then subtitles="${tmp}/vhs.${sublang}.srt"
		curl -L -s "${sublink}" | dec-html | ttml-to-srt > "$subtitles"
	 else subtitles=""
	fi

	# hae videolinkki Mobiilikatsomosta, poistu jos linkkiä ei löydy
	source="$( curl -L -s -A "${iOS_agent}" "${link/www.katsomo.fi\//m.katsomo.fi/}" |\
sed -n 's#.*<source type="video/mp4" src="http://[^.]*[.]\(.*\)/playlist[.]m3u8.*"/>.*#http://median3mobilevod.\1#p' |\
sed 's#HLS[A-Z]#HLSH#' )"
	[ -n "$source" ] || return 10

	# suoritetaan käyttäjän oma sekä tallentimessa annettu parsimiskoodi
	[ -x "${meta_script}" ] && ( . "${meta_script}" || return 100 )
	. $custom_parser || return 100
	echo

	# hae kaikki videosegmentit (aloittaen 0:sta) ja muunna lennossa mp4-muotoon
	segment-downloader "${source}/media_" ".ts" 0 |ffmpeg -i - -c copy -absf aac_adtstoasc "${tmp}/vhs.m4v" -y -v quiet || return 20

	meta-worker "${tmp}/vhs.m4v" "${subtitles}"
}


###########
# TV5

function tv5-programmes {
	curl -L -s 'http://tv5.fi/nettitv' |\
	iconv -f ISO-8859-1 |\
	sed -n 's#.*<a href="/nettitv/\([^/"]*\)/.*">\([^<]*\)</a>.*#tv5 \1 \2#p' |sed 's/, osa [0-9]*//'
}
function tv5-episodes {
	link="$1"
	# suodatetaan pois jaksot, jotka eivät (enää) ole katsottavissa
	curl -L -s "http://tv5.fi/nettitv/${link}" |\
	iconv -f ISO-8859-1 |\
	sed -n 's#.*<a href="\(/nettitv/'"${link}"'/[^"]*\)".*#http://tv5.fi\1#p' |\
	while read eplink
	 do [ -n "$( cached-get "${OSX_agent}" "$eplink" | sed -n '/jwplayer('\''video'\'').setup/ p' )" ] && echo "$eplink"
	done
}
function tv5-episode-string {
	link="$1"
	metadata="$( cached-get "${OSX_agent}" "${link}" | sed -n '/<meta.*\/>/ p; /jwplayer('\''video'\'').setup/ p' )"
	epno="$( sed -n 's#.*<meta property="og:title" content=".*, osa \([0-9]*\)".*#\1#p' <<<"$metadata" )"
	desc="$( sed -n 's#.*<meta property="og:description" content="\([^"]*\)".*#\1#p' <<<"$metadata" )"
	echo "Osa ${epno}. ${desc}"
}
function tv5-worker {
	link="$1"
	programme="$2"
	custom_parser="$3"

	# muistin säästämiseksi ota ympäristömuuttujaan 'metadata' vain oleelliset osat sivun sisällöstä
	metadata="$( cached-get "${OSX_agent}" "${link}" | sed -n '/<meta.*\/>/ p; /jwplayer('\''video'\'').setup/ p' )"

	epno="$( sed -n 's#.*<meta property="og:title" content=".*, osa \([0-9]*\)".*#\1#p' <<<"$metadata" )"
	desc="$( sed -n 's#.*<meta property="og:description" content="\([^"]*\)".*#\1#p' <<<"$metadata" )"

	direct_mp4="$( sed -n 's#.*jwplayer('\''video'\'').setup.*file: '\''\(http://[^'\'']*[.]mp4\)'\''.*#\1#p' <<<"$metadata" )"

	thumb="$( sed -n 's#.*jwplayer('\''video'\'').setup.*image: '\''\(http://[^'\'']*\)'\''.*#\1#p' <<<"$metadata" )"
	[ -n "${thumb}" ] && curl -L -s -o "${tmp}/vhs.jpg" "${thumb}" && thumb="${tmp}/vhs.jpg"

	# suoritetaan käyttäjän oma sekä tallentimessa annettu parsimiskoodi
	[ -x "${meta_script}" ] && ( . "${meta_script}" || return 100 )
	. $custom_parser || return 100
	echo
	
	# hae ensisijaisesti lähdetiedosto sellaisenaan, yritä sen jälkeen segmentoitua latausta
	if [ -z "${direct_mp4}" ] || ! curl -L -s -o "${tmp}/vhs.m4v" "${direct_mp4}"
	 then
		# nouda master-luettelo eri tarkkuuksia vastaavista soittolistoista
		master_m3u8="$( sed -n 's#.*jwplayer('\''video'\'').setup.*file: '\''\(http://.*/master.m3u8\)'\''.*#\1#p' <<<"$metadata" )"
		[ -n "$master_m3u8" ] || return 10

		# poimi master-luettelon viimeinen (korkeimman tarkkuuden) soittolista
		postfix="$( curl -L -s "${master_m3u8}" | sed -n 's#.*index\([^/]*\).m3u8$#\1#p' | tail -n 1 ).ts"

		# hae kaikki videosegmentit (aloittaen 1:stä) ja muunna lennossa mp4-muotoon
		prefix="${master_m3u8%/master.m3u8}/segment"
		segment-downloader "${prefix}" "${postfix}" 1 |ffmpeg -i - -c copy -absf aac_adtstoasc "${tmp}/vhs.m4v" -y -v quiet || return 20
	fi

	meta-worker "${tmp}/vhs.m4v" "${subtitles}"
}


##########
# OHJELMIEN, JAKSOJEN JA MEDIAN HAKURUTIINIT

# ohjelmalistaus ladataan verkosta vain kerran ja tallennetaan ajokohtaiseen välimuistitiedostoon
function sorted-programmes {
	cache="${tmp}/cache/programmes.txt"
	cat "${cache}" 2>/dev/null && return 0
	[ -d "${tmp}/cache" ] || return 1

	( areena-programmes; ruutu-programmes; katsomo-programmes; tv5-programmes ) |\
	LC_ALL=UTF-8 sort -f -u -t ' ' -k 3 |\
	tee "${cache}"
}
function query-sourced-programmes {
    regex="$1"

	sorted-programmes | while read source link title
	 do
		[ -n "$regex" ] && ! match-any-regex "$( remove-rating <<<"$title" )" <<<"$regex" && continue
		echo "$source" "$link" "$title"
	done
}
function query-programme-episodes {
	source="$1"
	link="$2"

	cache="${tmp}/cache/${source}-${link##*[/=]}-episodes.txt"
	cat "${cache}" 2>/dev/null && return 0
	[ -d "${tmp}/cache" ] || return 1

	case $source in
	 areena-tv) areena-episodes tv "$link" ;;
	 areena-r) areena-episodes radio "$link" ;;
	 ruutu) ruutu-episodes "$link" ;;
	 katsomo) katsomo-episodes "$link" ;;
	 tv5) tv5-episodes "$link" ;;
	 *) echo "*** OHJELMAVIRHE: source=\"${source}\" ***" >&2; exit -1 ;;
	# suodatetaan pois useaan kertaan esiintyvät jakson linkit
	esac | awk '!x[$0]++' | tee "${cache}"
}
function unified-episode-string {
	link="$1"

	case "$( sed 's#http://\([^/]*\).*#\1#' <<<"$link" )" in
	 areena.yle.fi) areena-episode-string "$@" ;;
	 www.ruutu.fi) ruutu-episode-string "$@" ;;
	 www.katsomo.fi) katsomo-episode-string "$@" ;;
	 tv5.fi) tv5-episode-string "$@" ;;
	 *) echo "*** OHJELMAVIRHE: link=\"${link}\" ***" >&2; exit -2 ;;
	esac
}
function unified-worker {
	link="$1"

	case "$( sed 's#http://\([^/]*\).*#\1#' <<<"$link" )" in
	 areena.yle.fi) areena-worker "$@" ;;
	 www.ruutu.fi) ruutu-worker "$@" ;;
	 www.katsomo.fi) katsomo-worker "$@" ;;
	 tv5.fi) tv5-worker "$@" ;;
	 *) echo "*** OHJELMAVIRHE: link=\"${link}\" ***" >&2; exit -2 ;;
	esac
}


##########
# JAKSON TALLENNUS, VIRHEIDEN KÄSITTELY JA TIETOKANNAN YLLÄPITO

function record-episode {
	programme="$1"
	eplink="$2"
	custom_parser="$3"

	mkdir -p "${lib}/${programme}"

	# ota linkin loppuosa jakson tunnisteeksi
	clipid="${eplink##*[/=]}"
	donefile="${lib}/${programme}/${clipid}.done"

	# tutki onko jokin tätä tunnistetta vastaava jakso tallennettu jo aiemmin:
	# - ohita, jos aiemmalla tallenteella ei ole tarkempaa yksilöintitietoa;
	# - muuten annetaan tv-sarjakohtaisen koodin päättää
	[ -f "$donefile" ] && ! [ -s "$donefile" ] && continue

	# anna työrutiinille tyhjä syöte vakiosyötteen (linkit ohjelman jaksoihin) sijaan
	unified-worker "$eplink" "$programme" "$custom_parser" </dev/zero
	case $? in
	 0) echo "[${clipid}]"; touch "$donefile";;
	 1) echo "(${clipid}: TIEDOSTOVIRHE)" ;;
	 2) echo "(${clipid}: TEKSTITYSVIRHE)" ;;
	 3) echo "(${clipid}: METATIETOVIRHE)" ;;
	 10) echo "(${clipid}: EI SAATAVILLA)" ;;
	 20) echo "(${clipid}: LATAUSVIRHE)" ;;
	 100) ;; # ohitettu, ei virhettä
	 *) echo "(${clipid}: VIRHE $?)" ;;
	esac
}


############
# AUTOMAATTITALLENTAJA

function recording-worker {
	custom_parser="${tmp}/custom-parser.sh"
	
	for recorder in "${vhs}"/*"${vhsext}"
	 do
		programme="$( basename "$recorder" ${vhsext} )"
		regex="$( sed 1q "$recorder" )"
		sed 1d "$recorder" >"$custom_parser"

		if [ -n "${regex}" ]
		 then query-sourced-programmes "${regex}"
		 else query-sourced-programmes "^$( escape-regex <<<"$programme" )$"
		fi | while read source link title
		 do
			query-programme-episodes "$source" "$link" | while read eplink
			 do record-episode "$programme" "$eplink" "$custom_parser"
			done | while read receps
			 do [ -z "$neweps" ] && echo -n "${programme} " && neweps="y"
				[ -n "$receps" ] && echo -n "$receps "
			done
		done | tee "${tmp}/record-output.txt"

		[ -s "${tmp}/record-output.txt" ] && echo
		rm "${tmp}/record-output.txt"
	done
}


#############
# OPASTUS

function print-cmds {
	echo " p <regex> - listaa kaikki saatavilla olevat ohjelmat <tai hae lausekkeella>"
	echo " e regex   - näytä saatavilla olevien jaksojen määrä"
	echo " l regex   - listaa saatavilla olevien jaksojen tiedot"
	echo " r regex   - tallenna kaikki saatavilla olevat jaksot"
	echo " s regex   - valitse ja tallenna halutut jaksot"
	echo " v <regex> - listaa kaikki asetetut tallentimet <tai hae lausekkeella>"
	echo " a regex   - aseta tallennusajastimia"
	echo " d regex   - poista tallennusajastimia"
	echo " i         - komentotulkkitila: suorita useita komentoja"
	echo " q         - poistu komentotulkkitilasta"
}

function print-help {
	echo "vhs.sh [versio $script_version] : automaattinen internet-tv-tallentaja"
	echo
	echo "Tuetut palvelut: YLE Areena (TV ja radio), Nelonen Ruutu, MTV Katsomo ja TV5"
	echo
	echo "Käytössä ovat seuraavat komennot, joissa 'regex' viittaa ohjelman nimeen :"
	print-cmds
	echo
	echo "Suoritus ilman parametrejä toteuttaa komennolla \"a\" asetetut tallennukset"
}


#############
# KOMENTOTULKKI

function interpret {
	cmd="$1"
	shift
	[ -n "$cmd" ] || return 0

	case "$cmd" in
	 p|prog)
		query-sourced-programmes "$*" | while read source link title
		 do
			printf "%11s %s\n" "[$source]" "$( remove-rating <<<"$title" )"
		done
		;;
	 e|ep)
		[ -n "$*" ] && query-sourced-programmes "$*" | while read source link title
		 do
			episodes="$( query-programme-episodes "$source" "$link" | wc -l )"
			printf "%11s %s : %d jakso" "[$source]" "$( remove-rating <<<"$title" )" "$episodes"
			[ $episodes -eq 1 ] || echo -n "a"
			echo
		done
		;;
	 l|list)
		[ -n "$*" ] && query-sourced-programmes "$*" | while read source link title
		 do
			remove-rating <<<"$title"
			query-programme-episodes "$source" "$link" | while read eplink
			 do unified-episode-string "${eplink}"
			done | cat -n
		done
		;;
	 r|rec)
		[ -n "$*" ] && query-sourced-programmes "$*" | while read source link title
		 do
			programme="$( remove-rating <<<"$title" )"
			echo "${programme}"
			query-programme-episodes "$source" "$link" | while read eplink
			 do record-episode "$programme" "$eplink" /dev/null
			done | while read receps
			 do ( [ -n "$receps" ] && echo -n "$receps " ) || echo -n "..."
			done && echo
		done
		;;
	 s|select)
		exec 3<&0
		[ -n "$*" ] && query-sourced-programmes "$*" | while read source link title
		 do
			programme="$( remove-rating <<<"$title" )"
			echo "${programme}"
			query-programme-episodes "$source" "$link" | tee "${tmp}/episodes.txt" | while read eplink
			 do unified-episode-string "${eplink}"
			done | cat -n

			read -e -p "Valitse tallennettavat jaksot: " indices <&3

			# laajennetaan merkinnät muotoa '1-5' muotoon '1 2 3 4 5'
			for i in $( eval echo "$( sed 's/\([0-9]*\)-\([0-9]*\)/{\1..\2}/g' <<<"${indices}" )" )
			 do
				if [ "$i" -gt 0 ] 2>/dev/null
				 then record-episode "$programme" "$( sed -n "$i p" "${tmp}/episodes.txt" )" /dev/null
				fi
			done | while read receps
			 do ( [ -n "$receps" ] && echo -n "$receps " ) || echo -n "..."
			done && echo
		done
		exec 3<&-
		;;
	 /|v|vhs)
		echo "Aktiiviset tallentimet:"
		echo "-----------------------"
		for recorder in "${vhs}"/*"${vhsext}"
		 do
			programme="$( basename "${recorder}" "${vhsext}" )"
			[ -n "$*" ] && ! match-any-regex "$programme" <<<"$*" && continue
			echo -n "${programme} "
			[ -n "$( sed 1q "$recorder" )" ] && echo -n "($( sed 1q "$recorder" ))"
			[ -n "$( sed 1d "$recorder" )" ] && echo -n "*"
			echo
		done
		;;
	 +|a|add)
		[ -n "$*" ] && query-sourced-programmes "$*" | while read source link title
		 do
			recorder="${vhs}/$( remove-rating <<<"$title" )${vhsext}"
			touch "${recorder}" && echo "+ ${recorder}"
		done
		;;
	 -|d|del)
		[ -n "$*" ] && for recorder in "${vhs}"/*"${vhsext}"
		 do
			programme="$( basename "${recorder}" "${vhsext}" )"
			match-any-regex "$programme" <<<"$*" && rm "${recorder}" && echo "- ${recorder}"
		done
		;;
	 i|interactive)
	 	print-cmds
		while read -e -p "vhs.sh> " cmdline
		 do
			history -s $cmdline
		 	if [ "$cmdline" = "q" -o "$cmdline" = "quit" ]
			 then break
			elif [ "$cmdline" = "h" -o "$cmdline" = "help" ]
			 then print-cmds
			 else interpret $cmdline
			fi
		done
		;;
	 *)
		print-help
		;;
	esac
}


#############
# PÄÄOHJELMA

# tarkista apuohjelmien saatavuus
dependencies

# vaihda vanhojen tallentimien tiedostopäätteet (.vhs) tarvittaessa
[ "$vhsext" != ".vhs" ] && for old_recorder in "${vhs}"/*.vhs
 do mv "$old_recorder" "${old_recorder%.vhs}${vhsext}"
done

# ei argumentteja: käsittele kaikki tallentimet
# muuten: tulkitse annettu komentorivi
if [ $# -eq 0 ]
 then
	if [ -n "$( echo "${vhs}"/*${vhsext} )" ]
	 then
		# älä aja automaattitallennusta, jos sessio on jo käynnissä
		existing_pidfile="$( find -L "${vhs}" -name autorec.pid )"
		if [ -n "$existing_pidfile" ]
		 then
			if pgrep -F "$existing_pidfile" &>/dev/null
			 then [ -t 0 ] && echo "Skripti on jo käynnissä: PID $( cat "$existing_pidfile" )" >&2
				exit 0
			 else rm -rf "$( dirname "$existing_pidfile" )" &>/dev/null
			fi
		fi
		echo $$ > "${tmp}/autorec.pid"
		recording-worker
		exit $?
	 else
		echo "Ei asetettuja tallentimia!" >&2
		print-help >&2
	fi
 else
	interpret "$@"
fi
