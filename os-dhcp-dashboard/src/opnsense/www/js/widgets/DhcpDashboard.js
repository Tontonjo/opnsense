/*
 * os-dhcp-dashboard - DHCP leases widget for the OPNsense dashboard
 * Version: 1.2.0
 *
 * Shows the active DHCP leases of every running DHCP server in one table:
 *   - ISC DHCP (v4 / v6)  : core up to 25.x, os-isc-dhcp plugin since 26.1
 *   - Kea DHCP (v4 / v6)
 *   - Dnsmasq DHCP (v4 / v6)
 *
 * Inspired by the legacy dHCP_leases.widget.php by Tonton Jo
 * (https://github.com/Tontonjo/opnsense), rewritten for the JavaScript
 * dashboard introduced in OPNsense 24.7.
 *
 * Copyright (C) 2026
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice,
 *    this list of conditions and the following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES,
 * INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
 * AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
 * AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY,
 * OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 */

/*
 * Changelog
 *   1.2.0  Columns can be shown / hidden in the widget options, no more overlapping texts
 *          (auto table layout, horizontal scroll, long texts truncated with full value in tooltip)
 *   1.1.0  Silent backend probing (no more "Endpoint not found" popup when a backend is absent),
 *          sortable columns (click a header), manufacturer column (MAC vendor lookup)
 *   1.0.0  Initial release
 *
 * Normalized lease record used by the renderer:
 * {
 *   ip:           string   IPv4 or IPv6 address
 *   family:       'v4'|'v6'
 *   hostname:     string
 *   mac:          string
 *   manufacturer: string   vendor from the OUI database, or the "random MAC" label
 *   randomMac:    boolean  true when the MAC is locally administered (privacy / random MAC)
 *   iface:        string   interface description
 *   type:         'dynamic'|'static'
 *   source:       'ISC'|'Kea'|'Dnsmasq'
 *   online:       true|false|null (null = unknown, resolved through ARP/NDP)
 * }
 */

export default class DhcpDashboard extends BaseWidget {
    constructor(config) {
        super(config);
        this.configurable = true;
        this.configChanged = false;
        // Lease lookups trigger several backend scripts, no need to poll every 10s
        this.tickTimeout = 30;

        // Available table columns, visibility is selected in the widget options.
        // "truncate": long free texts are cut with "..." and the full value is shown in a tooltip
        this.columns = [
            { key: 'ip',           label: 'ipaddress' },
            { key: 'hostname',     label: 'hostname',     truncate: true },
            { key: 'mac',          label: 'mac' },
            { key: 'manufacturer', label: 'manufacturer', truncate: true },
            { key: 'iface',        label: 'interface',    truncate: true },
            { key: 'type',         label: 'leasetype' },
            { key: 'source',       label: 'source' },
            { key: 'online',       label: 'status',       center: true }
        ];
        this.visibleColumns = this.columns;

        // Current sort, changed by clicking a column header (kept while the page is open)
        this.sortKey = 'ip';
        this.sortAsc = true;
        this.leases = [];
    }

    getGridOptions() {
        return {
            // Scrollbar appears once the content exceeds 650px
            sizeToContent: 650
        };
    }

    getMarkup() {
        /*
         * The dashboard stylesheet forces "table-layout: fixed" (equal column widths) and
         * "word-break: break-all" on every table, which makes texts overflow into the next cell.
         * Here: automatic layout (each column as wide as its content), no wrapping, and a
         * horizontal scrollbar when the widget is narrower than the table.
         */
        return $(`
            <div class="dhcp-dashboard" id="dhcpDashboard">
                <style>
                    #dhcpDashboard .dd-table-wrap { overflow-x: auto; width: 100%; }
                    #dhcpDashboard table { table-layout: auto; width: 100%; margin-bottom: 0; }
                    #dhcpDashboard th, #dhcpDashboard td {
                        white-space: nowrap; word-break: normal; overflow: hidden; vertical-align: middle;
                    }
                    #dhcpDashboard td.dd-truncate { max-width: 200px; text-overflow: ellipsis; }
                    #dhcpDashboard .dd-sortable { cursor: pointer; user-select: none; }
                    #dhcpDashboard .dd-message { padding: 10px; text-align: center; }
                </style>
                <div class="dd-message" id="dhcpDashboardMessage" style="display:none;"></div>
                <div class="dd-table-wrap" id="dhcpDashboardTableWrap" style="display:none;">
                    <table class="table table-striped table-condensed">
                        <thead><tr id="dhcpDashboardHead"></tr></thead>
                        <tbody id="dhcpDashboardBody"></tbody>
                    </table>
                </div>
            </div>
        `);
    }

