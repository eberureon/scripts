#!/bin/bash

## -- Examples --

# -- Get all sitemap urls --
# ./sitemap-urls.sh https://developer.mozilla.org/sitemap.xml

# -- Get only urls that end with `.js` --
# ./sitemap-urls.sh https://developer.mozilla.org/sitemap.xml | grep -e "\.js$"

# -- Get only urls that do not end with `.js` --
# ./sitemap-urls.sh https://developer.mozilla.org/sitemap.xml | grep -v -e "\.js$"

# -- Get urls and write them to file --
# ./sitemap-urls.sh https://developer.mozilla.org/sitemap.xml > mdn.urls.txt

# -- Check pages availability --
# ./sitemap-urls.sh https://developer.mozilla.org/sitemap.xml | xargs -I{} sh -c '
#   RED="\033[0;31m"
#   GREEN="\033[0;32m"
#   NO_COLOR="\033[0m"
#
#   if curl --output /dev/null --silent --head --fail "$1"; then
#     echo "[${GREEN}OK${NO_COLOR}] $1"
#   else
#     echo "[${RED}BAD${NO_COLOR}] $1"
#   fi
# ' -- {}

## -- Examples --

# Messages go to stderr so that they never end up in the piped URL list.

if ! command -v xpath &>/dev/null; then
	echo "Error: xpath command not found. Please install it and try again." >&2
	exit 1
fi

if ! command -v curl &>/dev/null; then
	echo "Error: curl command not found. Please install it and try again." >&2
	exit 1
fi

if [[ $# -eq 0 ]]; then
	echo "Error: no argument provided." >&2
	echo "Usage: $(basename "$0") <sitemap_url>" >&2
	exit 1
fi

# Sitemaps that were already read, one URL per line. A sitemap index that
# refers back to itself would otherwise recurse forever.
visited=""

# Exit status of the script: 1 as soon as one sitemap could not be fetched.
status=0

tmp_file=$(mktemp) || exit 1
trap 'rm -f "$tmp_file"' EXIT

# fetch_xml - Fetches an XML file from a URL, decompressing it if it is gzipped
#
# Usage:
#   fetch_xml "url"
#
# Arguments:
#   $1 - The URL of the XML file to fetch
#
# Returns non-zero if the download fails, including on HTTP errors.
fetch_xml() {
	local url=$1

	if ! curl -fsSL --compressed -o "$tmp_file" "$url"; then
		return 1
	fi

	# Decided by content, not by file name: a ".gz" URL may carry a query
	# string, and some servers send gzip data under a plain name.
	if gzip -t "$tmp_file" 2>/dev/null; then
		gunzip -c "$tmp_file"
	else
		cat "$tmp_file"
	fi
}

# decode_xml_entities - Decodes HTML entities in an XML or HTML string
#
# Usage:
#   cat file.xml | decode_xml_entities
#
# Output:
#   The decoded XML or HTML string, printed to standard output
decode_xml_entities() {
	sed 's/&lt;/</g; s/&gt;/>/g; s/&quot;/"/g; s/&apos;/\x27/g; s/&amp;/\&/g;'
}

# parse_sitemap - Recursively parses a sitemap XML file and outputs the URLs
#
# Usage:
#   parse_sitemap "sitemap_url"
#
# Arguments:
#   $1 - The URL of the sitemap XML file to parse
#
# Output:
#   The URLs of all pages contained within the sitemap, printed to standard output
parse_sitemap() {
	local url=$1
	local xml sub_sitemaps xml_url

	if printf '%s\n' "$visited" | grep -Fxq -- "$url"; then
		return 0
	fi
	visited+="$url"$'\n'

	# Declared above on purpose: "local xml=$(...)" would hide the exit status.
	if ! xml=$(fetch_xml "$url"); then
		echo "Error: could not fetch $url" >&2
		status=1
		return 0
	fi

	# Pages of this sitemap, one per line
	printf '%s\n' "$xml" | xpath -q -e "//urlset/url/loc/text()" 2>/dev/null | decode_xml_entities

	sub_sitemaps=$(printf '%s\n' "$xml" | xpath -q -e "//sitemap/loc/text()" 2>/dev/null | decode_xml_entities)

	# Read line by line: no word splitting or globbing on the URLs
	while IFS= read -r xml_url; do
		if [[ -n "$xml_url" ]]; then
			parse_sitemap "$xml_url"
		fi
	done <<<"$sub_sitemaps"
}

parse_sitemap "$1"

exit $status
