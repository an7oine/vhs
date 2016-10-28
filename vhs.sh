#!/bin/bash

script_version=1.3.7

#######
# ASETUKSET

# tietokanta kaikista jo tallennetuista jaksoista pidetään täällä (luodaan ellei olemassa)
lib="${HOME}/.vhs"

# tallentimet (ja väliaikaistiedostot) sijoitetaan tänne (luodaan ellei olemassa)
vhs="${HOME}/Movies/vhs"

# valmiit tiedostot sijoitetaan tänne, jos olemassa
fine="${HOME}/Movies/tunes"

# automaattitallentajien tiedostopääte
vhsext=".txt"

# montako kertaa kutakin latausta yritetään?
retries=3

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

function sort-versions {
	if [ "$( uname )" = "Darwin" ]
	 then sort -t . -g -k1,1 -k2,2 -k3,3 # Mac OS X (numeerinen järjestys kentittäin)
	 else sort -V # Linux / Cygwin (versiojärjestys)
	fi
}
function check-version {
	local current_version minimum_version
	current_version=$1
	minimum_version=$2
	[ "$( echo $current_version$'\n'$minimum_version | sort-versions | head -n1 )" = $minimum_version ]
}
function dependencies {
	local deps
	deps="$( (
	check-version $BASH_VERSION 3.2 || echo -n "bash-3.2 "
	( which php &>/dev/null && check-version 6.999 $( php -v | sed -n '1 s/^PHP \([^ ]*\) .*/\1/p' ) ) \
	 || echo -n "php<7.0 "
	which curl &>/dev/null || echo -n "curl "
	which xmllint &>/dev/null || echo -n "xmllint "
	which MP4Box &>/dev/null || echo -n "gpac "
	( which yle-dl &>/dev/null && check-version $( yle-dl 2>&1 | sed -n '1 s/^yle-dl \([^:]*\):.*/\1/p' ) 2.7.0 ) \
	 || echo -n "yle-dl-2.7.0 "
	( which rtmpdump &>/dev/null && check-version $( rtmpdump 2>&1 | sed -n 's/^RTMPDump v\([^ ]*\).*/\1/p' ) 2.4 ) \
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
	local programme_withrating
	read programme_withrating
	echo "${programme_withrating%% (+([SK[:digit:]]))}"
}
function escape-regex {
	sed 's/[(){}\[^]/\\&/g; s/]/\\&/g'
}
function match-any-regex {
	local programme regex
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
	local path
	path="${1}/@${2}"
	xmllint --nocdata --xpath "$path" /dev/stdin 2>/dev/null | sed 's/[^"]*"\([^"]*\)"/\1/g'
}
function get-xml-content {
	local path
	path="$1"
	xmllint --nocdata --xpath "$path" /dev/stdin 2>/dev/null | sed 's/<[^<]*>//g'
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
	local txtime
	read txtime
	[ -n "$txtime" ] || return
	if [ "$( uname )" = "Darwin" ]
	 then date -j -f '%d.%m.%Y %H:%M:%S' "${txtime}" "+%s" # Mac OS X
	 else date -d "$( sed 's#\(..\)[.]\(..\)[.]\(....\)#\3-\2-\1#' <<<"$txtime" )" "+%s" # Linux / Cygwin
	fi
}
function epoch-to-utc {
	local epoch
	read epoch
	[ -n "$epoch" ] || return
	if [ "$( uname )" = "Darwin" ]
	 then date -j -u -r "$epoch" "+%Y-%m-%dT%H:%M:%SZ" # Mac OS X
	 else date -u -d "@$epoch" "+%Y-%m-%dT%H:%M:%SZ" # Linux / Cygwin
	fi
}
function epoch-to-touch {
	local epoch
	read epoch
	[ -n "$epoch" ] || return
	if [ "$( uname )" = "Darwin" ]
	 then date -j -r "$epoch" "+%Y%m%d%H%M.%S" # Mac OS X
	 else date -d "@$epoch" "+%Y%m%d%H%M.%S" # Linux / Cygwin
	fi
}
function tv-rating {
	local age
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
	local age
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
	local user_agent url cache
	user_agent="$1"
	url="$2"

	cache="${tmp}/cache/${url//[^A-Za-z0-9]/-}"
	cat "$cache" 2>/dev/null && return 0

	curl --fail --retry "$retries" --compressed -L -s -A "${user_agent}" "${url}" | tee "$cache"
}
function segment-downloader {
	local prefix postfix begin seg
	prefix="$1"
	postfix="$2"
	begin="$3"

	# lataa enintään 10000 videosegmenttiä (~ 10Gt)
	for seg in $( seq ${begin} 9999 )
	 do
		curl --fail --retry "$retries" -L -N -s -A "${iOS_agent}" "${prefix}${seg}${postfix}" || break
	done
}
function meta-worker {
	local input subtitles output out_ext hdvideo subtracks
	input="$1"
	subtitles="$2"

	# muodosta tulostiedostolle järkevä nimi
	if [ -n "${output_filename}" ]
	 then output="${output_filename}"
	elif [ -n "${artist}" ]
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
	[ "$( ffmpeg -i "${input}" 2>&1 | sed -n '/Video: h264/s/.*[0-9]x\([0-9]\{1,\}\).*/\1/p' )" -ge 720 ] && hdvideo=true

	# lisää kaikki olemassa olevat tekstitykset
	subtracks=()
	for subfile in ${subtitles}
	 do subtracks+=(-add "${subfile}:lang=$( sed 's/.*[.]\([^.]*\)[.]srt/\1/' <<<"$subfile" ):hdlr=sbtl")
	done
	if [ ${#subtracks[@]} -gt 0 ]
	 then MP4Box "${subtracks[@]}" -out "${output}.${out_ext}" "${input}" || return 2
	 else mv "${input}" "${output}.${out_ext}" || return 2
	fi

	# lataa kansikuva ja korjaa sen FourCC-tunnistekoodi
	[ -n "${thumb}" ] && curl --fail --retry "$retries" -L -s -o "${tmp}/vhs.jpg.prepatch" "${thumb}" \
	&& echo -n $'\xFF\xD8\xFF\xE0' > "${tmp}/vhs.jpg" && dd bs=1 skip=4 seek=4 if="${tmp}/vhs.jpg.prepatch" of="${tmp}/vhs.jpg" &>/dev/null \
	&& thumb="${tmp}/vhs.jpg"
	[ -s "$thumb" ] || thumb="REMOVE_ALL"

	if [ "${out_ext}" = m4v ]
	 then
		# anna metatiedot videotiedostolle
		if [ -n "${epno}" -o -n "${episode}" ]
		 # metatiedot TV-sarjan mukaisesti
		 then AtomicParsley "${output}.m4v" \
--stik "TV Show" \
--title "" \
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
--overWrite
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
--overWrite
		fi
	 # metatiedot radio-ohjelman mukaisesti
	 else AtomicParsley "${output}.m4a" \
--stik value=1 \
--title "$title" \
--album "$album" \
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
--overWrite
	fi
	[ $? -eq 0 ] || return 3

	# tuo julkaisuajankohta ympäristömuuttujaan ja aseta se tulostiedoston aikaleimaksi
	export touched_at="$( epoch-to-touch <<<"${epoch:-$( date +%s )}" )"
	touch -t "$touched_at" "${output}.${out_ext}"

	# poista lähtötiedostot ja aja finish-skripti ja/tai siirrä tulos 'fine'- tai ohjelmakohtaiseen hakemistoon
	rm "${input}" ${subtitles}
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
	curl --fail --retry "$retries" -L -s http://areena.yle.fi/tv/a-o |\
	dec-html |\
	sed -n 's#.*<a.*href="/\([^"]*\)".*>\([^<]\{1,\}\)</a>.*#areena-tv \1 \2#p'
	curl --fail --retry "$retries" -L -s http://areena.yle.fi/radio/a-o |\
	dec-html |\
	sed -n 's#.*<a.*href="/\([^"]*\)".*>\([^<]\{1,\}\)</a>.*#areena-r \1 \2#p'
}
function areena-episodes {
	local type link
	type="$1" # "tv" tai "radio"
	link="$2"
	# ohjelmalinkit elokuviin, konsertteihin yms. toimivat sellaisenaan videolinkkeinä
	curl --compressed --fail -L -s "http://areena.yle.fi/api/search.rss?id=${link#1-}" |\
	dec-html |\
	sed 's#</[^>]*>#&'\\$'\n''#g' |\
	sed -n 's#.*<link>\(.*\)</link>.*#\1#p' |\
	grep -v "http://areena.yle.fi/${link}" |\
	tee "${tmp}/areena-eps"
	[ -s "${tmp}/areena-eps" ] || echo "http://areena.yle.fi/${link}"
}
function areena-episode-string {
	local link metadata epno desc title
	link="$1"
	metadata="$( cached-get "${OSX_agent}" "${link}" | dec-html )"
	epno="$( sed -n 's/.*<meta property="og:title" content="Jakso \(.*\) | .*">.*/\1/p' <<<"$metadata" )"
	title="$( sed -n 's#.*<div id="programDetails" itemprop="description"><p>[0-9/. ]*\([^.!?]*[!?]\{0,1\}\).*</p></div>.*#\1#p' <<<"$metadata" )"
	desc="$( sed -n 's#.*<div id="programDetails" itemprop="description"><p>[0-9/. ]*\(.*\)</p></div>.*#\1#p' <<<"$metadata" | sed 's/[^.!?]*[.!?] //' )"

	echo "Osa ${epno}: ${title}. ${desc}"
}
function areena-worker {
	local link programme custom_parser metadata areena_clipid type desc epno snno epoch agelimit thumb product album title audio_recode subtitles
	link="$1"
	programme="$2"
	custom_parser="$3"

	metadata="$( cached-get "${OSX_agent}" "${link}" | dec-html )"

	epno="$( sed -n 's/.*<meta property="og:title" content="Jakso \(.*\) | .*">.*/\1/p' <<<"$metadata" )"
	episode="$( sed -n 's#.*<div id="programDetails" itemprop="description"><p>[0-9/. ]*\([^.!?]*[!?]\{0,1\}\).*</p></div>.*#\1#p' <<<"$metadata" )"
	desc="$( sed -n 's#.*<div id="programDetails" itemprop="description"><p>[0-9/. ]*\(.*\)</p></div>.*#\1#p' <<<"$metadata" | sed 's/[^.!?]*[.!?] //' )"

    # yritetään tulkita jakson kuvauksessa numeroin tai sanallisesti ilmaistu kauden numero
    snno="$( season-number <<<"$desc" )"

    type="$( sed -n 's/.*<meta property="og:type" content="\([videoaudio]*\).*">.*/\1/p' <<<"$metadata" )"
    epoch="$( sed -n 's/.*<meta property="og:.*:release_date" content="\([0-9]*\)-\([0-9]*\)-\([0-9]*\)T\(.*\)[.].*+.*">.*/\3.\2.\1 \4/p' <<<"$metadata" | txtime-to-epoch )"

    # (näitä tietoja ei löydy V4:stä?)
    #areena_clipid="$( sed -n '/AREENA.clip = {/,/}/ s/.*id: '\''\([0-9a-z]*\)'\''.*/\1/p' <<<"$metadata" )"
    #agelimit="$( sed -n 's#.*class="restriction age-\([0-9]*\) masterTooltip".*#\1#p' <<<"$metadata" )"

	thumb="$( sed -n 's#.*<meta property="og:image" content="\(.*\)">.*#\1#p' <<<"$metadata" )"

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
	if [ -x "${meta_script}" ]; then . "${meta_script}" || return 100; fi
	. $custom_parser || return 100
	echo

	if ! [ -s "$product" ]
	 then
		# käytä väliaikaista .flv-tiedostoa
		yle-dl -q "$link" -o "${tmp}/vhs.flv" &> /dev/fd/6 || return 10
		ffmpeg -i "${tmp}/vhs.flv" -c copy $audio_recode "$product" -y &> /dev/fd/6 || return 20
		rm "${tmp}/vhs.flv"

		# ota kaikki tekstitykset talteen
		subtitles="${tmp}/vhs.*.srt"
	fi

	meta-worker "${product}" "${subtitles}" &> /dev/fd/6
}


###########
# NELONEN RUUTU

function ruutu-programmes {
	curl --fail --retry "$retries" -L -s http://www.ruutu.fi/ohjelmat/kaikki |\
	sed -n '/<a href="\/series\/[0-9]*">/{N;N;N;N;N;N;s#.*<a href="/\(series/[0-9]*\)">.*<div class="list-item-main1 truncate-text">\([^<]*\)</div>.*#ruutu \1 \2#p;}; /<a href="\/ohjelmat\/[^"]*">/{N;N;N;N;N;N;s#.*<a href="/\(ohjelmat/[^"]*\)">.*<div class="list-item-main1 truncate-text">\([^<]*\)</div>.*#ruutu \1 \2#p;};'
	curl --fail --retry "$retries" -L -s http://www.ruutu.fi/ohjelmat/elokuvat |\
	sed -n '/<a href="\/video\/[0-9]*">/{N;N;N;N;N;N;N;N;}; s#.*<a href="/\(video/[0-9]*\)">.*<h4 class="thumbnail-title">\([^<]*\)</h4>.*#ruutu \1 \2#p'
}
function ruutu-episodes {
	local link
	link="$1"
	( curl --fail --retry "$retries" -L -s "http://www.ruutu.fi/${link}" || echo "http://www.ruutu.fi/video/${link}" )|\
	sed -n 's#.*data-content-id="\([0-9]*\)".*#\1#p' |\
	while read ep
	 do [ -n "$( cached-get "${OSX_agent}" "http://gatling.ruutu.fi/media-xml-cache?id=${ep}" | dec-html | grep '<MediaType>video_episode</MediaType>' )" ] && echo "http://www.ruutu.fi/video/${ep}"
	done
}
function ruutu-episode-string {
	local link html_metadata epid metadata episode desc
	link="$1"
	html_metadata="$( cached-get "${OSX_agent}" "${link}" | dec-html )"
	og_title="$( sed -n 's#<meta property=\"og:title\" content=\"\(.*\)\" />#\1#p' <<<"$html_metadata" )"
	og_desc="$( sed -n 's#<meta property=\"og:description\" content=\"\(.*\)\" />#\1#p' <<<"$html_metadata" )"
	snno="$( sed -n 's/.* - Kausi \([0-9]*\) - Jakso [0-9]*.*/\1/p' <<<"$og_title" )"
	epno="$( sed -n 's/.* - Kausi [0-9]* - Jakso \([0-9]*\).*/\1/p' <<<"$og_title" )"
	episode="$( sed 's/Kausi [0-9]*[.] Jakso [0-9]*\/[0-9]*[.] //; s/\([^.!?]*[!?]\{0,1\}\).*/\1/' <<<"$og_desc" )"
	desc="$( sed 's/Kausi [0-9]*[.] Jakso [0-9]*\/[0-9]*[.] [^.!?]*[.!?] //' <<<"$og_desc" )"
	echo "Osa ${epno} (kausi ${snno}): ${episode}. ${desc}"
}
function ruutu-worker {
	local link programme custom_parser html_metadata og_title epno snno episode epid metadata source desc agelimit thumb product
	link="$1"
	programme="$2"
	custom_parser="$3"

	html_metadata="$( cached-get "${OSX_agent}" "${link}" | dec-html )"
	og_title="$( sed -n 's#<meta property=\"og:title\" content=\"\(.*\)\" />#\1#p' <<<"$html_metadata" )"
	og_desc="$( sed -n 's#<meta property=\"og:description\" content=\"\(.*\)\" />#\1#p' <<<"$html_metadata" )"
	snno="$( sed -n 's/.* - Kausi \([0-9]*\) - Jakso [0-9]*.*/\1/p' <<<"$og_title" )"
	epno="$( sed -n 's/.* - Kausi [0-9]* - Jakso \([0-9]*\).*/\1/p' <<<"$og_title" )"
	episode="$( sed 's/Kausi [0-9]*[.] Jakso [0-9]*\/[0-9]*[.] //; s/\([^.!?]*[!?]\{0,1\}\).*/\1/' <<<"$og_desc" )"
	desc="$( sed 's/Kausi [0-9]*[.] Jakso [0-9]*\/[0-9]*[.] [^.!?]*[.!?] //' <<<"$og_desc" )"

	epid="${link##*/}"
	metadata="$( cached-get "${OSX_agent}" "http://gatling.ruutu.fi/media-xml-cache?id=${epid}" | iconv -f ISO-8859-1 )"
	
	#bitrates="$( get-xml-field //Playerdata/Clip/BitRateLabels/map bitrate <<<"$metadata" )"
	#source="$( get-xml-content //Playerdata/Clip/HTTPMediaFiles/HTTPMediaFile <<<"$metadata" | sed 's/_[0-9]*\(_[^_]*.mp4\)/_@@@@\1/' )"
	m3u8_source="$( get-xml-content //Playerdata/Clip/AppleMediaFiles/AppleMediaFile <<<"$metadata" )"
	#[ -n "$source" -o -n "$m3u8_source" ] || return 10

	epoch="$( get-xml-field //Playerdata/Behavior/Program start_time <<<"$metadata" | sed 's#.$#:00#' | txtime-to-epoch )"
	agelimit="$( get-xml-content //Playerdata/Clip/AgeLimit <<<"$metadata" )"
	thumb="$( get-xml-field //Playerdata/Behavior/Startpicture href <<<"$metadata" )"

	product="${tmp}/vhs.m4v"

	# suoritetaan käyttäjän oma sekä tallentimessa annettu parsimiskoodi
	if [ -x "${meta_script}" ]; then . "${meta_script}" || return 100; fi
	. $custom_parser || return 100
	echo

	if ! [ -s "${product}" ]
	 then
		# lataa m3u8-muotoinen aineisto
		ffmpeg -i "${m3u8_source}" -bsf:a aac_adtstoasc -c copy -map 0:4 -map 0:5 -y "${tmp}/presync.m4v" &> /dev/fd/6 || return 10
		# siirrä ääniraitaa eteenpäin 3 ruutua (0,12 s)
		ffmpeg -i "${tmp}/presync.m4v" -itsoffset 0.120 -i "${tmp}/presync.m4v" -c copy -map 0:0 -map 1:1 -y "${product}" &> /dev/fd/6 || return 20
	fi

	meta-worker "${product}" "" &> /dev/fd/6
}


#########
# MTV KATSOMO

function katsomo-programmes {
	curl --fail --retry "$retries" -L -s "http://www.katsomo.fi/#" |\
	iconv -f ISO-8859-1 |\
	sed -n 's#.*<a.*href="http://www.katsomo.fi/?treeId=\([^"]*\)".*>\([^<]\{1,\}\)<.*#katsomo \1 \2#p'
}
function katsomo-episodes {
	local link
	link="$1"
	# suodatetaan pois maksulliset (muut kuin "play-link") jaksot
	curl --fail --retry "$retries" -L -s "http://www.katsomo.fi/?treeId=${link}" |\
	iconv -f ISO-8859-1 |\
	sed -n 's#.*<a href="\(/?progId=[^"]*\)".*class="play-link".*>.*#http://www.katsomo.fi\1#p'
}
function katsomo-episode-string {
	local link html_metadata metadata epno episode desc
	link="$1"
	html_metadata="$( cached-get "${OSX_agent}" "${link}" | iconv -f ISO-8859-1 |\
sed -n '\#<a class="title" href="/?progId='${link#*/?progId=}'">#,/<span class="hidden title-hidden">/p' )"
	metadata="$( cached-get "${OSX_agent}" "${link/\?/sumo/sl/playback.do?}" | iconv -f ISO-8859-1 )"
	epno="$( sed -n '/<div class="season-info" style="display:none;">/ {;n;s#.*[Jj]akso[: ]*\([0-9]*\).*#\1#p;}' <<<"$html_metadata" )"
	episode="$( get-xml-content //Playback/MatchId <<<"$metadata" )"
	desc="$( get-xml-content //Playback/Description <<<"$metadata" )"
	echo "Osa ${epno}: ${episode}. ${desc}"
}
function katsomo-worker {
	local link programme custom_parser html_metadata snno epno metadata episode desc epoch agelimit thumb product sublink subtitles source
	link="$1"
	programme="$2"
	custom_parser="$3"

	# hae kauden ja jakson numero www.katsomo.fi-sivun kautta
	html_metadata="$( cached-get "${OSX_agent}" "${link}" | iconv -f ISO-8859-1 |\
sed -n '\#<a class="title" href="/?progId='${link#*/?progId=}'">#,/<span class="hidden title-hidden">/p' )"
	snno="$( sed -n '/<div class="season-info" style="display:none;">/ {;n;s#.*[Kkv][au][uo]si[: ]*\([0-9]*\).*#\1#p;}' <<<"$html_metadata" )"
	epno="$( sed -n '/<div class="season-info" style="display:none;">/ {;n;s#.*[Jj]akso[: ]*\([0-9]*\).*#\1#p;}' <<<"$html_metadata" )"
	episode="$( sed -n '2 s#^'$'\t''*##p' <<<"$html_metadata" )"

	# hae muut metatiedot /sumo/sl/playback.do-osoitteen xml-dokumentista
	metadata="$( cached-get "${OSX_agent}" "${link/\?/sumo/sl/playback.do?}" | iconv -f ISO-8859-1 )"
	episode="${episode:-$( get-xml-content //Playback/MatchId <<<"$metadata" )}"
	desc="$( get-xml-content //Playback/Description <<<"$metadata" )"
	epoch="$( get-xml-content //Playback/TxTime <<<"$metadata" | txtime-to-epoch )"
	agelimit="$( get-xml-content //Playback/AgeRating <<<"$metadata" )"
	thumb="$( get-xml-content //Playback/ImageUrl <<<"$metadata" )"

	# älä kirjaa pelkkää ohjelman nimeä jakson nimeksi
	[ "$( remove-rating <<<"$episode" )" != "$programme" ] || unset episode

	product="${tmp}/vhs.m4v"

	# suoritetaan käyttäjän oma sekä tallentimessa annettu parsimiskoodi
	if [ -x "${meta_script}" ]; then . "${meta_script}" || return 100; fi
	. $custom_parser || return 100
	echo

	if ! [ -s "$product" ]
	 then
		sublink="$( get-xml-content //Playback/Subtitles/Subtitle <<<"$metadata" | sed 's#.*\(http://[^"]*\)".*#\1#' )"
		if [ -n "$sublink" ]
		 then subtitles="${tmp}/vhs.fin.srt"
			curl --fail --retry "$retries" -L -s "${sublink}" | dec-html | ttml-to-srt > "${subtitles}"
		 else subtitles=""
		fi

		# hae videolinkki Mobiilikatsomosta, poistu jos linkkiä ei löydy
		source="$( curl --fail --retry "$retries" -L -s -A "${iOS_agent}" -b "hq=1" "${link/www.katsomo.fi\//m.katsomo.fi/}" |\
sed -n 's#.*<source type="video/mp4" src="http://[^.]*[.]\(.*\)/playlist[.]m3u8.*"/>.*#http://median3mobilevod.\1#p' )"
		[ -n "$source" ] || return 10

		# hae kaikki videosegmentit (aloittaen 0:sta) ja muunna lennossa mp4-muotoon
		segment-downloader "${source}/media_" ".ts" 0 | ffmpeg -i - -c copy -absf aac_adtstoasc "$product" -y -v quiet || return 20
	fi

	meta-worker "${product}" "${subtitles}"
}


###########
# TV5

function tv5-programmes {
	curl --fail --retry "$retries" -L -s 'http://tv5.fi/nettitv' |\
	iconv -f ISO-8859-1 |\
	sed -n 's#.*<a href="/nettitv/\([^/"]*\)/.*">\([^<]*\)</a>.*#tv5 \1 \2#p' |sed 's/, osa [0-9]*//'
}
function tv5-episodes {
	local link eplink
	link="$1"
	# suodatetaan pois jaksot, jotka eivät (enää) ole katsottavissa
	curl --fail --retry "$retries" -L -s "http://tv5.fi/nettitv/${link}" |\
	iconv -f ISO-8859-1 |\
	sed -n 's#.*<a href="\(/nettitv/'"${link}"'/[^"]*\)".*#http://tv5.fi\1#p' |\
	while read eplink
	 do [ -n "$( cached-get "${OSX_agent}" "$eplink" | sed -n '/jwplayer('\''video'\'').setup/ p' )" ] && echo "$eplink"
	done
}
function tv5-episode-string {
	local link metadata epno desc
	link="$1"
	metadata="$( cached-get "${OSX_agent}" "${link}" | sed -n '/<meta.*\/>/ p; /jwplayer('\''video'\'').setup/ p' )"
	epno="$( sed -n 's#.*<meta property="og:title" content=".*, osa \([0-9]*\)".*#\1#p' <<<"$metadata" )"
	desc="$( sed -n 's#.*<meta property="og:description" content="\([^"]*\)".*#\1#p' <<<"$metadata" )"
	echo "Osa ${epno}. ${desc}"
}
function tv5-worker {
	local link programme custom_parser metadata epno desc direct_mp4 thumb product master_m3u8 postfix prefix
	link="$1"
	programme="$2"
	custom_parser="$3"

	# muistin säästämiseksi ota ympäristömuuttujaan 'metadata' vain oleelliset osat sivun sisällöstä
	metadata="$( cached-get "${OSX_agent}" "${link}" | sed -n '/<meta.*\/>/ p; /jwplayer('\''video'\'').setup/ p' )"

	epno="$( sed -n 's#.*<meta property="og:title" content=".*, osa \([0-9]*\)".*#\1#p' <<<"$metadata" )"
	desc="$( sed -n 's#.*<meta property="og:description" content="\([^"]*\)".*#\1#p' <<<"$metadata" )"

	direct_mp4="$( sed -n 's#.*jwplayer('\''video'\'').setup.*file: '\''\(http://[^'\'']*[.]mp4\)'\''.*#\1#p' <<<"$metadata" )"
	thumb="$( sed -n 's#.*jwplayer('\''video'\'').setup.*image: '\''\(http://[^'\'']*\)'\''.*#\1#p' <<<"$metadata" )"

	product="${tmp}/vhs.m4v"

	# suoritetaan käyttäjän oma sekä tallentimessa annettu parsimiskoodi
	if [ -x "${meta_script}" ]; then . "${meta_script}" || return 100; fi
	. $custom_parser || return 100
	echo

	if ! [ -s "$product" ]
	 then
		# hae ensisijaisesti lähdetiedosto sellaisenaan, yritä sen jälkeen segmentoitua latausta
		if [ -z "${direct_mp4}" ] || ! curl --fail --retry "$retries" -L -N -s -o "${product}" "${direct_mp4}"
		 then
			# nouda master-luettelo eri tarkkuuksia vastaavista soittolistoista
			master_m3u8="$( sed -n 's#.*jwplayer('\''video'\'').setup.*file: '\''\(http://.*/master.m3u8\)'\''.*#\1#p' <<<"$metadata" )"
			[ -n "$master_m3u8" ] || return 10

			# poimi master-luettelon viimeinen (korkeimman tarkkuuden) soittolista
			postfix="$( curl --fail --retry "$retries" -L -s "${master_m3u8}" | sed -n 's#.*index\([^/]*\).m3u8$#\1#p' | tail -n 1 ).ts"

			# hae kaikki videosegmentit (aloittaen 1:stä) ja muunna lennossa mp4-muotoon
			prefix="${master_m3u8%/master.m3u8}/segment"
			segment-downloader "${prefix}" "${postfix}" 1 | ffmpeg -i - -c copy -absf aac_adtstoasc "${product}" -y -v quiet || return 20
		fi
	fi

	meta-worker "${product}" ""
}


##########
# OHJELMIEN, JAKSOJEN JA MEDIAN HAKURUTIINIT

# ohjelmalistaus ladataan verkosta vain kerran ja tallennetaan ajokohtaiseen välimuistitiedostoon
function sorted-programmes {
	local cache
	cache="${tmp}/cache/programmes.txt"
	cat "${cache}" 2>/dev/null && return 0
	[ -d "${tmp}/cache" ] || return 1

	( areena-programmes; ruutu-programmes; katsomo-programmes; tv5-programmes ) |\
	LC_ALL=UTF-8 sort -f -t ' ' -k 3 |\
	tee "${cache}"
}
function query-sourced-programmes {
	local regex source link title
	regex="$1"

	sorted-programmes | while read source link title
	 do
		[ -n "$regex" ] && ! match-any-regex "$( remove-rating <<<"$title" )" <<<"$regex" && continue
		echo "$source" "$link" "$title"
	done
}
function query-programme-episodes {
	local source link cache
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
	local link
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
	local link
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
	local programme eplink custom_parser clipid donefile
	programme="$1"
	eplink="$2"
	custom_parser="$3"

	mkdir -p "${lib}/${programme}"

	# ota linkin loppuosa jakson tunnisteeksi
	clipid="${eplink##*[/=]}"
	donefile="${lib}/${programme}/${clipid}.done"
	exec 6>"${lib}/${programme}/${clipid}.log"

	# tutki onko jokin tätä tunnistetta vastaava jakso tallennettu jo aiemmin:
	# - ohita, jos aiemmalla tallenteella ei ole tarkempaa yksilöintitietoa;
	# - muuten annetaan tv-sarjakohtaisen koodin päättää
	[ -f "$donefile" ] && ! [ -s "$donefile" ] && continue

	# anna työrutiinille tyhjä syöte vakiosyötteen (linkit ohjelman jaksoihin) sijaan
	unified-worker "$eplink" "$programme" "$custom_parser" </dev/zero
	case $? in
	 0) echo "[${clipid}]"; touch -t "$touched_at" "$donefile"; unset touched_at;;
	 1) echo "(${clipid}: TIEDOSTOVIRHE)"; rm -f "$donefile";;
	 2) echo "(${clipid}: TEKSTITYSVIRHE)"; rm -f "$donefile";;
	 3) echo "(${clipid}: METATIETOVIRHE)"; rm -f "$donefile";;
	 10) echo "(${clipid}: EI SAATAVILLA)"; rm -f "$donefile";;
	 20) echo "(${clipid}: LATAUSVIRHE)"; rm -f "$donefile";;
	 100) ;; # ohitettu, ei virhettä
	 *) echo "(${clipid}: VIRHE $?)"; rm -f "$donefile";;
	esac
}


