#!/bin/bash

skriptin_versio=1.5.1

#######
# ASETUKSET

# tietokanta kaikista jo tallennetuista jaksoista pidetään täällä (luodaan ellei olemassa)
kanta="${HOME}/.vhs"

# tallentimet (ja väliaikaistiedostot) sijoitetaan tänne (luodaan ellei olemassa)
vhs="${HOME}/Movies/vhs"

# valmiit tiedostot sijoitetaan tänne, jos olemassa
valmis="${vhs}/valmiit"

# automaattitallentajien tiedostopääte
tallentimen_paate=".txt"

# montako kertaa kutakin latausta yritetään?
latausyritykset=3

# yle-dl-vivut
yle_dl_vivut=()

# käyttäjäagentti
OSX_agentti="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_13_3) AppleWebKit/604.5.6 (KHTML, like Gecko) Version/11.0.3 Safari/604.5.6"

# Areena-kirjautumisavain ohjelmien hakuun.
areena_ohjelmat_tunnus="$(
  # Ohjelmien haussa tarvitaan lisäksi `token`-avain.
  IFS=$'\n' read -d $'\0' data_view main_bundle_js < <(
    curl -s "https://areena.yle.fi/tv/ohjelmat/kaikki" \
    | sed -En '
s#.*class="package-view".*data-view='"'"'(.*)'"'"'></div>#\1#p;
s#.*<script src="(.*/main-bundle.js[^"]*)".*#\1#p;
'
  )
  echo -n "$(
    jq -r '.tabs[] | select(.title == "A-Ö").content[].source.uri' \
    <<<"${data_view}" \
    | sed -E 's/.*[?&](token=[^&]*).*/\1/'
  )&"
  curl -s "https://areena.yle.fi${main_bundle_js}" \
  | sed -En 's/.*appId:"([^"]*)",appKey:"([^"]*)".*/app_id=\1\&app_key=\2/p'
)"

# Areena-kirjautumisavain jaksojen yms. hakuun
areena_jaksohaku_tunnus="$(
  curl -s "$(
    curl -s "https://areena.api.yle.fi/v1/ui/content/list?language=fi&v=7&client=yle-areena-web&${areena_ohjelmat_tunnus}&limit=1" \
    | jq -r '.data[] | (.labels[] | select(.type == "itemId") | ("https://areena.yle.fi/" + .raw))'
  )" | sed -En 's/.*application(Id|Key): "(.*)".*/\2/p' | {
    read id; read key; echo "app_id=$id&app_key=$key";
  }
)"

# alkuasetus-, metatiedon asetus- ja viimeistelyskripti
profile_skripti="${kanta}/profile"
meta_skripti="${kanta}/meta.sh"
finish_skripti="${kanta}/finish.sh"

# asetetaan bash-liput
shopt -s extglob
shopt -s nullglob
shopt -s nocasematch


#######
# VÄLIAIKAINEN TYÖHAKEMISTO

tmp="$( mkdir -p "${vhs}"; mktemp -d "${vhs}/.vhs.XXXX" )"
cd "${tmp}"
mkdir "${tmp}/valimuisti"
trap "( cd -; rm -r \"${tmp}\" ) &>/dev/null" EXIT
trap "( cd -; rm -r \"${tmp}\" ) &>/dev/null" INT

# Cygwin-paikkaus
[[ "$( uname )" =~ cygwin ]] && tmp="$( cygpath -m "$tmp" )"

# Anna käyttäjän määritellä tarvittaessa lisää asetuksia ja apufunktioita
[ -e "${profile_skripti}" ] && . "${profile_skripti}"


#######
# ULKOISET APUOHJELMAT

function jarjesta_versiot {
	if [ "$( uname )" = "Darwin" ]
	 then sort -t . -g -k1,1 -k2,2 -k3,3 # Mac OS X (numeerinen järjestys kentittäin)
	 else sort -V # Linux / Cygwin (versiojärjestys)
	fi
}
function tarkista_versio {
	local nykyinen_versio minimiversio
	nykyinen_versio=$1
	minimiversio=$2
	[ "$( echo "$nykyinen_versio"$'\n'"$minimiversio" | jarjesta_versiot | head -n1 )" = "$minimiversio" ]
}
function jarjestelmavaatimukset {
	local puuttuvat
	puuttuvat="$( (
		tarkista_versio $BASH_VERSION 3.2 || echo -n "bash-3.2 "
		which php &>/dev/null || echo -n "php "
		which curl &>/dev/null || echo -n "curl "
		which xmllint &>/dev/null || echo -n "xmllint "
		which jq &>/dev/null || echo -n "jq "
		which youtube-dl &>/dev/null || echo -n "youtube-dl "
		( which yle-dl &>/dev/null && tarkista_versio $( yle-dl 2>&1 | sed -n 's/^yle-dl \([0-9.]*\):.*/\1/p' ) 2.21 ) \
		 || echo -n "yle-dl-2.21 "
		( which rtmpdump &>/dev/null && tarkista_versio $( rtmpdump 2>&1 | sed -n 's/^RTMPDump v\([^ ]*\).*/\1/p' ) 2.4 ) \
		 || echo -n "rtmpdump-2.4 "
		( which ffmpeg &>/dev/null && tarkista_versio $( ffmpeg -version | awk '/^ffmpeg version /{print $3}' ) 1.2.10 ) \
		 || echo -n "ffmpeg-1.2.10 "
		( which AtomicParsley &>/dev/null && tarkista_versio $( AtomicParsley -version |awk '{print $3}' ) 0.9.5 ) \
		 || echo -n "AtomicParsley-0.9.5 "
	) )"
	[ -z "$puuttuvat" ] && return 0
	echo "* Puuttuvat apuohjelmat: $puuttuvat" >&2
	exit 1
}


