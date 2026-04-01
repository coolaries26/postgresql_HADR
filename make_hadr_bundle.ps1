<#
make_hadr_bundle.ps1
Creates hadr_bundle/ with all configs/scripts populated and zips it to hadr_bundle.zip
Run in PowerShell as Administrator
#>

param()

# User-provided values (already substituted)
$PRIMARY_IP = "162.193.1.10"
$STANDBY_IP = "162.193.1.10"
$VIP = "10.0.0.100"
$PRIVATE_NET = "162.193.1.0/24"
$REPL_PASSWORD = "REPL@password"
$REPMGR_PASSWORD = "REPMGR@password"
$PGBOUNCER_USER = "pgbncr"
$PGBOUNCER_PASS = "BOUNCER@password"

$OutDir = "hadr_bundle"
$ZipFile = "hadr_bundle.zip"

function ProgressWrite($percent, $message) {
    Write-Progress -Activity "Building hadr_bundle" -Status $message -PercentComplete $percent
    Write-Host ("[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $message)
}

# Clean up previous
if (Test-Path $OutDir) { Remove-Item -Recurse -Force $OutDir }
if (Test-Path $ZipFile) { Remove-Item -Force $ZipFile }

ProgressWrite 2 "Creating directory structure"
New-Item -ItemType Directory -Path "$OutDir\configs" -Force | Out-Null
New-Item -ItemType Directory -Path "$OutDir\scripts" -Force | Out-Null

ProgressWrite 8 "Writing postgresql.primary.conf"
@"
# Primary PostgreSQL 18 configuration snippet
listen_addresses = '*'
port = 5430
wal_level = replica
max_wal_senders = 10
max_replication_slots = 10
synchronous_commit = on
synchronous_standby_names = 'standby1'
archive_mode = on
archive_command = 'test ! -f /var/lib/postgresql/wal_archive/%f && cp %p /var/lib/postgresql/wal_archive/%f'
hot_standby = on
shared_buffers = 1GB
work_mem = 16MB
"@ | Out-File -FilePath "$OutDir\configs\postgresql.primary.conf" -Encoding UTF8

ProgressWrite 12 "Writing postgresql.standby.conf"
@"
# Standby PostgreSQL 18 configuration snippet
listen_addresses = '*'
port = 5431
hot_standby = on
wal_receiver_timeout = 60s
shared_buffers = 1GB
work_mem = 16MB
"@ | Out-File -FilePath "$OutDir\configs\postgresql.standby.conf" -Encoding UTF8

ProgressWrite 16 "Writing pg_hba.conf"
@"
# Add these lines to /etc/postgresql/18/main/pg_hba.conf
# Private network: $PRIVATE_NET
host    all             all             $PRIVATE_NET            scram-sha-256
host    replication     repuser         $PRIVATE_NET            scram-sha-256
"@ | Out-File -FilePath "$OutDir\configs\pg_hba.conf" -Encoding UTF8

ProgressWrite 20 "Writing create_rep_users.sql"
@"
-- Run on primary as postgres user
CREATE ROLE repuser REPLICATION LOGIN ENCRYPTED PASSWORD '$REPL_PASSWORD';
CREATE ROLE repmgr LOGIN ENCRYPTED PASSWORD '$REPMGR_PASSWORD';
CREATE DATABASE repmgr OWNER repmgr;
"@ | Out-File -FilePath "$OutDir\scripts\create_rep_users.sql" -Encoding UTF8

ProgressWrite 24 "Writing create_replication_slot.sql"
@"
-- Run on primary as postgres user
SELECT * FROM pg_create_physical_replication_slot('slot_standby1');
"@ | Out-File -FilePath "$OutDir\scripts\create_replication_slot.sql" -Encoding UTF8

ProgressWrite 28 "Writing repmgr.primary.conf"
@"
node_id=1
node_name=primary1
conninfo='host=$PRIMARY_IP port=5430 user=repmgr dbname=repmgr password=$REPMGR_PASSWORD'
data_directory='/var/lib/postgresql/18/main'
log_level=INFO
use_replication_slots=1
promote_command='repmgr standby promote -f /etc/repmgr/18/repmgr.conf'
follow_command='repmgr standby follow -f /etc/repmgr/18/repmgr.conf'
monitoring_history=yes
"@ | Out-File -FilePath "$OutDir\configs\repmgr.primary.conf" -Encoding UTF8

ProgressWrite 32 "Writing repmgr.standby.conf"
@"
node_id=2
node_name=standby1
conninfo='host=$STANDBY_IP port=5431 user=repmgr dbname=repmgr password=$REPMGR_PASSWORD'
data_directory='/var/lib/postgresql/18/main'
log_level=INFO
use_replication_slots=1
promote_command='repmgr standby promote -f /etc/repmgr/18/repmgr.conf'
follow_command='repmgr standby follow -f /etc/repmgr/18/repmgr.conf'
monitoring_history=yes
"@ | Out-File -FilePath "$OutDir\configs\repmgr.standby.conf" -Encoding UTF8

ProgressWrite 36 "Writing check_pg.sh"
@'
#!/bin/bash
# keepalived health check script
PRIMARY_PORT=5430
STANDBY_PORT=5431

if /usr/bin/pg_isready -q -p $PRIMARY_PORT; then
  ROLE=$(/usr/bin/sudo -u postgres psql -t -c "SELECT pg_is_in_recovery();" | tr -d "[:space:]")
  if [ "$ROLE" = "f" ]; then
    exit 0
  fi
fi

if /usr/bin/pg_isready -q -p $STANDBY_PORT; then
  ROLE=$(/usr/bin/sudo -u postgres psql -t -c "SELECT pg_is_in_recovery();" | tr -d "[:space:]")
  if [ "$ROLE" = "t" ]; then
    exit 0
  fi
fi

exit 2
'@ | Out-File -FilePath "$OutDir\scripts\check_pg.sh" -Encoding UTF8
# make script executable bit note for Linux later; on Windows we just write file

ProgressWrite 40 "Writing keepalived.primary.conf"
@"
vrrp_script chk_pg {
    script \"/usr/local/bin/check_pg.sh\"
    interval 2
    weight 2
}

vrrp_instance VI_1 {
    state MASTER
    interface eth0
    virtual_router_id 51
    priority 150
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass keepalived_secret
    }
    virtual_ipaddress {
        $VIP
    }
    track_script {
        chk_pg
    }
}
"@ | Out-File -FilePath "$OutDir\configs\keepalived.primary.conf" -Encoding UTF8

