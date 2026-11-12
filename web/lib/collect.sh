#!/bin/sh
# RouterMon — сборщик метрик. Работает как служба /etc/init.d/rmon.
# Каждые 10 с пишет снимок в /tmp/rmon (в ОЗУ, после перезагрузки начинается заново):
#   sys.tsv   — система, последний час (360 строк по 10 с)
#   sys1m.tsv — система, последние сутки (1440 строк по 1 мин)
#   net.tsv / net1m.tsv — счётчики интерфейсов (час / сутки)
#   p/<время> — снимок всех процессов (последний час); первая строка «# <uptime в 1/100 с>»
#   cmd.tsv   — командные строки процессов (обновляется раз в минуту)
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
D=/tmp/rmon; P=$D/p; IV=10; KEEP=360; KEEPL=1440
mkdir -p "$P"
T=$(printf '\t')
NCPU=$(grep -c '^processor' /proc/cpuinfo); [ "$NCPU" -gt 0 ] || NCPU=1
n=0

# подпись датчика Wi-Fi: диапазон радиомодуля (2,4 / 5 / 6 ГГц) по первой частоте его phy, иначе имя датчика
wband() {
  ph=$(readlink "$1/device" 2>/dev/null); ph=${ph##*/}
  f=$(iw phy "$ph" info 2>/dev/null | grep -m1 -oE '\* [0-9]+(\.[0-9]+)? MHz' | grep -oE '[0-9]+' | head -n1)
  case "$f" in 24[0-9][0-9]) echo '2,4 ГГц' ;; 5[0-8][0-9][0-9]|59[0-2][0-9]) echo '5 ГГц' ;; 59[3-9][0-9]|6*|7*) echo '6 ГГц' ;; *) echo "$2" ;; esac
}
# Датчики одного радиочипа (2,4 и 5 ГГц на одном чипе, как у MT7981) показывают одну и ту же температуру —
# такие сливаются в один с подписью «2,4 + 5 ГГц»; отдельными остаются только датчики разных чипов.
WB=$(for h in /sys/class/hwmon/hwmon*; do
  nm=; read nm <"$h/name" 2>/dev/null
  case "$nm" in *cpu*|'') continue ;; esac
  ph=$(readlink "$h/device" 2>/dev/null); ph=${ph##*/}
  chip=$(readlink -f "/sys/class/ieee80211/$ph/device" 2>/dev/null); [ -n "$chip" ] || chip=$h
  printf '%s\t%s\t%s\n' "$chip" "$h" "$(wband "$h" "$nm")"
done | awk -F'\t' '{ if (!($1 in H)) { H[$1] = $2; o[++n] = $1; L[$1] = $3 } else L[$1] = L[$1] " + " $3 }
  END { for (i = 1; i <= n; i++) { l = L[o[i]]; gsub(/ ГГц \+ /, " + ", l); printf "%s\t%s\n", H[o[i]], l } }')
WB="$WB
"

# --- трафик по адресам (на роутере, через который идёт интернет) ---
# Раз в цикл: приращение байт каждого соединения из conntrack (нужен nf_conntrack_acct=1) раскладывается
# по паре «устройство → удалённый адрес» и копится в 5-минутных корзинах $D/tr/<ts/300>:
#   устройство<TAB>адрес<TAB>домен<TAB>отправлено<TAB>получено   (устройство «@» — сам роутер)
# Домен — из журнала DNS-запросов dnsmasq (/tmp/rmon-dns.log, включается setup.sh dnslog on):
# $D/dns.map — IP<TAB>запрошенное имя<TAB>когда видели.
CT=/proc/net/nf_conntrack; TR=$D/tr; DL=/tmp/rmon-dns.log
mkdir -p "$TR"; : >>"$D/ct.prev"; : >>"$D/dns.map"
myips() { ip -o addr show 2>/dev/null | awk '{ split($4, a, "/"); printf "%s ", a[1] }'; }
# адреса VPN-серверов WireGuard/AmneziaWG: трафик роутера к ним дублирует трафик устройств, ушедший в туннель
wgeps() { for c in awg wg; do command -v $c >/dev/null && $c show all endpoints 2>/dev/null; done | awk '{ e = $3; sub(/:[0-9]+$/, "", e); gsub(/[][]/, "", e); printf "%s ", e }'; }
MY=$(myips); EP=$(wgeps)
traffic() {
  [ -r "$CT" ] || return
  if [ -s "$DL" ]; then
    cat "$DL" >"$D/dns.new"; : >"$DL"   # dnsmasq пишет с O_APPEND — после обнуления продолжает с начала
    # IPv6 из журнала (2a00:1450::5) — в полную форму, как в conntrack (2a00:1450:0000:…:0005)
    awk -F'\t' -v now="$ts" -v MF="$D/dns.map" '
      function x6(a,   h, t, n, m, i, g, o) {
        if (a !~ /:/) return a
        if (index(a, "::")) { h = substr(a, 1, index(a, "::") - 1); t = substr(a, index(a, "::") + 2) } else { h = a; t = "" }
        n = (h == "") ? 0 : split(h, H, ":"); m = (t == "") ? 0 : split(t, T6, ":"); o = ""
        for (i = 1; i <= n; i++) o = o (o == "" ? "" : ":") substr("0000" H[i], length(H[i]) + 1)
        for (i = 0; i < 8 - n - m; i++) o = o (o == "" ? "" : ":") "0000"
        for (i = 1; i <= m; i++) o = o ":" substr("0000" T6[i], length(T6[i]) + 1)
        return o }
      FILENAME == MF { if (now - $3 < 86400) { M[$1] = $2; T[$1] = $3 }; next }
      { n = split($0, f, " "); s = 0; for (i = 1; i <= n; i++) if (f[i] ~ /^dnsmasq/) { id = f[i + 1]; s = i + 3; break }
        if (!s) next
        if (f[s] ~ /^query\[/) { Q[id] = f[s + 1]; next }
        if ((f[s] == "reply" || f[s] == "cached") && f[s + 2] == "is" && f[s + 3] ~ /^[0-9a-f.:]+$/ && f[s + 3] ~ /[.:]/) {
          ip = x6(f[s + 3]); M[ip] = (id in Q) ? Q[id] : f[s + 1]; T[ip] = now } }
      END { for (i in M) printf "%s\t%s\t%s\n", i, M[i], T[i] }' "$D/dns.map" "$D/dns.new" >"$D/dns.tmp" && mv "$D/dns.tmp" "$D/dns.map"
    rm -f "$D/dns.new"
  fi
  bf=$TR/$((ts / 300)); : >>"$bf"
  # соединения прокси (sing-box, xray и т. п.) повторяют трафик устройств, перехваченный прозрачным прокси, —
  # устройствам он уже засчитан; их удалённые адрес:порт исключаются
  PX=$(netstat -ntup 2>/dev/null | awk '$NF ~ /\/(sing-box|xray|v2ray|mihomo|clash|hysteria|trojan|ss-local|ss-redir|redsocks|tun2socks|naive)/ { printf "%s ", $5 }')
  # первый замер после запуска только запоминает счётчики: уже открытые соединения несут объём с момента открытия
  awk -F'\t' -v first="$CTFIRST" -v MY=" $MY" -v EP=" $EP " -v PX=" $PX" -v MF="$D/dns.map" -v PF="$D/ct.prev" -v BF="$bf" -v CTF="$CT" -v PN="$D/ct.prev.new" -v BN="$bf.new" '
    function priv(a) { return a ~ /^(10\.|192\.168\.|127\.|169\.254\.|172\.(1[6-9]|2[0-9]|3[01])\.|22[4-9]\.|2[3-5][0-9]\.|0\.)/ || a ~ /^(fe[89ab]|fc|fd|ff|::|0000:)/ }
    function mine(a) { return index(MY " ", " " a " ") > 0 }
    FILENAME == MF { nm[$1] = $2; next }
    # ct.prev: ключ, байты туда, байты обратно, сколько замеров подряд соединения не было видно.
    # Чтение /proc/net/nf_conntrack во время изменений таблицы иногда пропускает записи — пропавшее
    # соединение помним ещё 6 замеров, иначе при следующем появлении весь его объём засчитался бы заново
    FILENAME == PF { po[$1] = $2; pr[$1] = $3; pa[$1] = $4 + 0; next }
    FILENAME == BF { k = $1 "\t" $2; N[k] = $3; U[k] = $4; G[k] = $5; next }
    # ключ соединения — протокол и исходный кортеж (адреса, порты) до первого packets=; поля начиная с 5-го
    # (у TCP 5-е — таймаут, 6-е — состояние: они меняются и в ключ не входят)
    { n = split($0, f, " "); key = f[3]; s1 = d1 = s2 = p1 = ""; b1 = b2 = -1; inkey = 1
      for (i = 5; i <= n; i++) {
        if (f[i] ~ /^packets=/) inkey = 0
        if (inkey && f[i] ~ /=/) key = key " " f[i]   # без состояния TCP (ESTABLISHED → TIME_WAIT) и таймаута
        if (f[i] ~ /^src=/) { if (s1 == "") s1 = substr(f[i], 5); else if (s2 == "") s2 = substr(f[i], 5) }
        else if (f[i] ~ /^dst=/ && d1 == "") d1 = substr(f[i], 5)
        else if (f[i] ~ /^dport=/ && p1 == "") p1 = substr(f[i], 7)
        else if (f[i] ~ /^bytes=/) { if (b1 < 0) b1 = substr(f[i], 7) + 0; else { b2 = substr(f[i], 7) + 0; break } }
      }
      if (b1 < 0 || b2 < 0 || (key in seen)) next
      seen[key] = 1; printf "%s\t%.0f\t%.0f\t0\n", key, b1, b2 > PN
      if (key in po) { du = b1 - po[key]; dd = b2 - pr[key]; if (du < 0 || dd < 0) { du = b1; dd = b2 } } else { du = b1; dd = b2 }
      # у аппаратно ускоренных соединений (HW_OFFLOAD) ядро иногда скачком прибавляет к счётчику ровно 2^32;
      # за 10 с столько пройти не может — такой скачок отбрасываем
      while (du >= 4294967296) du -= 4294967296; while (dd >= 4294967296) dd -= 4294967296
      if (first || du + dd <= 0) next
      if (!priv(s1) && !mine(s1)) { r = s1; c = s2; up = dd; dn = du }   # входящее из интернета (проброс порта, торрент)
      else { r = d1; c = s1; up = du; dn = dd }
      if (priv(r) || mine(r)) next                                      # внутри локальной сети
      if (mine(c)) { if (index(EP, " " r " ") || index(PX " ", " " r ":" p1 " ")) next; c = "@" }
      k = c "\t" r; U[k] += up; G[k] += dn; if (r in nm) N[k] = nm[r]
    }
    END { for (k in po) if (!(k in seen) && pa[k] < 6) printf "%s\t%.0f\t%.0f\t%d\n", k, po[k], pr[k], pa[k] + 1 > PN
          for (k in U) printf "%s\t%s\t%.0f\t%.0f\n", k, N[k], U[k], G[k] > BN; close(BN); close(PN) }
  ' "$D/dns.map" "$D/ct.prev" "$bf" "$CT"
  [ -f "$bf.new" ] && mv "$bf.new" "$bf"
  if [ -f "$D/ct.prev.new" ]; then mv "$D/ct.prev.new" "$D/ct.prev"; else : >"$D/ct.prev"; fi
  CTFIRST=0
}
CTFIRST=1

while :; do
  ts=$(date +%s)
  read up _ </proc/uptime; up=${up%.*}${up#*.}; up=${up#0}   # 1/100 с

  # температура: CPU (thermal_zone0) и самый горячий из остальных датчиков (обычно Wi-Fi)
  ct=0; read ct </sys/class/thermal/thermal_zone0/temp 2>/dev/null
  # wt.now — каждый радиомодуль отдельно: подпись<TAB>милли-°C
  wt=0
  printf '%s' "$WB" | while IFS="$T" read -r h lb; do
    [ -n "$h" ] || continue
    t=0; read t <"$h/temp1_input" 2>/dev/null
    printf '%s\t%s\n' "$lb" "${t:-0}"
  done >"$D/wt.now"
  while IFS="$T" read -r lb t; do [ "${t:-0}" -gt "$wt" ] 2>/dev/null && wt=$t; done <"$D/wt.now"

  awk -v ts="$ts" -v up="$up" -v ct="${ct:-0}" -v wt="$wt" -v nc="$NCPU" '
    FILENAME == "/proc/stat" && $1 == "cpu" { u=$2; ni=$3; sy=$4; id=$5; io=$6; irq=$7; si=$8 }
    FILENAME == "/proc/meminfo" { sub(/:$/, "", $1); m[$1] = $2 }
    FILENAME == "/proc/loadavg" { l1=$1; l5=$2; l15=$3; split($4, a, "/"); np=a[2] }
    FILENAME == "/proc/vmstat" && $1 == "pswpin" { pin=$2 }
    FILENAME == "/proc/vmstat" && $1 == "pswpout" { pout=$2 }
    END {
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s", ts, up, u, ni, sy, id, io, irq, si
      printf "\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d", m["MemTotal"], m["MemAvailable"], m["MemFree"], m["Buffers"], m["Cached"], m["SReclaimable"], m["SUnreclaim"], m["AnonPages"], m["Shmem"], m["SwapTotal"], m["SwapFree"]
      printf "\t%s\t%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\n", l1, l5, l15, np, ct, wt, nc, pin, pout
    }' /proc/stat /proc/meminfo /proc/loadavg /proc/vmstat >"$D/sys.now"
  cat "$D/sys.now" >>"$D/sys.tsv"

  # интерфейсы: ts, имя, rx байт, tx байт (без lo и без нулевых)
  awk -v ts="$ts" 'NR > 2 { sub(/^ +/, ""); i = index($0, ":"); nm = substr($0, 1, i - 1); split(substr($0, i + 1), f, " ")
    if (nm != "lo" && (f[1] + f[9]) > 0) printf "%s\t%s\t%.0f\t%.0f\n", ts, nm, f[1], f[9] }' /proc/net/dev >"$D/net.now"
  cat "$D/net.now" >>"$D/net.tsv"

  # процессы: pid, ppid, тики CPU (utime+stime), RSS кБ, потоки, состояние, starttime, имя
  {
    printf '#\t%s\n' "$up"
    cd /proc && cat [0-9]*/stat 2>/dev/null | awk '{ c = $0; sub(/^[0-9]+ \(/, "", c); sub(/\) [A-Za-z] .*/, "", c); gsub(/\t/, " ", c)
      r = $0; sub(/.*\) /, "", r); split(r, f, " ")
      printf "%s\t%s\t%d\t%d\t%d\t%s\t%s\t%s\n", $1, f[2], f[12] + f[13], f[22] * 4, f[18], f[1], f[20], c }'
  } >"$P/$ts.tmp" && mv "$P/$ts.tmp" "$P/$ts"
  cd /

  # пики за час: для каждого процесса максимум CPU (доля ядра за 10 с) и памяти по 10-минутным корзинам.
  # pk.tsv: ключ(pid/starttime) корзина maxCPU maxRSS тикиCPU uptime имя; хранятся 7 корзин (60–70 мин).
  # Так API не перечитывает 360 снимков ради пиков.
  [ -f "$D/pk.tsv" ] || : >"$D/pk.tsv"
  if [ -n "$PREV" ] && [ -f "$PREV" ]; then
    awk -F'\t' -v OFS='\t' -v b=$((ts / 600)) -v PF="$PREV" -v NW="$P/$ts" '
      FILENAME == PF { if (FNR == 1) pu = $2; else pt[$1 "/" $7] = $3; next }
      FILENAME == NW { if (FNR == 1) { u = $2; next }
        k = $1 "/" $7; if (!(k in pt) || u <= pu) next
        cur[k] = ($3 - pt[k]) / (u - pu); rs[k] = $4; tk[k] = $3; nm[k] = $8; next }
      { if ($2 < b - 6) next
        if ($2 == b && ($1 in cur)) { m[$1] = $3; r[$1] = $4; next }
        print }
      END { for (k in cur) print k, b, ((k in m) && m[k] > cur[k] ? m[k] : cur[k]), ((k in r) && r[k] > rs[k] ? r[k] : rs[k]), tk[k], u, nm[k] }
    ' "$PREV" "$P/$ts" "$D/pk.tsv" >"$D/pk.tmp" && mv "$D/pk.tmp" "$D/pk.tsv"
  fi
  PREV=$P/$ts

  traffic

  n=$((n + 1))
  # раз в минуту: суточная история и командные строки
  if [ $((n % 6)) -eq 1 ]; then
    cat "$D/sys.now" >>"$D/sys1m.tsv"
    cat "$D/net.now" >>"$D/net1m.tsv"
    for p in /proc/[0-9]*; do
      [ -r "$p/cmdline" ] || continue
      printf '%s\t' "${p#/proc/}"; cat "$p/cmdline" 2>/dev/null | tr '\0\t\n' '   '; echo
    done >"$D/cmd.tmp" 2>/dev/null && mv "$D/cmd.tmp" "$D/cmd.tsv"
  fi

  # чистка старого: раз в 5 минут
  if [ $((n % 30)) -eq 0 ]; then
    tail -n $KEEP "$D/sys.tsv" >"$D/t" && mv "$D/t" "$D/sys.tsv"
    tail -n $KEEPL "$D/sys1m.tsv" >"$D/t" && mv "$D/t" "$D/sys1m.tsv"
    awk -v m=$((ts - 3600)) '$1 > m' "$D/net.tsv" >"$D/t" && mv "$D/t" "$D/net.tsv"
    awk -v m=$((ts - 86400)) '$1 > m' "$D/net1m.tsv" >"$D/t" && mv "$D/t" "$D/net1m.tsv"
    # корзины трафика по адресам — сутки (+ запас), свои адреса и VPN-серверы — перечитать
    old=$((ts / 300 - 290)); for f in "$TR"/*; do b=${f##*/}; case "$b" in *[!0-9]*|'') rm -f "$f" ;; *) [ "$b" -lt "$old" ] && rm -f "$f" ;; esac; done
    MY=$(myips); EP=$(wgeps)
  fi
  set -- "$P"/[0-9]*
  if [ $# -gt $((KEEP + 2)) ]; then   # +2 запасных: API читает последние 360, а старейший может удаляться в этот момент
    k=$(($# - KEEP - 2)); for f in "$@"; do [ $k -gt 0 ] || break; rm -f "$f"; k=$((k - 1)); done
  fi

  sleep $IV
done
