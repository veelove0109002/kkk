#!/bin/sh
# Cloudflare Tunnel 完全卸载与清理脚本（无备份版，执行后自动删除自身）
# 用法：chmod +x ./uninstall-cloudflared.sh && sh ./uninstall-cloudflared.sh

set -e

echo "=== Cloudflare Tunnel 卸载脚本启动（无备份） ==="

# 打印并容错执行
_do() {
  echo "+ $*"
  sh -c "$*" 2>/dev/null || true
}

echo "[1/6] 停止并禁用 Cloudflare Tunnel 服务"
if [ -x /etc/init.d/cloudflared ]; then
  _do "/etc/init.d/cloudflared stop"
  _do "/etc/init.d/cloudflared disable"
fi

echo "[2/6] 卸载 Cloudflare Tunnel 包（若已安装）"
_do "opkg update"
# 卸载所有语言包
_do "opkg list-installed | grep 'luci-i18n-cloudflared' | cut -f1 -d' ' | xargs opkg remove"
_do "opkg remove luci-app-cloudflared"
_do "opkg remove cloudflared"
_do "opkg autoremove"

echo "[3/6] 删除配置与所有残留文件（不可逆）"
# 配置
_do "rm -f /etc/config/cloudflared"
# LuCI 控制器/模型/视图
_do "rm -f /usr/lib/lua/luci/controller/cloudflared.lua"
_do "rm -rf /usr/lib/lua/luci/controller/cloudflared"
_do "rm -rf /usr/lib/lua/luci/model/cbi/cloudflared"
_do "rm -rf /usr/lib/lua/luci/view/cloudflared"
# 共享资源与脚本
_do "rm -rf /usr/share/cloudflared"
_do "rm -f /usr/bin/cloudflared*"
_do "rm -f /usr/sbin/cloudflared*"
# 启动脚本与开机链接
_do "rm -f /etc/init.d/cloudflared"
_do "find /etc/rc.d -maxdepth 1 -type l -name '*cloudflared*' -exec rm -f {} +"
# UCI 默认脚本、热插拔钩子
_do "rm -f /etc/uci-defaults/*cloudflared*"
_do "find /etc/hotplug.d -type f -name '*cloudflared*' -exec rm -f {} +"
# 运行时与日志
_do "rm -rf /tmp/cloudflared* /var/run/cloudflared* /var/log/cloudflared*"
# 可能的证书和配置文件
_do "rm -rf /etc/cloudflared"
_do "rm -rf /root/.cloudflared"

echo "[4/6] 移除可能的计划任务"
if [ -f /etc/crontabs/root ]; then
  _do "sed -i '/cloudflared/d' /etc/crontabs/root"
  _do "/etc/init.d/cron reload"
fi

echo "[5/6] 刷新 LuCI 缓存并重载 Web/防火墙"
_do "rm -f /tmp/luci-indexcache"
_do "rm -rf /tmp/luci-modulecache/*"
if command -v luci-reload >/dev/null 2>&1; then
  _do "luci-reload"
fi
[ -x /etc/init.d/uhttpd ] && _do "/etc/init.d/uhttpd reload"
[ -x /etc/init.d/nginx ] && _do "/etc/init.d/nginx reload"
[ -x /etc/init.d/firewall ] && _do "/etc/init.d/firewall reload"

sync
echo "✓ Cloudflare Tunnel 已卸载并完成清理。若 LuCI 菜单仍缓存，请清空浏览器缓存或重新登录。"

# [6/6] 删除自身脚本
SCRIPT_PATH="$0"
case "$SCRIPT_PATH" in
  */* ) ;;
  *   ) SCRIPT_PATH="./$SCRIPT_PATH" ;;
esac
_do "rm -f -- \"$SCRIPT_PATH\""

exit 0