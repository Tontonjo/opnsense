/*
 * os-dhcp-dashboard - DHCP leases widget for the OPNsense dashboard
 * Version: 1.0.0
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
 * Normalized lease record used by the renderer:
 * {
 *   ip:       string   IPv4 or IPv6 address
 *   family:   'v4'|'v6'
 *   hostname: string
 *   mac:      string
 *   iface:    string   interface description
 *   type:     'dynamic'|'static'
 *   source:   'ISC'|'Kea'|'Dnsmasq'
 *   online:   true|false|null (null = unknown, resolved through ARP/NDP)
 * }
 */

export default class DhcpDashboard extends BaseWidget {
    constructor(config) {
        super(config);
        this.configurable = true;
        this.configChanged = false;
        // Lease lookups trigger several backend scripts, no need to poll every 10s
        this.tickTimeout = 30;
    }

    getGridOptions() {
        return {
            // Scrollbar appears once the content exceeds 650px
            sizeToContent: 650
        };
    }

    getMarkup() {
        const t = this.translations;
        return $(`
            <div class="dhcp-dashboard" id="dhcpDashboard">
                <style>
                    #dhcpDashboard .dd-table-wrap { overflow-x: auto; }
                    #dhcpDashboard table { margin-bottom: 0; }
                    #dhcpDashboard td, #dhcpDashboard th { white-space: nowrap; }
                    #dhcpDashboard .dd-message { padding: 10px; text-align: center; }
                    #dhcpDashboard.dd-narrow .dd-col-optional { display: none; }
                    #dhcpDashboard.dd-very-narrow .dd-col-mac { display: none; }
                </style>
                <div class="dd-message" id="dhcpDashboardMessage" style="display:none;"></div>
                <div class="dd-table-wrap" id="dhcpDashboardTableWrap" style="display:none;">
                    <table class="table table-striped table-condensed">
                        <thead>
                            <tr>
                                <th>${t.ipaddress}</th>
                                <th>${t.hostname}</th>
                                <th class="dd-col-mac">${t.mac}</th>
                                <th class="dd-col-optional">${t.interface}</th>
                                <th>${t.leasetype}</th>
                                <th class="dd-col-optional">${t.source}</th>
                                <th class="text-center">${t.status}</th>
                            </tr>
                        </thead>
                        <tbody id="dhcpDashboardBody"></tbody>
                    </table>
                </div>
            </div>
        `);
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
            }
        };
    }

    async onWidgetOptionsChanged() {
        this.configChanged = true;
        await this.onWidgetTick();
    }

    onWidgetResize(elem, width, height) {
        // Hide the less important columns on small widgets
        $('#dhcpDashboard')
            .toggleClass('dd-narrow', width < 520)
            .toggleClass('dd-very-narrow', width < 380);
        return true;
    }

    async onWidgetTick() {
        const config = await this.getWidgetConfig();
        const families = config.showIpv6 === 'yes' ? ['v4', 'v6'] : ['v4'];

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
        leases.sort((a, b) => DhcpDashboard.ipSortKey(a.ip).localeCompare(DhcpDashboard.ipSortKey(b.ip)));

        if (!this.dataChanged('leases', leases) && !this.configChanged) {
            return;
        }
        this.configChanged = false;

        if (leases.length === 0) {
            this.showMessage(this.translations.noleases);
            return;
        }

        this.renderLeases(leases);
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

        const response = await this.safeAjax(`/api/${service}/leases/search_lease`, JSON.stringify({ rowCount: -1 }), 'POST');
        return (response?.rows ?? [])
            .filter(row => row.state === 'active' && row.address)
            .map(row => ({
                ip: row.address,
                family: family,
                hostname: row.hostname ?? '',
                mac: row.mac ?? '',
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
        const response = await this.safeAjax(`/api/kea/${endpoint}/search`, JSON.stringify({ rowCount: -1 }), 'POST');
        return (response?.rows ?? [])
            .filter(row => Number(row.state) === 0 && row.address)
            .map(row => ({
                ip: row.address,
                family: family,
                hostname: (row.hostname ?? '').replace(/\.$/, ''),
                mac: row.hwaddr ?? '',
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

        const response = await this.safeAjax('/api/dnsmasq/leases/search', JSON.stringify({ rowCount: -1 }), 'POST');
        const now = Math.floor(Date.now() / 1000);
        return (response?.rows ?? [])
            .filter(row => row.address && (Number(row.expire) === 0 || Number(row.expire) > now))
            .map(row => ({
                ip: row.address,
                family: row.address.includes(':') ? 'v6' : 'v4',
                hostname: row.hostname === '*' ? '' : (row.hostname ?? ''),
                mac: row.hwaddr ?? '',
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
     */
    async resolveOnlineStatus(leases) {
        const pending = leases.filter(lease => lease.online === null);
        if (pending.length === 0) {
            return;
        }

        const needArp = pending.some(lease => lease.family === 'v4');
        const needNdp = pending.some(lease => lease.family === 'v6');
        const [arp, ndp] = await Promise.all([
            needArp ? this.safeAjax('/api/diagnostics/interface/get_arp') : null,
            needNdp ? this.safeAjax('/api/diagnostics/interface/get_ndp') : null
        ]);

        const toIpSet = (table, skipExpired) => Array.isArray(table)
            ? new Set(table.filter(entry => !(skipExpired && entry.expired)).map(entry => String(entry.ip).toLowerCase()))
            : null;
        const neighbours = { v4: toIpSet(arp, true), v6: toIpSet(ndp, false) };

        pending.forEach(lease => {
            const known = neighbours[lease.family];
            if (known !== null) {
                lease.online = known.has(lease.ip.toLowerCase());
            }
        });
    }

    /* ---------- Rendering ---------- */

    renderLeases(leases) {
        const t = this.translations;
        const esc = DhcpDashboard.escapeHtml;

        const rows = leases.map(lease => {
            let statusIcon = `<i class="fa fa-question text-muted" title="${t.unknown}" data-toggle="tooltip"></i>`;
            if (lease.online === true) {
                statusIcon = `<i class="fa fa-signal text-success" title="${t.online}" data-toggle="tooltip"></i>`;
            } else if (lease.online === false) {
                statusIcon = `<i class="fa fa-ban text-danger" title="${t.offline}" data-toggle="tooltip"></i>`;
            }

            return `
                <tr>
                    <td>${esc(lease.ip)}</td>
                    <td>${esc(lease.hostname)}</td>
                    <td class="dd-col-mac">${esc(lease.mac)}</td>
                    <td class="dd-col-optional">${esc(lease.iface)}</td>
                    <td>${lease.type === 'static' ? t.static : t.dynamic}</td>
                    <td class="dd-col-optional">${esc(lease.source)}</td>
                    <td class="text-center">${statusIcon}</td>
                </tr>
            `;
        });

        $('#dhcpDashboard [data-toggle="tooltip"]').tooltip('hide');
        $('#dhcpDashboardMessage').hide();
        $('#dhcpDashboardBody').html(rows.join(''));
        $('#dhcpDashboardTableWrap').show();
        $('#dhcpDashboard [data-toggle="tooltip"]').tooltip({ container: 'body' });
    }

    showMessage(message) {
        this.cachedData = {};
        $('#dhcpDashboardTableWrap').hide();
        $('#dhcpDashboardMessage').text(message).show();
    }

    /* ---------- Helpers ---------- */

    /**
     * Wrapper around ajaxCall: a missing backend (plugin not installed, no ACL) resolves to null
     */
    async safeAjax(url, data = {}, method = 'GET') {
        try {
            return await this.ajaxCall(url, data, method);
        } catch (error) {
            return null;
        }
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
     * Hostnames are provided by DHCP clients: never inject them as raw HTML
     */
    static escapeHtml(value) {
        return String(value ?? '').replace(/[&<>"']/g, char => ({
            '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
        })[char]);
    }
}
