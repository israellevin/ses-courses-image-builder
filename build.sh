#!/usr/bin/bash -eu
# Builds an SES courses image.
chroot_dir=./chroot
chroot_user=ses
chroot_home="home/$chroot_user"
mysql_package=https://downloads.mysql.com/archives/get/p/23/file/mysql-server_8.0.23-1debian10_amd64.deb-bundle.tar
mysql_package_md5sum=32bc0153e844ffec559b862a9191eefa
db_init=dbinit.sql
api_server=ses-courses-api
node_version=10.16.3
server_port=5500

cd "$(dirname "${BASH_SOURCE[0]}")"

create_chroot(){(
    mkdir "$chroot_dir"
    cd "$chroot_dir"
    debootstrap --arch=amd64 --variant=minbase stable .
    chroot . useradd "$chroot_user" -m

    # Configure apt.
    echo 'APT::Install-Recommends "0";' > etc/apt/apt.conf.d/10no-recommends
    echo 'APT::Install-Suggests "0";' > etc/apt/apt.conf.d/10no-suggests
    cat > etc/apt/sources.list <<EOF
deb http://deb.devuan.org/merged stable main
deb http://deb.devuan.org/merged stable-security main
deb http://deb.devuan.org/merged stable-updates main
EOF
    chroot . apt update

    # Prepare mysql packages.
    [ -f ../mysql.tar ] || curl -sL "$mysql_package" > ../mysql.tar
    if ! md5sum ../mysql.tar | grep "$mysql_package_md5sum"; then
        echo 'Can not get correct mysql version, aborting'
        return 1
    fi
    tar xf ../mysql.tar
    rm mysql-*test*.deb
    rm mysql-*debug*.deb

    # Install packages without running any services.
    echo exit 101 > usr/sbin/policy-rc.d
    DEBIAN_FRONTEND=noninteractive chroot . apt -y install -f linux-image-amd64 grub-pc cron locales \
        ca-certificates curl dhcpcd5 iproute2 netbase openssh-server
    DEBIAN_FRONTEND=noninteractive chroot . apt -y install -f ./*.deb
    rm *.deb usr/sbin/policy-rc.d
    chroot . apt clean

    # Generate locale.
    echo en_US.UTF-8 UTF-8 > etc/locale.gen
    chroot . locale-gen

    # Install current LTS node version to install the right node version.
    curl -s https://nodejs.org/dist/v16.13.0/node-v16.13.0-linux-x64.tar.xz | tar -Jx
    PATH="node-v16.13.0-linux-x64/bin:$PATH" chroot . npm install --global npm@latest n@latest
    PATH="node-v16.13.0-linux-x64/bin:$PATH" chroot . n $node_version
    rm -rf node-v16.13.0-linux-x64/bin
)}
# Create and install a chroot environment if needed.
[ -d "$chroot_dir" ] || create_chroot

## Initialize the database.
chroot "$chroot_dir" service mysql start
chroot "$chroot_dir" mysql < "$dbinit"
chroot "$chroot_dir" service mysql stop

## Copy frontends and media to the server, and the server to the chroot.
cp -a "$api_server" "$chroot_dir/$chroot_home/."

# Create a service to start the server.
service_file="$chroot_dir/etc/init.d/ses-courses"
cat > "$service_file" <<'EOF'
### BEGIN INIT INFO
# Provides: ses-courses
# Required-Start: $remote_fs $syslog
# Required-Stop: $remote_fs $syslog
# Default-Start: 2 3 4 5
# Default-Stop: 0 1 6
# Short-Description: SES courses system
### END INIT INFO
set -e
. /lib/lsb/init-functions
EOF
# Inject some variables to the service script - this part goes through variable expansion.
cat >> "$service_file" <<EOF
courses_home='/$chroot_home/$api_server'
courses_user='$chroot_user'
EOF
# Continue with the service script - no more variable expansion.
cat >> "$service_file" <<'EOF'
case "$1" in
    reload)
        log_daemon_msg "SES courses service loading"
        load=1
        ;;
    start)
        log_daemon_msg "SES courses service starting"
        load=1
        start=1
        ;;
    stop)
        log_daemon_msg "SES courses service stopping"
        stop=1
        ;;
    status)
        log_daemon_msg "SES courses service fetching status"
        ;;
    restart)
        stop=1
        start=1
        ;;
    *)
        echo "usage: $0 {start|stop|status|restart|reload}"
        log_daemon_msg "SES courses service got unknown command $@"
        log_end_msg 1
esac

get_ip(){
    ip addr show dev eth0 | grep -Po '(?<=inet )[^/ ]*'
}

connect(){
    get_ip && return 0
    log_progress_msg 'connecting to network.'
    pkill dhclient
    ip link set eth0 down
    ip link set eth0 up
    dhclient eth0
}

if [ "$load" ]; then
    connect
    # Try to mount USB drive and write ip.
    mount_point=/mnt
    if mount /dev/sdb1 "$mount_point" 2> /dev/null; then
        log_progress_msg 'writing index.html to external drive.'
        cat > "$mount_point/index.html" <<EOHTML
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>SES Index</title>
</head>
<body>
    <a href="http://$(get_ip)">
</body>
</html>
EOHTML
        umount "$mount_point"
    fi
fi

ssd="start-stop-daemon --quiet --pidfile=/tmp/ses-courses.pid --chdir '$courses_home' --chuid '$courses_user'"
log="$courses_home/server.log"

if [ "$stop" ]; then
        $ssd --stop && log_progress_msg 'server stopped.' || log_end_msg $?
        sleep 1
fi

if [ "$start" ]; then
        $ssd --start --background --make-pidfile --exec /usr/local/bin/node -- index.js >> "$log" 2>&1 \
            && log_progress_msg 'server started.' || log_end_msg $?
fi

$ssd --status && log_progress_msg 'all running' || log_progress_msg 'all stopped'
log_end_msg $?
EOF

# Set up the service (with a cron job).
chmod +x "$service_file"
chroot "$chroot_dir" update-rc.d ses-courses defaults
echo '* * * * * sh -c "service ses-courses status || service ses-courses start"' | chroot "$chroot_dir" crontab -

# Fix permissions, set the password and show it.
chroot "$chroot_dir" chown -R "$chroot_user:$chroot_user" "/$chroot_home"
password="$(shuf -zern8 {A..Z} {a..z} {0..9} | tr -d '\0')"
echo "root:$password" | chroot "$chroot_dir" chpasswd
echo "$chroot_user:$password" | chroot "$chroot_dir" chpasswd
echo "Your password is $password"
exit
