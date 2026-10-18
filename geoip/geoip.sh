#!/usr/bin/env bash
#
# build-opnsense-geoip-zip.sh
# Version: 2.1.0
#
# Bash port of Build-OpnsenseGeoIpZip.ps1 (PowerShell version 2.1.0).
#
# Builds a GeoLite2-Country-CSV compatible zip for the OPNsense GeoIP alias feature,
# from the free IPLocate.io "IP to Country" database:
#   https://github.com/iplocate/ip-address-databases/tree/main/ip-to-country
# No MaxMind data, account or service is used; the GeoLite2 file names are kept only
# because OPNsense expects them.
#
# Data license: IP address data powered by IPLocate.io (https://www.iplocate.io),
# licensed under CC BY-SA 4.0 (https://creativecommons.org/licenses/by-sa/4.0/).
# A COPYRIGHT.txt file with this attribution is added to the generated zip.
#
# Usage:
#   Build mode : ./build-opnsense-geoip-zip.sh [-o OUTPUT_DIRECTORY]
#   Lookup mode: ./build-opnsense-geoip-zip.sh -t IP_ADDRESS [-z ZIP_PATH]
#
#   Without -o or -z, the fixed output directory below is used when enabled,
#   otherwise the script folder.
#
# Requirements: bash, curl, awk, zip, unzip
#
# Changelog:
#   2.1.0  Output zip renamed to geoip.zip (inner CSV names unchanged, required by OPNsense).
#   2.0.0  Data source replaced: IPLocate.io ip-to-country CSV instead of the five RIR
#          statistics files. COPYRIGHT.txt (CC BY-SA 4.0 attribution) added to the zip.
#   1.1.0  Added a fixed output directory setting (USE_FIXED_OUTPUT_DIRECTORY).
#   1.0.0  Initial bash version, same features and output as the PowerShell version 1.1.0.

set -euo pipefail

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------
# Fixed output directory. When enabled (true), it is used as the default folder for
# the zip in both modes. An explicit -o or -z on the command line still overrides it.
USE_FIXED_OUTPUT_DIRECTORY=false
FIXED_OUTPUT_DIRECTORY="/path/to/wordpress/ressources/geoip"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZIP_NAME="geoip.zip"

# IPLocate ip-to-country database (zip with one CSV: network,continent_code,country_code,country_name).
# The file is stored with Git LFS; this URL redirects to the real content.
SOURCE_URL="https://github.com/iplocate/ip-address-databases/raw/main/ip-to-country/ip-to-country.csv.zip"

# Shared awk helper: converts any IPv4 or IPv6 address to a 128 character bit string,
# so that a network match is a simple prefix comparison of two strings.
AWK_IP_BITS='
function hex_to_bits(h,    i, d, b, out) {
    out = ""
    for (i = 1; i <= length(h); i++) {
        d = index("0123456789abcdef", substr(h, i, 1)) - 1
        b = ""
        for (j = 0; j < 4; j++) { b = (d % 2) b; d = int(d / 2) }
        out = out b
    }
    return out
}
function ipv4_to_bits(ip,    p, i, v, b, out) {
    split(ip, p, ".")
    out = ""
    for (i = 1; i <= 4; i++) {
        v = p[i] + 0; b = ""
        for (j = 0; j < 8; j++) { b = (v % 2) b; v = int(v / 2) }
        out = out b
    }
    return out
}
function ipv6_to_bits(ip,    halves, left, right, lg, rg, n, i, groups, missing, out) {
    ip = tolower(ip)
    n = split(ip, halves, "::")
    lg = (halves[1] == "") ? 0 : split(halves[1], left, ":")
    rg = (n < 2 || halves[2] == "") ? 0 : split(halves[2], right, ":")
    missing = 8 - lg - rg
    out = ""
    for (i = 1; i <= lg; i++) out = out hex_to_bits(substr("0000" left[i], length(left[i]) + 1))
    for (i = 1; i <= missing; i++) out = out hex_to_bits("0000")
    for (i = 1; i <= rg; i++) out = out hex_to_bits(substr("0000" right[i], length(right[i]) + 1))
    return out
}
function ip_to_bits(ip) {
    return (index(ip, ":") > 0) ? ipv6_to_bits(ip) : ipv4_to_bits(ip)
}
'

usage() {
    sed -n '/^# Usage:/,/^# Requirements:/p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
}

require_commands() {
    local cmd
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || { echo "Error: '$cmd' is required but not installed." >&2; exit 1; }
    done
}

