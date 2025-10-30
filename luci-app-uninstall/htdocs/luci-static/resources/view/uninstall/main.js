// SPDX-License-Identifier: Apache-2.0
'use strict';
'require view';
'require ui';
'require rpc';

return view.extend({
	// Centralized RPC client
	_rpc: rpc.declare({
		object: 'luci.uninstall',
		// Placeholder - actual calls are done via L.Request to controller actions
		// This just establishes a base for any potential future RPC usage.
	}),

	// Custom HTTP client using LuCI's modern L.Request API
	_uciRequest: function(url, options) {
		options = options || {};
		var token = (L.env && (L.env.token || L.env.csrf_token)) || '';
		var headers = {
			'Accept': 'application/json',
			'X-CSR-FToken': token
		};

		if (options.method === 'POST') {
			headers['Content-Type'] = 'application/x-www-form-urlencoded; charset=utf-8';
		}
		
		var opts = Object.assign({
			headers: headers,
			// LuCI's L.Request uses `data` for url-encoded POST body
			data: options.body ? new URLSearchParams(options.body).toString() : null
		}, options);
		
		// L.Request wants data as an object, but our controller is simple.
		// Stringify data to avoid issues.
		if (opts.method === 'POST' && typeof opts.body === 'object') {
			var params = new URLSearchParams();
			for (var key in opts.body) {
				params.append(key, opts.body[key]);
			}
			opts.data = params.toString();
			delete opts.body;
		}

		return L.Request.request(url, opts)
			.then(function(res) {
				if (!res.ok) {
					throw new Error('HTTP error ' + res.status);
				}
				return res.json();
			});
	},

	load: function() {
		return this._uciRequest(L.url('admin/system/uninstall/list'));
	},

	render: function(data) {
		var pkgs = (Array.isArray(data.packages) ? data.packages : [])
			.filter(function(p) { return p.name && p.name.indexOf('luci-app-') === 0; });
		
		var root = E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('Uninstall Packages')),
			E('div', { 'class': 'cbi-section-descr' }, _('Select installed packages to uninstall. You can optionally remove their configuration files as well.')),
			E('div', { 'style': 'margin:8px 0; display:flex; gap:8px; align-items:center;' }, [
				E('input', { id: 'filter', type: 'text', placeholder: _('Filter by name…'), 'style': 'flex:1;', 'spellcheck': 'false' }),
				E('label', { 'style': 'display:flex; align-items:center; gap:6px;' }, [
					E('input', { id: 'purge', type: 'checkbox' }),
					_('Remove configuration files')
				])
			])
		]);

		var grid = E('div', { 'class': 'card-grid', 'style': 'display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));gap:12px;margin-top:8px;' });
		root.appendChild(grid);
		
		var DEFAULT_ICON = 'data:image/svg+xml;base64,' + btoa('<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 24 24" fill="none" stroke="#6b7280" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="7" width="18" height="14" rx="2" ry="2"/><path d="M9 7V5a3 3 0 0 1 6 0v2"/></svg>');

		var renderGrid = function(filter) {
			// Clear grid
			while (grid.firstChild) grid.removeChild(grid.firstChild);

			var filteredPkgs = pkgs;
			if (filter) {
				filter = filter.toLowerCase();
				filteredPkgs = pkgs.filter(function(p) { return p.name.toLowerCase().includes(filter); });
			}

			if (filteredPkgs.length === 0) {
				grid.appendChild(E('em', { 'class': 'cbi-value-none' }, _('No matching packages found.')));
			}

			filteredPkgs.forEach(function(pkg) {
				var img = E('img', { src: L.resource('icons/' + pkg.name + '.png'), alt: pkg.name, width: 48, height: 48, 'style': 'border-radius:8px;background:#f3f4f6;object-fit:contain;' });
				img.addEventListener('error', function(){ img.src = DEFAULT_ICON; });
				
				var btn = E('button', { type: 'button', 'class': 'btn cbi-button cbi-button-remove', 'style': 'margin-top:8px;' }, _('Uninstall'));
				btn.addEventListener('click', this.handleUninstall.bind(this, pkg.name));

				var card = E('div', { 'class': 'pkg-card', 'style': 'display:flex;flex-direction:column;align-items:flex-start;padding:12px;border:1px solid #e5e7eb;border-radius:12px;background:#fff;box-shadow:0 1px 2px rgba(0,0,0,0.04);' }, [
					img,
					E('div', { 'style': 'font-weight:600;color:#111827;margin-top:6px;word-break:break-all;' }, pkg.name),
					E('div', { 'style': 'font-size:12px;color:#6b7280;margin-top:2px;' }, (pkg.version || '')),
					btn
				]);
				grid.appendChild(card);
			}.bind(this));
		}.bind(this);
		
		var filterInput = root.querySelector('#filter');
		filterInput.addEventListener('input', function(ev) { renderGrid(ev.target.value); });
		
		renderGrid();
		return root;
	},

	handleUninstall: function(name) {
		var purge = document.getElementById('purge').checked;
		var title = _('Uninstall Package');
		var desc = purge ? _('Are you sure you want to uninstall "%s" and remove its configuration files?').format(name) : _('Are you sure you want to uninstall "%s"?').format(name);

		ui.confirm(title, desc, { dangerous: true }).then(function(is_confirmed) {
			if (!is_confirmed) return;

			ui.showModal(title, [
				E('p', {}, _('Uninstalling %s...').format(name)),
				E('pre', { 'id': 'uninstall-log', 'style': 'max-height:260px;overflow:auto;background:#0b1024;color:#cbd5e1;padding:10px;border-radius:8px;' }, '')
			]);

			var logEl = document.getElementById('uninstall-log');
			var println = function(s) {
				logEl.appendChild(document.createTextNode(s + '\n'));
				logEl.scrollTop = logEl.scrollHeight;
			};

			println(_('Preparing uninstall...'));
			
			var body = {
				package: name,
				purge: purge ? '1' : '0',
				force: '1' // Always force dependencies for luci-app-*
			};

			return this._uciRequest(L.url('admin/system/uninstall/remove'), { method: 'POST', body: body })
				.then(function(res) {
					println(res.message || '');
					if (res.ok) {
						println('\n' + _('Uninstall successful. Reloading package list...'));
						ui.hideModal();
						// Simple reload of the view to reflect changes
						return L.resolveDefault(L.require('view.uninstall.main').render(), 'html').then(function (html) {
							var newContent = html.firstElementChild;
							var oldContent = document.querySelector('.cbi-map');
							if (oldContent && newContent) {
								oldContent.parentNode.replaceChild(newContent, oldContent);
							}
						});
					} else {
						throw new Error(res.message || _('Uninstall failed for an unknown reason.'));
					}
				})
				.catch(function(err) {
					println('\n! ERROR: ' + err.message);
					ui.addNotification(null, E('p', {}, _('Uninstall failed: %s').format(err.message)), 'danger');
					// Add a close button to the modal on error
					var modalContent = logEl.parentNode;
					var closeBtn = E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Close'));
					modalContent.appendChild(E('div', {'class': 'right', 'style': 'margin-top:10px;'}, closeBtn));
				});
		}.bind(this));
	},

	addFooter: function() { return E('div', {}); }
});
