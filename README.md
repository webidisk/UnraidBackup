# Weekly Unraid-to-Unraid Backup Solution

**Documentation revision:** v1.1.3  
**Backup script:** `weekly_unraid_backup_v1.2.3.sh`  
**Report helper:** `weekly_unraid_report_v1.1.0.sh`  
**Prepared for:** Carlos Lugo's Unraid environment

---

## 1. Purpose and Current Design

This solution backs up data from the main Unraid server to a larger standby Unraid backup server once per week.

| Role | System | Address / detail |
|---|---|---|
| Main/source server | ASUSTeK PRIME Z690-P | `172.20.30.251` |
| Backup/destination server | Intel S2600STB | `172.20.30.250` |
| Backup server BMC/IPMI | Intel Integrated BMC | `172.20.30.136` |
| Backup server BMC user | IPMI login | `lugocloud` |
| SSH transfer user | Unraid OS login on both servers | `root` |

### Automated workflow

1. The weekly User Scripts job starts on the **main** server.
2. The main server uses the existing `IPMI-Tools` Docker container to power on the backup server through its BMC.
3. The script waits for the backup server to respond to ping, accept SSH, and mount `/mnt/user`.
4. On a real run, Docker is disabled on the backup server so standby containers do not run while backup data is being written.
5. On a real run, Docker is temporarily disabled on the main server while critical shares are copied:
   - `/mnt/user/appdata`
   - `/mnt/user/system`
6. Docker is restored on the main server, then the remaining shares continue backing up.
7. A detailed end-of-run report is generated while the backup server is still online.
8. A PDF copy of each successful real-run report is submitted to Paperless GPT at `/mnt/user/Paperless/consume/paperless-gpt-auto/BackupReports/`.
9. The backup server is shut down cleanly through SSH using `shutdown -h now`.

### Important: this is a protected backup copy, not a strict identical mirror

The current design intentionally uses **no-delete** behavior:

- New files on the main server are copied to the backup server.
- Changed files on the main server update the corresponding current backup copy.
- Files that exist only on the backup server are retained.
- Files deleted accidentally from the main server remain on the backup server.

Because no-delete is enabled and some paths are excluded, the destination is **not** a byte-for-byte mirror.

### Current exclusions

The following are not backed up:

| Excluded path | Reason |
|---|---|
| `/mnt/user/CCTVStorage` | CCTV data is intentionally excluded. |
| `/mnt/user/BackupReports` | Prevents the active report/log share from backing up itself. |
| `/mnt/user/system/docker/docker.img` | Large Docker virtual image; Docker applications are recovered from appdata/templates instead. |
| `/mnt/user/system/libvirt/libvirt.img` | Large libvirt image; currently excluded. |
| `/mnt/user/appdata/ipmi_tools/backup_bmc.pass` | Prevents copying the BMC password file to the backup server. |
| Common appdata cache/temp/log/runtime files | Reduces churn and rsync code 24 warnings. |

---

## 2. Files in This Release

| File | Purpose | Installation location |
|---|---|---|
| `weekly_unraid_backup_v1.2.3.sh` | Main scheduled backup script | Paste into the User Scripts job on the main server. |
| `weekly_unraid_report_v1.1.0.sh` | Generates TXT and PDF final backup reports | `/boot/config/backup_scripts/weekly_unraid_report_v1.1.0.sh` on the main server. |
| `weekly_unraid_backup_v1.2.3_README_v1.1.3.md` | This setup and operations guide | Keep with release documentation. |

All terminal commands below are run on the **main server** unless explicitly labeled **backup server**.

---

## 3. Prerequisites Checklist

Before installing the scripts, confirm:

- Both Unraid servers are online and reachable on the same network.
- Main server IP is `172.20.30.251`.
- Backup server OS IP is `172.20.30.250`.
- Backup server BMC web console is reachable at `172.20.30.136`.
- You can log into both Unraid servers as `root`.
- The User Scripts plugin is already installed on the main server.
- The `IPMI-Tools` Docker container exists on the main server.
- The IPMI-Tools container has `/data` mapped to `/mnt/user/appdata/ipmi_tools`.
- The backup server has sufficient storage and its `/mnt/user` array/share filesystem mounts successfully after boot.

---

## 4. Configure Persistent SSH Transfer from Main to Backup Server

The backup runs from the main server and copies files directly over SSH to:

```text
root@172.20.30.250:/mnt/user/
```

