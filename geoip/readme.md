# Free and self-built GEOIP Database
 
Version: 1.1.0
Related script: `Build-OpnsenseGeoIpZip.ps1` (version 1.1.0)
 
This document describes how the zip produced by `Build-OpnsenseGeoIpZip.ps1` is built and how OPNsense reads it for GeoIP aliases.

This database is built exclusively from the primary sources: the public statistics files published by the five Regional Internet Registries (ARIN, RIPE NCC, APNIC, LACNIC, AFRINIC).
 
> **Independence notice**
> It has no link with MaxMind: no MaxMind data, account, license key, software or service is used at any stage.
> The "GeoLite2" file names are kept only because OPNsense expects this naming convention. They describe a file layout, not the origin of the data.

This file is not yet regulary updated