    async onMarkupRendered() {
        $('#dhcpDashboard').on('click', '.dd-sortable', event => {
            const key = $(event.currentTarget).data('sort');
            // Same column: reverse order, new column: ascending
            this.sortAsc = (key === this.sortKey) ? !this.sortAsc : true;
            this.sortKey = key;
            this.renderLeases();
        });
    }

    async getWidgetOptions() {
        return {
            showIpv6: {
                id: 'showIpv6',
                title: this.translations.showipv6,
                type: 'select',
                options: [
                    { value: 'no', label: this.translations.no },
                    { value: 'yes', label: this.translations.yes }
                ],
                default: 'no',
                required: true
            },
            columns: {
                id: 'columns',
                title: this.translations.columns,
                type: 'select_multiple',
                options: this.columns.map(col => ({ value: col.key, label: this.translations[col.label] })),
                default: this.columns.map(col => col.key),
                required: true
            }
        };
    }

    async onWidgetOptionsChanged() {
        this.configChanged = true;
        await this.onWidgetTick();
    }

    async onWidgetTick() {
        const config = await this.getWidgetConfig();
        const families = config.showIpv6 === 'yes' ? ['v4', 'v6'] : ['v4'];

        // Keep the column order of this.columns; an empty or invalid selection shows every column
        const selected = Array.isArray(config.columns) ? config.columns : [];
        const visible = this.columns.filter(col => selected.includes(col.key));
        this.visibleColumns = visible.length > 0 ? visible : this.columns;

        // Query every backend in parallel, each fetcher returns null when the server is not running
        const results = await Promise.all([
            ...families.map(family => this.fetchIsc(family)),
            ...families.map(family => this.fetchKea(family)),
            this.fetchDnsmasq(families)
        ]);

        const activeBackends = results.filter(result => result !== null);
        if (activeBackends.length === 0) {
            this.showMessage(this.translations.nobackend);
            return;
        }

        const leases = activeBackends.flat();
        await this.resolveOnlineStatus(leases);
        leases.forEach(lease => this.resolveManufacturer(lease));

        if (!this.dataChanged('leases', leases) && !this.configChanged) {
            return;
        }
        this.configChanged = false;

        if (leases.length === 0) {
            this.showMessage(this.translations.noleases);
            return;
        }

        this.leases = leases;
        this.renderLeases();
    }

    /* ---------- Backend fetchers ---------- */

    /**
     * ISC DHCP: only "active" leases are kept (static mappings are reported as active too)
     */
    async fetchIsc(family) {
        const service = family === 'v4' ? 'dhcpv4' : 'dhcpv6';
        const status = await this.safeAjax(`/api/${service}/service/status`);
        if (status?.status !== 'running') {
            return null;
        }

        const response = await this.safeAjax(`/api/${service}/leases/search_lease`, { rowCount: -1 });
        return (response?.rows ?? [])
            .filter(row => row.state === 'active' && row.address)
            .map(row => ({
                ip: row.address,
                family: family,
                hostname: row.hostname ?? '',
                mac: row.mac ?? '',
                manufacturer: row.man ?? '',
                iface: row.if_descr ?? '',
                type: row.type === 'static' ? 'static' : 'dynamic',
                source: 'ISC',
                online: row.status === 'online'
            }));
    }

    /**
     * Kea DHCP: state 0 means "default" (active), other states are declined or expired
     */
    async fetchKea(family) {
        const settings = await this.safeAjax(`/api/kea/dhcp${family}/get`);
        if (settings?.[`dhcp${family}`]?.general?.enabled !== '1') {
            return null;
        }

        const endpoint = family === 'v4' ? 'leases4' : 'leases6';
        const response = await this.safeAjax(`/api/kea/${endpoint}/search`, { rowCount: -1 });
        return (response?.rows ?? [])
            .filter(row => Number(row.state) === 0 && row.address)
            .map(row => ({
                ip: row.address,
                family: family,
                hostname: (row.hostname ?? '').replace(/\.$/, ''),
                mac: row.hwaddr ?? '',
                manufacturer: row.mac_info ?? '',
                iface: row.if_descr ?? '',
                type: row.lease_type === 'static' ? 'static' : 'dynamic',
                source: 'Kea',
                online: null
            }));
    }

