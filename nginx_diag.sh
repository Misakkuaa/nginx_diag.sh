#!/bin/sh
# OpenWrt 综合诊断脚本 - 逐层排查网络问题
# 检测顺序: 时间 → WAN/网关 → 公网 IP → DNS → Nginx → API → DHCP → Conntrack → 网站 → nftables

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

pass() { echo -e "${GREEN}[PASS]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
info() { echo -e "${BLUE}[INFO]${NC} $*"; }

echo "==== OpenWrt 综合诊断 ===="
echo ""

# === 1. 系统时间 (时间不准 → HTTPS 证书校验失败) ===
TIMENOW=$(date +%s 2>/dev/null || echo 0)
if [ "$TIMENOW" -gt 1700000000 ] 2>/dev/null; then
    pass "1. 系统时间: $(date '+%Y-%m-%d %H:%M:%S')"
else
    fail "1. 系统时间: 异常 (HTTPS 证书验证将失败)"
fi

# === 2. WAN 口 + 网关 ===
DEFAULT_ROUTE=$(ip route show default 2>/dev/null | head -1)
if [ -z "$DEFAULT_ROUTE" ]; then
    fail "2. WAN: 无默认路由, 网络已断开"
else
    GW=$(echo "$DEFAULT_ROUTE" | awk '{print $3}')
    WAN_IF=$(echo "$DEFAULT_ROUTE" | awk '{print $5}')
    WAN_IP=$(ip -4 addr show "$WAN_IF" 2>/dev/null | grep -oE 'inet [0-9.]+' | awk '{print $2}' | head -1)
    [ -n "$WAN_IP" ] && info "2. WAN ($WAN_IF): $WAN_IP  →  网关 $GW" || warn "2. WAN ($WAN_IF): 无 IPv4"
    if ping -c1 -W2 "$GW" >/dev/null 2>&1; then
        pass "   网关可达"
    else
        fail "   网关不可达 (检查光猫/上游设备)"
    fi
fi

# === 3. 公网 IP 直连 (纯 IP, 绕过 DNS) ===
echo ""
if ping -c2 -W3 8.8.8.8 >/dev/null 2>&1; then
    pass "3. 公网 IP: 8.8.8.8 可达"
else
    fail "3. 公网 IP: 8.8.8.8 不可达 (基础网络不通, 非 DNS 问题)"
fi

# === 4. DNS 解析 (本地 vs 公共 DNS) ===
echo ""
info "4. DNS 解析 (www.google.com)"

TEST_DOMAIN="www.google.com"
DNS_LOCAL=""; DNS_8=""; DNS_1=""

if command -v nslookup >/dev/null 2>&1; then
    DNS_LOCAL=$(nslookup "$TEST_DOMAIN"            2>/dev/null | grep "Address:" | awk '{print $NF}' | grep -v ':' | head -1)
    DNS_8=$(   nslookup "$TEST_DOMAIN" 8.8.8.8    2>/dev/null | grep "Address:" | awk '{print $NF}' | grep -v ':' | head -1)
    DNS_1=$(   nslookup "$TEST_DOMAIN" 1.1.1.1    2>/dev/null | grep "Address:" | awk '{print $NF}' | grep -v ':' | head -1)
fi

[ -n "$DNS_LOCAL" ] && pass "   本地 DNS:  $DNS_LOCAL"      || fail "   本地 DNS:  解析失败 (dnsmasq 异常?)"
[ -n "$DNS_8" ]     && pass "   8.8.8.8:    $DNS_8" || fail "   8.8.8.8:   解析失败 (UDP 53 被劫持或封锁)"
[ -n "$DNS_1" ]     && pass "   1.1.1.1:    $DNS_1" || fail "   1.1.1.1:   解析失败"

# === 5. Nginx 状态 ===
echo ""
NGINX_INIT="/etc/init.d/nginx"
if [ ! -x "$NGINX_INIT" ]; then
    fail "5. Nginx: 初始化脚本不存在"
else
    STATUS=$($NGINX_INIT status 2>&1) || true
    if echo "$STATUS" | grep -q "running"; then
        pass "5. Nginx: 运行中"
    else
        fail "5. Nginx: 未运行"
        NGINX_T=$(nginx -t 2>&1) || true
        echo "$NGINX_T" | grep -q "syntax is ok" && pass "   配置语法正确" || fail "   配置语法错误"
    fi
fi

# === 6. API 接口 ===
RESPONSE=$(curl -s --connect-timeout 5 "http://127.0.0.1/api/copyright1" 2>&1) || true
if [ "$RESPONSE" = "1" ]; then
    pass "6. API /api/copyright1: 正常"
else
    fail "6. API /api/copyright1: 异常 (期望 1, 实际: $RESPONSE)"
    timeout 2 nc -z 127.0.0.1 80 2>/dev/null && pass "   127.0.0.1:80 TCP 通" || fail "   127.0.0.1:80 TCP 不通"
fi

# === 7. DHCP 地址池 ===
if ! pgrep dnsmasq >/dev/null 2>&1; then
    fail "7. DHCP: dnsmasq 未运行"
else
    POOL_START=""; POOL_LIMIT=""
    if command -v uci >/dev/null 2>&1; then
        POOL_START=$(uci get dhcp.lan.start 2>/dev/null || echo "")
        POOL_LIMIT=$(uci get dhcp.lan.limit 2>/dev/null || echo "")
    fi
    [ -z "$POOL_START" ] && POOL_START=$(grep "option start" /etc/config/dhcp 2>/dev/null | head -1 | awk '{print $NF}' | tr -d "'\"")
    [ -z "$POOL_LIMIT" ] && POOL_LIMIT=$(grep "option limit" /etc/config/dhcp 2>/dev/null | head -1 | awk '{print $NF}' | tr -d "'\"")
    POOL_START=${POOL_START:-100}
    POOL_LIMIT=${POOL_LIMIT:-150}

    LEASE_COUNT=0
    [ -f /tmp/dhcp.leases ] && LEASE_COUNT=$(wc -l < /tmp/dhcp.leases | tr -d ' ')
    USAGE=$((LEASE_COUNT * 100 / POOL_LIMIT))

    if [ "$LEASE_COUNT" -ge "$POOL_LIMIT" ]; then
        fail "7. DHCP: 地址池已满 (${LEASE_COUNT}/${POOL_LIMIT})"
    elif [ "$USAGE" -ge 90 ]; then
        warn "7. DHCP: 使用率 ${USAGE}% (${LEASE_COUNT}/${POOL_LIMIT})"
    elif [ "$USAGE" -ge 70 ]; then
        warn "7. DHCP: 使用率 ${USAGE}% (${LEASE_COUNT}/${POOL_LIMIT})"
    else
        pass "7. DHCP: 正常 (${LEASE_COUNT}/${POOL_LIMIT}, ${USAGE}%)"
    fi
fi

# === 8. Conntrack 连接跟踪表 (满了 → 新连接丢弃) ===
echo ""
CT_COUNT_F="/proc/sys/net/netfilter/nf_conntrack_count"
CT_MAX_F="/proc/sys/net/netfilter/nf_conntrack_max"

if [ -f "$CT_MAX_F" ]; then
    CT_MAX=$(cat "$CT_MAX_F")
    CT_COUNT=$(cat "$CT_COUNT_F")
    CT_PCT=$((CT_COUNT * 100 / CT_MAX))
    if [ "$CT_PCT" -ge 95 ]; then
        fail "8. Conntrack: 表已满 (${CT_COUNT}/${CT_MAX}, ${CT_PCT}%) - 新连接将被丢弃"
    elif [ "$CT_PCT" -ge 80 ]; then
        warn "8. Conntrack: 使用率 ${CT_PCT}% (${CT_COUNT}/${CT_MAX})"
    else
        pass "8. Conntrack: 正常 (${CT_COUNT}/${CT_MAX}, ${CT_PCT}%)"
    fi
else
    info "8. Conntrack: 不可用 (内核模块未加载)"
fi

# === 9. 常用网站可达性 ===
echo ""
info "9. 网站可达性"

SITES="youtube:https://www.youtube.com
facebook:https://www.facebook.com
instagram:https://www.instagram.com
google:https://www.google.com
gstatic:https://www.gstatic.com/generate_204"

echo "$SITES" | while IFS=':' read -r name url; do
    [ -z "$name" ] && continue
    OUT=$(curl -k -L -sS --connect-timeout 5 --max-time 10 \
        -o /dev/null -w "%{http_code} %{time_total}" "$url" 2>&1) || true
    CODE=$(echo "$OUT" | awk '{print $1}')
    TIME=$(echo "$OUT" | awk '{print $2}')
    if echo "$CODE" | grep -qE '^[23][0-9]{2}$'; then
        pass "   $name: 可达 (HTTP $CODE, ${TIME}s)"
    elif echo "$CODE" | grep -qE '^[0-9]{3}$'; then
        warn "   $name: HTTP $CODE (${TIME}s)"
    else
        fail "   $name: 不可达"
    fi
done

# === 10. DNS 解析 vs nftables 放行 IP ===
echo ""
DOMAIN="scontent-ph-1.nybl.fbcdn.net"
SET_NAME="set_wifidogx_inner_trust_domains"

DNS_IPS=""
if command -v nslookup >/dev/null 2>&1; then
    DNS_IPS=$(nslookup "$DOMAIN" 2>/dev/null | grep "Address:" | awk '{print $NF}' | grep -v ':' | sort -u)
fi
[ -z "$DNS_IPS" ] && DNS_IPS=$(ping -c1 -W1 "$DOMAIN" 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)

if [ -z "$DNS_IPS" ]; then
    fail "10. DNS: $DOMAIN 解析失败"
else
    NFT_IPS=""
    if command -v nft >/dev/null 2>&1; then
        for TABLE in "inet filter" "ip filter"; do
            NFT_IPS=$(nft list set $TABLE $SET_NAME 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | sort -u)
            [ -n "$NFT_IPS" ] && break
        done
        [ -z "$NFT_IPS" ] && NFT_IPS=$(nft list ruleset 2>/dev/null | grep -A50 "$SET_NAME" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | sort -u)
    fi

    if [ -z "$NFT_IPS" ]; then
        fail "10. nftables: 未找到 set $SET_NAME"
    else
        for dns_ip in $DNS_IPS; do
            if echo "$NFT_IPS" | grep -qw "$dns_ip"; then
                pass "10. DNS/nft: $dns_ip 已放行"
            else
                fail "10. DNS/nft: $dns_ip 未放行"
            fi
        done
    fi
fi

echo ""
echo "==== 诊断完成 ===="
