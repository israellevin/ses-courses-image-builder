#!/bin/bash -eu
# Installs SES-courses server on a devuan machine.
server_user=ses
db_init_file=dbinit.sql
server_directory=ses-courses-api
node_version=20.9.0
node_lts_version=20.9.0
server_port=5500

# Run as root.
if [ "$EUID" -ne 0 ]; then
    sudo "$0" "$@"
    exit
fi

# Create the server user.
if [ -d "/home/$server_user" ]; then
    echo "User $server_user already exists - exiting"
    exit 1
fi
useradd --create-home --user-group --shell "$(type -p bash)" "$server_user"

# Install required packages.
apt update
DEBIAN_FRONTEND=noninteractive apt -y install -f \
        ca-certificates curl dhcpcd5 ifupdown iproute2 monit netbase openssh-server mysql-server

# Use node LTS version to install the right node version.
[ -d node-v$node_lts_version-linux-x64/bin ] || \
    curl -s https://nodejs.org/dist/v$node_lts_version/node-v$node_lts_version-linux-x64.tar.xz | tar -Jx
PATH="./node-v$node_lts_version-linux-x64/bin:$PATH" npm install --global npm@latest n@latest
PATH="./node-v$node_lts_version-linux-x64/bin:$PATH" n $node_version

# Move to script directory.
pushd "$(dirname "${BASH_SOURCE[0]}")" > /dev/null

# Initialize the database.
service mysql status || service mysql start
mysql < "$db_init_file"

# Copy server directory to the user's home with right permissions.
rsync -a --chown="$server_user:$server_user" --no-inc-recursive --info=progress2 \
    "$server_directory"/ "/home/$server_user/$server_directory/"

# Create a service to start the server.
service_file="/etc/init.d/ses-courses"
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
courses_home='/home/$server_user/$server_directory'
courses_user='$server_user'
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
update-rc.d ses-courses defaults

# Configure monit to monitor our service with a simple starter script.
cat > /sbin/run-ses-courses <<EOF
service ses-courses start
EOF
chmod +x /sbin/run-ses-courses
cat > /etc/monit/conf.d/ses-courses <<'EOF'
check process ses-courses with pidfile /tmp/ses-courses.pid
    start program = "/sbin/run-ses-courses"
EOF

popd > /dev/null
exit 0