    /**
     * Dnsmasq DHCP: one endpoint returns both families, expire 0 means infinite lease
     */
    async fetchDnsmasq(families) {
        const settings = await this.safeAjax('/api/dnsmasq/settings/get');
        if (settings?.dnsmasq?.enable !== '1') {
            return null;
        }

        const response = await this.safeAjax('/api/dnsmasq/leases/search', { rowCount: -1 });
        const now = Math.floor(Date.now() / 1000);
        return (response?.rows ?? [])
            .filter(row => row.address && (Number(row.expire) === 0 || Number(row.expire) > now))
            .map(row => ({
                ip: row.address,
                family: row.address.includes(':') ? 'v6' : 'v4',
                hostname: row.hostname === '*' ? '' : (row.hostname ?? ''),
                mac: row.hwaddr ?? '',
                manufacturer: row.mac_info ?? '',
                iface: row.if_descr ?? '',
                type: row.lease_type === 'static' ? 'static' : 'dynamic',
                source: 'Dnsmasq',
                online: null
            }))
            .filter(lease => families.includes(lease.family));
    }

    /**
     * Kea and Dnsmasq do not report presence: look the address up in the ARP (v4) or NDP (v6) table.
     * Tables are only fetched when needed. If not readable, the status stays unknown (null).
     * ARP/NDP entries also carry a manufacturer, used to fill the gaps of the lease data.
     */
    async resolveOnlineStatus(leases) {
        const pending = leases.filter(lease => lease.online === null || !lease.manufacturer);
        if (pending.length === 0) {
            return;
        }

        const needArp = pending.some(lease => lease.family === 'v4');
        const needNdp = pending.some(lease => lease.family === 'v6');
        const [arp, ndp] = await Promise.all([
            needArp ? this.safeAjax('/api/diagnostics/interface/get_arp') : null,
            needNdp ? this.safeAjax('/api/diagnostics/interface/get_ndp') : null
        ]);

        // Index neighbour tables by IP (presence) and by MAC (vendor)
        const index = (table, skipExpired) => {
            if (!Array.isArray(table)) {
                return null;
            }
            const result = { ips: new Set(), vendors: new Map() };
            table.forEach(entry => {
                if (entry.manufacturer && entry.mac) {
                    result.vendors.set(String(entry.mac).toLowerCase(), entry.manufacturer);
                }
                if (!(skipExpired && entry.expired)) {
                    result.ips.add(String(entry.ip).toLowerCase());
                }
            });
            return result;
        };
        const neighbours = { v4: index(arp, true), v6: index(ndp, false) };

        pending.forEach(lease => {
            const known = neighbours[lease.family];
            if (known === null) {
                return;
            }
            if (lease.online === null) {
                lease.online = known.ips.has(lease.ip.toLowerCase());
            }
            if (!lease.manufacturer && lease.mac) {
                lease.manufacturer = known.vendors.get(lease.mac.toLowerCase()) ?? '';
            }
        });
    }

    /**
     * Random / private MAC addresses (locally administered bit set) have no registered vendor:
     * label them instead of leaving the manufacturer empty
     */
    resolveManufacturer(lease) {
        lease.randomMac = false;
        if (!lease.manufacturer && DhcpDashboard.isRandomMac(lease.mac)) {
            lease.manufacturer = this.translations.randommac;
            lease.randomMac = true;
        }
    }

    /* ---------- Sorting ---------- */

    compareLeases(a, b) {
        const key = this.sortKey;
        let result;

        if (key === 'ip') {
            result = DhcpDashboard.ipSortKey(a.ip).localeCompare(DhcpDashboard.ipSortKey(b.ip));
        } else if (key === 'online') {
            // online, then offline, then unknown
            const rank = value => value === true ? 0 : (value === false ? 1 : 2);
            result = rank(a.online) - rank(b.online);
        } else {
            const valueA = String(a[key] ?? '');
            const valueB = String(b[key] ?? '');
            // Empty values always at the end, whatever the direction
            if (valueA === '' || valueB === '') {
                return (valueA === '') - (valueB === '') ||
                    DhcpDashboard.ipSortKey(a.ip).localeCompare(DhcpDashboard.ipSortKey(b.ip));
            }
            result = valueA.localeCompare(valueB, undefined, { numeric: true, sensitivity: 'base' });
        }

        if (!this.sortAsc) {
            result = -result;
        }
        // Stable tie-break on IP address
        return result || DhcpDashboard.ipSortKey(a.ip).localeCompare(DhcpDashboard.ipSortKey(b.ip));
    }

    /* ---------- Rendering ---------- */

