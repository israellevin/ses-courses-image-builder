#!/usr/bin/bash -eu
# Builds an SES courses image.
chroot_dir=./chroot
chroot_user=ses
chroot_home="home/$chroot_user"
node_version='10.16.3'
server_port=5500

git_root=git@github.com:ses-education
api_server=ses-courses-api
client_front=ses-courses-client
organization_front=ses-courses-organization

cd "$(dirname "${BASH_SOURCE[0]}")"

# Verify/install required node version
verify_node_version(){
[ "$(node --version)" == v$node_version ] && return 0
read -n 1 -p"Install node $node_version? " q; echo
if [ "$(tr '[:upper:]' '[:lower:]' <<<"$q")" = 'y' ]; then
    npm install -global n
    n $node_version && return 0
fi
echo 'Can not build without correct node version, aborting'
return 1
}

# Clone and install the main server.
clone_and_install(){(
    git clone --depth 1 --branch dev "$git_root/$1"
    cd "$1"
    verify_node_version
    npm install
    rm -rf .git
)}
[ -d "$api_server" ] || clone_and_install "$api_server" &

# Clone, install and build the frontends.
clone_install_and_build(){(
    clone_and_install "$1"
    cd "$1"
    REACT_APP_BASE_URL="$1" npm run build
    mv build "../$1.build"
    cd ..
    rm -rf "$1"
    mv "$1.build" "$1"
)}
[ -d "$client_front" ] || clone_install_and_build "$client_front" &
[ -d "$organization_front" ] || clone_install_and_build "$organization_front" &

# Create and install a chroot environment in the background.
create_chroot(){(
    mkdir "$chroot_dir"
    cd "$chroot_dir"
    debootstrap --arch=amd64 --variant=minbase stable .
    chroot . useradd "$chroot_user" -m
)}
[ -d "$chroot_dir" ] || create_chroot &

wait

# Install software on the chroot.
install_chroot(){(
    cd "$chroot_dir"
    echo 'APT::Install-Recommends "0";' > etc/apt/apt.conf.d/10no-recommends
    echo 'APT::Install-Suggests "0";' > etc/apt/apt.conf.d/10no-suggests
    cat > etc/apt/sources.list <<EOF
deb http://deb.devuan.org/merged stable main
deb http://deb.devuan.org/merged stable-security main
deb http://deb.devuan.org/merged stable-updates main
EOF
    chroot . apt update
    # Installs should not try to run any services.
    echo exit 101 > usr/sbin/policy-rc.d
    DEBIAN_FRONTEND=noninteractive chroot . apt -y install -f linux-image-amd64 grub-pc locales \
        ca-certificates curl dhcpcd5 iproute2 iw netbase openssh-server wpasupplicant mariadb-server
    rm usr/sbin/policy-rc.d
    chroot . apt clean
    echo en_US.UTF-8 UTF-8 > etc/locale.gen
    chroot . locale-gen

    # Install the latest node version to install the right node version.
    curl https://nodejs.org/dist/v16.13.0/node-v16.13.0-linux-x64.tar.xz | tar -Jx
    PATH="node-v16.13.0-linux-x64/bin:$PATH" chroot . npm install --global npm@latest n@latest
    PATH="node-v16.13.0-linux-x64/bin:$PATH" chroot . n $node_version
    rm -rf node-v16.13.0-linux-x64/bin
)}
install_chroot

genpas(){
    length=${1:-8}
    {
        shuf -ern1 ':' ';' '<' '=' '>' '?' '@' '[' ']' '^' '_' '`' '{' '|' '}' '~'
        shuf -ern1 {0..9}
        shuf -ern1 {A..Z}
        shuf -ern$((length - 3)) {0..9} {A..Z} {a..z} {a..z} {a..z}
    } | shuf | tr -d "\n"
}

