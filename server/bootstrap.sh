set -eu
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq postgresql python3-venv
if ! id daily-consume >/dev/null 2>&1; then useradd --system --home /opt/daily-consume --shell /usr/sbin/nologin daily-consume; fi
install -d -o daily-consume -g daily-consume -m 750 /opt/daily-consume
if ! runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='daily_consume'" | grep -q 1; then
  runuser -u postgres -- createuser daily_consume
fi
if ! runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_database WHERE datname='daily_consume'" | grep -q 1; then
  runuser -u postgres -- createdb -O daily_consume daily_consume
fi
# A dedicated OS account connects through PostgreSQL peer authentication.
if ! grep -q '^local daily_consume daily_consume peer map=daily_consume$' /etc/postgresql/14/main/pg_hba.conf; then
  sed -i '1ilocal daily_consume daily_consume peer map=daily_consume' /etc/postgresql/14/main/pg_hba.conf
  printf '\ndaily_consume daily-consume daily_consume\n' >> /etc/postgresql/14/main/pg_ident.conf
  systemctl reload postgresql
fi
if [ ! -d /opt/daily-consume/venv ]; then python3 -m venv /opt/daily-consume/venv; fi
install -d -m 700 /etc/daily-consume
if [ ! -f /etc/daily-consume/server.crt ]; then
  openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 1095 \
    -keyout /etc/daily-consume/server.key -out /etc/daily-consume/server.crt \
    -subj '/CN=47.99.142.117' -addext 'subjectAltName=IP:47.99.142.117' \
    -addext 'basicConstraints=critical,CA:TRUE'
  chmod 600 /etc/daily-consume/server.key
fi
echo 'Database and deployment environment ready.'