############
# AUTOMAATTITALLENTAJA

function recording-worker {
	local custom_parser recorder programme regex source link title eplink receps neweps
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
	echo " m regex   - merkitse jaksoja jo tallennetuiksi tai poista näitä merkintöjä"
	echo " v <regex> - listaa kaikki asetetut tallentimet <tai hae lausekkeella>"
	echo " a regex   - aseta tallennusajastimia"
	echo " d regex   - poista tallennusajastimia"
	echo " i         - komentotulkkitila: suorita useita komentoja samalla istunnolla"
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
	local cmd source link title episodes eplink programme receps indices recorder cmdline
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
			cache="${tmp}/cache/selecting-episodes.txt"
			echo "${programme}"
			query-programme-episodes "$source" "$link" | tee "${cache}" | while read eplink
			 do unified-episode-string "${eplink}"
			done | cat -n

			read -e -p "Valitse tallennettavat jaksot: " indices <&3

			# laajennetaan merkinnät muotoa '1-5' muotoon '1 2 3 4 5'
			for i in $( eval echo "$( sed 's/\([0-9]*\)-\([0-9]*\)/{\1..\2}/g' <<<"${indices}" )" )
			 do
				if [ "$i" -gt 0 ] 2>/dev/null
				 then record-episode "$programme" "$( sed -n "$i p" "${cache}" )" /dev/null
				fi
			done | while read receps
			 do ( [ -n "$receps" ] && echo -n "$receps " ) || echo -n "..."
			done && echo
		done
		exec 3<&-
		;;
	 m|mark)
		exec 3<&0
		[ -n "$*" ] && query-sourced-programmes "$*" | while read source link title
		 do
			programme="$( remove-rating <<<"$title" )"
			cache="${tmp}/cache/selecting-episodes.txt"
			echo "${programme}"
			query-programme-episodes "$source" "$link" | tee "${cache}" | while read eplink
			 do donefile="${lib}/${programme}/${eplink##*[/=]}.done"
				unified-episode-string "${eplink}" | ( ( [ -f "${donefile}" ] && sed 's/^/* /' ) || sed 's/^/  /' )
			done | cat -n

			# luetaan syöte, poistutaan jos tyhjä
			read -e -p "Aseta tallennetut jaksot: " indices <&3
			[ -n "$indices" ] || return

			# poistetaan kaikki olemassa olevat done-tiedostot
			while read eplink
			 do rm "${lib}/${programme}/${eplink##*[/=]}.done" 2>/dev/null
			done < "${cache}"

			# laajennetaan merkinnät muotoa '1-5' muotoon '1 2 3 4 5'
			for i in $( eval echo "$( sed 's/\([0-9]*\)-\([0-9]*\)/{\1..\2}/g' <<<"${indices}" )" )
			 do
				if [ "$i" -gt 0 ] 2>/dev/null
				 then eplink="$( sed -n "$i p" "${cache}" )"
					mkdir -p "${lib}/${programme}"
					touch "${lib}/${programme}/${eplink##*[/=]}.done"
				fi
			done
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