ProgressWrite 44 "Writing keepalived.standby.conf"
@"
vrrp_script chk_pg {
    script \"/usr/local/bin/check_pg.sh\"
    interval 2
    weight 2
}

vrrp_instance VI_1 {
    state BACKUP
    interface eth0
    virtual_router_id 51
    priority 100
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass keepalived_secret
    }
    virtual_ipaddress {
        $VIP
    }
    track_script {
        chk_pg
    }
}
"@ | Out-File -FilePath "$OutDir\configs\keepalived.standby.conf" -Encoding UTF8

ProgressWrite 48 "Writing pgbouncer.ini"
@"
[databases]
* = host=127.0.0.1 port=5430

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 6432
auth_type = md5
auth_file = /etc/pgbouncer/userlist.txt
admin_users = $PGBOUNCER_USER
pool_mode = transaction
max_client_conn = 1000
default_pool_size = 100
logfile = /var/log/pgbouncer/pgbouncer.log
pidfile = /var/run/pgbouncer/pgbouncer.pid
"@ | Out-File -FilePath "$OutDir\configs\pgbouncer.ini" -Encoding UTF8

ProgressWrite 52 "Writing userlist.txt"
@"
""$PGBOUNCER_USER"" ""$PGBOUNCER_PASS""
"@ | Out-File -FilePath "$OutDir\configs\userlist.txt" -Encoding UTF8

ProgressWrite 56 "Writing bootstrap.sh"
@'
#!/bin/bash
# bootstrap.sh - deploy files from the archive to correct locations
# Usage: sudo ./bootstrap.sh <role>   where <role> is primary or standby
set -euo pipefail
ROLE=${1:-}
if [[ "$ROLE" != "primary" && "$ROLE" != "standby" ]]; then
  echo "Usage: sudo $0 <primary|standby>"
  exit 2
fi

PG_CONF_DIR="/etc/postgresql/18/main"
REPMGR_CONF_DIR="/etc/repmgr/18"
KEEPALIVED_DIR="/etc/keepalived"
PGBOUNCER_DIR="/etc/pgbouncer"
SCRIPTS_DIR="/usr/local/bin"

mkdir -p "$REPMGR_CONF_DIR"
mkdir -p "$KEEPALIVED_DIR"
mkdir -p "$PGBOUNCER_DIR"
mkdir -p /var/log/pgbouncer

if [[ "$ROLE" == "primary" ]]; then
  cp configs/postgresql.primary.conf "$PG_CONF_DIR/postgresql.conf"
  cp configs/repmgr.primary.conf "$REPMGR_CONF_DIR/repmgr.conf"
  cp configs/keepalived.primary.conf "$KEEPALIVED_DIR/keepalived.conf"
else
  cp configs/postgresql.standby.conf "$PG_CONF_DIR/postgresql.conf"
  cp configs/repmgr.standby.conf "$REPMGR_CONF_DIR/repmgr.conf"
  cp configs/keepalived.standby.conf "$KEEPALIVED_DIR/keepalived.conf"
fi

