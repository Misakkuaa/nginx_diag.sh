#!/bin/sh
# OpenWrt 综合诊断脚本 - Nginx / API / DHCP / 网站 / DNS-nftables

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

# === 1. Nginx 状态 ===
NGINX_INIT="/etc/init.d/nginx"
if [ ! -x "$NGINX_INIT" ]; then
    fail "1. Nginx: 初始化脚本不存在"
else
    STATUS=$($NGINX_INIT status 2>&1) || true
    if echo "$STATUS" | grep -q "running"; then
        pass "1. Nginx: 运行中"
    else
        fail "1. Nginx: 未运行"
        NGINX_T=$(nginx -t 2>&1) || true
        if echo "$NGINX_T" | grep -q "syntax is ok"; then
            pass "   配置语法正确"
        else
            fail "   配置语法错误: $(echo "$NGINX_T" | tail -1)"
        fi
    fi
fi

# === 2. API 接口 ===
RESPONSE=$(curl -s --connect-timeout 5 "http://127.0.0.1/api/copyright1" 2>&1) || true
if [ "$RESPONSE" = "1" ]; then
    pass "2. API /api/copyright1: 正常"
else
    fail "2. API /api/copyright1: 异常 (期望 1, 实际: $RESPONSE)"
    timeout 2 nc -z 127.0.0.1 80 2>/dev/null && pass "   127.0.0.1:80 TCP 通" || fail "   127.0.0.1:80 TCP 不通"
fi

# === 3. DHCP 地址池 ===
if ! pgrep dnsmasq >/dev/null 2>&1; then
    fail "3. DHCP: dnsmasq 未运行"
else
    POOL_START=""
    POOL_LIMIT=""
    if command -v uci >/dev/null 2>&1; then
        POOL_START=$(uci get dhcp.lan.start 2>/dev/null || echo "")
        POOL_LIMIT=$(uci get dhcp.lan.limit 2>/dev/null || echo "")
    fi
    [ -z "$POOL_START" ] && POOL_START=$(grep "option start" /etc/config/dhcp 2>/dev/null | head -1 | awk '{print $NF}' | tr -d "'\"")
    [ -z "$POOL_LIMIT" ] && POOL_LIMIT=$(grep "option limit" /etc/config/dhcp 2>/dev/null | head -1 | awk '{print $NF}' | tr -d "'\"")
    POOL_START=${POOL_START:-100}
    POOL_LIMIT=${POOL_LIMIT:-150}

    if [ -f /tmp/dhcp.leases ]; then
        LEASE_COUNT=$(wc -l < /tmp/dhcp.leases | tr -d ' ')
    else
        LEASE_COUNT=0
    fi
    USAGE=$((LEASE_COUNT * 100 / POOL_LIMIT))

    if [ "$LEASE_COUNT" -ge "$POOL_LIMIT" ]; then
        fail "3. DHCP: 地址池已满 (${LEASE_COUNT}/${POOL_LIMIT})"
    elif [ "$USAGE" -ge 90 ]; then
        warn "3. DHCP: 使用率 ${USAGE}% (${LEASE_COUNT}/${POOL_LIMIT})"
    elif [ "$USAGE" -ge 70 ]; then
        warn "3. DHCP: 使用率 ${USAGE}% (${LEASE_COUNT}/${POOL_LIMIT})"
    else
        pass "3. DHCP: 正常 (${LEASE_COUNT}/${POOL_LIMIT}, ${USAGE}%)"
    fi
fi

# === 4. 网站可达性 ===
echo ""
info "4. 网站可达性"

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

# === 5. DNS 解析 vs nftables ===
echo ""
DOMAIN="scontent-ph-1.nybl.fbcdn.net"
SET_NAME="set_wifidogx_inner_trust_domains"

DNS_IPS=""
if command -v nslookup >/dev/null 2>&1; then
    DNS_IPS=$(nslookup "$DOMAIN" 2>/dev/null | grep -A10 "Name:" | grep "Address" | awk '{print $NF}' | grep -v ':' | sort -u)
fi
[ -z "$DNS_IPS" ] && DNS_IPS=$(ping -c1 -W1 "$DOMAIN" 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)

if [ -z "$DNS_IPS" ]; then
    fail "5. DNS: $DOMAIN 解析失败"
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
        fail "5. nftables: 未找到 set $SET_NAME"
    else
        ALL_MATCH=true
        for dns_ip in $DNS_IPS; do
            if echo "$NFT_IPS" | grep -qw "$dns_ip"; then
                pass "5. DNS/nft: $dns_ip 已放行"
            else
                fail "5. DNS/nft: $dns_ip 未放行"
                ALL_MATCH=false
            fi
        done
    fi
fi

echo ""
echo "==== 诊断完成 ===="