Unraid stores persistent root SSH data under `/boot/config/ssh/root/` on the server receiving SSH logins. Modern Unraid versions link `/root/.ssh` to this persistent location, so the authorized key survives a reboot.

### Step 4.1 — Create the persistent private key on the main server

On the **main server** terminal:

```bash
mkdir -p /boot/config/ssh_keys
chmod 700 /boot/config/ssh_keys

ssh-keygen -t ed25519 \
  -f /boot/config/ssh_keys/id_ed25519_unraid_backup \
  -N ""

chmod 600 /boot/config/ssh_keys/id_ed25519_unraid_backup
chmod 644 /boot/config/ssh_keys/id_ed25519_unraid_backup.pub
```

Expected files on the main server:

```text
/boot/config/ssh_keys/id_ed25519_unraid_backup
/boot/config/ssh_keys/id_ed25519_unraid_backup.pub
```

The file **without** `.pub` is the private key. Do not copy or share it.

### Step 4.2 — Install the public key persistently on the backup server

The following command appends the main server's public key to the persistent authorized-keys file on the **backup server**. Run it from the **main server**:

```bash
cat /boot/config/ssh_keys/id_ed25519_unraid_backup.pub | \
ssh root@172.20.30.250 '
  read -r NEW_KEY
  mkdir -p /boot/config/ssh/root
  touch /boot/config/ssh/root/authorized_keys
  if ! grep -qxF "$NEW_KEY" /boot/config/ssh/root/authorized_keys; then
    printf "%s\n" "$NEW_KEY" >> /boot/config/ssh/root/authorized_keys
  fi
  chmod 700 /boot/config/ssh/root
  chmod 600 /boot/config/ssh/root/authorized_keys
'
```

You will enter the backup server `root` password once during this setup step.

### Step 4.3 — Confirm the persistent SSH location on the backup server

Run from the main server:

```bash
ssh root@172.20.30.250 'ls -ld /root/.ssh /boot/config/ssh/root; ls -l /boot/config/ssh/root/authorized_keys'
```

Confirm that `/boot/config/ssh/root/authorized_keys` exists. This is the persistent authorization file used by this solution.

### Step 4.4 — Create a dedicated persistent known_hosts file on the main server

The backup script uses a dedicated host-key file instead of `/root/.ssh/known_hosts`:

```bash
mkdir -p /boot/config/ssh_keys
touch /boot/config/ssh_keys/known_hosts_unraid_backup
chmod 600 /boot/config/ssh_keys/known_hosts_unraid_backup

ssh-keyscan -H 172.20.30.250 > /boot/config/ssh_keys/known_hosts_unraid_backup
chmod 600 /boot/config/ssh_keys/known_hosts_unraid_backup
```

This avoids the earlier Unraid error where SSH could not update `/root/.ssh/known_hosts`.

### Step 4.5 — Test passwordless SSH transfer access

Run from the main server:

```bash
ssh -i /boot/config/ssh_keys/id_ed25519_unraid_backup \
  -o UserKnownHostsFile=/boot/config/ssh_keys/known_hosts_unraid_backup \
  -o StrictHostKeyChecking=yes \
  -o UpdateHostKeys=no \
  -o BatchMode=yes \
  root@172.20.30.250 'hostname && date && test -d /mnt/user && echo /mnt/user-is-ready'
```

Expected result:

- It connects without requesting a password.
- It prints the backup server hostname and date.
- It prints `/mnt/user-is-ready` when the destination share filesystem is mounted.

Do not continue until this test works.

---

## 5. Configure IPMI Power-On Through the Existing Docker Container

The backup server's Intel BMC is used only to **power on** the backup server. Normal shutdown is performed cleanly through SSH after the backup.

### Step 5.1 — Confirm IPMI-Tools container and `/data` mapping

On the main server:

```bash
docker ps -a --format '{{.Names}}' | grep -Fx 'IPMI-Tools'
```

In the Unraid Docker container settings, confirm this mapping exists:

```text
Container path: /data
Host path:      /mnt/user/appdata/ipmi_tools
```

### Step 5.2 — Store the BMC password without using an editor

Run on the main server:

```bash
mkdir -p /mnt/user/appdata/ipmi_tools

read -rsp "Enter backup server BMC password: " BMC_PASS
echo
printf '%s\n' "$BMC_PASS" > /mnt/user/appdata/ipmi_tools/backup_bmc.pass
chmod 600 /mnt/user/appdata/ipmi_tools/backup_bmc.pass
unset BMC_PASS
```

