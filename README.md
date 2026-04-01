HADR bundle for PostgreSQL 18 on Ubuntu 25.04

Values substituted:
- PRIMARY_IP  : 162.193.1.10
- STANDBY_IP  : 162.193.1.10
- VIP         : 10.0.0.100
- PRIVATE_NET : 162.193.1.0/24
- REPL_PASSWORD : REPL@password
- REPMGR_PASSWORD : REPMGR@password
- PGBOUNCER_USER : pgbncr
- PGBOUNCER_PASS : BOUNCER@password

Important: you provided the same IP for primary and standby (162.193.1.10).
If standby is a different host, update configs/repmgr.standby.conf and deployment commands accordingly.

Quick create & deploy:
1) Create zip:
   tar -czf hadr_bundle.tar.gz hadr_bundle/
   zip -r hadr_bundle.zip hadr_bundle/

2) Copy to node and bootstrap (example for primary):
   scp hadr_bundle.zip root@162.193.1.10:/tmp/
   ssh root@162.193.1.10 'cd /tmp && unzip -o hadr_bundle.zip && sudo ./hadr_bundle/bootstrap.sh primary'

Post-deploy manual steps (on primary):
   sudo -u postgres psql -f /tmp/hadr_bundle/scripts/create_rep_users.sql
   sudo -u postgres psql -f /tmp/hadr_bundle/scripts/create_replication_slot.sql
   sudo -u postgres repmgr -f /etc/repmgr/18/repmgr.conf primary register
   sudo systemctl enable --now repmgrd

On standby (ensure standby IP is correct):
   sudo systemctl stop postgresql
   sudo -u postgres rm -rf /var/lib/postgresql/18/main/*
   sudo -u postgres pg_basebackup -h 162.193.1.10 -p 5430 -D /var/lib/postgresql/18/main -U repuser -P -R -X stream --slot=slot_standby1
   sudo chown -R postgres:postgres /var/lib/postgresql/18/main
   sudo systemctl start postgresql
   sudo -u postgres repmgr -f /etc/repmgr/18/repmgr.conf standby register
   sudo systemctl enable --now repmgrd

Verification:
   sudo -u postgres psql -c ""SELECT pid, client_addr, state, sync_state, application_name FROM pg_stat_replication;""
   sudo -u postgres repmgr -f /etc/repmgr/18/repmgr.conf cluster show
   ip a | grep 10.0.0.100
   psql -h 10.0.0.100 -p 6432 -U pgbncr -d postgres
