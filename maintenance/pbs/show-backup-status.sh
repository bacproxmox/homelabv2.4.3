#!/usr/bin/env bash
set -Eeuo pipefail
PBS_STORAGE_ID="${PBS_STORAGE_ID:-pbs-homelab}"
PBS_IP="${PBS_IP:-192.168.50.110}"

echo "📦 PVE storage status"
pvesm status | grep -E "^(Name|${PBS_STORAGE_ID}[[:space:]])" || pvesm status || true

echo
echo "🗓️ PVE backup job"
grep -A12 '^vzdump: homelab-daily-vm-backup' /etc/pve/jobs.cfg 2>/dev/null || echo "Backup job bulunamadı."

echo
echo "🌐 PBS reachability"
curl -kIs "https://${PBS_IP}:8007" | sed -n '1,12p' || true
