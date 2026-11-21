#!/bin/sh
# BusyBox start-stop-daemon 无 -d；cwd 必须落在安装目录，否则 ConfigDir 会退化到 /.GoWebSSH。
cd /data/webssh || exit 1
exec /data/webssh/webssh -ConfigDir /data/webssh >>/tmp/webssh.log 2>&1