-- SPDX-License-Identifier: Apache-2.0

module("luci.controller.uninstall", package.seeall)

function index()
	if not nixio.fs.access('/etc/config') then
		return
	end

	entry({ 'admin', 'system', 'uninstall' }, view('uninstall/main'), _('Uninstall'), 90).acl_depends = { 'luci-app-uninstall' }

	local e
	e = entry({ 'admin', 'system', 'uninstall', 'list' }, call('action_list'))
	e.leaf = true
	e.acl_depends = { 'luci-app-uninstall' }

	e = entry({ 'admin', 'system', 'uninstall', 'remove' }, call('action_remove'))
	e.leaf = true
	e.acl_depends = { 'luci-app-uninstall' }
end

local http = require 'luci.http'
local sys = require 'luci.sys'
local ipkg = require 'luci.model.ipkg'
local json = require 'luci.jsonc'
local fs = require 'nixio.fs'

local function json_response(tbl, code)
	code = code or 200
	http.status(code, '')
	-- Avoid client/proxy caching
	http.header('Cache-Control', 'no-cache, no-store, must-revalidate')
	http.header('Pragma', 'no-cache')
	http.header('Expires', '0')
	http.prepare_content('application/json')
	http.write(json.stringify(tbl or {}))
end

function action_list()
	local pkgs = {}

	-- Prefer parsing status file directly for stability
	local function parse_status(path)
		local s = fs.readfile(path)
		if not s or #s == 0 then return end
		local name, ver
		for line in s:gmatch("[^\n\r]*") do
			local n = line:match("^Package:%s*(.+)$")
			if n then
				-- starting a new record, flush previous if exists
				if name then pkgs[#pkgs+1] = { name = name, version = ver or '' } end
				name, ver = n, nil
			end
			local v = line:match("^Version:%s*(.+)$")
			if v then ver = v end
		end
		if name then pkgs[#pkgs+1] = { name = name, version = ver or '' } end
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
			if n then pkgs[#pkgs+1] = { name = n, version = v or '' } end
		end
	end

	-- mark whether package looks like a LuCI app, but return all installed packages
	for _, p in ipairs(pkgs) do
		p.is_app = (p.name and p.name:match('^luci%-app%-')) and true or false
	end
	-- sort by name
	table.sort(pkgs, function(a,b) return a.name < b.name end)
	json_response({ packages = pkgs, count = #pkgs })
end

local function collect_conffiles(pkg)
	-- Try to get files list before uninstall
	local out = sys.exec(string.format("opkg files '%s' 2>/dev/null", pkg)) or ''
	local files = {}
	for line in out:gmatch("[^\n]+") do
		if line:match('^/[^%s]+') then
			files[#files+1] = line
		end
	end
	return files
end

local function remove_confs(files)
	local removed = {}
	for _, f in ipairs(files or {}) do
		-- only remove under /etc to be safe
		if f:sub(1,5) == '/etc/' and fs.stat(f) then
			fs.remove(f)
			removed[#removed+1] = f
		end
		-- also remove any corresponding symlinks in /etc/rc.d
		if f:sub(1,12) == '/etc/init.d/' then
			local base = f:match('/etc/init.d/(.+)$')
			if base then
				for rc in fs.dir('/etc/rc.d') or function() return nil end do end
				local d = '/etc/rc.d'
				local h = fs.dir(d)
				if h then
					for n in h do
						if n:match(base .. '$') then
							local p = d .. '/' .. n
							if fs.lstat(p) then fs.remove(p) end
						end
					end
				end
			end
		end
	end
	return removed
end

function action_remove()
	local body = http.content() or ''
	local data = nil
	local ct = http.getenv('CONTENT_TYPE') or ''
	if body and #body > 0 and ct:find('application/json', 1, true) then
		data = json.parse(body)
	end
	local pkg = data and data.package or http.formvalue('package')
	local purge = false
	if data and data.purge ~= nil then
		purge = data.purge and true or false
	else
		purge = http.formvalue('purge') == '1'
	end
	local force = false
	if data and data.force ~= nil then
		force = data.force and true or false
	else
		force = http.formvalue('force') == '1'
	end

	if not pkg or pkg == '' then
		return json_response({ ok = false, message = 'Missing package' }, 400)
	end

	local files
	if purge then
		files = collect_conffiles(pkg)
	end

	local logs = {}
	local function logln(s) logs[#logs+1] = s end
	local function run(cmd)
		local out = sys.exec(cmd .. " 2>&1") or ''
		logln('$ ' .. cmd)
		if #out > 0 then logln(out) end
		return out
	end

	-- derive short name from luci-app-xxx
	local short = pkg:gsub('^luci%-app%-','')

	-- 1) stop and disable service if exists
	run(string.format("[ -x /etc/init.d/%q ] && /etc/init.d/%q stop || true", short, short))
	run(string.format("[ -x /etc/init.d/%q ] && /etc/init.d/%q disable || true", short, short))

	-- 2) resolve related package names
	local related = {}
	-- meta
	related[#related+1] = 'app-meta-' .. short
	-- i18n variants discovered dynamically
	local i18n_list = sys.exec(string.format("opkg list-installed | awk '{print $1}' | grep '^luci%-i18n%-%s%-' || true", short)) or ''
	for line in i18n_list:gmatch("[^\n]+") do related[#related+1] = line end
	-- main luci-app and base pkg
	related[#related+1] = pkg
	related[#related+1] = short

	-- 3) opkg remove in order with force flags if requested; retry with --force-remove if prerm fails
	local any_removed = false
	for _, name in ipairs(related) do
		if name and #name > 0 then
			local flags = "--autoremove"
			if force then flags = "--force-removal-of-dependent-packages --force-depends " .. flags end
			local out = run(string.format("opkg remove %s '%s'", flags, name))
			local low = out:lower()
			if low:match('prerm script failed') then
				-- retry with --force-remove
				out = run(string.format("opkg remove --force-remove %s '%s'", flags, name))
				low = out:lower()
			end
			if low:match('removing') or low:match('removed') then any_removed = true end
		end
	end

	-- 4) purge residual configs/files if requested
	local removed_confs = {}
	if purge then
		removed_confs = remove_confs(files)
		local cfg1 = '/etc/config/' .. short
		local cfg2 = '/etc/config/' .. pkg
		if fs.stat(cfg1) then fs.remove(cfg1); removed_confs[#removed_confs+1] = cfg1 end
		if fs.stat(cfg2) then fs.remove(cfg2); removed_confs[#removed_confs+1] = cfg2 end
		-- remove init scripts and rc.d symlinks
		run(string.format("rm -f /etc/init.d/%q; find /etc/rc.d -maxdepth 1 -type l -name '*%s*' -exec rm -f {} + || true", short, short))
		-- remove LuCI pages (controller/model/view/resources) best effort
		run(string.format("rm -f /usr/lib/lua/luci/controller/%s.lua; rm -rf /usr/lib/lua/luci/controller/%s; rm -rf /usr/lib/lua/luci/model/cbi/%s; rm -rf /usr/lib/lua/luci/view/%s || true", short, short, short, short))
		-- remove common runtime leftovers
		run(string.format("rm -rf /tmp/%s* /var/run/%s* /var/log/%s* || true", short, short, short))
		-- remove binaries with same name if any
		run(string.format("rm -f /usr/bin/%s* /usr/sbin/%s* || true", short, short))
	end

	-- 5) refresh LuCI cache and reload services
	run("rm -f /tmp/luci-indexcache; rm -rf /tmp/luci-modulecache/* || true")
	run("[ -x /etc/init.d/uhttpd ] && /etc/init.d/uhttpd reload || true")
	run("[ -x /etc/init.d/nginx ] && /etc/init.d/nginx reload || true")

	local success = any_removed
	json_response({
		ok = success,
		message = table.concat(logs, '\n'),
		removed_configs = removed_confs
	})
end