cp configs/pg_hba.conf "$PG_CONF_DIR/pg_hba.conf"
cp configs/pgbouncer.ini "$PGBOUNCER_DIR/pgbouncer.ini"
cp configs/userlist.txt "$PGBOUNCER_DIR/userlist.txt"
cp scripts/check_pg.sh "$SCRIPTS_DIR/check_pg.sh"
chmod 750 "$SCRIPTS_DIR/check_pg.sh"
chown root:root "$SCRIPTS_DIR/check_pg.sh"
chown -R postgres:postgres "$PG_CONF_DIR"
chown -R postgres:postgres "$REPMGR_CONF_DIR"
chown -R pgbouncer:pgbouncer "$PGBOUNCER_DIR"
chown pgbouncer:pgbouncer /var/log/pgbouncer

systemctl daemon-reload
systemctl restart postgresql
systemctl restart repmgrd || true
systemctl restart keepalived
systemctl restart pgbouncer

echo "Bootstrap completed for role: $ROLE"
echo "Verify services: systemctl status postgresql repmgrd keepalived pgbouncer"
'@ | Out-File -FilePath "$OutDir\bootstrap.sh" -Encoding UTF8

ProgressWrite 60 "Writing README.md"
@"
HADR bundle for PostgreSQL 18 on Ubuntu 25.04

Values substituted:
- PRIMARY_IP  : $PRIMARY_IP
- STANDBY_IP  : $STANDBY_IP
- VIP         : $VIP
- PRIVATE_NET : $PRIVATE_NET
- REPL_PASSWORD : $REPL_PASSWORD
- REPMGR_PASSWORD : $REPMGR_PASSWORD
- PGBOUNCER_USER : $PGBOUNCER_USER
- PGBOUNCER_PASS : $PGBOUNCER_PASS

Important: you provided the same IP for primary and standby ($PRIMARY_IP).
If standby is a different host, update configs/repmgr.standby.conf and deployment commands accordingly.

Quick create & deploy:
1) Create zip:
   tar -czf hadr_bundle.tar.gz $OutDir/
   zip -r hadr_bundle.zip $OutDir/

2) Copy to node and bootstrap (example for primary):
   scp hadr_bundle.zip root@${PRIMARY_IP}:/tmp/
   ssh root@$PRIMARY_IP 'cd /tmp && unzip -o hadr_bundle.zip && sudo ./hadr_bundle/bootstrap.sh primary'

Post-deploy manual steps (on primary):
   sudo -u postgres psql -f /tmp/hadr_bundle/scripts/create_rep_users.sql
   sudo -u postgres psql -f /tmp/hadr_bundle/scripts/create_replication_slot.sql
   sudo -u postgres repmgr -f /etc/repmgr/18/repmgr.conf primary register
   sudo systemctl enable --now repmgrd

On standby (ensure standby IP is correct):
   sudo systemctl stop postgresql
   sudo -u postgres rm -rf /var/lib/postgresql/18/main/*
   sudo -u postgres pg_basebackup -h $PRIMARY_IP -p 5430 -D /var/lib/postgresql/18/main -U repuser -P -R -X stream --slot=slot_standby1
   sudo chown -R postgres:postgres /var/lib/postgresql/18/main
   sudo systemctl start postgresql
   sudo -u postgres repmgr -f /etc/repmgr/18/repmgr.conf standby register
   sudo systemctl enable --now repmgrd

Verification:
   sudo -u postgres psql -c ""SELECT pid, client_addr, state, sync_state, application_name FROM pg_stat_replication;""
   sudo -u postgres repmgr -f /etc/repmgr/18/repmgr.conf cluster show
   ip a | grep $VIP
   psql -h $VIP -p 6432 -U $PGBOUNCER_USER -d postgres
"@ | Out-File -FilePath "$OutDir\README.md" -Encoding UTF8

ProgressWrite 72 "Setting file attributes"
# Ensure scripts are Unix style where needed
Get-ChildItem -Path "$OutDir\scripts" -Filter "*.sh" | ForEach-Object {
    (Get-Content $_.FullName) -replace "`r`n", "`n" | Set-Content -NoNewline -Encoding UTF8 $_.FullName
}

ProgressWrite 80 "Creating ZIP archive"
if (Test-Path $ZipFile) { Remove-Item -Force $ZipFile }
Compress-Archive -Path $OutDir -DestinationPath $ZipFile -Force

ProgressWrite 92 "Computing SHA256 checksum"
# Compute SHA256
$sha = Get-FileHash -Path $ZipFile -Algorithm SHA256
$sha.Hash | Out-File -FilePath "$ZipFile.sha256" -Encoding ASCII

ProgressWrite 100 "Bundle created"
Write-Host ""
Write-Host "Bundle created: $ZipFile"
Write-Host "SHA256: $($sha.Hash)"
Write-Host "Location: $(Resolve-Path $ZipFile)"
Write-Host "You can now copy the ZIP to your servers using scp or WinSCP and follow README.md"
