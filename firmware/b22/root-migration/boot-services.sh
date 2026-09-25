#!/bin/sh
PATH=/sbin:/bin:/usr/sbin:/usr/bin
umask 077
[ "$(uci -q get zwrt_common_info.common_config.wa_inner_version)" = 'BD_ENCNMU5252V1.0.0B22' ] || exit 1
exec >> /data/local/root-b22/services.log 2>&1
sh /data/zwrt-datad/service.sh start
/etc/init.d/mihomo-manager-web start
/etc/init.d/web-full-menu start
if /etc/init.d/mihomo-netns enabled; then
    /etc/init.d/mihomo-netns start
fi
if [ -x /data/local/mwan3-tuning/activate.sh ]; then
    /data/local/mwan3-tuning/activate.sh
fi
