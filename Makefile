# os-dhcp-dashboard - Version: 1.2.0
# Build inside an opnsense/plugins checkout (e.g. plugins/net/dhcp-dashboard): make package
PLUGIN_NAME=		dhcp-dashboard
PLUGIN_VERSION=		1.2.0
PLUGIN_COMMENT=		Dashboard widget showing ISC, Kea and Dnsmasq DHCP leases
PLUGIN_MAINTAINER=	N/A
PLUGIN_NO_ABI=		yes

.include "../../Mk/plugins.mk"