    renderLeases() {
        const t = this.translations;
        const esc = DhcpDashboard.escapeHtml;
        const columns = this.visibleColumns;

        // A hidden column cannot stay the sort column: fall back to the first visible one
        if (!columns.some(col => col.key === this.sortKey)) {
            this.sortKey = columns[0].key;
            this.sortAsc = true;
        }
        const leases = [...this.leases].sort((a, b) => this.compareLeases(a, b));

        // Header, with the sort indicator on the active column
        const header = columns.map(col => {
            const icon = col.key !== this.sortKey ? '' : (this.sortAsc ? 'fa-sort-asc' : 'fa-sort-desc');
            return `<th class="dd-sortable ${col.center ? 'text-center' : ''}" data-sort="${col.key}">` +
                `${t[col.label]} <i class="fa fa-fw ${icon}"></i></th>`;
        }).join('');

        const rows = leases.map(lease => {
            let statusIcon = `<i class="fa fa-question text-muted" title="${t.unknown}" data-toggle="tooltip"></i>`;
            if (lease.online === true) {
                statusIcon = `<i class="fa fa-signal text-success" title="${t.online}" data-toggle="tooltip"></i>`;
            } else if (lease.online === false) {
                statusIcon = `<i class="fa fa-ban text-danger" title="${t.offline}" data-toggle="tooltip"></i>`;
            }

            // Plain text value per column (also used as tooltip of truncated cells) and its HTML rendering
            const text = {
                ip: lease.ip,
                hostname: lease.hostname,
                mac: lease.mac,
                manufacturer: lease.manufacturer,
                iface: lease.iface,
                type: lease.type === 'static' ? t.static : t.dynamic,
                source: lease.source
            };
            const html = {
                manufacturer: lease.randomMac ? `<em class="text-muted">${esc(lease.manufacturer)}</em>` : null,
                online: statusIcon
            };

            const cells = columns.map(col => {
                const content = html[col.key] ?? esc(text[col.key]);
                const classes = [col.center ? 'text-center' : '', col.truncate ? 'dd-truncate' : ''].join(' ').trim();
                const title = col.truncate && text[col.key] ? ` title="${esc(text[col.key])}"` : '';
                return `<td class="${classes}"${title}>${content}</td>`;
            });
            return `<tr>${cells.join('')}</tr>`;
        });

        $('#dhcpDashboard [data-toggle="tooltip"]').tooltip('hide');
        $('#dhcpDashboardMessage').hide();
        $('#dhcpDashboardHead').html(header);
        $('#dhcpDashboardBody').html(rows.join(''));
        $('#dhcpDashboardTableWrap').show();
        $('#dhcpDashboard [data-toggle="tooltip"]').tooltip({ container: 'body' });
    }

    showMessage(message) {
        this.cachedData = {};
        this.leases = [];
        $('#dhcpDashboardTableWrap').hide();
        $('#dhcpDashboardMessage').text(message).show();
    }

    /* ---------- Helpers ---------- */

    /**
     * Silent API call: resolves to null on any error.
     * "global: false" keeps the error out of the OPNsense global ajaxError handler, which would
     * otherwise pop up "Endpoint not found" for every backend that is not installed.
     * The CSRF header is still added by the $.ajaxSetup() defaults.
     */
    safeAjax(url, postData = null) {
        return new Promise(resolve => {
            $.ajax({
                url: url,
                type: postData === null ? 'GET' : 'POST',
                dataType: 'json',
                contentType: 'application/json',
                data: postData === null ? undefined : JSON.stringify(postData),
                timeout: this.timeoutPeriod,
                global: false,
                success: response => resolve(response),
                error: () => resolve(null)
            });
        });
    }

    /**
     * Locally administered MAC: second hex digit of the first octet is 2, 6, A or E
     */
    static isRandomMac(mac) {
        return /^[0-9a-f][26ae]/i.test(String(mac ?? ''));
    }

    /**
     * Sortable key: IPv4 first ("4" + zero padded octets), then IPv6 ("6" + fully expanded groups)
     */
    static ipSortKey(ip) {
        const address = String(ip).split('%')[0];
        if (!address.includes(':')) {
            return '4' + address.split('.').map(octet => octet.padStart(3, '0')).join('.');
        }

        const [head, tail] = address.split('::');
        const headGroups = head ? head.split(':') : [];
        const tailGroups = tail ? tail.split(':') : [];
        const fill = tail === undefined ? [] : Array(8 - headGroups.length - tailGroups.length).fill('0');
        return '6' + [...headGroups, ...fill, ...tailGroups].map(group => group.padStart(4, '0')).join(':');
    }

    /**
     * Hostnames and vendors come from client / database data: never inject them as raw HTML
     */
    static escapeHtml(value) {
        return String(value ?? '').replace(/[&<>"']/g, char => ({
            '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
        })[char]);
    }
}
