# Free and self-built GEOIP Database for Opnsense (maxmind format)

## Tonton Jo  
### Join the community:
[![Youtube](https://badgen.net/badge/Youtube/Subscribe)](http://youtube.com/channel/UCnED3K6K5FDUp-x_8rwpsZw?sub_confirmation=1)
[![Discord Tonton Jo](https://badgen.net/discord/members/h6UcpwfGuJ?label=Discord%20Tonton%20Jo%20&icon=discord)](https://discord.gg/h6UcpwfGuJ)
### Support my work, give a thanks and help the youtube channel:
[![Ko-Fi](https://badgen.net/badge/Buy%20me%20a%20Coffee/Link?icon=buymeacoffee)](https://ko-fi.com/tontonjo)
[![Infomaniak](https://badgen.net/badge/Infomaniak/Affiliated%20link?icon=K)](https://www.infomaniak.com/goto/fr/home?utm_term=6151f412daf35)

<img width="440" height="175" alt="image" src="https://github.com/user-attachments/assets/eaf4c7a7-616e-4f1a-b15f-582be762ea7c" /> <img width="312" height="175" alt="image" src="https://github.com/user-attachments/assets/dc16df01-9a59-4f8a-bc44-9f1750a7b26c" />


This document describes how the zip produced by `geoizip.ps1` is built and how OPNsense reads it for GeoIP aliases.

This database is built exclusively from the primary sources: the public statistics files published by the five Regional Internet Registries (ARIN, RIPE NCC, APNIC, LACNIC, AFRINIC).
 
> **Independence notice**
> It has no link with MaxMind: no MaxMind data, account, license key, software or service is used at any stage.
> The "GeoLite2" file names are kept only because OPNsense expects this naming convention. They describe a file layout, not the origin of the data.

The file is [build daily](https://github.com/Tontonjo/opnsense/blob/main/.github/workflows/update-geoip.yml) from sources and is [available here](https://github.com/Tontonjo/opnsense/releases/download/geoip/geoip.zip)

[Protip](https://docs.opnsense.org/manual/aliases.html#aliases):
Geo IP lists can be rather large, especially when using IPv6. When creating rules, always try to minimize the number of addresses needed in your selection. A selection of all countries in the world not being the Netherlands can usually be rewritten as only addresses from the Netherlands for example.

# Plugin
A plugin for opnsense is available here, not tested.
https://github.com/Tontonjo/opnsense-os-rir-geoip

## Guide d'utilisation

**PowerShell (Windows)**
- Générer le zip : `.\geoizip.ps1 -OutputDirectory C:\GeoIP`
- Tester une IP : `.\geoizip.ps1 -TestIp 8.8.8.8 -ZipPath C:\GeoIP\geoip.zip`
- Si l'exécution est bloquée : `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass`

**Bash (Linux)**
- Prérequis : `curl`, `awk`, `zip`, `unzip`, puis `chmod +x geoizip.sh`
- Générer le zip : `./geoizip.sh -o /var/www/geoip`
- Tester une IP : `./geoizip.sh -t 8.8.8.8 -z /var/www/geoip/geoip.zip`

**OPNsense**
1. Publiez `geoip.zip` sur un serveur web accessible par le pare-feu.
2. Saisissez son URL dans Firewall > Aliases > GeoIP settings, puis cliquez sur Apply.
3. Créez un alias de type GeoIP avec les pays souhaités et utilisez-le dans vos règles.
4. Régénérez le zip régulièrement (tâche planifiée Windows ou cron), les données RIR étant mises à jour chaque jour.
