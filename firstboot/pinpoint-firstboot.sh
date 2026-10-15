#!/bin/bash

set -e

LOG="/var/log/pinpoint-firstboot.log"

echo "==================================" | tee -a "$LOG"
echo " PinPoint First Boot Setup"
echo "==================================" | tee -a "$LOG"

echo "Starting PinPoint installation..." | tee -a "$LOG"

echo "[1/9] Installing required packages..." | tee -a "$LOG"
/root/pinpoint/install-packages.sh

echo "[2/9] Installing Nagios Core..." | tee -a "$LOG"
/root/pinpoint/install-nagios-core.sh

echo "[3/9] Installing Nagios Plugins..." | tee -a "$LOG"
/root/pinpoint/install-nagios-plugins.sh

echo "[4/9] Configuring SNMP..." | tee -a "$LOG"
/root/pinpoint/configure-snmp.sh

echo "[5/9] Configuring Nagios..." | tee -a "$LOG"
/root/pinpoint/configure-nagios.sh

echo "[6/9] Deploying PinPoint web interface..." | tee -a "$LOG"
/root/pinpoint/deploy-pinpoint-web.sh

echo "[7/9] Configuring PinPoint privileges..." | tee -a "$LOG"
/root/pinpoint/configure-pinpoint-privileges.sh

echo "[8/9] Configuring the event handler..." | tee -a "$LOG"
/root/pinpoint/configure-event-handler.sh

echo "[9/9] Configuring log limits..." | tee -a "$LOG"
/root/pinpoint/configure-journald-logs.sh

echo "PinPoint installation completed successfully." | tee -a "$LOG"
echo "Web administrator credentials will be shown at the next login." | tee -a "$LOG"
echo "Disabling PinPoint First Boot service..." | tee -a "$LOG"
systemctl disable pinpoint-firstboot.service

echo "Done." | tee -a "$LOG"
