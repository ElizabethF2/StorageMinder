#!/bin/sh

# Defaults
PATH_TO_CHECK="/"
FREE_SPACE_PERCENT_THRESHOLD=10
COOLDOWN_TIME_IN_SEC=5
CLEANUP_SCRIPT_PATH="$HOME/.config/StorageMinder/cleanup.sh"
DAEMON_INSTALL_PATH="/usr/bin/storageminderd"
SERVICE_NAME="storage_minder"
USE_FANOTIFY=0
ONLY_BUILD="no"
REMOVE_CONTAINER="no"
IMAGE_NAME_OVERRIDE="unset"

CCMD=$(type -p podman)
[ -z "$CCMD" ] && CCMD=$(type -p docker)

HAS_MUSL=true; ls /lib/ld-musl* > /dev/null 2>&1 || HAS_MUSL=false
DRIVE_SPEED_IN_MBPS="unset"
AUTO_SET_DRIVE_SPEED_SIZE="no"

SERVICE_TYPE="root"
[ $(id -u) = 0 ] || SERVICE_TYPE="user"

while [ $# -gt 0 ]; do
  case $1 in
    -p|--path)
      PATH_TO_CHECK="$2"
      shift ; shift
      ;;
    -t|--threshold)
      FREE_SPACE_PERCENT_THRESHOLD="$2"
      shift ; shift
      ;;
    -c|--cooldown)
      COOLDOWN_TIME_IN_SEC="$2"
      shift ; shift
      ;;
    -s|--script)
      CLEANUP_SCRIPT_PATH="$2"
      shift ; shift
      ;;
    -d|--drive-speed)
      DRIVE_SPEED_IN_MBPS="$2"
      shift ; shift
      ;;
    -i|--install-path)
      DAEMON_INSTALL_PATH="$2"
      shift ; shift
      ;;
    -b|--only-build)
      ONLY_BUILD="yes"
      shift
      ;;
    -k|--keep-container)
      REMOVE_CONTAINER="no"
      shift
      ;;
    -o|--container-name)
      IMAGE_NAME_OVERRIDE="$2"
      shift ; shift
      ;;
    -g|--glibc)
      HAS_MUSL=false
      shift
      ;;
    -m|--musl)
      HAS_MUSL=true
      shift
      ;;
    -n|--service-name)
      SERVICE_NAME="$2"
      shift ; shift
      ;;
    -f|--fanotify)
      USE_FANOTIFY=1
      shift
      ;;
    --image-name)
      SERVICE_NAME="$2"
      shift ; shift
      ;;
    -r|--root)
      SERVICE_TYPE="root"
      shift
      ;;
    -u|--user)
      SERVICE_TYPE="user"
      shift
      ;;
    *)
      echo "Unknown option $1, see readme"
      exit 1
      ;;
  esac
done

DEFAULT_CONTAINER_REGISTRY="docker.io/library"
CONTAINER_NAME="storage_minder_build_container"
CONTAINER_IMAGE="$DEFAULT_CONTAINER_REGISTRY/alpine"
INITAL_CMD="apk add --no-cache clang lld"
$HAS_MUSL || CONTAINER_IMAGE="$DEFAULT_CONTAINER_REGISTRY/archlinux"
$HAS_MUSL || INITAL_CMD="pacman -Syu --noconfirm clang lld"

if [ "$IMAGE_NAME_OVERRIDE" != unset ]; then
  CONTAINER_IMAGE="$IMAGE_NAME_OVERRIDE"
fi

if [ "$ONLY_BUILD" = no ]; then
  if [ "$PATH_TO_CHECK" = "" ]; then
    echo The path you want the daemon to check cannot be blank
    exit 1
  fi

  if [ "$DRIVE_SPEED_IN_MBPS" = unset ]; then
    device=$(df "$PATH_TO_CHECK" | awk 'END{split($1,a,"/");print a[3];}')
    sector_size=$(cat /sys/block/$device/queue/hw_sector_size)
    sectors_written=$(awk '{print $7}' /sys/block/$device/stat)
    ms_spent_writing=$(awk '{print $8}' /sys/block/$device/stat)
    bytes_per_mb=1048576
    ms_per_sec=1000
    ratio=15 # block layer statistics measure average performance
             # this scales up the speed by a worst-case (peak speed to average speed) ratio
    DRIVE_SPEED_IN_MBPS=$(awk "BEGIN{print (($ratio * $ms_per_sec * $sector_size * $sectors_written)/ \
                                            ($ms_spent_writing * $bytes_per_mb));exit}")
    echo "Auto-detected drive write speed for $device from $PATH_TO_CHECK at $DRIVE_SPEED_IN_MBPS MB/s"
  fi

  if [ ! -e "$CLEANUP_SCRIPT_PATH" ]; then
    echo Cleanup script is missing
    exit 1
  fi

  if [ ! -x "$CLEANUP_SCRIPT_PATH" ]; then
    chmod +x "$CLEANUP_SCRIPT_PATH"
  fi
