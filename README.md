# ses-courses-installer
An idempotent script to install the ses-courses server on a devuan machine.

## Requirements
A GNU linux devuan machine with the basic toolchain and the following tools:
- bash
- curl

In addition, the script expects:
- An existing user named `ses` with a home directory in `/home/ses/`
- A directory named `ses-courses-api` with the full server (frontends, media, configs and all)
- A file named `dbinit.sql` with a full initialization of the database (including users)
- A working network connection

## Usage
Just run the `install.sh` script:
```sh
./install.sh
```