# Initialize the database.
db_password="$(genpas)"
chroot "$chroot_dir" service mariadb start || true # Allow for an sql server running on the host.
chroot "$chroot_dir" mysql <<EOF
CREATE DATABASE $chroot_user;
CREATE USER '$chroot_user'@'localhost' IDENTIFIED BY '$db_password';
GRANT ALL PRIVILEGES ON $chroot_user.* TO '$chroot_user'@'localhost' WITH GRANT OPTION;
EOF
chroot "$chroot_dir" mysql "$chroot_user" < dbinit.sql
chroot "$chroot_dir" service mariadb stop || true

# Configure the main server.
cat > "$api_server/.env" <<EOF
AUTH_JWT_KEY='$(genpas 32)'
PORT=$server_port
STUDENT_SITE_URL=http://localhost:$server_port/client
ORGANIZATION_SITE_URL=http://localhost:$server_port/organization
STATIC_FILES_FOLDER=/public
AUTH_DB_HOST=localhost
DB_REMOTE_HOST=localhost
AUTH_DB_PORT=3306
DB_REMOTE_PORT=3306
AUTH_DB_DB='$chroot_user'
DB_REMOTE_DATABASE='$chroot_user'
AUTH_DB_USER='$chroot_user'
DB_REMOTE_USER='$chroot_user'
AUTH_DB_PASSWORD='$db_password'
DB_REMOTE_PASSWORD='$db_password'
DB_REMOTE_CONNECTION_LIMIT=100
AUTH_TABLE_USERS=users
AUTH_TABLE_SESSIONS=sessions
AUTH_USER_FIELDS_LOGIN=email
AUTH_USER_FIELDS_ID=id
AUTH_USER_FIELDS_PASSWORD=password
AUTH_SESSION_FIELDS_SESSION=session_id
AUTH_SESSION_FIELDS_USER=user_id
MEDIA_URL=http://localhost:$server_port/media
MEDIA_PATH='/home/$chroot_user/$api_server/public/media'
EOF

# Copy our system into the chroot.
mkdir "$api_server/public" 2> /dev/null || true
cp -a "$client_front" "$api_server/public/client"
cp -a "$organization_front" "$api_server/public/organization"
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
log='$courses_home/server.log'
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

connection_file=connection.conf
connect(){
    log_progress_msg 'connecting to internet.'
    # FIXME
    return 0
    read ssid password < "$courses_home/$connection_file" 2> /dev/null
    ip link set eth0 down
    ip link set wlan0 down
    pkill wpa_supplicant || true
    iw dev wlan0 disconnect || true
    if [ "$ssid" ]; then
        ip link set wlan0 up
        if [ "$password" ]; then
            bash -c 'wpa_supplicant -i wlan0 -c <(wpa_passphrase "'$ssid'" "'$password'")'
        else
            iw dev wlan0 connect "$ssid"
            dhclient wlan0
        fi
    else
        ip link set eth0 up
        dhclient eth0
    fi
}

if [ "$load" ]; then
    # Try to mount USB drive and update settings before connecting.
    mount_point=/mnt
    if mount /dev/sdb1 "$mount_point" 2> /dev/null; then
        log_progress_msg 'mounting external drive.'
        if [ -r "$mount_point/$connection_file" ]; then
            cat "$mount_point/$connection_file" > "$courses_home/$connection_file"
            log_progress_msg 'loaded connection file.'
        fi
        connect
        ip a > "$mount_point/courses.ip.txt"
        umount "$mount_point"
    else
        connect
    fi
fi

ssd="start-stop-daemon --quiet --pidfile=/tmp/ses-courses.pid --chdir '$courses_home' --chuid '$courses_user'"

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
chmod +x "$service_file"

# Initialize database.
chroot "$chroot_dir" chown -R "$chroot_user:$chroot_user" "/$chroot_home"

# Fix permissions, set the password and show it.
chroot "$chroot_dir" chown -R "$chroot_user:$chroot_user" "/$chroot_home"
password="$(genpas)"
echo "$chroot_user:$password" | chroot "$chroot_dir" chpasswd
echo "Your password is $password"
exit
