#!/usr/bin/bash -eu
# Builds an SES courses image.
chroot_dir=./chroot
chroot_user=ses
chroot_home="home/$chroot_user"
db_init=dbinit.sql
api_server=ses-courses-api
node_version=10.16.3
server_port=5500

pushd "$(dirname "${BASH_SOURCE[0]}")" > /dev/null

create_chroot(){(
    mkdir "$chroot_dir"
    cd "$chroot_dir"
    debootstrap --arch=amd64 --variant=minbase stable .
    chroot . useradd "$chroot_user" -m

    # Configure apt.
    echo 'APT::Install-Recommends "0";' > ./etc/apt/apt.conf.d/10no-recommends
    echo 'APT::Install-Suggests "0";' > ./etc/apt/apt.conf.d/10no-suggests
    cat > ./etc/apt/sources.list <<EOF
deb http://deb.devuan.org/merged stable main
deb http://deb.devuan.org/merged stable-security main
deb http://deb.devuan.org/merged stable-updates main
EOF
    chroot . apt update

    # Install packages without running any services.
    echo exit 101 > ./usr/sbin/policy-rc.d
    DEBIAN_FRONTEND=noninteractive chroot . apt -y install -f linux-image-amd64 grub-pc locales \
        ca-certificates curl dhcpcd5 ifupdown iproute2 monit netbase openssh-server

    # Add unstable repo for latest mysql.
    cat > ./etc/apt/sources.list <<EOF
deb http://deb.devuan.org/merged unstable main
EOF
    chroot . apt update
    # This fails on chroot, but still works.
    DEBIAN_FRONTEND=noninteractive chroot . apt -y install -f mysql-server || true
    chroot . usermod -d /var/lib/mysql/ mysql

    # Restore and clean apt.
    rm ./usr/sbin/policy-rc.d
    chroot . apt clean

    # Generate locale.
    echo en_US.UTF-8 UTF-8 > etc/locale.gen
    chroot . locale-gen

    # Configure network.
    cat >> ./etc/network/interfaces <<EOF
# Wired interface
auto eth0
allow-hotplug eth0
iface eth0 inet dhcp
EOF

    # Install current LTS node version to install the right node version.
    curl -s https://nodejs.org/dist/v16.13.0/node-v16.13.0-linux-x64.tar.xz | tar -Jx
    PATH="node-v16.13.0-linux-x64/bin:$PATH" chroot . npm install --global npm@latest n@latest
    PATH="node-v16.13.0-linux-x64/bin:$PATH" chroot . n $node_version
    rm -rf node-v16.13.0-linux-x64/bin
)}
# Create and install a chroot environment if needed.
[ -d "$chroot_dir" ] || create_chroot

# Initialize the database.
chroot "$chroot_dir" service mysql start
chroot "$chroot_dir" mysql < "$db_init"
chroot "$chroot_dir" service mysql stop

# Copy frontends and media to the server, and the server to the chroot.
cp -a "$api_server" "$chroot_dir/$chroot_home/."

pushd "$chroot_dir" > /dev/null

# Create a service to start the server.
service_file="./etc/init.d/ses-courses"
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
server_port='$server_port'
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
        status=1
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

if [ "$load" ]; then
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
    <a href="http://$(get_ip):$server_port">courses app</a>
</body>
</html>
EOHTML
        umount "$mount_point"
    fi
fi

ssd="start-stop-daemon --quiet --pidfile=/tmp/ses-courses.pid --chdir $courses_home --chuid $courses_user"
log="$courses_home/server.log"

exit_code=0

if [ "$stop" ]; then
        $ssd --stop && log_progress_msg 'server stopped.' || exit_code=1
        sleep 1
fi

if [ "$start" ]; then
    if ss -lnt | grep ":$server_port " > /dev/null 2>&1; then
        log_progress_msg 'server already running.'
        exit_code=1
    else
        $ssd --start --background --make-pidfile --exec /usr/local/bin/node -- index.js >> "$log" 2>&1 \
            && log_progress_msg 'server started.' || exit_code=1
    fi
fi

if [ "$status" ]; then
    if $ssd --status; then
        log_progress_msg 'all running.'
    else
        log_progress_msg 'all stopped.'
        exit_code=1
    fi
fi
log_end_msg > /dev/null "$exit_code"
EOF
chmod +x "$service_file"

# Install the service.
chroot . update-rc.d ses-courses defaults

# Configure monit to monitor our service with a simple starter script.
cat > ./root/run-ses-courses <<EOF
service ses-courses start
EOF
chmod +x ./root/run-ses-courses
cat > ./etc/monit/conf.d/ses-courses <<'EOF'
check process ses-courses with pidfile /tmp/ses-courses.pid
    start program = "/root/run-ses-courses"
EOF

# Fix permissions, set the password and show it.
chroot . chown -R "$chroot_user:$chroot_user" "/$chroot_home"
password="$(shuf -zern8 {A..Z} {a..z} {0..9} | tr -d '\0')"
echo "root:$password" | chroot . chpasswd
echo "$chroot_user:$password" | chroot . chpasswd
echo "Your password is $password"

popd > /dev/null
popd > /dev/null
exit 0
