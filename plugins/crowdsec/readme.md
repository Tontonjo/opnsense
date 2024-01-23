# Crowdsec installation and management

### Install the whitelist for local ip's
- Update
```ssh
cscli update
```
- Install
```ssh
cscli parsers install crowdsecurity/whitelists
```
- Check the list
```ssh
cat "/usr/local/etc/crowdsec/hub/parsers/s02-enrich/crowdsecurity/whitelists.yaml"
```

## Management
