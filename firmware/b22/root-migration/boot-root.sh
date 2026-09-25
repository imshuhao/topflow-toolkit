#!/bin/sh
# Minimal MU5252 B22 root ADB hook. No vendor binary replacement on disk.
PATH=/sbin:/bin:/usr/sbin:/usr/bin
umask 077
root_dir=/data/local/root-b22
[ "$(uci -q get zwrt_common_info.common_config.wa_inner_version)" = 'BD_ENCNMU5252V1.0.0B22' ] || exit 1
[ -x "$root_dir/adb_shell" ] || exit 1
if ! grep -q ' /bin/adb_shell ' /proc/mounts; then
    mount --bind "$root_dir/adb_shell" /bin/adb_shell || exit 1
fi
[ "$(sha256sum /bin/adb_shell | awk '{print $1}')" = "$(sha256sum "$root_dir/adb_shell" | awk '{print $1}')" ] || exit 1
[ -e /sys/class/android_usb/android0/usb_op ] || exit 1
echo 1 > /sys/class/android_usb/android0/usb_op || exit 1
printf 'root_hook_ready boot_id=%s\n' "$(cat /proc/sys/kernel/random/boot_id)" > "$root_dir/boot-status"
exit 0
