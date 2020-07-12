# RHSync
The Remote HTTP Synchronization

## Install

```bash
sudo apt install parallel gpg curl wget
cp config.dist config
nano config
```


## If you host the node 0

### Create a PGP key for sign your release

```bash
./RHSync.sh keygen
```
/!\ gpg-agent open a window to let you enter your password.
So you need a display :-/

### Create a release
```bash
./RHSync.sh index
./RHSync.sh release
```


## If you host a clone

```bash
./RHSync.sh index
./RHSync.sh sync
```


## Help

```bash
$ ./RHSync.sh 
Remote HTTP Synchronization
Usage: RHSync.sh [OPTION] ACTION [wwwDir]

Actions:
sync		Synchronization
index		Create new hash index (Contents.gz)
release		Create new release (Release.gz + ReleaseInfos)
keygen		Generate a PGP key used to sign Release.gz and ReleaseInfos

Options:
-c, --config	Path to the config file
-h, --help		Help
--refreshkeys	[1|0] 1: Refresh PGP key, 0: skip the refresh

wwwDir: Path to the www directory

Examples:
./RHSync.sh sync
./RHSync.sh -c myConf1 sync
./RHSync.sh -c myConf1 --refreshkeys 0 sync
./RHSync.sh index /var/www/mySite
./RHSync.sh release /var/www/mySite
```