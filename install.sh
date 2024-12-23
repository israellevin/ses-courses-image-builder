#!/bin/bash -eu
# Installs SES-courses server on a devuan machine.
server_user=ses
db_init_file=dbinit.sql
server_directory=ses-courses-api
node_version=20.9.0

# Run as root.
if [ "$EUID" -ne 0 ]; then
    sudo "$0" "$@"
    exit
fi

# Move to script directory.
cd "$(dirname "${BASH_SOURCE[0]}")"

# Create the server user if needed.
if [ -z "$(getent passwd $server_user)" ]; then
    useradd --create-home --user-group --shell "$(type -p bash)" $server_user
fi

# Install required packages.
apt update
DEBIAN_FRONTEND=noninteractive apt -y install -f \
        ca-certificates curl dhcpcd5 ifupdown iproute2 netbase openssh-server mysql-server npm

# Correct node version.
npm install --global n
n $node_version

# Initialize the database.
service mysql status || service mysql start
mysql < $db_init_file

# Copy server directory to the user's home with right permissions.
rsync -a --chown=$server_user:$server_user --no-inc-recursive --info=progress2 \
    $server_directory/ /home/$server_user/$server_directory/

# Install node requirements as the server user.
su - $server_user -c "cd /home/$server_user/$server_directory && npm install"

# Create a service to start the server.
service_file="/etc/systemd/system/ses-courses.service"
cat > "$service_file" <<'EOF'
[Unit]
Description=SES Courses System
After=mysql.service
Requires=mysql.service

[Service]
EOF
# This part goes through variable expansion.
cat >> "$service_file" <<EOF
Type=simple
User=$server_user
WorkingDirectory=/home/$server_user/$server_directory
PIDFile=/tmp/ses-courses.pid
ExecStart=/usr/local/bin/node index.js >> /home/$server_user/$server_directory/server.log 2>&1
ExecStop=/bin/sh -c 'start-stop-daemon --quiet --stop --pidfile=/tmp/ses-courses.pid --chuid $server_user'
Restart=always
EOF
# This part does not.
cat >> "$service_file" <<'EOF'
[Install]
WantedBy=multi-user.target
EOF

# Enable the service.
systemctl daemon-reload
systemctl enable ses-courses
systemctl start ses-courses

exit 0
