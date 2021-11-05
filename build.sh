#!/usr/bin/bash -e
chroot_dir=./chroot
git_root=git@github.com:ses-education

pushd "$(dirname "${BASH_SOURCE[0]}")"
set -o allexport
. courses.env
set +o allexport

genpas(){
    length=${1:-8}
    {
        shuf -ern1 ':' ';' '<' '=' '>' '?' '@' '[' ']' '^' '_' '`' '{' '|' '}' '~'
        shuf -ern1 {0..9}
        shuf -ern1 {A..Z}
        shuf -ern$((length - 3)) {0..9} {A..Z} {a..z} {a..z} {a..z}
    } | shuf | tr -d "\n"
}
export -f genpas

# Clone the repos and build what requires building.

(
    repo=ses-courses-client
    git clone --depth 1 "$git_root/$repo"
    cd "$repo"
    npm install
    npm run build
    mv build "../$COURSES_SERVER_DIR"
    cd ..
    rm -rf "$repo"
)&

(
    repo=ses-courses-organization
    git clone --depth 1 "$git_root/$repo"
    cd "$repo"
    npm install
    npm install sass
    npm run build
    mv build "../$COURSES_ORGANIZATION_DIR"
    cd ..
    rm -rf "$repo"
)&

(
    repo=ses-courses-api
    git clone --depth 1 --branch dev "$git_root/$repo"
    cd "$repo"
    npm install
    npm install nodemon
    cat > .env <<EOF
AUTH_JWT_KEY='$(genpas 32)'
PORT=$COURSES_SERVER_PORT
STUDENT_SITE_URL=https://localhost:$COURSES_STUDENT_PORT
ORGANIZATION_SITE_URL=https://localhost:$COURSES_ORGANIZATION_PORT
ADMIN_SITE_URL=https://localhost:$COURSES_ADMIN_PORT
DB_REMOTE_HOST=localhost
DB_REMOTE_PORT=3306
DB_REMOTE_DATABASE=ses
DB_REMOTE_USER=ses
DB_REMOTE_PASSWORD=ses
DB_REMOTE_CONNECTION_LIMIT=100
AUTH_DB_HOST=localhost
AUTH_DB_PORT=3306
AUTH_DB_DB=auth
AUTH_DB_USER=auth
AUTH_DB_PASSWORD=auth
EOF
    rm -rf .git
    cd ..
    mv "$repo" "$COURSES_SERVER_DIR"
)&

# # Create the base system.
# (
#     mkdir "$chroot_dir"
#     debootstrap --arch=amd64 --variant=minbase stable "$chroot_dir"
# )&

wait

popd
exit
