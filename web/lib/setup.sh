#!/bin/sh
# RouterMon — установка и удаление на ЭТОМ роутере. Запускается из распакованного пакета
# (его присылает install.ps1 / install.sh с ПК или другой роутер с RouterMon):
#   sh setup.sh install <порт> [<открытый ключ ssh>|-] [IP соседних роутеров...]
#   sh setup.sh remove
#   sh setup.sh dnslog on|off   — журнал DNS-запросов для топа адресов (включается при установке сам, где нужен)
# Последняя строка вывода: INSTALLED / REMOVED, либо «ERR <причина>».
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
DST=/etc/rmon-web
err() { echo "ERR $*"; exit 1; }

# журнал DNS-запросов dnsmasq в ОЗУ — по нему сборщик подписывает адреса доменами (топ адресов).
# Включается только на роутере, через который идёт интернет (в conntrack есть соединения); файл в /tmp, не на флеше.
DNSLOG=/tmp/rmon-dns.log
dnslog() {
  s=$(uci -q show dhcp | awk -F'[.=]' '$3 == "dnsmasq" || /=dnsmasq$/ { print $2; exit }'); [ -n "$s" ] || return 0
  if [ "$1" = on ]; then
    [ "$(uci -q get dhcp.$s.logfacility)" = "$DNSLOG" ] && return 0
    touch "$DNSLOG"; uci set dhcp.$s.logqueries=1; uci set dhcp.$s.logfacility="$DNSLOG"; uci commit dhcp
  else
    [ "$(uci -q get dhcp.$s.logfacility)" = "$DNSLOG" ] || return 0
    uci -q delete dhcp.$s.logqueries; uci -q delete dhcp.$s.logfacility; uci commit dhcp; rm -f "$DNSLOG"
  fi
  /etc/init.d/dnsmasq restart >/dev/null 2>&1
}
if [ "$1" = dnslog ]; then dnslog "$2"; echo "DNSLOG $2"; exit 0; fi

if [ "$1" = remove ]; then
  dnslog off
  /etc/init.d/rmon stop 2>/dev/null; /etc/init.d/rmon disable 2>/dev/null
  rm -f /etc/init.d/rmon
  uci -q delete uhttpd.rmon; uci commit uhttpd; /etc/init.d/uhttpd restart
  rm -rf "$DST" /tmp/rmon /tmp/rmon-web
  sed -i -e '\#^/etc/rmon-web/$#d' -e '\#^/etc/init.d/rmon$#d' /etc/sysupgrade.conf
  echo REMOVED; exit 0
fi
[ "$1" = install ] || err "использование: setup.sh install <порт> [ключ|-] [IP...] | setup.sh remove"

PKG=$(cd "$(dirname "$0")/.." && pwd)
PORT=${2:-8089}; KEY=${3:--}
[ $# -ge 3 ] && shift 3 || shift $#

# --- проверки до каких-либо изменений ---
[ -f /etc/openwrt_release ] || err "это не OpenWrt: RouterMon работает только на роутерах с OpenWrt"
command -v uhttpd >/dev/null || err "на роутере нет веб-сервера uhttpd (поставьте его: opkg update && opkg install uhttpd)"
[ -x /etc/init.d/uhttpd ] || err "нет службы /etc/init.d/uhttpd"
[ -f "$PKG/cgi-bin/api" ] && [ -f "$PKG/lib/collect.sh" ] || err "пакет неполный: $PKG"
free=$(df -k /overlay 2>/dev/null | awk 'NR == 2 { print $4 }')
[ -z "$free" ] || [ "$free" -gt 400 ] || err "на роутере осталось ${free} КБ флеш-памяти, нужно хотя бы 400 КБ"
if netstat -ltn 2>/dev/null | grep -q ":$PORT " && ! uci -q get uhttpd.rmon >/dev/null; then
  err "порт $PORT уже занят другой программой"
fi

# --- файлы ---
if [ "$PKG" != "$DST" ]; then
  rm -rf "$DST.new" && mkdir -p "$DST.new" && cp -a "$PKG/." "$DST.new/" || err "не удалось скопировать файлы"
  for f in routers.conf hidden.conf; do [ -f "$DST/$f" ] && cp "$DST/$f" "$DST.new/$f"; done
  /etc/init.d/rmon stop >/dev/null 2>&1
  rm -rf "$DST" && mv "$DST.new" "$DST" || err "не удалось записать $DST"
fi
chmod 755 "$DST/cgi-bin/api" "$DST"/lib/*.sh
# соседние роутеры — в список, чтобы этот роутер их видел, даже если их нет в ARP
for ip in "$@"; do
  case "$ip" in *[!0-9.]*|'') continue ;; esac
  ip -4 -o addr show | grep -q " $ip/" && continue   # себя не добавляем
  touch "$DST/routers.conf"; grep -qx "$ip" "$DST/routers.conf" || echo "$ip" >>"$DST/routers.conf"
done
# постоянный доступ по ключу для роутера, который ставит (если разрешили)
if [ "$KEY" != "-" ] && [ -n "$KEY" ]; then
  case "$KEY" in ssh-*) ;; *) err "неверный открытый ключ" ;; esac
  touch /etc/dropbear/authorized_keys; chmod 600 /etc/dropbear/authorized_keys
  grep -qF "$KEY" /etc/dropbear/authorized_keys || echo "$KEY" >>/etc/dropbear/authorized_keys
fi

# --- служба сбора ---
cp "$DST/lib/rmon.init" /etc/init.d/rmon && chmod 755 /etc/init.d/rmon
grep -qx '/etc/rmon-web/' /etc/sysupgrade.conf || echo '/etc/rmon-web/' >>/etc/sysupgrade.conf
grep -qx '/etc/init.d/rmon' /etc/sysupgrade.conf || echo '/etc/init.d/rmon' >>/etc/sysupgrade.conf
/etc/init.d/rmon enable
# топ адресов: учёт байт в conntrack и журнал DNS — там, где роутер сам выпускает устройства в интернет
if [ "$(grep -c . /proc/net/nf_conntrack 2>/dev/null)" -gt 20 ] 2>/dev/null; then
  sysctl -qw net.netfilter.nf_conntrack_acct=1 2>/dev/null
  dnslog on
fi
/etc/init.d/rmon restart >/dev/null 2>&1

# --- веб-сервер ---
uci -q delete uhttpd.rmon
uci set uhttpd.rmon=uhttpd
uci add_list uhttpd.rmon.listen_http="0.0.0.0:$PORT"
uci set uhttpd.rmon.home="$DST"
uci set uhttpd.rmon.cgi_prefix='/cgi-bin'
uci set uhttpd.rmon.script_timeout='90'
uci set uhttpd.rmon.network_timeout='30'
uci set uhttpd.rmon.max_requests='6'
uci set uhttpd.rmon.no_dirlists='1'
uci commit uhttpd
/etc/init.d/uhttpd restart
rm -rf /tmp/rmon-web
case "$PKG" in /tmp/rmon-inst*) rm -rf "$PKG" ;; esac

sleep 2
netstat -ltn | grep -q ":$PORT " || err "веб-сервер не запустился на порту $PORT"
pgrep -f rmon-web/lib/collect.sh >/dev/null || err "служба сбора rmon не запустилась"
echo INSTALLED
