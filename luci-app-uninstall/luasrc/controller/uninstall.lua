-- SPDX-License-Identifier: Apache-2.0

module("luci.controller.uninstall", package.seeall)

function index()
	if not nixio.fs.access('/etc/config') then
		return
	end

	entry({ 'admin', 'system', 'uninstall' }, view('uninstall/main'), _('Uninstall'), 90).acl_depends = { 'luci-app-uninstall' }

	entry({ 'admin', 'system', 'uninstall', 'list' }, call('action_list'), nil, 10).json = true
	entry({ 'admin', 'system', 'uninstall', 'remove' }, call('action_remove'), nil, 20).json = true
end

local sys = require 'luci.sys'
local fs = require 'nixio.fs'
local http = require 'luci.http'

function action_list()
	local pkgs = {}
	local seen = {}
	local function parse_status(path)
		local s = fs.readfile(path)
		if not s or #s == 0 then return end
		local name, ver
		for line in s:gmatch("[^\n\r]*") do
			local n = line:match("^Package:%s*(.+)$")
			if n then
				if name and not seen[name] then
					pkgs[#pkgs+1] = { name = name, version = ver or '' }
					seen[name] = true
				end
				name, ver = n, nil
			end
			local v = line:match("^Version:%s*(.+)$")
			if v then ver = v end
		end
		if name and not seen[name] then
			pkgs[#pkgs+1] = { name = name, version = ver or '' }
			seen[name] = true
		end
	end
	if fs.stat('/usr/lib/opkg/status') then
		parse_status('/usr/lib/opkg/status')
	elseif fs.stat('/var/lib/opkg/status') then
		parse_status('/var/lib/opkg/status')
	end
	if #pkgs == 0 then
		local out = sys.exec("opkg list-installed 2>/dev/null") or ''
		for line in out:gmatch("[^\n]+") do
			local n, v = line:match("^([^%s]+)%s+-%s+(.+)$")
			if n and not seen[n] then
				pkgs[#pkgs+1] = { name = n, version = v or '' }
				seen[n] = true
			end
		end
	end
	table.sort(pkgs, function(a,b) return a.name < b.name end)
	luci.http.prepare_content('application/json')
	luci.http.write_json({ packages = pkgs, count = #pkgs })
end

function action_remove()
	if http.getenv('REQUEST_METHOD') ~= 'POST' then
		http.status(405, 'Method Not Allowed')
		return
	end
	local pkg = http.formvalue('package')
	local purge = http.formvalue('purge') == '1'
	local force = http.formvalue('force') == '1'
	if not pkg or pkg == '' then
		http.status(400, 'Bad Request')
		luci.http.prepare_content('application/json')
		luci.http.write_json({ ok = false, message = 'Missing package name' })
		return
	end
	local logs = {}
	local function logln(s) logs[#logs+1] = s end
	local function run(cmd)
		logln('$ ' .. cmd)
		local out = sys.exec(cmd .. " 2>&1") or ''
		if #out > 0 then logln(out) end
		return out
	end
	local short = pkg:gsub('^luci%-app%-','')

	logln("=== " .. pkg .. " (最强卸载) ===")

	-- 1. 停止并禁用服务
	run(string.format("[ -x /etc/init.d/%s ] && /etc/init.d/%s stop || true", short, short))
	run(string.format("[ -x /etc/init.d/%s ] && /etc/init.d/%s disable || true", short, short))

	-- 2. 卸载主包、多语言包（i18n）、基本二进制，同名 variant
	run("opkg update")
	run("opkg list-installed | grep 'luci-i18n-"..short.."-' | cut -f1 -d' ' | xargs opkg remove")
	run(string.format("opkg remove %s", pkg))
	run(string.format("opkg remove %s", short))
	run("opkg autoremove")

	-- 3. 删除所有配置、脚本、视图、控制器、模型、共享资源、二进制、日志等
	run(string.format("rm -f /etc/config/%s", short))
	run(string.format("rm -f /usr/lib/lua/luci/controller/%s.lua", short))
	run(string.format("rm -rf /usr/lib/lua/luci/controller/%s", short))
	run(string.format("rm -rf /usr/lib/lua/luci/model/cbi/%s", short))
	run(string.format("rm -rf /usr/lib/lua/luci/view/%s", short))
	run(string.format("rm -rf /usr/share/%s", short))
	run(string.format("rm -f /usr/bin/%s*", short))
	run(string.format("rm -f /usr/sbin/%s*", short))
	run(string.format("rm -f /etc/init.d/%s", short))
	run(string.format("find /etc/rc.d -maxdepth 1 -type l -name '*%s*' -exec rm -f {} +", short))
	run(string.format("rm -f /etc/uci-defaults/*%s*", short))
	run(string.format("find /etc/hotplug.d -type f -name '*%s*' -exec rm -f {} +", short))
	run(string.format("rm -rf /tmp/%s* /var/run/%s* /var/log/%s*", short, short, short))
	run(string.format("rm -rf /etc/%s /root/.%s", short, short))

	-- 4. 清理计划任务
	if fs.stat("/etc/crontabs/root") then
		run(string.format("sed -i '/%s/d' /etc/crontabs/root", short))
		run("/etc/init.d/cron reload")
	end

	-- 5. 刷新 LuCI 缓存并重载 Web/防火墙
	run("rm -f /tmp/luci-indexcache")
	run("rm -rf /tmp/luci-modulecache/*")
	run("/etc/init.d/uhttpd reload || true")
	run("/etc/init.d/nginx reload || true")
	run("/etc/init.d/firewall reload || true")

	logln('✓ 卸载与清理完成。如界面无变化请刷新浏览器。')

	luci.http.prepare_content('application/json')
	luci.http.write_json({
		ok = true,
		message = table.concat(logs, '\n')
	})
end
