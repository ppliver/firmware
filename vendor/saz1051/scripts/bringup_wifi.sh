#!/bin/sh
# SAZ1051 WS73(Hi3873V100) USB WiFi 拉起
# 只用 /opt/saz_wifi 里的厂商 ko（含 cfg80211_v20/mac80211 的厂商构建版），
# 绝不加载内树 cfg80211/mac80211 —— 两者符号会撞。
K=/opt/saz_wifi
LOG=/tmp/wifi.log

log() { echo "$*"; }

[ -d "$K" ] || { log "WiFi: $K missing"; exit 1; }
if [ -e /sys/class/net/wlan0/phy80211 ]; then log "WiFi already up"; exit 0; fi

mkdir -p /system/etc
[ -f /system/etc/ws73_cfg.ini ] || cp /etc/ws73_cfg.ini /system/etc/ws73_cfg.ini 2>/dev/null

# wpa_supplicant 的 ctrl_iface 需要 unix socket -> 必须在可写文件系统上
mkdir -p /var/run/wpa_supplicant

mount -t tmpfs tmpfs /sys 2>/dev/null   # 仅当 /sys 尚未挂载时无害；已有挂载则失败
mount -t sysfs sysfs /sys 2>/dev/null

# 重新插一次前先清干净（muxfix mode=1 skip_usb=1 只允许插一次）
rmmod wifi_soc_v15 2>/dev/null; rmmod plat_soc 2>/dev/null; rmmod muxfix 2>/dev/null

insmod $K/rfkill.ko          2>&1 | sed 's/^/  /'
insmod $K/libarc4.ko         2>&1 | sed 's/^/  /'
insmod $K/firmware_class.ko  2>&1 | sed 's/^/  /'
insmod $K/cfg80211_v20.ko    2>&1 | sed 's/^/  /'
insmod $K/mac80211.ko        2>&1 | sed 's/^/  /'
sleep 2
insmod $K/muxfix.ko mode=1 skip_usb=1 2>&1 | sed 's/^/  /'
sleep 2
insmod $K/plat_soc.ko        2>&1 | sed 's/^/  /'
if [ -f $K/wifi_soc_v15.ko ]; then
	insmod $K/wifi_soc_v15.ko 2>&1 | sed 's/^/  /'
else
	insmod $K/wifi_soc.ko     2>&1 | sed 's/^/  /'
fi

i=0
while [ $i -lt 90 ]; do
	[ -e /sys/class/net/wlan0/phy80211 ] && break
	sleep 2
	i=$((i+1))
done
if [ ! -e /sys/class/net/wlan0/phy80211 ]; then
	log "WiFi FAIL: wlan0/phy80211 not present"; exit 1
fi

# ---- 配置真源：官方约定 env wlanssid/wlanpass（WebUI network.cgi 读写）----
# env 有值 -> wpa_passphrase 生成 /tmp/wpa_supplicant.conf（与官方
# /etc/network/interfaces.d/wlan0 的 pre-up 语义一致）；env 空 -> 退回构建时
# 预置的 /etc/wireless/wpa_supplicant.conf（v5 兼容路径，从未配过 WebUI 也不断网）。
SSID=$(fw_printenv -n wlanssid 2>/dev/null)
PASS=$(fw_printenv -n wlanpass 2>/dev/null)
WPA_CONF=/etc/wireless/wpa_supplicant.conf
if [ -n "$SSID" ] && [ -n "$PASS" ] && command -v wpa_passphrase >/dev/null 2>&1; then
	wpa_passphrase "$SSID" "$PASS" > /tmp/wpa_supplicant.conf 2>/dev/null
	sed -i 's/#psk.*/scan_ssid=1/g' /tmp/wpa_supplicant.conf
	WPA_CONF=/tmp/wpa_supplicant.conf
	log "WiFi: using env wlanssid=$SSID"
else
	log "WiFi: env wlanssid/wlanpass empty -> builtin conf"
fi

ifconfig wlan0 0.0.0.0 up
wpa_supplicant -B -Dnl80211 -iwlan0 -c "$WPA_CONF" -f /tmp/wp.log 2>/dev/null
i=0
while [ $i -lt 45 ]; do
	wpa_cli -iwlan0 status 2>/dev/null | grep -q COMPLETED && break
	sleep 2
	i=$((i+1))
done
# IP：官方 interfaces.d/wlan0 = dhcp；DHCP 拿不到再退回 v5 静态地址兜底
if udhcpc -i wlan0 -n -q -t 4 >/dev/null 2>&1; then
	log "WiFi: dhcp OK"
else
	ifconfig wlan0 192.168.6.178 netmask 255.255.255.0
	route add default gw 192.168.6.1 wlan0 2>/dev/null
	log "WiFi: dhcp failed -> static 192.168.6.178 fallback"
fi
log "WiFi up: $(ifconfig wlan0 | grep inet)"
