### BEGIN INIT INFO
# Provides: ses-courses
# Required-Start: $remote_fs $syslog
# Required-Stop: $remote_fs $syslog
# Default-Start: 2 3 4 5
# Default-Stop: 0 1 6
# Short-Description: SES courses system
### END INIT INFO
courses_dir=/root/ses
env_file=courses.env
connection_file=connection.env
mount_point=/mnt
ssd='start-stop-daemon --quiet --exec /usr/local/bin/node'

set -e

. /lib/lsb/init-functions

if [ ! -r "$courses_dir/$env_file" ]; then
    log_daemon_msg "SES courses service $1"
    log_progress_msg "SES courses env file ($courses_dir/$env_file) not found, aborting"
    log_end_msg 1
fi
cd "$courses_dir"
set -o allexport
. "./$env_file"
set +o allexport

connect(){
    pkill wpa_supplicant
    iw dev wlan0 disconnect
    set -o allexport
    . "./$connection_file"
    set +o allexport
    if [ "$SSID" ]; then
        if [ "$WPA_PASSWORD" ]; then
            wpa_supplicant -i wlan0 -c <(wpa_passphrase "$SSID" "$WPA_PASSWORD")
        else
            iw dev wlan0 connect "$SSID"
        fi
    fi
}

case "$1" in

    reload)
        if mount "$COURSES_USB" "$mount_point" 2> /dev/null; then
            if [ -r "$mount_point/$connection_file" ]; then
                cat "$mount_point/$connection_file" > "$connection_file"
                connect
            fi
            ip a > "$mount_point/courses.ip.txt"
            umount "$mount_point"
        fi
        ;;

    start)
        log_daemon_msg "SES courses service starting"

        start="$ssd --start --background --make-pidfile --chdir . --chuid root"
        webserver='./node_modules/node-static/bin/cli.js'
        $start --pidfile="$COURSES_STUDENT_PID" -- $webserver -p "$COURSES_STUDENT_PORT" "$COURSES_STUDENT_DIR" \
            && log_progress_msg 'students running...' || log_end_msg $?
        $start --pidfile="$COURSES_ORGANIZATION_PID" -- $webserver -p "$COURSES_ORGANIZATION_PORT" "$COURSES_ORGANIZATION_DIR" \
            && log_progress_msg 'organization running...' || log_end_msg $?
        $start --pidfile="$COURSES_ADMIN_PID" -- $webserver -p "$COURSES_ADMIN_PORT" "$COURSES_ADMIN_DIR" \
            && log_progress_msg 'admin running...' || log_end_msg $?
        cd "$COURSES_SERVER_DIR"
        $start --pidfile="$COURSES_SERVER_PID" -- index.js && log_progress_msg 'main running!' || log_end_msg $?
        ;;

    stop)
        log_daemon_msg "SES courses service stopping"
        stop="$ssd --stop"
        $stop --pidfile="$COURSES_STUDENT_PID" -- $webserver -p "$COURSES_STUDENT_PORT" "$COURSES_STUDENT_DIR" \
            && log_progress_msg 'students stopped...' || log_end_msg $?
        $stop --pidfile="$COURSES_ORGANIZATION_PID" -- $webserver -p "$COURSES_ORGANIZATION_PORT" "$COURSES_ORGANIZATION_DIR" \
            && log_progress_msg 'organization stopped...' || log_end_msg $?
        $stop --pidfile="$COURSES_ADMIN_PID" -- $webserver -p "$COURSES_ADMIN_PORT" "$COURSES_ADMIN_DIR" \
            && log_progress_msg 'admin stopped...' || log_end_msg $?
        $stop --pidfile="$COURSES_SERVER_PID" -- index.js && log_progress_msg 'main stopped!' || log_end_msg $?
        ;;

    status)
        log_daemon_msg "SES courses service status"
        status="$ssd --status"
        $status --pidfile="$COURSES_STUDENT_PID" \
            && log_progress_msg 'students running.' || log_progress_msg 'students stopped.'
        $status --pidfile="$COURSES_ORGANIZATION_PID" \
            && log_progress_msg 'organization running.' || log_progress_msg 'organization stopped.'
        $status --pidfile="$COURSES_ADMIN_PID" \
            && log_progress_msg 'admin running.' || log_progress_msg 'admin stopped.'
        $status --pidfile="$COURSES_SERVER_PID" && log_progress_msg 'main running.' || log_progress_msg 'main stopped.'
        ;;

    restart)
        $0 stop || true
        $0 start
        ;;

    *)
        echo "usage: $0 {start|stop|status|restart|reload}"
esac
echo
