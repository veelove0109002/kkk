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

-- Get list of all installed packages
function action_list()
	local pkgs = {}
	local seen = {}

	-- Prefer parsing status file directly for stability
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
		-- Fallback: `opkg list-installed`
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

-- Remove a package
function action_remove()
	-- Only allow POST requests for safety
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

	-- 1) Stop and disable service if exists
	run(string.format("[ -x /etc/init.d/%q ] && /etc/init.d/%q stop && /etc/init.d/%q disable", short, short, short))

	-- 2) Collect related packages
	local related = { pkg }
	-- Also find i18n packages
	local i18n_list = sys.exec(string.format("opkg list-installed | awk '{print $1}' | grep '^luci-i18n-%s-'", short)) or ''
	for line in i18n_list:gmatch("[^\n]+") do related[#related+1] = line end

	-- 3) Opkg remove
	local any_removed = false
	for _, name in ipairs(related) do
		if name and #name > 0 then
			local flags = "--autoremove"
			if force then flags = flags .. " --force-depends --force-removal-of-dependent-packages" end
			local out = run(string.format("opkg remove %s %q", flags, name))
			if out:find('Removing package') then any_removed = true end
		end
	end

	-- 4) Purge config files if requested
	if purge then
		run(string.format("rm -f /etc/config/%s", short))
		run(string.format("rm -f /etc/init.d/%s", short))
		-- remove rc.d symlinks
		run(string.format("find /etc/rc.d/ -name 'S*%s' -o -name 'K*%s' | xargs -r rm -f", short, short))
	end

	-- 5) Refresh LuCI cache
	run("rm -f /tmp/luci-indexcache")
	sys.call("/etc/init.d/uhttpd reload >/dev/null 2>&1")

	luci.http.prepare_content('application/json')
	luci.http.write_json({
		ok = any_removed,
		message = table.concat(logs, '\n')
	})
end