fi

echo Looking for a past install of the daemon at $DAEMON_INSTALL_PATH
if [ ! -e "$DAEMON_INSTALL_PATH" ]; then
  [ -z "$CCMD" ] && echo "No container manager found" && exit 1

  # Ensure container exists
  $CCMD ps -a --format "Container Already Created: {{.Status}}" -f "name=$CONTAINER_NAME" | grep .
  if [ "$?" != "0" ]; then
    $CCMD container create -it -v "$(pwd):/ws:ro" --name $CONTAINER_NAME $CONTAINER_IMAGE /bin/sh
    echo Created a container named $CONTAINER_NAME via $CCMD
  fi

  # Start the container
  $CCMD start $CONTAINER_NAME

  echo "Building the daemon"
  $CCMD exec -it $CONTAINER_NAME /bin/sh -c \
    "$INITAL_CMD; \
    clang -Oz -g0 -flto=full -DUSE_FANOTIFY=$USE_FANOTIFY /ws/storage_minder.c -o /tmp/storage_minder_bin; \
    strip -s --remove-section=.comment /tmp/storage_minder_bin"

  echo "Copying the daemon to $DAEMON_INSTALL_PATH"
  $CCMD cp "$CONTAINER_NAME:/tmp/storage_minder_bin" "$DAEMON_INSTALL_PATH"
  chmod +x "$DAEMON_INSTALL_PATH"

  if [ "$REMOVE_CONTAINER" = yes ]; then
    echo "Removing container: $CONTAINER_NAME"
    $CCMD rm -f $CONTAINER_NAME
  fi
else
  echo Found the daemon, skipping compilation
fi

if [ "$ONLY_BUILD" = yes ]; then
  echo ONLY_BUILD flag was set, skipping service installation
  exit 0
fi

if [ "$SERVICE_TYPE" = root ]; then
  SERVICE_ROOT="/etc/systemd/system"
else
  SERVICE_ROOT="$HOME/.config/systemd/user"
fi

SERVICE_PATH="$SERVICE_ROOT/$SERVICE_NAME.service"
echo Attemping to install the service as a $SERVICE_TYPE service at $SERVICE_PATH
if [ ! -e "$SERVICE_ROOT" ]; then
  echo systemd unit path missing. Make sure systemd is installed and running.
  exit 1
fi

cat <<EOF > "$SERVICE_PATH"
[Unit]
Description=StorageMinder
After=multi-user.target
Wants=multi-user.target
AssertPathExists=$PATH_TO_CHECK
AssertPathExists=$CLEANUP_SCRIPT_PATH
StartLimitIntervalSec=200
StartLimitBurst=5

[Service]
Type=simple
ExecStart=$DAEMON_INSTALL_PATH
Restart=always
RestartSec=$COOLDOWN_TIME_IN_SEC
Environment=FREE_SPACE_PERCENT_THRESHOLD=$FREE_SPACE_PERCENT_THRESHOLD
Environment=COOLDOWN_TIME_IN_SEC=$COOLDOWN_TIME_IN_SEC
Environment=DRIVE_SPEED_IN_MBPS=$DRIVE_SPEED_IN_MBPS
Environment=PATH_TO_CHECK=$PATH_TO_CHECK
Environment=CLEANUP_SCRIPT_PATH=$CLEANUP_SCRIPT_PATH

[Install]
WantedBy=default.target
EOF

if [ "$SERVICE_TYPE" = root ]; then
  systemctl restart "$SERVICE_NAME"
  systemctl enable "$SERVICE_NAME"
else
  systemctl --user restart "$SERVICE_NAME"
  systemctl --user enable "$SERVICE_NAME"
fi

