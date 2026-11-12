#!/bin/sh
# RouterMon: установка с Linux или macOS.
#   ./install.sh                                 спросит IP основного роутера (по умолчанию — шлюз этого ПК)
#   ./install.sh 192.168.1.1 [ещё IP...]         поставить на указанные роутеры
#   ./install.sh --uninstall 192.168.1.1         убрать
# После установки ищет в сети другие роутеры с OpenWrt и предлагает поставить и на них (отключить: RMON_NOSCAN=1).
# Ключ SSH: переменная RMON_KEY=/путь/к/ключу, иначе ssh пробует свои ключи и спрашивает пароль root.
set -e
PORT=8089
cd "$(dirname "$0")"
MODE=install; [ "$1" = --uninstall ] && { MODE=remove; shift; }
if [ $# -eq 0 ]; then
  gw=$( { ip route show default 2>/dev/null | awk '{ print $3; exit }'; route -n get default 2>/dev/null | awk '/gateway:/ { print $2 }'; } | head -n 1)
  if [ -n "$gw" ]; then printf 'IP основного роутера с OpenWrt [%s]: ' "$gw"; else printf 'IP основного роутера с OpenWrt: '; fi
  read -r ip; [ -n "$ip" ] || ip=$gw; set -- $ip
fi
[ $# -gt 0 ] || exit 0
# адрес роутера попадает в команду ssh — допускаем только IP или имя хоста
for h in "$@"; do
  case $h in ''|[!A-Za-z0-9]*|*[!A-Za-z0-9.:-]*) echo "Недопустимый адрес роутера: '$h'" >&2; exit 1 ;; esac
done
SSH="ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"
[ -n "$RMON_KEY" ] && SSH="$SSH -i $RMON_KEY"

if [ $MODE = remove ]; then
  for h in "$@"; do $SSH "root@$h" 'sh /etc/rmon-web/lib/setup.sh remove' | tail -n 1; done
  exit 0
fi

STAGE=$(mktemp -d); trap 'rm -rf "$STAGE"' EXIT
cp -R web/. "$STAGE/"
find "$STAGE" -type f -exec sed -i.bak 's/\r$//' {} \; -exec rm -f {}.bak \;

# install_to "<роутеры>" "<все роутеры установки>": каждый запишет остальных в свой список
OK=
install_to() {
  for h in $1; do
    echo "$h: устанавливаю… (если спросит — пароль root этого роутера)"
    out=$(tar -cf - -C "$STAGE" . | $SSH "root@$h" "rm -rf /tmp/rmon-inst && mkdir -p /tmp/rmon-inst && tar -xf - -C /tmp/rmon-inst && sh /tmp/rmon-inst/lib/setup.sh install $PORT - $2" 2>&1) || true
    case "$out" in
      *INSTALLED*) echo "$h: готово — http://$h:$PORT/"; OK="$OK $h" ;;
      *) echo "$h: не удалось: $(printf '%s\n' "$out" | grep '^ERR ' | tail -n 1 | cut -c5-)"; printf '%s\n' "$out" | tail -n 3 ;;
    esac
  done
}
install_to "$*" "$*"

first=$(echo $OK | awk '{ print $1 }')
if [ -n "$first" ] && [ -z "$RMON_NOSCAN" ]; then
  echo; echo "Ищу другие роутеры с OpenWrt в локальной сети…"
  url="http://$first:$PORT/cgi-bin/api?a=scan"
  js=$(curl -s -m 30 "$url" 2>/dev/null || wget -q -T 30 -O - "$url" 2>/dev/null || true)
  found=$(printf '%s' "$js" | grep -o '"ip":"[0-9.]*"' | cut -d'"' -f4 | while read -r f; do case " $* " in *" $f "*) ;; *) echo "$f" ;; esac; done | tr '\n' ' ')
  if [ -n "$found" ]; then
    echo "Найдены роутеры с OpenWrt без RouterMon: $found"
    printf 'Поставить RouterMon и на них? Для каждого понадобится пароль root [Y/n]: '; read -r a
    case "$a" in n*|N*) echo "Их можно добавить позже на странице: «+ Добавить роутер» → «Найдены в сети»." ;; *) install_to "$found" "$* $found" ;; esac
  else echo "Других роутеров с OpenWrt без RouterMon не найдено."; fi
fi
[ -n "$first" ] && echo "Откройте http://$first:$PORT/ — другие роутеры добавляются там кнопкой «+ Добавить роутер»."
exit 0
