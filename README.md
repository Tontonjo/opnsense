#  Opensense
Scripts and files usefull for Opensense

## Tonton Jo  
### Join the community:
[![Youtube](https://badgen.net/badge/Youtube/Subscribe)](http://youtube.com/channel/UCnED3K6K5FDUp-x_8rwpsZw?sub_confirmation=1)
[![Discord Tonton Jo](https://badgen.net/discord/members/h6UcpwfGuJ?label=Discord%20Tonton%20Jo%20&icon=discord)](https://discord.gg/h6UcpwfGuJ)
### Support my work, give a thanks and help the youtube channel:
[![Ko-Fi](https://badgen.net/badge/Buy%20me%20a%20Coffee/Link?icon=buymeacoffee)](https://ko-fi.com/tontonjo)
[![Infomaniak](https://badgen.net/badge/Infomaniak/Affiliated%20link?icon=K)](https://www.infomaniak.com/goto/fr/home?utm_term=6151f412daf35)
[![Express VPN](https://badgen.net/badge/Express%20VPN/Affiliated%20link?icon=K)](https://www.xvuslink.com/?a_fid=TontonJo)  

### DHCP Leases Widget  
#### Sources:  
[jbaconsult](https://github.com/jbaconsult/opnsense_stuff/blob/main/dhcp_leases.widget.php)  
[bobbyearl](https://github.com/bobbyearl/pfSense-DHCP-leases-widget/blob/master/DHCP_leases.widget.php)  
### Installation:
- Put [dHCP_leases.widget.php](https://github.com/Tontonjo/opnsense/blob/main/usr/local/www/widgets/widgets/dHCP_leases.widget.php) in /usr/local/www/widgets/widgets/
```shell
pkg install wget
```
```shell
wget -qO /usr/local/www/widgets/widgets/dHCP_leases.widget.php https://raw.githubusercontent.com/Tontonjo/opnsense/main/usr/local/www/widgets/widgets/dHCP_leases.widget.php
```
- Add widget trough Opnsense GUI

### To do: But i dont know how:
- DONE: Mask expired Leases (wich i find useless)
- DONE: Add a MAC address row wich can be usefull to identify a device
