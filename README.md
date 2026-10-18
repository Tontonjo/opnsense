# os-dhcp-dashboard

Version: 1.2.0

DHCP leases widget for the OPNsense dashboard (24.7 and newer), in the spirit of the
legacy `dHCP_leases.widget.php` by Tonton Jo, which stopped working with the new
JavaScript dashboard.

## Features

- One table for all running DHCP servers:
  - ISC DHCP v4/v6 (core up to 25.x, `os-isc-dhcp` plugin since 26.1)
  - Kea DHCP v4/v6
  - Dnsmasq DHCP v4/v6
- Columns: IP address, Hostname, MAC address, Manufacturer, Interface, Lease type, Server, Status
- Sortable: click a column header to sort, click again to reverse (kept while the page is open)
- Manufacturer: vendor lookup from the OPNsense MAC database (lease data, then ARP/NDP table);
  random / private MAC addresses (locally administered) are labelled as such
- Only active leases are shown (expired, declined and released leases are hidden)
- Online status: provided by ISC, looked up in the ARP (IPv4) / NDP (IPv6) table for Kea and Dnsmasq
- Widget options (pencil icon, then the gear of the widget): show IPv6 leases (off by default),
  columns to display (all by default)
- Sorted by IP address (IPv4 first), refreshed every 30 seconds
- No overlapping texts: long hostnames / vendors / interfaces are truncated with "..." (full value
  on mouse over), and the table scrolls horizontally when the widget is too narrow

## Installation

### Option 1: quick install from the OPNsense shell

Open a root shell on the firewall (SSH, or console menu option 8), then run:

```sh
fetch -o /usr/local/opnsense/www/js/widgets/DhcpDashboard.js https://raw.githubusercontent.com/Tontonjo/opnsense/main/os-dhcp-dashboard/src/opnsense/www/js/widgets/DhcpDashboard.js
fetch -o /usr/local/opnsense/www/js/widgets/Metadata/DhcpDashboard.xml https://raw.githubusercontent.com/Tontonjo/opnsense/main/os-dhcp-dashboard/src/opnsense/www/js/widgets/Metadata/DhcpDashboard.xml
```

Then in the web interface: reload the dashboard (Ctrl+F5), click the pencil icon,
**Add widget > DHCP Leases**, and save.

- Update: run the same two commands again.
- Uninstall:

```sh
rm -f /usr/local/opnsense/www/js/widgets/DhcpDashboard.js /usr/local/opnsense/www/js/widgets/Metadata/DhcpDashboard.xml
```

### Option 2: install from a local copy

Copy this folder to the firewall (e.g. with `scp`), then as root:

```sh
cd os-dhcp-dashboard
sh install.sh            # install or update
sh install.sh uninstall  # remove
```

Reload the dashboard (Ctrl+F5), click the pencil icon, then **Add widget > DHCP Leases**.

Note: files installed manually are not tracked by the package manager. A firmware
update does not remove them, but reinstall after a major upgrade if the widget disappears.

### Option 3: build a real package (os-dhcp-dashboard)

On an OPNsense (or FreeBSD build) machine:

```sh
pkg install git
git clone https://github.com/opnsense/plugins /usr/plugins
cp -R os-dhcp-dashboard /usr/plugins/net/dhcp-dashboard
cd /usr/plugins/net/dhcp-dashboard
make package
pkg add work/pkg/os-dhcp-dashboard-*.pkg
```

## Files

```
Makefile                                         plugin build definition
pkg-descr                                        package description and changelog
install.sh                                       manual installer
src/opnsense/www/js/widgets/DhcpDashboard.js     widget code
src/opnsense/www/js/widgets/Metadata/DhcpDashboard.xml   widget metadata and labels
```

## Permissions

The widget is visible to every dashboard user. Data from a backend the user is not
allowed to read (or that is not installed) is simply skipped. Online status requires
access to *Diagnostics: ARP Table* / *NDP Table*; without it the status shows "Unknown".

## API endpoints used

| Backend | Status check | Leases |
|---|---|---|
| ISC | `/api/dhcpv{4,6}/service/status` | `/api/dhcpv{4,6}/leases/search_lease` |
| Kea | `/api/kea/dhcpv{4,6}/get` | `/api/kea/leases{4,6}/search` |
| Dnsmasq | `/api/dnsmasq/settings/get` | `/api/dnsmasq/leases/search` |
| Presence | | `/api/diagnostics/interface/get_arp`, `get_ndp` |

## Credits

- Tonton Jo: https://github.com/Tontonjo/opnsense
- Based on earlier work by Bobby Earl and jbaconsult
