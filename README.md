# StorageMinder

StorageMinder is a daemon which monitors drive usage and which will run a user-customizable script to clear temporary files, caches, etc when disk space becomes low. It is designed with ultra-efficiency in mind. The compiled daemon is just under 15 KB and uses a negligible amount of ram and cpu cycles. It works by using the drive's current free space and write speed to calculate the shortest time that the drive could become too full. The daemon is kept sleeping until that time has elapsed but is woken the instant it is possible that the disk space may be too low. This avoids the performance overhead of having the daemon constantly poll the drive's free space or of having it be notified of every disk write while still enabling it to near instantly react if a disk suddenly becomes too full. StorageMinder also includes optional support for using [fanotify](https://docs.kernel.org/admin-guide/filesystem-monitoring.html) which can further improve performance on drives that are infrequently written to. StorageMinder is highly customizable and supports monitoring multiple drives, each with their own threshholds and cleanup scripts.

StorageMinder is mainly designed to be used on Linux systems which use systemd. The included install script, `install.sh` uses Podman or Docker to automatically build the daemon and install it as a systemd service. However, most of StorageMinder itself is portable code and it should be relatively easy to get it built and installed on any OS or init system. See the "Building without Podman, Docker or systemd" section if you are not using Linux, don't have Podman or Docker or don't use systemd. Note that Podman or Docker are only used to build the daemon; they can be uninstalled once it's built.

## Build and Install

1. Clone or download the repo to your device and install Podman or Docker if you don't have either

2. Create a cleanup script which will delete the files you want deleted when disk space is low. `cleanup.sh` is included as an example/reference for your script. Place the script wherever you want. `~/.config/StorageMinder/cleanup.sh` is the default path `install.sh` uses. See the "Environment Variables" section below regarding variables which will be set before your script is run.

3. See the "Setup Flags" section to see what flags can be used with `install.sh` and the "Drive Speed" section then run `sh install.sh`.

4. The service should now be running and enabled on startup. Use `systemctl status` to check. You can change your settings by rerunning `install.sh` or by modifying the configuration file given by `systemctl status`.


## Uninstallation

The default name of the service is `storage-minder`. The default install path is `/etc/systemd/system` for a root service and `~/.config/systemd/user` for a user service. The default path of the daemon is `/usr/sbin/storage_minder`. You may need to substitute different names or paths for the below commands depending on which options you selected during installation.

If StorageMinder was installed as root run:
```
systemctl stop storage-minder.service
systemctl disable storage-minder.service
rm /etc/systemd/system/storage-minder.service
rm /usr/sbin/storage_minder
```

If StorageMinder was installed as a user service run:
```
systemctl --user stop storage-minder.service
systemctl --user disable storage-minder.service
rm ~/.config/systemd/user/storage-minder.service
rm /usr/sbin/storage_minder
```

You may also wish to delete the cleanup script your created. The default path `install.sh` looks in for the cleanup script is `~/.config/StorageMinder/cleanup.sh`


## Setup Flags

The below flags can be passed to `install.sh`. All flags are optional but it is highly recommended that you use the `-d` or `--drive-speed` flag. See the "Drive Speed" section for more details.

```
Flag: -d 300 or --drive-speed 300
Default Value: (Auto Detected)
Description: The max speed of the monitored drive in MB/s. It is strongly recommended that the speed be
             manually specified rather than letting install.sh auto detect the drive's max speed.
             See the "Drive Speed" section below for details.

Flag: -p /some/path or --path /some/path
Default Value: /
Description: The path to the mount point of the drive you want the daemon to monitor.

Flag: -t 10 or --threshold 10
Default Value: 10
Description: The percent of free drive space that is considered "too low". If drive space is below this
             threshold, the cleanup script will be run. This can be set to any value between 0 and 100.
             The value may include decimals so 55.574 would be a valid value.

Flag: -c 10 or --cooldown 10
Default Value: 5
Description: The cooldown time in seconds. To improve performance, the daemon tries to avoid checking
             the drive's free space or running the cleanup script too often. If either have been done
             recently, the daemon will wait until the cooldown time has elapsed until doing so again.
             Cooldown time can include decimals .e.g a cooldown time of 0.5 will wait half a second.
             A cooldown time of 0 can be used to disable the cooldown time. Note that cooldown times
             are relative to the time of the last check. So, if the cooldown time is 5 and the drive
             space was checked 2 seconds before another check is triggered, the daemon will wait 3
             seconds, not 5.

Flag: -s /home/alice/cleanup.sh or --script /home/alice/cleanup.sh
Default Value: $HOME/.config/StorageMinder/cleanup.sh
Description: The path to the script that will be run when drive space gets too low. This can be any
             executable file as long as the user the service is running as has permission to execute it.

Flag: -i /bin/storage_minder or --install-path /bin/storage_minder
Default Value: /usr/sbin/storage_minder
Description: The path where the daemon is or will be. If the path exists, install.sh skips building the
             daemon. If it does not, the daemon will be built and copied to the path.

Flag: -b or --only-build
Default Value: (Disabled)
Description: If specified, install.sh will only build the daemon and will not try to setup the service.
             If omitted, install.sh will create a systemd service for the daemon after building completes.

Flag: -k or --keep-container
Default Value: (Disabled)
Description: If specified, install.sh will not remove the Podman/Docker container used to build the daemon.
             If omitted, the container will be deleted. Keeping the container around can be useful when
             debugging build errors.

Flag: -o mycontainer or --container-name mycontainer
Default: storage_minder_build_container
Description: The name that will be used for the Podman/Docker container used to build the daemon

Flag: -g or --glibc
Default: (Auto Detected)
Description: Force the script to build the daemon for use in a system with glibc support. If this flag
             is omitted, the script will detect if the device it's running on uses glibc or musl
             automatically. See "Building without Podman, Docker or systemd" if building on a platform
             with neither.

Flag: -m or --musl
Default: (Auto Detected)
Description: Force the script to build the daemon for use in a system with musl support. If this flag
             is omitted, the script will detect if the device it's running on uses glibc or musl
             automatically. See "Building without Podman, Docker or systemd" if building on a platform
             with neither.

Flag: -n storage-minder-sd2 or --service-name storage-minder-sd2
Default: storage_minder
Description: Sets the name of the systemd service that will be created or replaced. Each service has its
             own drive, drive speed, cleanup script, etc so creating multiple StorageMinder services,
             each with their own name is necessary if you want to have it monitor multiple drives. Running
             install.sh twice with the same name will replace the existing service configuration rather than
             create a second service.

Flag: -f or --fanotify
Default: (Disabled)
Description: If specified, the daemon will be built with fanotify enabled. If omitted, fanotify is disabled.
             If fanotify is enabled, StorageMinder will attempt to subscribe to fanotify events using
             FAN_MARK_FILESYSTEM. If the kernel the daemon is running under doesn't support fanotify or if
             the user the daemon is running under doesn't have the CAP_SYS_ADMIN capability, the daemon will
             automatically fallback to the same behavior it would have if fanotify is disabled. fanotify is
             used to have the daemon be informed of all disk writes as soon as they happen. This can lead to
             poor performance in terms of both speed and memory usage in most cases which is why fanotify is
             disabled by default. On drives with a very low number of infrequent disk writes, it may improve
             performance to enable fanotify as the daemon will sleep until a disk write occurs if fanotify
             is enabled.

Flag: --image-name example.com/myregistry/archlinux
Default: (Auto Detected)
Description: The name of the image to use with Podman or Docker when building the daemon. By default,
             the script uses "alpine" if musl is detected and "archlinux" if glibc is detected. Both
             images are pulled from Docker's registry. You can use this flag to force the script to use
             a different container registry or a different image. The name may be an unqualified name as
             long as your install of Podman or Docker is configured to use unqualified names.

Flag: -r or --root
Default: (Auto Detected)
Description: Installs the service as a root service. If this option is omitted, the kind of service to
             use will be auto-detected based on the user running install.sh

Flag: -u or --user
Default: (Auto Detected)
Description: Installs the service as a user service. If this option is omitted, the kind of service to
             use will be auto-detected based on the user running install.sh

```


## Environment Variables

The following environment variables should be set before starting the daemon. The daemon passes all of its environment variables to the cleanup script so it is safe to assume that these variables will be available for you to use in your cleanup script. If you are installing StorageMinder via `install.sh`, it will create a systemd service which automatically sets up these variables for you. If you are not using systemd or are not using `install.sh`, you will need to manually set these variables in your init system before starting the StorageMinder daemon. Each environment variable has the same value as one of the setup flags. See "Setup Flags" for descriptions, default values and valid values.

  - FREE_SPACE_PERCENT_THRESHOLD corresponds to `-t` or `--threshold`
  - COOLDOWN_TIME_IN_SEC corresponds to `-c` or `--cooldown`
  - DRIVE_SPEED_IN_MBPS corresponds to `-d` or `--drive-speed`
  - PATH_TO_CHECK corresponds to `-p` or `--path`
  - CLEANUP_SCRIPT_PATH corresponds to `-s` or `--script`


## Drive Speed

When `install.sh` runs, if the `-d` or `--drive-speed` flag is not specified, the script will attempt to automatically detect the drive's max speed using Linux's block layer statistics. For more accurate results, when installing use the `-d` flag to manually specify the drive's max speed in MB/s. You may use whichever drive benchmarking tool you prefer to measure your drives max speed, however, make sure your benchmark tests for the fastest possible speed rather than average or real world speeds. When in doubt, it's better to have drive speed set too high rather than too low.

Tips:
  - Test sequential write speeds rather than random write speeds
  - Avoid running any other programs in the background that write to the drive while the benchmark is running
  - Match the benchmark's block size to your drive's block size

You can run the below commands to get the block size in bytes of your drive:
```
cd /path/to/mount/point/of/your/drive
stat -fc %s .
```

Use the below commands to check your drive's sequential write speed using [fio](https://github.com/axboe/fio) with a block size of 4k and using 4 GB of drive space. Make sure your drive has at least 4 GB free before running it.
```
cd /path/to/mount/point/of/your/drive
fio --name=storageminderspeedtest --rw=write --bs=4k --numjobs=1 --size=4g --runtime=60 --time_based --end_fsync=1
```


## Building without Podman, Docker or systemd

`install.sh` will build the daemon and create a systemd service configuration file for the daemon. These two parts of the script can be used independently. If you have Podman or Docker but not systemd, you can still build the daemon automatically using `install.sh --only-build` then manually setup your service. Likewise, if you have systemd but can't or don't want to use Podman or Docker, you can manually compile the daemon, copy it to where you want it installed, then run `install.sh` to setup the service as `install.sh` will skip building the daemon if it already exists in the path specified by the `--install-path` flag or, if the flag is omitted, if it exists in the default location.

To compile the daemon without Podman or Docker, use the build commands under the section that starts with `echo "Building the daemon"` in `install.sh`. Note that, as fanotify is only available on Linux, you'll want to pass `-DUSE_FANOTIFY=0` to Clang when building on any non-Linux platforms. Even if you are building on Linux, it will likely make sense to leave fanotify disabled unless the disk you are monitoring is only written to very infrequently.

The daemon uses no arguments when starting. All of its configuration is passed to it as environment variables. All of those variable are listed in the "Environment Variables" section above. When setting up the service for StorageMinder in your init system, ensure that it is started with those variables set, the path specified in PATH_TO_CHECK is mounted and the path in CLEANUP_SCRIPT_PATH exists and is accessible before starting the daemon. The daemon can be stopped by sending it SIGTERM.


## Troubleshooting

You can check the status of the daemon using `systemctl status storage-minder.service`. Use `systemctl --user status storage-minder.service` if the service was installed as a user service. If you specified a different name for the service, use that name instead of `storage-minder.service`. The service should keep running unless an error occurs. StorageMinder reports errors using exit codes. You can view the list of codes and what they mean in `storage_minder.c` under the `/* Error Codes */` heading.

If the service exits with ERROR_INVALID_THRESHOLD_PERCENT, ERROR_INVALID_COOLDOWN_TIME or ERROR_INVALID_DRIVE_SPEED, check the "Setup Flags" section again and make sure you are using a valid value. You can safely rerun `install.sh` to replace the existing service file with a new one with the correct values.

If you didn't use `install.sh` to generate your service configuration or if you've modified your service configuration and you get an error starting with "ERROR_MISSING" e.g. ERROR_MISSING_THRESHOLD, make sure that the environment variable for that setting is not missing.

If you get ERROR_UNABLE_TO_OPEN_PATH_TO_CHECK, make sure that the path you specified exists and is a mount point at the time the service is started. If your drive is removable, you can add lines with `After=your-device-name-here.device` and `StopWhenUnneeded=true` to the `[Unit]` section of your service file for StorageMinder so that the service only starts after the device is inserted.