#######
# SISÄISET APUOHJELMAT (VAKIOSYÖTE-VAKIOTULOSTE)

function poista_ikarajamerkinta {
	local ohjelma_ikarajamerkittyna
	read ohjelma_ikarajamerkittyna
	echo "${ohjelma_ikarajamerkittyna%% (+([SK[:digit:]]))}"
}
function suojaa-regex {
	sed 's/[(){}\[^]/\\&/g; s/]/\\&/g'
}
function vertaa-lausekkeita {
	local programme regex
	programme="$1"
	tr '|' '\n' | while read regex
	 do [[ "$programme" =~ $regex ]] && break
	done
}
function tulkitse-html {
	# muunnetaan html-koodatut erikoismerkit oletusmerkistöön
	php -R 'echo html_entity_decode($argn, ENT_QUOTES)."\n";'
}
function hae-xml-kentta {
	local path
	path="${1}/@${2}"
	xmllint --nocdata --xpath "$path" /dev/stdin 2>/dev/null | sed 's/[^"]*"\([^"]*\)"/\1/g'
}
function hae-xml-sisalto {
	local path
	path="$1"
	xmllint --nocdata --xpath "$path" /dev/stdin 2>/dev/null | sed 's/<[^<]*>//g'
}
function ttml-srt {
	# suodatetaan pelkät tekstit, kukin omalle rivilleen
	# sen jälkeen numeroidaan tekstit, muunnetaan aikakoodit srt-muotoon ja jaetaan kukin 2-3 riville
	sed -n '\#<p begin=.*>.*<br/># {N;s/\n//;}; /^<p/ p' |\
	sed '=; s#<p begin=.\([0-9:.]*\). end=.\([0-9:.]*\).>\(.*\)</p>.*#\1 --> \2\
\3\
#; s#\([0-9:]\{8\}\)[.]\([0-9]\{3\}\)#\1,\2#g; s#<br/>#\
#g'
}
function txtime-epoch {
	local txtime
	read txtime
	[ -n "$txtime" ] || return
	if [ "$( uname )" = "Darwin" ]
	 then date -j -f '%d.%m.%Y %H:%M:%S' "${txtime}" "+%s" # Mac OS X
	 else date -d "$( sed 's#\(..\)[.]\(..\)[.]\(....\)#\3-\2-\1#' <<<"$txtime" )" "+%s" # Linux / Cygwin
	fi
}
function epoch-utc {
	local epoch
	read epoch
	[ -n "$epoch" ] || return
	if [ "$( uname )" = "Darwin" ]
	 then date -j -u -r "$epoch" "+%Y-%m-%dT%H:%M:%SZ" # Mac OS X
	 else date -u -d "@$epoch" "+%Y-%m-%dT%H:%M:%SZ" # Linux / Cygwin
	fi
}
function epoch-touch {
	local epoch
	read epoch
	[ -n "$epoch" ] || return
	if [ "$( uname )" = "Darwin" ]
	 then date -j -r "$epoch" "+%Y%m%d%H%M.%S" # Mac OS X
	 else date -d "@$epoch" "+%Y%m%d%H%M.%S" # Linux / Cygwin
	fi
}
function tv-ikaraja {
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
function elokuva-ikaraja {
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
function kauden-numero {
	local description_text r
	read description_text
	r='([0-9]{1,})[.]* [tuotanto]*kau[sdt]'; [[ "$description_text" =~ $r ]] && echo ${BASH_REMATCH[1]} && return 0
	r='[tuotanto]*kausi ([0-9]{1,})'; [[ "$description_text" =~ $r ]] && echo ${BASH_REMATCH[1]} && return 0
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

function valimuistihaku {
	local user_agentti url cache
	kayttajaagentti="$1"
	url="$2"

	valimuisti="${tmp}/valimuisti/${url//[^A-Za-z0-9]/-}"
	valimuisti="${valimuisti:0:254}"
	cat "${valimuisti}" 2>/dev/null && return 0

	curl --fail --retry "${latausyritykset}" --compressed -L -s \
	-A "${kayttajaagentti}" "${url}" | tee "${valimuisti}"
}
function lataa-segmentit {
	local prefix postfix begin seg
	prefix="$1"
	postfix="$2"
	begin="$3"

	# lataa enintään 10000 videosegmenttiä (~ 10Gt)
	for seg in $( seq ${begin} 9999 )
	 do
		curl --fail --retry "$latausyritykset" -L -N -s -A "${OSX_agentti}" "${prefix}${seg}${postfix}" || break
	done
}
function meta-kirjoitin {
	local input output out_ext hdvideo subtracks
	input="$1"

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

	# siivoa tiedostonimestä vfat-yhteensopimattomat merkit
	output="${tmp}/${output//[<>:\"\/\\|?*]/-}"

	# käytä samaa tarkenninta kuin lähdetiedostossa (m4v tai m4a)
	out_ext="${input##*.}"

	# tutki, onko videokuvan pystysuuntainen tarkkuus vähintään 720p ja aseta HD-videomerkintä sen mukaisesti
	hdvideo=false
	[ "$( ffmpeg -i "${input}" 2>&1 | sed -n '/Video: h264/s/.*[0-9]x\([0-9]\{1,\}\).*/\1/p' )" -ge 720 ] 2>/dev/null && hdvideo=true

	# nimeä tiedosto uudelleen
	mv "${input}" "${output}.${out_ext}"

	# lataa kansikuva
	[ -n "${thumb}" ] \
	&& curl --fail --retry "$latausyritykset" -L -s -o "${tmp}/vhs-thumb" "${thumb}" \
	&& thumb="${tmp}/vhs-thumb" \
	&& [ -s "${thumb}" ] || thumb="REMOVE_ALL"

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
--year "$( epoch-utc <<<"$epoch" )" \
--purchaseDate "timestamp" \
--Rating "$( tv-ikaraja <<<"$agelimit" )" \
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
--year "$( epoch-utc <<<"$epoch" )" \
--purchaseDate "timestamp" \
--Rating "$( elokuva-ikaraja <<<"$agelimit" )" \
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
--year "$( epoch-utc <<<"$epoch" )" \
--purchaseDate "timestamp" \
--longdesc "$desc" \
--description "$desc" \
--artwork "$thumb" \
--comment "$comment" \
--overWrite
	fi
	[ $? -eq 0 ] || return 3

	# tuo julkaisuajankohta ympäristömuuttujaan ja aseta se tulostiedoston aikaleimaksi
	export touched_at="$( epoch-touch <<<"${epoch:-$( date +%s )}" )"
	touch -t "$touched_at" "${output}.${out_ext}"

	# aja finish-skripti, poista lähtötiedosto ja siirrä tulos 'valmis'- tai ohjelmakohtaiseen hakemistoon
	if [ -x "${finish_skripti}" ]
	 then . "${finish_skripti}" "${output}.${out_ext}"
	fi
	rm "${input}"
	if [ -e "${output}.${out_ext}" ]
	 then if [ -d "${valmis}" ]
		 then mv "${output}.${out_ext}" "${valmis}/"
		 else
			outdir="${vhs}/${programme//[<>:\"\/\\|?*]/-}"
			mkdir -p "${outdir}/" && mv "${output}.${out_ext}" "${outdir}/"
		fi
	fi
	[ $? -eq 0 ] || return 1
}


#######
# YLE AREENA

function areena-json {
	local lang cache limit offset
	lang="$1" # "fi" tai "sv"

    cache="${tmp}/valimuisti/areena-${lang}.json"
    cat "$cache" 2>/dev/null && return 0

    (
        echo '['
        limit=100
        offset=0
        while true
          do
            data="$(
              curl --fail --retry "$latausyritykset" --compressed -L -s \
              -A "${OSX_agentti}" \
              "https://areena.api.yle.fi/v1/ui/content/list?language=${lang}&v=7&client=yle-areena-web&${areena_ohjelmat_tunnus}&limit=${limit}&offset=${offset}" 2>/dev/null \
              | jq -r '.data'
            )"
            if [ $( jq -r '. | length' <<<"$data" ) -eq 0 ]
              then break
            fi
            if [ $offset -gt 0 ]
              then
                echo ','
            fi
            grep '^ ' <<<"${data}"
            offset=$(( offset + limit ))
        done
        echo ']'
    ) | tee "$cache"
}

function areena-ohjelmat {
	(
		areena-json fi |\
		jq -r '.[] | ("areena " + (.labels[] | select(.type == "seriesLink") | .raw) + " " + .title)'
		areena-json fi |\
		jq -r '.[] | select(.labels[] | .type | contains("seriesLink") | not) | ("areena " + (.labels[] | select(.type == "itemId") | .raw) + " " + .title)'

		areena-json sv |\
		jq -r '.[] | ("arenan " + (.labels[] | select(.type == "seriesLink") | .raw) + " " + .title)'
		areena-json sv |\
		jq -r '.[] | select(.labels[] | .type | contains("seriesLink") | not) | ("arenan " + (.labels[] | select(.type == "itemId") | .raw) + " " + .title)'
	)
}
function areena-jaksot {
	local link base
	link="$1"

	valimuistihaku "${OSX_agentti}" "https://programs-cdn.api.yle.fi/v1/episodes/${link}.json?availability=ondemand&${areena_jaksohaku_tunnus}" |\
	jq -r '.data[] | ("https://areena.yle.fi/" + .id + "")' |\
	tee "${tmp}/areena-eps"
}
function areena-jaksotunnus {
	local link json title desc epno episode
	link="$1" # "1-xxxxxxx"

	json="$( valimuistihaku "${OSX_agentti}" "${link/areena.yle.fi/areena.yle.fi/api/programs/v1/id}.json?${areena_jaksohaku_tunnus}" |\
	jq -r '.data' )"
	title="$( jq -r '.title.fi' <<<"${json}" )"
	desc="$( jq -r '.description.fi' <<<"${json}" )"

	epno="$( jq -r '.episodeNumber | select(.)' <<<"${json}" )"
	episode="$( jq -r '.itemTitle.fi | select(.)' <<<"${json}" )"
	if [ -n "$epno" ]
	  then echo "Osa ${epno}: ${episode}. ${desc}"
	  else echo "${episode}. ${desc}"
	fi | tr $'\n' ' '
	echo
}
function areena-latain {
	local link programme vivut custom_parser json title desc type startTime epoch image thumb agelimit snno epno episode product album audio_recode
	link="$1"
	programme="$2"
	custom_parser="$3"

	json="$( valimuistihaku "${OSX_agentti}" "${link/areena.yle.fi/areena.yle.fi/api/programs/v1/id}.json?${areena_jaksohaku_tunnus}" |\
	jq -r '.data' )"
	title="$( jq -r '.title.fi' <<<"${json}" )"
	desc="$( jq -r '.description.fi' <<<"${json}" )"
	type="$( jq -r '.type' <<<"${json}" )"

	startTime="$( jq -r '.publicationEvent[0].startTime' <<<"${json}" )"
	epoch="$( sed 's/\([0-9]*\)-\([0-9]*\)-\([0-9]*\)T\([0-9]*:[0-9]*:[0-9]*\)+.*/\3.\2.\1 \4/' <<<"$startTime" | txtime-epoch )"

	image="$( jq -r '.image.id' <<<"${json}" )"
	thumb="https://images.cdn.yle.fi/image/upload/w_940,dpr_1.0,fl_lossy,f_auto,q_auto,fl_progressive,d_yle-areena.jpg/v1494648649/${image}.jpg"

	agelimit="$( jq -r '.contentRating.ageRestriction' <<<"${json}" )"
	snno="$( jq -r '.partOfSeason.seasonNumber' <<<"${json}" )"
	epno="$( jq -r '.episodeNumber | select(.)' <<<"${json}" )"
	episode="$( jq -r '.itemTitle.fi | select(.)' <<<"${json}" )"

	if [ "$type" = "audio" ]
	 then product="${tmp}/vhs.m4a"
		# aseta radio-ohjelman nimi albumin nimeksi
		album="$programme"
		# aseta radio-ohjelman jakson nimi raidan nimeksi
		title="$title"
		#title="$( sed -n '/title:/ s/.*'\''\(.*\)'\''.*/\1/p' <<<"$metadata" )"
		# etsi sopiva AAC-koodekki ja aseta mp3-ääni koodattavaksi aac-muotoon
		if [ -n "$( ffmpeg -codecs 2>/dev/null |grep libfaac )" ]; then audio_recode="-acodec libfaac"
		elif [ -n "$( ffmpeg -codecs 2>/dev/null |grep libfdk_aac )" ]; then audio_recode="-acodec libfdk_aac"
		elif [ -n "$( ffmpeg -codecs 2>/dev/null |grep libvo_aacenc )" ]; then audio_recode="-acodec libvo_aacenc"
		 else echo "* FFmpeg-yhteensopivaa AAC-koodekkia (libfaac/libfdk_aac/libvo_aacenc) ei löydy" >&2; exit 2;
		fi
	 else product="${tmp}/vhs.m4v"
	fi

        # asetetaan oletusasetukset yle-dl:lle, näitä voidaan muuttaa ohjelmakohtaisesti
	vivut=("-o" "${tmp}/vhs.mp4")

	# suoritetaan käyttäjän oma sekä tallentimessa annettu parsimiskoodi
	if [ -x "${meta_skripti}" ]; then . "${meta_skripti}" || return 100; fi
	. $custom_parser || return 101
	echo

	if ! [ ${#yle_dl_vivut[@]} -eq 0 ]
         then vivut+="${yle_dl_vivut[@]}"
	fi

	if ! [ -s "$product" ]
	 then
		# lataa flv-muotoinen video sekä tekstitykset
                yle-dl "${link}" "${vivut[@]}" &> /dev/fd/6 || return 10

		# muodosta ffmpeg-komento, joka muuntaa videon mp4-muotoon ja lisää siihen suomen- ja ruotsinkieliset tekstit, jos saatavilla
		FFMPEG_alku=("-i" "${tmp}/vhs.mp4")
		FFMPEG_loppu=("-map" "0" "-c:v" "copy" "-c:a" "aac" "-b:a" "192k" "-c:s" "mov_text")

		sindex=0
		for srt in ${tmp}/vhs.*.srt
		 do FFMPEG_alku+=("-i" "${srt}")
			FFMPEG_loppu+=("-map" "$(( sindex + 1 ))" "-metadata:s:s:${sindex}" "language=$( basename "${srt}" .srt | sed 's/^vhs.//' )")
			sindex=$(( sindex + 1 ))
		done

		# aja em. komento
		ffmpeg "${FFMPEG_alku[@]}" "${FFMPEG_loppu[@]}" "${product}" -y &> /dev/fd/6 || return 20

                # poista tekstitystiedostot
		rm ${tmp}/vhs.*.srt 2>/dev/null
	fi

	meta-kirjoitin "${product}" &> /dev/fd/6
}


###########
# NELONEN RUUTU

function ruutu-ohjelmat {
	valimuistihaku "${OSX_agentti}" https://www.ruutu.fi/ohjelmat/kaikki \
	| tr '<' $'\n' \
	| sed -n 's#.*title="\([^"]*\)" href="/\(ohjelmat/[^"]*\)".*#ruutu-sarja \2 \1#p'
	valimuistihaku "${OSX_agentti}" https://www.ruutu.fi/ohjelmat/elokuvat \
	| tr '<' $'\n' \
	| sed -n 's#.*title="\([^"]*\)" href="/\(video/[^"]*\)".*#ruutu-elokuva \2 \1#p'
}
function ruutu-jaksot {
	local type link
	type="$1"
	link="$2"
	if [ "$type" = "sarja" ]
	 then valimuistihaku "${OSX_agentti}" "https://www.ruutu.fi/${link}" \
		| tr '&' $'\n' \
		| sed -n 's#^quot;/video/\([0-9]*\)$#\1#p' |\
		while read ep
		 do [ -n "$( valimuistihaku "${OSX_agentti}" "https://gatling.nelonenmedia.fi/media-xml-cache?id=${ep}" | tulkitse-html | grep '<MediaType>video_episode</MediaType>' )" ] && echo "https://www.ruutu.fi/video/${ep}"
		done
	 else echo "https://www.ruutu.fi/${link}"
	fi
}
function ruutu-jaksotunnus {
	local link html_metadata epid metadata episode desc
	link="$1"
	html_metadata="$( valimuistihaku "${OSX_agentti}" "${link}" | tulkitse-html )"
	og_desc="$( sed -n 's#.*property="og:description" content="\([^"]*\)".*#\1#p' <<<"$html_metadata" )"
	snno="$( sed -n 's/Kausi \([0-9]*\). Jakso [0-9]*.*/\1/p' <<<"$og_desc" )"
	epno="$( sed -n 's/Kausi [0-9]*. Jakso \([0-9]*\).*/\1/p' <<<"$og_desc" )"
	episode="$( sed 's/Kausi [0-9]*. Jakso [0-9]*\/[0-9]*. //; s/\([^.!?]*[!?]\{0,1\}\).*/\1/' <<<"$og_desc" )"
	desc="$( sed 's/Kausi [0-9]*. Jakso [0-9]*\/[0-9]*. [^.!?]*[.!?] //' <<<"$og_desc" )"
	echo "Osa ${epno} (kausi ${snno}): ${episode}. ${desc}"
}
function ruutu-latain {
	local link programme custom_parser html_metadata og_title epno snno episode epid metadata source desc agelimit thumb product
	link="$1"
	programme="$2"
	custom_parser="$3"

	html_metadata="$( valimuistihaku "${OSX_agentti}" "${link}" | tulkitse-html )"
	og_title="$( sed -n 's#.*property="og:titlt" content="\([^"]*\)".*#\1#p' <<<"$html_metadata" )"
	og_desc="$( sed -n 's#.*property="og:description" content="\([^"]*\)".*#\1#p' <<<"$html_metadata" )"
	snno="$( sed -n 's/Kausi \([0-9]*\). Jakso [0-9]*.*/\1/p' <<<"$og_desc" )"
	epno="$( sed -n 's/Kausi [0-9]*. Jakso \([0-9]*\).*/\1/p' <<<"$og_desc" )"
	episode="$( sed 's/Kausi [0-9]*. Jakso [0-9]*\/[0-9]*. //; s/\([^.!?]*[!?]\{0,1\}\).*/\1/' <<<"$og_desc" )"
	desc="$( sed 's/Kausi [0-9]*. Jakso [0-9]*\/[0-9]*. [^.!?]*[.!?] //' <<<"$og_desc" )"

	epid="${link##*/}"
	metadata="$( valimuistihaku "${OSX_agentti}" "https://gatling.nelonenmedia.fi/media-xml-cache?id=${epid}" | iconv -f ISO-8859-1 )"
	
	#bitrates="$( hae-xml-kentta //Playerdata/Clip/BitRateLabels/map bitrate <<<"$metadata" )"
	#source="$( hae-xml-sisalto //Playerdata/Clip/HTTPMediaFiles/HTTPMediaFile <<<"$metadata" | sed 's/_[0-9]*\(_[^_]*.mp4\)/_@@@@\1/' )"
	m3u8_source="$( hae-xml-sisalto //Playerdata/Clip/AppleMediaFiles/AppleMediaFile <<<"$metadata" )"
	#[ -n "$source" -o -n "$m3u8_source" ] || return 10

       m3u8_source="$(
         curl -s "https://gatling.nelonenmedia.fi/auth/access/v2?stream=$(
           php -r "echo urlencode(\"$m3u8_source\");"
         )&timestamp=$( date +%s )"
       )"

	epoch="$( hae-xml-kentta //Playerdata/Behavior/Program start_time <<<"$metadata" | sed 's#.$#:00#' | txtime-epoch )"
	agelimit="$( hae-xml-sisalto //Playerdata/Clip/AgeLimit <<<"$metadata" )"
	thumb="$( hae-xml-kentta //Playerdata/Behavior/Startpicture href <<<"$metadata" )"

	product="${tmp}/vhs.m4v"

	# suoritetaan käyttäjän oma sekä tallentimessa annettu parsimiskoodi
	if [ -x "${meta_skripti}" ]; then . "${meta_skripti}" || return 100; fi
	. $custom_parser || return 101
	echo

	if ! [ -s "${product}" ]
	 then
		# lataa m3u8-muotoinen aineisto
		ffmpeg -i "${m3u8_source}" -bsf:a aac_adtstoasc -c copy -y "${tmp}/presync.m4v" &> /dev/fd/6 || return 10
		# siirrä ääniraitaa eteenpäin 3 ruutua (0,12 s)
		ffmpeg -i "${tmp}/presync.m4v" -itsoffset 0.120 -i "${tmp}/presync.m4v" -c copy -map 0:0 -map 1:1 -y "${product}" &> /dev/fd/6 || return 20
		rm "${tmp}/presync.m4v"
	fi

	meta-kirjoitin "${product}" &> /dev/fd/6
}


#########
# MTV KATSOMO

function katsomo-ohjelmat {
	valimuistihaku "${OSX_agentti}" "https://static.katsomo.fi/cms_prod/all-programs-subcats.json" |\
	jq -r '.categories[] | ("katsomo " + .id + " " + .title)'
}
function katsomo-jaksot {
	local link
	link="$1"

	valimuistihaku "${OSX_agentti}" "https://api.katsomo.fi/api/web/search/categories/${link}/assets.json" |\
	jq -r '.assets[][]? | ("https://api.katsomo.fi/api/web/asset/" + .["@id"])'
}
function katsomo-jaksotunnus {
	local link metadata episode desc
	link="$1"

	metadata="$( valimuistihaku "${OSX_agentti}" "${link}" )"
	episode="$( hae-xml-sisalto //asset/subtitle <<<"$metadata" | tulkitse-html )"
	desc="$( hae-xml-sisalto //asset/description <<<"$metadata" | tulkitse-html )"
	echo "${episode}. ${desc}"
}
function katsomo-latain {
	local link programme custom_parser metadata episode desc snno manifest product 
	link="$1"
	programme="$2"
	custom_parser="$3"

	metadata="$( valimuistihaku "${OSX_agentti}" "${link}" )"
	episode="$( hae-xml-sisalto //asset/subtitle <<<"$metadata" | tulkitse-html )"
	desc="$( hae-xml-sisalto //asset/description <<<"$metadata" | tulkitse-html )"

	# yritetään tulkita jakson kuvauksessa numeroin tai sanallisesti ilmaistu kauden numero
	snno="$( kauden-numero <<<"$desc" )"

	manifest="$( valimuistihaku "${OSX_agentti}" "${link}/play.json" | jq -r '.playback.items[][0].url' )"

	product="${tmp}/vhs.m4v"

	# suoritetaan käyttäjän oma sekä tallentimessa annettu parsimiskoodi
	if [ -x "${meta_skripti}" ]; then . "${meta_skripti}" || return 100; fi
	. $custom_parser || return 101
	echo

	if ! [ -s "$product" ]
	 then
		youtube-dl -o "${tmp}/vhs.ismv" "${manifest}" &> /dev/fd/6 || return 10
		ffmpeg -i "${tmp}/vhs.ismv" -c copy "${product}" -y -v quiet || return 20
	fi

	meta-kirjoitin "${product}" &> /dev/fd/6
}


##########
# OHJELMIEN, JAKSOJEN JA MEDIAN HAKURUTIINIT

# ohjelmalistaus ladataan verkosta vain kerran ja tallennetaan ajokohtaiseen välimuistitiedostoon
function jarjestetyt-ohjelmat {
	local cache
	cache="${tmp}/valimuisti/programmes.txt"
	cat "${cache}" 2>/dev/null && return 0
	[ -d "${tmp}/valimuisti" ] || return 1

	# hae kaikki saatavilla olevat TV-ohjelmat
	(
		areena-ohjelmat
		ruutu-ohjelmat
		katsomo-ohjelmat
	) |\
	LC_ALL=UTF-8 sort -f -t ' ' -u -k3 |\
	tee "${cache}"
}
function hae-ohjelmat-lahteineen {
	local regex source link title
	regex="$1"

	jarjestetyt-ohjelmat | while read source link title
	 do
		[ -n "$regex" ] && ! vertaa-lausekkeita "$( poista_ikarajamerkinta <<<"$title" )" <<<"$regex" && continue
		echo "$source" "$link" "$title"
	done
}
function hae-jaksot {
	local lahde linkki valimuisti
	lahde="$1"
	linkki="$2"

	valimuisti="${tmp}/valimuisti/${lahde}-${linkki##*[/=]}-episodes.txt"
	cat "${valimuisti}" 2>/dev/null && return 0
	[ -d "${tmp}/valimuisti" ] || return 1

	shift
	case $lahde in
	 areena|arenan) areena-jaksot "$@" ;;
	 ruutu-sarja) ruutu-jaksot "sarja" "$@" ;;
	 ruutu-elokuva) ruutu-jaksot "elokuva" "$@" ;;
	 katsomo) katsomo-jaksot "$@" ;;
	 *) echo "*** hae-jaksot: lähde=\"${lahde}\" ***" >&2; exit -1 ;;
	# suodatetaan pois useaan kertaan esiintyvät jakson linkit
	esac | awk '!x[$0]++' | tee "${valimuisti}"
}
function jaksotunnus {
	local linkki
	linkki="$1"

	case "$( sed 's#https*://\([^/]*\).*#\1#' <<<"$linkki" )" in
	 areena.yle.fi) areena-jaksotunnus "$@" ;;
	 www.ruutu.fi) ruutu-jaksotunnus "$@" ;;
	 api.katsomo.fi) katsomo-jaksotunnus "$@" ;;
	 *) echo "*** jaksotunnus: linkki=\"${linkki}\" ***" >&2; exit -2 ;;
	esac
}
function latain {
	local linkki
	linkki="$1"

	case "$( sed 's#https*://\([^/]*\).*#\1#' <<<"$linkki" )" in
	 areena.yle.fi) areena-latain "$@" ;;
	 www.ruutu.fi) ruutu-latain "$@" ;;
	 api.katsomo.fi) katsomo-latain "$@" ;;
	 *) echo "*** latain: linkki=\"${linkki}\" ***" >&2; exit -2 ;;
	esac
}