The backup script explicitly excludes this file from transfer:

```text
/mnt/user/appdata/ipmi_tools/backup_bmc.pass
```

### Step 5.3 — Test BMC power status

Run on the main server:

```bash
docker exec IPMI-Tools ipmitool \
  -I lanplus \
  -C 17 \
  -L ADMINISTRATOR \
  -H 172.20.30.136 \
  -U lugocloud \
  -f /data/backup_bmc.pass \
  power status
```

Expected output:

```text
Chassis Power is on
```

or:

```text
Chassis Power is off
```

### Step 5.4 — Test IPMI power-on from an off state

After the backup server is shut down cleanly, run:

```bash
docker exec IPMI-Tools ipmitool \
  -I lanplus \
  -C 17 \
  -L ADMINISTRATOR \
  -H 172.20.30.136 \
  -U lugocloud \
  -f /data/backup_bmc.pass \
  power on
```

Confirm the backup server eventually responds:

```bash
ping -c 4 172.20.30.250
```

The script allows up to 30 minutes for ping and another 15 minutes for SSH plus `/mnt/user` readiness.

---

## 6. Install the Report Helper Script on the Main Server

The report helper is called automatically by the backup script after a successful backup, while the destination server is still online.

### Step 6.1 — Create the persistent script folder

```bash
mkdir -p /boot/config/backup_scripts
```

### Step 6.2 — Copy the helper script into place

Copy the downloaded file `weekly_unraid_report_v1.1.0.sh` to:

```text
/boot/config/backup_scripts/weekly_unraid_report_v1.1.0.sh
```

Example, if the file is already available in a temporary folder on the main server:

```bash
cp /path/to/weekly_unraid_report_v1.1.0.sh \
   /boot/config/backup_scripts/weekly_unraid_report_v1.1.0.sh

chmod 600 /boot/config/backup_scripts/weekly_unraid_report_v1.1.0.sh
```

Verify that the helper exists, is readable, and has valid shell syntax:

```bash
ls -l /boot/config/backup_scripts/weekly_unraid_report_v1.1.0.sh

test -r /boot/config/backup_scripts/weekly_unraid_report_v1.1.0.sh \
  && echo "Report helper installed and readable"

bash -n /boot/config/backup_scripts/weekly_unraid_report_v1.1.0.sh \
  && echo "Report helper syntax OK"
```

Important: files stored under Unraid `/boot` intentionally do not retain executable permission. Seeing `-rw-------` is expected. Backup script `v1.2.1` executes the helper using:

```bash
bash /boot/config/backup_scripts/weekly_unraid_report_v1.1.0.sh
```

Do not rely on `chmod +x` for files stored under `/boot`.

---

## 7. Create the BackupReports Share

The verbose logs and final reports are stored on array storage rather than the Unraid USB flash drive.

In the main server Unraid web interface:

```text
Shares → Add Share → BackupReports
```

Expected output folders after runs begin:

```text
/mnt/user/BackupReports/WeeklyUnraidBackup/logs/
/mnt/user/BackupReports/WeeklyUnraidBackup/reports/
```

The `BackupReports` share is excluded from replication by the backup script.

---

## 8. Install the Main Backup Script in User Scripts

On the **main server**:

1. Open **Settings → User Scripts**.
2. Add a new script, or edit the existing backup script job.
3. Use a descriptive name, for example:

   ```text
   Weekly Mirror to Backup Unraid
   ```

4. Paste the complete contents of:

   ```text
   weekly_unraid_backup_v1.2.0.sh
   ```

5. Save the script.

### Step 8.1 — Review the key script settings

The following values are already configured for this environment:

```bash
SOURCE_IP="172.20.30.251"
DEST_IP="172.20.30.250"
BMC_IP="172.20.30.136"
BMC_USER="lugocloud"
IPMI_CONTAINER="IPMI-Tools"
```

For the first test, keep:

```bash
DRY_RUN="yes"
```

For a real backup that actually copies files and shuts down the destination, change to:

```bash
DRY_RUN="no"
```

Reporting defaults:

```bash
GENERATE_REPORT="yes"
GENERATE_REPORT_DURING_DRY_RUN="no"
CALCULATE_SHARE_SIZES="yes"
```

