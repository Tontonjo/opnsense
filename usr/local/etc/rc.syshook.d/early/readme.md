# 

## ifacerename 
This script is intended to rename interfaces of opnsense
It's especially usefull when your device has wrongly mapped port numbers.

### Usage:
Make a backup of your configurations (you never know)
Get the script and place it in the correct folder.
edit the script variables $newname and $oldname to fit your needs.
Save the file
make it executable
```shell
chmod +x "/usr/local/etc/rc.syshook.d/early/99-ifacerename"
```

Edit your configuration.xml in "/conf/config.xml"
- I'd suggest you to use a find and remplace tool to find every mention in the config file.

Save - reboot - check