##########
# JAKSON TALLENNUS, VIRHEIDEN KÄSITTELY JA TIETOKANNAN YLLÄPITO

function tallenna-jakso {
	local programme eplink custom_parser clipid donefile
	programme="$1"
	eplink="$2"
	custom_parser="$3"

	mkdir -p "${kanta}/${programme}"

	# ota linkin loppuosa jakson tunnisteeksi
	clipid="${eplink##*[/=]}"
	donefile="${kanta}/${programme}/${clipid}.done"
	exec 6>"${kanta}/${programme}/${clipid}.log"

	# tutki onko jokin tätä tunnistetta vastaava jakso tallennettu jo aiemmin:
	# - ohita, jos aiemmalla tallenteella ei ole tarkempaa yksilöintitietoa;
	# - muuten annetaan tv-sarjakohtaisen koodin päättää
	[ -f "$donefile" ] && ! [ -s "$donefile" ] && return 0

	# anna työrutiinille tyhjä syöte vakiosyötteen (linkit ohjelman jaksoihin) sijaan
	latain "$eplink" "$programme" "$custom_parser" </dev/zero

	# jos tallennus onnistui, luo '.done', muuten näytä virhekuvaus
	case $? in
	 0) echo "[${clipid}]"; touch -t "$touched_at" "$donefile"; unset touched_at;;
	 1) echo "(${clipid}: TIEDOSTOVIRHE)"; rm -f "$donefile";;
	 2) echo "(${clipid}: TEKSTITYSVIRHE)"; rm -f "$donefile";;
	 3) echo "(${clipid}: METATIETOVIRHE)"; rm -f "$donefile";;
	 10) echo "(${clipid}: EI SAATAVILLA)"; rm -f "$donefile";;
	 20) echo "(${clipid}: LATAUSVIRHE)"; rm -f "$donefile";;
	 100) ;; # ohitettu, ei virhettä
	 101) ;; # ohitettu, ei virhettä
	 *) echo "(${clipid}: VIRHE $?)"; rm -f "$donefile";;
	esac
}


