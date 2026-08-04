#!/usr/bin/env bash

# currently supported flags: --intro, --standard, --suite
# couldn't find any exposed links for beta packages

TYPE=${1#--}

get_download_url() {
	case "$TYPE" in
		intro|standard|suite) ;;
		*) return 1 ;;
	esac
	
	echo "Determining latest version..." 1>&2
	for MINOR in {9..1}; do
		BASE="https://cdn-downloads.ableton.com/channels/12.${MINOR}"
		URL="${BASE}/ableton_live_${TYPE}_12.${MINOR}_64.zip"
		curl -fsI "$URL" >/dev/null || continue
		for POINT in {9..1}; do
		    POINT_URL="${BASE}.${POINT}/ableton_live_${TYPE}_12.${MINOR}.${POINT}_64.zip"
		    if curl -fsI "$POINT_URL" >/dev/null; then
		        URL=$POINT_URL
		        break
		    fi
		done
		curl -LsI -w '%{url_effective}' "$URL" | tail -n1
		return
	done
}

download_live() {
	DOWNLOAD_URL=$(get_download_url)
	VERSION=$(echo "$DOWNLOAD_URL" | grep -Eo '12\.[0-9]+(\.[0-9]+)?' | head -n1)
	echo -e "Downloading \e[1mAbleton Live $(echo "${VERSION}\e[0m...\n${DOWNLOAD_URL}" \
		| sed 's/?.*//')" 1>&2
	curl --create-dirs --output-dir $PWD \
		--remote-name -C - $DOWNLOAD_URL
}

download_live