# ---------------------------------------------------------------------------
# Lookup mode: finds the country of an IP address in an existing zip.
# ---------------------------------------------------------------------------
lookup_ip() {
    local ip="$1" zip_path="$2" blocks_pattern

    require_commands unzip awk
    [[ -f "$zip_path" ]] || { echo "Error: zip file not found: $zip_path. Run the script without -t first to build it." >&2; exit 1; }

    if [[ "$ip" == *:* ]]; then blocks_pattern='*Blocks-IPv6.csv'; else blocks_pattern='*Blocks-IPv4.csv'; fi

    # The locations file is read first (FNR==NR), then the blocks file is scanned
    # until the first network containing the address.
    awk -F',' -v ip="$ip" "$AWK_IP_BITS"'
        FNR == NR { if ($1 ~ /^[0-9]+$/) { code[$1] = $5; name[$1] = $6 }; next }
        FNR == 1  { target = ip_to_bits(ip); next }
        {
            split($1, net, "/")
            if (substr(ip_to_bits(net[1]), 1, net[2]) == substr(target, 1, net[2])) {
                gsub(/"/, "", name[$2])
                printf "IpAddress   : %s\nCountryCode : %s\nCountryName : %s\nNetwork     : %s\n", ip, code[$2], name[$2], $1
                found = 1
                exit
            }
        }
        END { if (!found) printf "Warning: no country found for %s (private, reserved or unassigned address).\n", ip > "/dev/stderr" }
    ' <(unzip -p "$zip_path" '*Locations-en.csv') <(unzip -p "$zip_path" "$blocks_pattern")
}

# ---------------------------------------------------------------------------
# Build mode: downloads the IPLocate database and creates the zip.
# ---------------------------------------------------------------------------
build_zip() {
    local output_directory="$1"
    local date_stamp folder_name work_directory csv_directory source_zip zip_path

    require_commands curl awk zip unzip

    date_stamp="$(date +%Y%m%d)"
    folder_name="GeoLite2-Country-CSV_${date_stamp}"
    work_directory="$(mktemp -d)"
    csv_directory="${work_directory}/${folder_name}"
    source_zip="${work_directory}/ip-to-country.csv.zip"
    mkdir -p "$csv_directory"
    # The path is expanded now, because the local variable no longer exists when the trap runs.
    trap "rm -rf '${work_directory}'" EXIT

    echo "Downloading $SOURCE_URL"
    curl -fsSL --retry 3 -o "$source_zip" "$SOURCE_URL"

    # Source line format: network,continent_code,country_code,country_name
    # Only the first three fields are used, so the quoted country names (which may
    # contain commas) do not need CSV parsing. The three output files are written
    # in a single pass.
    unzip -p "$source_zip" '*.csv' | awk -F',' -v dir="$csv_directory" '
        function country_id(cc) {
            return 1000000 + (index(LETTERS, substr(cc, 1, 1)) - 1) * 26 + (index(LETTERS, substr(cc, 2, 1)) - 1)
        }
        BEGIN {
            LETTERS = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
            header = "network,geoname_id,registered_country_geoname_id,represented_country_geoname_id,is_anonymous_proxy,is_satellite_provider,is_anycast"
            ipv4_file = dir "/GeoLite2-Country-Blocks-IPv4.csv"
            ipv6_file = dir "/GeoLite2-Country-Blocks-IPv6.csv"
            locations_file = dir "/GeoLite2-Country-Locations-en.csv"
            print header > ipv4_file
            print header > ipv6_file
        }
        NR == 1 { next }   # source header
        {
            sub(/\r$/, "")
            cc = toupper($3)
            if (cc !~ /^[A-Z][A-Z]$/ || index($1, "/") == 0) { skipped++; next }

            id = country_id(cc)
            countries[cc] = id
            if (index($1, ":") > 0) {
                printf "%s,%d,%d,,0,0,0\n", $1, id, id > ipv6_file; ipv6_count++
            } else {
                printf "%s,%d,%d,,0,0,0\n", $1, id, id > ipv4_file; ipv4_count++
            }
        }
        END {
            # Locations file: the ISO code is used as name (OPNsense does not read this column).
            print "geoname_id,locale_code,continent_code,continent_name,country_iso_code,country_name,is_in_european_union" > locations_file
            for (cc in countries) { printf "%d,en,,,%s,\"%s\",0\n", countries[cc], cc, cc > locations_file; country_count++ }
            printf "Countries     : %d\nIPv4 networks : %d\nIPv6 networks : %d\nSkipped lines : %d\n", country_count, ipv4_count, ipv6_count, skipped + 0
        }
    '

    # Attribution required by the CC BY-SA 4.0 license of the IPLocate data.
    cat > "${csv_directory}/COPYRIGHT.txt" <<EOF
IP address data powered by IPLocate.io (https://www.iplocate.io)

Source : ${SOURCE_URL}
License: Creative Commons Attribution-ShareAlike 4.0 International (CC BY-SA 4.0)
         https://creativecommons.org/licenses/by-sa/4.0/
Built  : $(date -u +%Y-%m-%dT%H:%M:%SZ)

This file set was converted to the GeoLite2-Country-CSV layout for OPNsense GeoIP aliases.
It contains no MaxMind data; the GeoLite2 file names only describe the layout.
EOF

    # Entries are stored as "<folder>/<file>" with forward slashes, as OPNsense expects.
    mkdir -p "$output_directory"
    zip_path="$(cd "$output_directory" && pwd)/${ZIP_NAME}"
    rm -f "$zip_path"
    (cd "$work_directory" && zip -q -r "$zip_path" "$folder_name")

    echo "Zip created   : $zip_path"
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
if [[ "$USE_FIXED_OUTPUT_DIRECTORY" == "true" ]]; then
    output_directory="$FIXED_OUTPUT_DIRECTORY"
else
    output_directory="$SCRIPT_DIR"
fi
test_ip=""
zip_path="${output_directory}/${ZIP_NAME}"

while getopts ":o:t:z:h" option; do
    case "$option" in
        o) output_directory="$OPTARG" ;;
        t) test_ip="$OPTARG" ;;
        z) zip_path="$OPTARG" ;;
        *) usage ;;
    esac
done

if [[ -n "$test_ip" ]]; then
    lookup_ip "$test_ip" "$zip_path"
else
    build_zip "$output_directory"
fi
