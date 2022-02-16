# ses-courses-image-builder
A script to build an image that runs a node webserver with mysql.

## Requirements
A GNU linux machine (preferably debian based) with the basic toolchain and the following tools:
- bash
- curl
- debootstrap
- md5sum

In addition, the script expects:
- A directory named `ses-courses-api` with the full server (frontends, media, configs and all)
- A file named `dbinit.sql` with a full initialization of the database (including users)

## Usage

Just run the `build.sh` script:
```sh
./build.sh
```

If a chroot directory does not exist, this will create a chroot directory and install a full system into it.

In any case, it will initialize the database, copy the server, and create a service to run it.
