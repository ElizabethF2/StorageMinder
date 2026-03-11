#!/bin/sh

PTC="${PATH_TO_CHECK:-/}"
FSPT="${FREE_SPACE_PERCENT_THRESHOLD:-10}"
FSAIGT="${FREE_SPACE_AMOUNT_IN_GB_THRESHOLD:-3}"
FREE_SPACE_THRESHOLD_METHOD="fixed_amount"

stop_early_if_enough_space_is_free()
{
  if [ "$FREE_SPACE_THRESHOLD_METHOD" = "percentage" ]; then
    [ "x$(df "$PTC" | awk 'END{print ((100*$4/$2)>('"$FSPT"'+0))}')" = "x0" ] \
      || exit 0
  elif [ "$FREE_SPACE_THRESHOLD_METHOD" = "fixed_amount" ]; then
    [ "x$(df "$PTC" | \
          awk 'END{print (($4)>(('"$FSAIGT"'+0)*1048576))}')" = "x0" ] \
      || exit 0
  else
    echo "Invalid threshold method: $FREE_SPACE_THRESHOLD_METHOD" 1>&2
    exit 1
  fi
}

remove_old_log_lines()
{
python - "$1" <<EOF
target = 50*1024*1024 # 50 MB
import sys, os, shutil
try:
  with open(os.path.expanduser(sys.argv[1]), 'r') as f:
    txt = f.read()
except FileNotFoundError:
  sys.exit(0)
if len(txt) > target:
  try:
    txt = txt[txt.index('\n', len(txt) - target)+1:]
  except IndexError:
    txt = ''
  (bak := open(f.name + '.storageminder-bak', 'x')).close()
  shutil.copy2(f.name, bak.name)
  with open(f.name, 'w') as f:
    f.write(txt)
  os.remove(bak.name)
EOF
}

# Create a toast to let active users know the cleanup script was triggered
stop_early_if_enough_space_is_free
# for uid in $(ls /run/user/); do
#   sudo -u "#$uid" "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus" \
#     notify-send -a StorageMinder "Cleanup Started" 2>/dev/null
# done
echo "Cleanup Started"

# Enumerate active users
users="$(printf "%s\n%s\n%s\n%s" \
        "$(who | awk '{print($1)}')" \
        "$USER" "$SUDO_USER" "$DOAS_USER" \
        | sort -u)"

# Clean temp files older than 30 days
find /tmp -mindepth 1 -mtime +30 -delete
stop_early_if_enough_space_is_free

# Clean temp files older than 7 days
find /tmp -mindepth 1 -mtime +7 -delete
stop_early_if_enough_space_is_free

# Cleanup unused flatpaks
# View current space usage with:
#   flatpak list --columns size,ref | sort -g
#   flatpak info <ref> -l
if type flatpak >/dev/null 2>/dev/null; then
  flatpak uninstall --unused --assumeyes
  for u in $users; do
    sudo -u "$u" sh -c 'flatpak uninstall --user --unused --assumeyes'
  done
  stop_early_if_enough_space_is_free
fi

# Clear the thumbnail cache
for u in users ; do
  rm -rf "$(eval echo "~$u/.cache/thumbnails")"
done
stop_early_if_enough_space_is_free

# Cleanup journal
if type journalctl >/dev/null 2>/dev/null; then
  journalctl --vacuum-size=500M
  for u in $users ; do
    sudo -u "$u" journalctl --user --vacuum-size=500M
  done
  stop_early_if_enough_space_is_free
fi

# Clear uninstalled cached packages
if type paccache >/dev/null 2>/dev/null; then
  paccache -rk1
  stop_early_if_enough_space_is_free
elif type pacman >/dev/null 2>/dev/null; then
  pacman -Sc --noconfirm
  stop_early_if_enough_space_is_free
elif type apk >/dev/null 2>/dev/null; then
  apk cache clean
  stop_early_if_enough_space_is_free
fi

# Clear all packages from the cache
# if type pacman >/dev/null 2>/dev/null; then
#   pacman -Scc --noconfirm
#   stop_early_if_enough_space_is_free
# fi

# Purge old containers and images
# podman system prune --all --force
# stop_early_if_enough_space_is_free

# Clean all temp files
# find /tmp -mindepth 1 -delete
# stop_early_if_enough_space_is_free

# Clear EncryptedNAS cache files older than 30 days
# for u in users ; do
#   find "$(eval echo "~$u/.cache/EncryptedNAS")" -mindepth 1 -mtime +30 -delete
# done
# stop_early_if_enough_space_is_free

# Clear EncryptedNAS cache files older than 7 days
# for u in users ; do
#   find "$(eval echo "~$u/.cache/EncryptedNAS")" -mindepth 1 -mtime +7 -delete
# done
# stop_early_if_enough_space_is_free

# Clear the entire EncryptedNAS cache
# for u in users ; do
#   rm -rf "$(eval echo "~$u/.cache/EncryptedNAS")"
# done
# stop_early_if_enough_space_is_free

# Clear cache files older than 30 days (excludes rclone)
# for u in users ; do
#   find "$(eval echo "~$u/.cache")" -maxdepth 1 ! -name rclone -mtime +30 -exec echo rm -f {} +
# done
# stop_early_if_enough_space_is_free

# Clear cache files older than 7 days (excludes rclone)
# for u in users ; do
#   find "$(eval echo "~$u/.cache")" -maxdepth 1 ! -name rclone -mtime +7 -exec echo rm -f {} +
# done
# stop_early_if_enough_space_is_free

# Empty the trash
# for u in users ; do
#   rm -rf "$(eval echo "~$u/.local/share/Trash/files/*")"
#   rm "$(eval echo "~$u/.local/share/Trash/info/*.trashinfo")"
# done
# stop_early_if_enough_space_is_free

# Shrink large log files
for u in $users ; do
  remove_old_log_lines "~$u/.local/state/prbsync/log.txt"
  remove_old_log_lines "~$u/.local/state/healthcheck.log"
  remove_old_log_lines "~$u/.local/state/git_mirror_sync/log.txt"
done
stop_early_if_enough_space_is_free

# Cleanup temporary maldet files older than 30 days
if [ -e /var/lib/maldet/tmp ]; then
  find /var/lib/maldet/tmp/ -mindepth 1 -mtime +30 -delete
fi