`CALCULATE_SHARE_SIZES="yes"` gives detailed storage usage in the final report, but it can add runtime on very large shares.

---

## 9. Run the Initial Dry-Run Test

A dry run validates startup, SSH, destination readiness, and rsync planning without changing backup data.

### Dry-run behavior

| Action | Dry run behavior |
|---|---|
| IPMI power-on backup server | Yes, if the server is off |
| Stop/disable Docker on either server | No |
| Copy files | No |
| Delete files | No; deletes are not enabled in real mode either |
| Generate report | No, by default |
| Shut down backup server | No |

Run the script manually from User Scripts with:

```bash
DRY_RUN="yes"
```

### Monitor the current run log

`v1.2.0` stores detailed logs under the `BackupReports` share:

```bash
LATEST_LOG="$(ls -1t /mnt/user/BackupReports/WeeklyUnraidBackup/logs/weekly_unraid_backup_*.log | head -n 1)"
echo "$LATEST_LOG"
tail -f "$LATEST_LOG"
```

For a dry-run startup test, it is sufficient to confirm the sequence reaches:

```text
Backup server responds to ping.
Backup server SSH is ready and /mnt/user is mounted.
PHASE 1: Critical backup started: appdata and system.
```

A dry run leaves the backup server powered on. Shut it down manually afterward:

```bash
ssh -i /boot/config/ssh_keys/id_ed25519_unraid_backup \
  -o UserKnownHostsFile=/boot/config/ssh_keys/known_hosts_unraid_backup \
  -o StrictHostKeyChecking=yes \
  -o UpdateHostKeys=no \
  root@172.20.30.250 'sync && shutdown -h now'
```

---

## 10. Run the First Real Backup

After the dry run passes, edit the User Script and set:

```bash
DRY_RUN="no"
```

Start one real run manually before enabling the weekly schedule.

### Real-run workflow

```text
IPMI power-on
  → wait for ping
  → wait for SSH and mounted /mnt/user
  → disable backup-server Docker
  → disable main-server Docker
  → back up appdata and system
  → re-enable main-server Docker
  → back up remaining shares, excluding CCTVStorage and BackupReports
  → back up main-server flash configuration
  → generate final report
  → shut down backup server cleanly
```

### Existing files on the backup server during the first run

The backup server already contained approximately 80–90% of the main server's files before this script was introduced. Rsync will reconcile the existing copy:

| Existing situation | Result |
|---|---|
| Same path, matching size and modified time | File is skipped. |
| Same path, different source file metadata/content | Current destination copy is updated by the source copy. |
| Present on main only | File is copied. |
| Present on backup only | File remains because no-delete is enabled. |

This first real adoption run may still transfer substantial data if timestamps or file contents differ.

---

## 11. Schedule the Weekly Backup

After a successful manual real run, configure the weekly schedule in **User Scripts**.

Example: every Sunday at 2:00 AM:

```cron
0 2 * * 0
```

Example: every Monday at 2:00 AM:

```cron
0 2 * * 1
```

Choose a time when temporary Docker downtime for `appdata` and `system` backup is acceptable.

---

## 12. Logs and Reports

### Detailed run logs

Every run creates a timestamped log on the main server:

```text
/mnt/user/BackupReports/WeeklyUnraidBackup/logs/
```

View the newest log:

```bash
LATEST_LOG="$(ls -1t /mnt/user/BackupReports/WeeklyUnraidBackup/logs/weekly_unraid_backup_*.log | head -n 1)"
less "$LATEST_LOG"
```

Follow a running log:

```bash
tail -f "$(ls -1t /mnt/user/BackupReports/WeeklyUnraidBackup/logs/weekly_unraid_backup_*.log | head -n 1)"
```

### End-of-run reports

Successful report-enabled runs create reports here:

```text
/mnt/user/BackupReports/WeeklyUnraidBackup/reports/
```

The report includes:

- Backup script/report-helper versions.
- Run status, start/end time, and duration.
- Files transferred during the run.
- Files newly created versus existing files updated.
- Folders created and changed links.
- Data transferred overall and by share.
- Current source and destination share sizes, when enabled.
- Main and backup `/mnt/user` total/used/free storage information.

---

### Paperless-ngx report import

Backup script `v1.2.2` retains the permanent report in:

```bash
/mnt/user/BackupReports/WeeklyUnraidBackup/reports/
```

The report helper stores permanent text and PDF copies in:

