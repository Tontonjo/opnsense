# Free and self-built GEOIP Database


<img width="440" height="175" alt="image" src="https://github.com/user-attachments/assets/eaf4c7a7-616e-4f1a-b15f-582be762ea7c" />
 
This document describes how the zip produced by `Build-OpnsenseGeoIpZip.ps1` is built and how OPNsense reads it for GeoIP aliases.

This database is built exclusively from the primary sources: the public statistics files published by the five Regional Internet Registries (ARIN, RIPE NCC, APNIC, LACNIC, AFRINIC).
 
> **Independence notice**
> It has no link with MaxMind: no MaxMind data, account, license key, software or service is used at any stage.
> The "GeoLite2" file names are kept only because OPNsense expects this naming convention. They describe a file layout, not the origin of the data.

This file is not yet regulary updated



## Guide d'utilisation

**PowerShell (Windows)**
- Générer le zip : `.\Build-OpnsenseGeoIpZip.ps1 -OutputDirectory C:\GeoIP`
- Tester une IP : `.\Build-OpnsenseGeoIpZip.ps1 -TestIp 8.8.8.8 -ZipPath C:\GeoIP\GeoLite2-Country-CSV.zip`
- Si l'exécution est bloquée : `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass`

**Bash (Linux)**
- Prérequis : `curl`, `awk`, `zip`, `unzip`, puis `chmod +x build-opnsense-geoip-zip.sh`
- Générer le zip : `./build-opnsense-geoip-zip.sh -o /var/www/geoip`
- Tester une IP : `./build-opnsense-geoip-zip.sh -t 8.8.8.8 -z /var/www/geoip/GeoLite2-Country-CSV.zip`

**OPNsense**
1. Publiez `GeoLite2-Country-CSV.zip` sur un serveur web accessible par le pare-feu.
2. Saisissez son URL dans Firewall > Aliases > GeoIP settings, puis cliquez sur Apply.
3. Créez un alias de type GeoIP avec les pays souhaités et utilisez-le dans vos règles.
4. Régénérez le zip régulièrement (tâche planifiée Windows ou cron), les données RIR étant mises à jour chaque jour.
