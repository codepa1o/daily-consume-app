set -eu
requirements=/opt/daily-consume/requirements.txt
if [ -f /opt/daily-consume/requirements.lock ]; then requirements=/opt/daily-consume/requirements.lock; fi
/opt/daily-consume/venv/bin/pip install -q -r "$requirements"
chown -R daily-consume:daily-consume /opt/daily-consume
cd /opt/daily-consume
# Run once as the peer-authenticated database user; failure aborts before restart.
runuser -u daily-consume -- /opt/daily-consume/venv/bin/alembic -c /opt/daily-consume/alembic.ini upgrade head
install -m 644 /opt/daily-consume/daily-consume.service /etc/systemd/system/daily-consume.service
install -m 644 /opt/daily-consume/nginx.conf /etc/nginx/conf.d/daily-consume.conf
nginx -t
systemctl daemon-reload
systemctl enable daily-consume
systemctl restart daily-consume
systemctl reload nginx
sleep 3
curl --fail --silent http://127.0.0.1:8091/health
echo
systemctl is-active daily-consume