```bash
/mnt/user/BackupReports/WeeklyUnraidBackup/reports/
```

After a successful **real** backup report is generated, the main script copies only the PDF into the Paperless GPT auto-ingestion folder you provided:

```bash
/mnt/user/Paperless/consume/paperless-gpt-auto/BackupReports/
```

The Paperless PDF copy is first written with a `.part` suffix and is renamed to `.pdf` only after copying completes. This prevents the ingestion workflow from seeing an incomplete PDF.

To submit the newest existing report to Paperless one time:

```bash
PAPERLESS_DIR="/mnt/user/Paperless/consume/paperless-gpt-auto/BackupReports"
LATEST_REPORT="$(ls -1t /mnt/user/BackupReports/WeeklyUnraidBackup/reports/*.pdf | head -n 1)"

mkdir -p "$PAPERLESS_DIR"
cp -p "$LATEST_REPORT" "$PAPERLESS_DIR/$(basename "$LATEST_REPORT").part"
mv -f "$PAPERLESS_DIR/$(basename "$LATEST_REPORT").part" \
      "$PAPERLESS_DIR/$(basename "$LATEST_REPORT")"

echo "Submitted to Paperless: $PAPERLESS_DIR/$(basename "$LATEST_REPORT")"
```

Paperless settings in `weekly_unraid_backup_v1.2.3.sh`:

```bash
COPY_REPORT_PDF_TO_PAPERLESS="yes"
PAPERLESS_CONSUME_DIR="/mnt/user/Paperless/consume/paperless-gpt-auto/BackupReports"
COPY_DRY_RUN_REPORT_PDF_TO_PAPERLESS="no"
```

## 13. Manual Operations and Health Checks

### Check whether the backup server is powered on through IPMI

```bash
docker exec IPMI-Tools ipmitool \
  -I lanplus -C 17 -L ADMINISTRATOR \
  -H 172.20.30.136 -U lugocloud \
  -f /data/backup_bmc.pass power status
```

### Cleanly shut down the backup server manually

```bash
ssh -i /boot/config/ssh_keys/id_ed25519_unraid_backup \
  -o UserKnownHostsFile=/boot/config/ssh_keys/known_hosts_unraid_backup \
  -o StrictHostKeyChecking=yes \
  -o UpdateHostKeys=no \
  root@172.20.30.250 'sync && shutdown -h now'
```

### Confirm the main server Docker setting after an interrupted run

```bash
grep '^DOCKER_ENABLED=' /boot/config/docker.cfg
/etc/rc.d/rc.docker status
docker ps
```

If Docker needs to be restored manually:

```bash
sed -i 's/^DOCKER_ENABLED=.*/DOCKER_ENABLED="yes"/' /boot/config/docker.cfg
/etc/rc.d/rc.docker start
```

---

## 14. Troubleshooting

### Script says another backup instance is running

`v1.2.0` uses a PID lock directory rather than `flock`, preventing Docker from inheriting and permanently holding the backup lock.

Check the stored PID:

```bash
cat /var/run/weekly_unraid_backup.lockdir/pid 2>/dev/null
```

Check related processes:

```bash
ps -ef | grep -Ei 'weekly_unraid|rsync|ssh .*172.20.30.250' | grep -v grep
```

If no script or rsync transfer is active, remove a stale lock directory:

```bash
rm -rf /var/run/weekly_unraid_backup.lockdir
```

### Rsync reports code 24

Code 24 means files vanished while rsync was processing them, commonly due to temporary/cache/runtime files. The script treats code 24 as a warning and continues.

### Backup server powers on but is slow to become ready

Configured wait limits:

```text
Initial IPMI wait:       2 minutes
Ping readiness timeout: 30 minutes
SSH/share timeout:      15 minutes after ping responds
```

The tested Intel backup server reached `/mnt/user` readiness in approximately 7.5 minutes after IPMI power-on.

### Backup completes but destination does not shut down

The correct shutdown command used by `v1.2.0` is:

```bash
shutdown -h now
```

Run the manual shutdown command in Section 13 to verify SSH shutdown access.

### No log appears under `/boot/logs`

Starting with `v1.2.0`, verbose logs are intentionally stored under array storage:

```text
/mnt/user/BackupReports/WeeklyUnraidBackup/logs/
```

This reduces writes to the Unraid USB flash drive.

---

## 15. Security Notes

