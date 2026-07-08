#!/bin/sh
# ============================================================
# OpenWrt Nginx & API 连通性诊断脚本
# 功能：
#   1. 检查 Nginx 状态，非 running 时排查配置错误
#   2. 通过 curl 127.0.0.1/api/copyright1 检测接口连通性
#   3. 对比 DNS 解析 IP 与 nftables 放行 IP 是否匹配
# ============================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

pass()  { echo -e "${GREEN}[PASS]${NC} $*"; }
fail()  { echo -e "${RED}[FAIL]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
step()  { echo ""; echo "============================================"; echo -e "  $*"; echo "============================================"; }

# ---- 步骤 1: Nginx 状态与配置检查 ----
step "1. Nginx 状态检查"

NGINX_INIT="/etc/init.d/nginx"

if [ ! -x "$NGINX_INIT" ]; then
    fail "找不到 $NGINX_INIT"
    exit 1
fi

STATUS=$($NGINX_INIT status 2>&1) || true
echo "$STATUS"

if echo "$STATUS" | grep -q "running"; then
    pass "Nginx 运行中"
else
    fail "Nginx 未运行，开始排查..."
    echo ""

    # 1a. 测试配置文件语法
    info "检查配置文件语法..."
    if nginx -t 2>&1; then
        pass "nginx.conf 语法正确"
    else
        fail "nginx.conf 存在语法错误（见上方输出）"
    fi

    # 1b. 检查端口占用
    echo ""
    info "检查 80 / 443 端口占用..."
    if netstat -tlnp 2>/dev/null | grep -qE ':(80|443)\b'; then
        warn "80 或 443 端口已被占用："
        netstat -tlnp 2>/dev/null | grep -E ':(80|443)\b' || ss -tlnp | grep -E ':(80|443)\b'
    else
        pass "80 / 443 端口未被占用"
    fi

    # 1c. 检查 nginx 二进制
    echo ""
    info "Nginx 二进制：$(which nginx 2>/dev/null || echo '未找到')"
    if which nginx >/dev/null 2>&1; then
        nginx -v 2>&1
    fi

    # 1d. 检查日志最近错误
    echo ""
    info "最近 5 条 Nginx 错误日志："
    if [ -f /var/log/nginx/localrouter_error.log ]; then
        tail -5 /var/log/nginx/localrouter_error.log 2>/dev/null || echo "  (无日志)"
    else
        warn "错误日志文件不存在"
    fi
fi

# ---- 步骤 2: API 接口连通性检测 ----
step "2. API 接口连通性检测"

TEST_URL="http://127.0.0.1/api/copyright1"
info "测试: curl -s --connect-timeout 5 $TEST_URL"

RESPONSE=$(curl -s --connect-timeout 5 "$TEST_URL" 2>&1) || true
echo "响应: $RESPONSE"

if [ "$RESPONSE" = "1" ]; then
    pass "API 接口正常，返回 1"
else
    fail "API 接口异常（期望 1，实际: $RESPONSE）"
    echo ""

    # 2a. 测试 127.0.0.1:80 端口
    info "测试 TCP 连接 127.0.0.1:80 ..."
    if timeout 3 nc -zv 127.0.0.1 80 2>&1; then
        pass "127.0.0.1:80 TCP 连接正常"
    else
        fail "127.0.0.1:80 TCP 连接失败"
    fi

    # 2b. 测试 127.0.0.1:443 端口
    info "测试 TCP 连接 127.0.0.1:443 ..."
    if timeout 3 nc -zv 127.0.0.1 443 2>&1; then
        pass "127.0.0.1:443 TCP 连接正常"
    else
        fail "127.0.0.1:443 TCP 连接失败"
    fi

    # 2c. 测试上游 HTTPS 连通性
    echo ""
    info "测试上游 scontent-ph-1.nybl.fbcdn.net:443 SSL 握手..."
    if command -v openssl >/dev/null 2>&1; then
        SSL_OUT=$(echo "Q" | timeout 5 openssl s_client -connect scontent-ph-1.nybl.fbcdn.net:443 -servername scontent-ph-1.nybl.fbcdn.net 2>&1) || true
        if echo "$SSL_OUT" | grep -q "Verify return code"; then
            echo "$SSL_OUT" | grep -E "(subject=|issuer=|Verify return code)"
            if echo "$SSL_OUT" | grep -q "Verify return code: 0"; then
                pass "上游 SSL 握手成功"
            else
                warn "上游 SSL 握手完成但证书验证不通过"
            fi
        else
            fail "上游 SSL 握手失败："
            echo "$SSL_OUT" | tail -5
        fi
    else
        warn "openssl 未安装，跳过 SSL 握手测试"
    fi
fi

# ---- 步骤 3: DNS 解析与 nftables 放行 IP 对比 ----
step "3. DNS 解析 vs nftables 放行 IP 对比"

DOMAIN="scontent-ph-1.nybl.fbcdn.net"
SET_NAME="set_wifidogx_inner_trust_domains"

# 3a. DNS 解析
info "解析域名: $DOMAIN"
DNS_IPS=""

if command -v nslookup >/dev/null 2>&1; then
    DNS_IPS=$(nslookup "$DOMAIN" 2>/dev/null | grep -A10 "Name:" | grep "Address" | awk '{print $NF}' | grep -v ':' | sort -u)
elif command -v ping >/dev/null 2>&1; then
    DNS_IPS=$(ping -c1 -W1 "$DOMAIN" 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
fi

if [ -z "$DNS_IPS" ]; then
    fail "DNS 解析 $DOMAIN 失败"
    echo "  请检查 DNS 配置或网络连通性"
else
    echo "$DNS_IPS" | while read -r ip; do
        [ -z "$ip" ] && continue
        info "解析到 IP: $ip"
    done
fi

# 3b. 读取 nftables 放行 IP 集合
echo ""
info "读取 nftables set: $SET_NAME"

if ! command -v nft >/dev/null 2>&1; then
    fail "nft 命令不可用"
    exit 1
fi

NFT_ELEMENTS=""
for TABLE in "inet filter" "ip filter"; do
    ELEMS=$(nft list set $TABLE $SET_NAME 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | sort -u) || true
    if [ -n "$ELEMS" ]; then
        NFT_ELEMENTS="$ELEMS"
        break
    fi
done

if [ -z "$NFT_ELEMENTS" ]; then
    NFT_ELEMENTS=$(nft list ruleset 2>/dev/null | grep -A50 "$SET_NAME" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | sort -u)
fi

if [ -z "$NFT_ELEMENTS" ]; then
    fail "未找到 nftables set: $SET_NAME"
    info "当前 nftables 中所有 set："
    nft list sets 2>/dev/null || echo "  (无法列出)"
else
    echo "$NFT_ELEMENTS" | while read -r nft_ip; do
        [ -z "$nft_ip" ] && continue
        info "放行 IP: $nft_ip"
    done
fi

# 3c. 对比
echo ""
info "=== 对比结果 ==="

if [ -z "$DNS_IPS" ] || [ -z "$NFT_ELEMENTS" ]; then
    fail "无法对比（缺少 DNS 解析或 nftables 数据）"
else
    ALL_MATCH=true
    for dns_ip in $DNS_IPS; do
        if echo "$NFT_ELEMENTS" | grep -qw "$dns_ip"; then
            pass "$dns_ip 已在 nftables 放行集合中"
        else
            fail "$dns_ip 不在 nftables 放行集合中！"
            ALL_MATCH=false
        fi
    done
    if $ALL_MATCH; then
        echo ""
        pass "所有解析 IP 均在放行集合中"
    fi
fi

echo ""
echo "============================================"
echo "  诊断完成"
echo "============================================"
