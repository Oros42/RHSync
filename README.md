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
./RHSync.sh sync
```