- The SSH private key remains only on the main server at `/boot/config/ssh_keys/id_ed25519_unraid_backup`.
- The BMC password file remains only on the main server at `/mnt/user/appdata/ipmi_tools/backup_bmc.pass` and is excluded from backup transfer.
- Do not place passwords directly in the User Scripts body.
- The backup server is powered off after a successful real run, reducing the time it is online.
- The destination Docker setting is disabled during a real backup to keep standby containers from starting while copied data is being written.

---

## 16. Version History

### README v1.1.3 - for backup script v1.2.3

- Corrected the Paperless GPT auto-ingestion location to `/mnt/user/Paperless/consume/paperless-gpt-auto/BackupReports/`.
- Documented PDF report generation and PDF-only submission to Paperless GPT.
- Updated one-time import instructions to use the generated PDF report.

### Backup script v1.2.3

- Uses report helper `v1.1.0`.
- Saves permanent TXT and PDF report files.
- Copies only completed PDF reports into the correct Paperless GPT auto-ingestion folder.
- Uses `.part` then `.pdf` rename when submitting to Paperless GPT.

### Report helper v1.1.0

- Adds dependency-free PDF generation directly in Bash.
- Retains the human-readable text report.
- Produces a monospaced multi-page PDF suitable for Paperless GPT ingestion.

### README v1.1.2 — for backup script v1.2.2

- Added Paperless-ngx consume-directory setup instructions.
- Documented recursive-consumer requirement when using the `BackupReports` subfolder.
- Added one-time command for importing an already-generated report.

### Backup script v1.2.2

- Copies successfully generated real-run reports into Paperless-ngx consume storage.
- Uses `.part` then atomic rename to prevent ingesting incomplete report files.
- Adds configurable Paperless consume destination and optional dry-run import.

### README v1.1.1 — for backup script v1.2.1

- Corrected report helper installation instructions for files stored under Unraid `/boot`.
- Replaced the incorrect executable-bit requirement with readable-file and Bash syntax checks.
- Documented that the helper is invoked with `bash` because `/boot` files are intentionally non-executable.

### Backup script v1.2.1

- Fixed report generation on Unraid flash storage by invoking the persistent report helper with `bash`.
- Changed report-helper validation from executable (`-x`) to readable (`-r`).
- Added a `bash -n` syntax validation before report generation.

### README v1.1.0 — for backup script v1.2.0

- Added complete step-by-step installation instructions.
- Added persistent SSH key setup and verification instructions.
- Added dedicated `known_hosts` setup and SSH transfer test.
- Added IPMI-Tools Docker BMC password and power-control validation steps.
- Added User Scripts installation, dry-run, real-run, scheduling, monitoring, and troubleshooting sections.
- Added explanation that the solution is a no-delete protected backup rather than a strict mirror.

### Backup script v1.2.0

- Added successful-run reporting support through report helper v1.0.0.
- Added itemized per-share transfer records for created/updated totals.
- Moved verbose logs and reports from `/boot` to `/mnt/user/BackupReports`.
- Excluded `BackupReports` from replication.
- Excluded `appdata/ipmi_tools/backup_bmc.pass` from replication.
- Preserved v1.1.3 PID-lock and shutdown fixes.

### Backup script v1.1.3

- Replaced inherited `flock` lock with a PID lock directory.
- Fixed destination shutdown command to `shutdown -h now`.

---

## 17. Installed File Locations Summary

| Item | Main server path |
|---|---|
| SSH private key | `/boot/config/ssh_keys/id_ed25519_unraid_backup` |
| SSH public key | `/boot/config/ssh_keys/id_ed25519_unraid_backup.pub` |
| SSH known hosts file | `/boot/config/ssh_keys/known_hosts_unraid_backup` |
| BMC password file for IPMI container | `/mnt/user/appdata/ipmi_tools/backup_bmc.pass` |
| Report helper | `/boot/config/backup_scripts/weekly_unraid_report_v1.1.0.sh` |
| Detailed logs | `/mnt/user/BackupReports/WeeklyUnraidBackup/logs/` |
| Final reports | `/mnt/user/BackupReports/WeeklyUnraidBackup/reports/` |

| Item | Backup server path |
|---|---|
| Persistent authorized SSH keys | `/boot/config/ssh/root/authorized_keys` |
| Protected data destination | `/mnt/user/<matching-share-name>/` |
| Main flash config copy | `/mnt/user/flash-backup-main-server/` |