############
# AUTOMAATTITALLENTAJA

function automaattilatain {
	local custom_parser recorder programme regex source link title eplink receps neweps
	custom_parser="${tmp}/custom-parser.sh"
	
	for recorder in "${vhs}"/*"${tallentimen_paate}"
	 do
		programme="$( basename "$recorder" ${tallentimen_paate} )"
		regex="$( sed 1q "$recorder" )"
		sed 1d "$recorder" >"$custom_parser"

		if [ -n "${regex}" ]
		 then hae-ohjelmat-lahteineen "${regex}"
		 else hae-ohjelmat-lahteineen "^$( suojaa-regex <<<"$programme" )$"
		fi | while read source link title
		 do
			hae-jaksot "$source" "$link" | while read eplink
			 do tallenna-jakso "$programme" "$eplink" "$custom_parser"
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

function nayta-komennot {
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

function nayta-ohje {
	echo "vhs.sh [versio ${skriptin_versio}] : automaattinen internet-tv-tallentaja"
	echo
    echo "Tuetut palvelut: YLE Areena, Nelonen Ruutu, (MTV Katsomo : vain metatiedot)"
	echo
	echo "Käytössä ovat seuraavat komennot, joissa 'regex' viittaa ohjelman nimeen :"
	nayta-komennot
	echo
	echo "Suoritus ilman parametrejä toteuttaa komennolla \"a\" asetetut tallennukset"
}


#############
# KOMENTOTULKKI

function tulkki {
	local cmd source link title episodes eplink programme receps indices recorder cmdline
	cmd="$1"
	shift
	[ -n "$cmd" ] || return 0

	case "$cmd" in
	 p)
		hae-ohjelmat-lahteineen "$*" | while read source link title
		 do
			printf "%15s %s\n" "[$source]" "$( poista_ikarajamerkinta <<<"$title" )"
		done
		;;
	 e)
		[ -n "$*" ] && hae-ohjelmat-lahteineen "$*" | while read source link title
		 do
			episodes="$( hae-jaksot "$source" "$link" | wc -l )"
			printf "%15s %s : %d jakso" "[$source]" "$( poista_ikarajamerkinta <<<"$title" )" "$episodes"
			[ $episodes -eq 1 ] || echo -n "a"
			echo
		done
		;;
	 l)
		[ -n "$*" ] && hae-ohjelmat-lahteineen "$*" | while read source link title
		 do
			poista_ikarajamerkinta <<<"$title"
			hae-jaksot "$source" "$link" | while read eplink
			 do jaksotunnus "${eplink}"
			done | cat -n
		done
		;;
	 r)
		[ -n "$*" ] && hae-ohjelmat-lahteineen "$*" | while read source link title
		 do
			programme="$( poista_ikarajamerkinta <<<"$title" )"
			echo "${programme}"
			hae-jaksot "$source" "$link" | while read eplink
			 do tallenna-jakso "$programme" "$eplink" /dev/null
			done | while read receps
			 do ( [ -n "$receps" ] && echo -n "$receps " ) || echo -n "..."
			done && echo
		done
		;;
	 s)
		exec 3<&0
		[ -n "$*" ] && hae-ohjelmat-lahteineen "$*" | while read source link title
		 do
			programme="$( poista_ikarajamerkinta <<<"$title" )"
			cache="${tmp}/valimuisti/selecting-episodes.txt"
			echo "${programme}"
			hae-jaksot "$source" "$link" | tee "${cache}" | while read eplink
			 do jaksotunnus "${eplink}"
			done | cat -n

			read -e -p "Valitse tallennettavat jaksot: " indices <&3

			# laajennetaan merkinnät muotoa '1-5' muotoon '1 2 3 4 5'
			for i in $( eval echo "$( sed 's/\([0-9]*\)-\([0-9]*\)/{\1..\2}/g' <<<"${indices}" )" )
			 do
				if [ "$i" -gt 0 ] 2>/dev/null
				 then tallenna-jakso "$programme" "$( sed -n "$i p" "${cache}" )" /dev/null
				fi
			done | while read receps
			 do ( [ -n "$receps" ] && echo -n "$receps " ) || echo -n "..."
			done && echo
		done
		exec 3<&-
		;;
	 m)
		exec 3<&0
		[ -n "$*" ] && hae-ohjelmat-lahteineen "$*" | while read source link title
		 do
			programme="$( poista_ikarajamerkinta <<<"$title" )"
			cache="${tmp}/valimuisti/selecting-episodes.txt"
			echo "${programme}"
			hae-jaksot "$source" "$link" | tee "${cache}" | while read eplink
			 do donefile="${kanta}/${programme}/${eplink##*[/=]}.done"
				jaksotunnus "${eplink}" | ( ( [ -f "${donefile}" ] && sed 's/^/* /' ) || sed 's/^/  /' )
			done | cat -n

			# luetaan syöte, poistutaan jos tyhjä
			read -e -p "Aseta tallennetut jaksot: " indices <&3
			[ -n "$indices" ] || return

			# poistetaan kaikki olemassa olevat done-tiedostot
			while read eplink
			 do rm "${kanta}/${programme}/${eplink##*[/=]}.done" 2>/dev/null
			done < "${cache}"

			# laajennetaan merkinnät muotoa '1-5' muotoon '1 2 3 4 5'
			for i in $( eval echo "$( sed 's/\([0-9]*\)-\([0-9]*\)/{\1..\2}/g' <<<"${indices}" )" )
			 do
				if [ "$i" -gt 0 ] 2>/dev/null
				 then eplink="$( sed -n "$i p" "${cache}" )"
					mkdir -p "${kanta}/${programme}"
					touch "${kanta}/${programme}/${eplink##*[/=]}.done"
				fi
			done
		done
		exec 3<&-
		;;
	 /|v)
		echo "Aktiiviset tallentimet:"
		echo "-----------------------"
		for recorder in "${vhs}"/*"${tallentimen_paate}"
		 do
			programme="$( basename "${recorder}" "${tallentimen_paate}" )"
			[ -n "$*" ] && ! vertaa-lausekkeita "$programme" <<<"$*" && continue
			echo -n "${programme} "
			[ -n "$( sed 1q "$recorder" )" ] && echo -n "($( sed 1q "$recorder" ))"
			[ -n "$( sed 1d "$recorder" )" ] && echo -n "*"
			echo
		done
		;;
	 +|a)
		[ -n "$*" ] && hae-ohjelmat-lahteineen "$*" | while read source link title
		 do
			recorder="${vhs}/$( poista_ikarajamerkinta <<<"$title" )${tallentimen_paate}"
			touch "${recorder}" && echo "+ ${recorder}"
		done
		;;
	 -|d)
		[ -n "$*" ] && for recorder in "${vhs}"/*"${tallentimen_paate}"
		 do
			programme="$( basename "${recorder}" "${tallentimen_paate}" )"
			vertaa-lausekkeita "$programme" <<<"$*" && rm "${recorder}" && echo "- ${recorder}"
		done
		;;
	 i)
	 	nayta-komennot
		while read -e -p "vhs.sh> " cmdline
		 do
			history -s $cmdline
		 	if [ "$cmdline" = "q" -o "$cmdline" = "quit" ]
			 then break
                       elif [ "$cmdline" = "h" -o "$cmdline" = "help" ]
			 then nayta-komennot
			 else tulkki $cmdline
			fi
		done
		;;
	 *)
		nayta-ohje
		;;
	esac
}


#############
# PÄÄOHJELMA

# tarkista apuohjelmien saatavuus
jarjestelmavaatimukset

# vaihda vanhojen tallentimien tiedostopäätteet (.vhs) tarvittaessa
[ "$tallentimen_paate" != ".vhs" ] && for vanha_tallennin in "${vhs}"/*.vhs
 do mv "$vanha_tallennin" "${vanha_tallennin%.vhs}${tallentimen_paate}"
done

# ei argumentteja: käsittele kaikki tallentimet
# muuten: tulkitse annettu komentorivi
if [ $# -eq 0 ]
 then
	if [ -n "$( echo "${vhs}"/*${tallentimen_paate} )" ]
	 then
		# älä aja automaattitallennusta, jos sessio on jo käynnissä
		pid_tiedosto="$( find -L "${vhs}" -name autorec.pid )"
		if [ -n "$pid_tiedosto" ]
		 then
			if pgrep -F "$pid_tiedosto" &>/dev/null
			 then [ -t 0 ] && echo "Skripti on jo käynnissä: PID $( cat "$pid_tiedosto" )" >&2
				exit 0
			 else rm -rf "$( dirname "$pid_tiedosto" )" &>/dev/null
			fi
		fi
		echo $$ > "${tmp}/autorec.pid"
		automaattilatain
		exit $?
	 else
		echo "Ei asetettuja tallentimia!" >&2
		nayta-ohje >&2
	fi
 else
	tulkki "$@"
fi
