#!/usr/bin/env bash
#
# build-opnsense-geoip-zip.sh
# Version: 1.0.0
#
# Bash port of Build-OpnsenseGeoIpZip.ps1 (PowerShell version 1.1.0).
#
# Builds a GeoLite2-Country-CSV compatible zip for the OPNsense GeoIP alias feature,
# exclusively from the public statistics files of the five Regional Internet
# Registries (ARIN, RIPE NCC, APNIC, LACNIC, AFRINIC). No MaxMind data, account or
# service is used; the GeoLite2 file names are kept only because OPNsense expects them.
#
# Note: the RIR data reflects the country where a block is registered, not the
# physical location of each host.
#
# Usage:
#   Build mode : ./build-opnsense-geoip-zip.sh [-o OUTPUT_DIRECTORY]
#   Lookup mode: ./build-opnsense-geoip-zip.sh -t IP_ADDRESS [-z ZIP_PATH]
#
# Requirements: bash, curl, awk, zip, unzip
#
# Changelog:
#   1.0.0  Initial bash version, same features and output as the PowerShell version 1.1.0.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZIP_NAME="GeoLite2-Country-CSV.zip"

RIR_SOURCES=(
    "https://ftp.arin.net/pub/stats/arin/delegated-arin-extended-latest"
    "https://ftp.ripe.net/pub/stats/ripencc/delegated-ripencc-extended-latest"
    "https://ftp.apnic.net/stats/apnic/delegated-apnic-extended-latest"
    "https://ftp.lacnic.net/pub/stats/lacnic/delegated-lacnic-extended-latest"
    "https://ftp.afrinic.net/pub/stats/afrinic/delegated-afrinic-extended-latest"
)

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
# Build mode: downloads the RIR files and creates the zip.
# ---------------------------------------------------------------------------
build_zip() {
    local output_directory="$1"
    local date_stamp folder_name work_directory csv_directory zip_path url

    require_commands curl awk zip

    date_stamp="$(date +%Y%m%d)"
    folder_name="GeoLite2-Country-CSV_${date_stamp}"
    work_directory="$(mktemp -d)"
    csv_directory="${work_directory}/${folder_name}"
    mkdir -p "$csv_directory" "${work_directory}/raw"
    # The path is expanded now, because the local variable no longer exists when the trap runs.
    trap "rm -rf '${work_directory}'" EXIT

    for url in "${RIR_SOURCES[@]}"; do
        echo "Downloading $url"
        curl -fsSL --retry 3 -o "${work_directory}/raw/$(basename "$url")" "$url"
    done

    # Line format: registry|cc|type|start|value|date|status[|extensions]
    # Writes the three CSV files in a single pass over all RIR files.
    awk -F'|' -v dir="$csv_directory" '
        function country_id(cc) {
            return 1000000 + (index(LETTERS, substr(cc, 1, 1)) - 1) * 26 + (index(LETTERS, substr(cc, 2, 1)) - 1)
        }
        function ip_to_int(ip,    p) { split(ip, p, "."); return ((p[1] * 256 + p[2]) * 256 + p[3]) * 256 + p[4] }
        function int_to_ip(v) {
            return sprintf("%d.%d.%d.%d", int(v / 16777216) % 256, int(v / 65536) % 256, int(v / 256) % 256, v % 256)
        }
        # Splits an IPv4 range (start address + host count) into the minimal list of CIDR blocks.
        function write_ipv4_cidrs(start, count, id,    current, last, bits, size) {
            current = ip_to_int(start)
            last = current + count   # exclusive upper bound
            while (current < last) {
                bits = 0; size = 1
                while (bits < 32 && current % (size * 2) == 0 && current + size * 2 <= last) { size *= 2; bits++ }
                printf "%s/%d,%d,%d,,0,0,0\n", int_to_ip(current), 32 - bits, id, id > ipv4_file
                current += size
            }
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
        /^#/ || NF < 7 { next }   # comments, version and summary lines
        {
            cc = toupper($2)
            if (cc !~ /^[A-Z][A-Z]$/) next
            if ($7 != "allocated" && $7 != "assigned") next

            id = country_id(cc)
            if ($3 == "ipv4") {
                write_ipv4_cidrs($4, $5 + 0, id); countries[cc] = id; ipv4_count++
            } else if ($3 == "ipv6") {
                # For IPv6 the value field is already the prefix length.
                printf "%s/%s,%d,%d,,0,0,0\n", $4, $5, id, id > ipv6_file; countries[cc] = id; ipv6_count++
            }
        }
        END {
            # Locations file: country names are not available without an external source,
            # so the ISO code is used as name (OPNsense does not read this column).
            print "geoname_id,locale_code,continent_code,continent_name,country_iso_code,country_name,is_in_european_union" > locations_file
            for (cc in countries) { printf "%d,en,,,%s,\"%s\",0\n", countries[cc], cc, cc > locations_file; country_count++ }
            printf "Countries      : %d\nIPv4 RIR lines : %d\nIPv6 RIR lines : %d\n", country_count, ipv4_count, ipv6_count
        }
    ' "${work_directory}"/raw/*

    # Entries are stored as "<folder>/<file>" with forward slashes, as OPNsense expects.
    mkdir -p "$output_directory"
    zip_path="$(cd "$output_directory" && pwd)/${ZIP_NAME}"
    rm -f "$zip_path"
    (cd "$work_directory" && zip -q -r "$zip_path" "$folder_name")

    echo "Zip created    : $zip_path"
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
output_directory="$SCRIPT_DIR"
test_ip=""
zip_path="${SCRIPT_DIR}/${ZIP_NAME}"

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
