#!/bin/sh
# os-dhcp-dashboard - manual installer for the DHCP leases dashboard widget
# Version: 1.0.0
#
# Usage (as root on the OPNsense firewall, from this folder):
#   sh install.sh            install or update the widget
#   sh install.sh uninstall  remove the widget

set -e

SRC_DIR="$(cd "$(dirname "$0")" && pwd)/src/opnsense/www/js/widgets"
DST_DIR="/usr/local/opnsense/www/js/widgets"
FILES="DhcpDashboard.js Metadata/DhcpDashboard.xml"

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root." >&2
    exit 1
fi

if [ ! -d "${DST_DIR}/Metadata" ]; then
    echo "${DST_DIR}/Metadata not found: OPNsense 24.7 or newer is required." >&2
    exit 1
fi

case "${1:-install}" in
    install)
        for f in ${FILES}; do
            install -m 0644 -o root -g wheel "${SRC_DIR}/${f}" "${DST_DIR}/${f}"
            echo "Installed ${DST_DIR}/${f}"
        done
        echo "Done. Reload the dashboard (Ctrl+F5) and add the 'DHCP Leases' widget."
        ;;
    uninstall)
        for f in ${FILES}; do
            rm -f "${DST_DIR}/${f}"
            echo "Removed ${DST_DIR}/${f}"
        done
        echo "Done. Reload the dashboard (Ctrl+F5)."
        ;;
    *)
        echo "Usage: sh $0 [install|uninstall]" >&2
        exit 1
        ;;
esac
