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

	-- try stopping init script if exists
	sys.call(string.format("/etc/init.d/%q stop >/dev/null 2>&1", pkg))

	-- remove package (honor force); preserve output for UI)
	local cmd = string.format("opkg remove %s --autoremove '%s' 2>&1", (force and '--force-removal-of-dependent-packages --force-depends' or ''), pkg)
	local output = sys.exec(cmd)
	local lower = (output or ''):lower()
	local success = (lower:match('removing') or lower:match('ok') or lower:match('removed')) and (not lower:match('failed'))

	local removed_confs = {}
	if purge then
		removed_confs = remove_confs(files)
		-- best-effort: also remove /etc/config/<pkg> if exists
		local cfg = '/etc/config/' .. pkg
		if fs.stat(cfg) then
			fs.remove(cfg)
			removed_confs[#removed_confs+1] = cfg
		end
	end

	json_response({
		ok = success,
		message = output or '',
		removed_configs = removed_confs
	})
end
