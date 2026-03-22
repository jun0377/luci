
/*
	页面: 状态 -> 概览 -> 已分配的 DHCP 租约/已分配的 DHCPv6 租约
*/

'use strict';
'require baseclass';
'require rpc';
'require uci';
'require network';
'require validation';

// 声明RPC调用，用于获取DHCP租约信息
var callLuciDHCPLeases = rpc.declare({
	object: 'luci-rpc',				// RPC对象名称
	method: 'getDHCPLeases',		// 调用的方法名
	expect: { '': {} }				// 期望返回的数据结构
});

return baseclass.extend({
	title: '',

	// 用于跟踪哪些MAC地址已经配置了静态租约
	isMACStatic: {},
	// 用于跟踪哪些DUID已经配置了静态租约
	isDUIDStatic: {},

	// 加载所需的所有数据：DHCP租约、网络提示信息和DHCP配置
	load: function() {
		return Promise.all([
			callLuciDHCPLeases(),
			network.getHostHints(),
			L.resolveDefault(uci.load('dhcp'))
		]);
	},

	// 从活动租约创建IPv4静态DHCP租约
	handleCreateStaticLease: function(lease, ev) {

		// 在按钮上显示加载状态
		ev.currentTarget.classList.add('spinning');
		ev.currentTarget.disabled = true;
		ev.currentTarget.blur();

		// 在DHCP配置中添加新的主机条目
		var cfg = uci.add('dhcp', 'host');
		uci.set('dhcp', cfg, 'name', lease.hostname);
		uci.set('dhcp', cfg, 'ip', lease.ipaddr);
		uci.set('dhcp', cfg, 'mac', [lease.macaddr.toUpperCase()]);

		// 保存配置并向用户显示更改
		return uci.save()
			.then(L.bind(L.ui.changes.init, L.ui.changes))
			.then(L.bind(L.ui.changes.displayChanges, L.ui.changes));
	},

	// 从活动租约创建IPv6静态DHCP租约
	handleCreateStaticLease6: function(lease, ev) {

		// 在按钮上显示加载状态
		ev.currentTarget.classList.add('spinning');
		ev.currentTarget.disabled = true;
		ev.currentTarget.blur();

		var cfg = uci.add('dhcp', 'host'),
		    ip6arr = lease.ip6addrs[0] ? validation.parseIPv6(lease.ip6addrs[0]) : null;	// 解析IPv6地址以提取主机ID

		uci.set('dhcp', cfg, 'name', lease.hostname);
		uci.set('dhcp', cfg, 'duid', lease.duid.toUpperCase());
		uci.set('dhcp', cfg, 'mac', [lease.macaddr]);

		// 从IPv6地址的最后32位计算并设置主机ID
		if (ip6arr)
			uci.set('dhcp', cfg, 'hostid', (ip6arr[6] * 0xFFFF + ip6arr[7]).toString(16));

		return uci.save()
			.then(L.bind(L.ui.changes.init, L.ui.changes))
			.then(L.bind(L.ui.changes.displayChanges, L.ui.changes));
	},

	renderLeases: function(data) {
		var leases = Array.isArray(data[0].dhcp_leases) ? data[0].dhcp_leases : [],
		    leases6 = Array.isArray(data[0].dhcp6_leases) ? data[0].dhcp6_leases : [],
		    machints = data[1].getMACHints(false),
		    hosts = uci.sections('dhcp', 'host'),
		    isReadonlyView = !L.hasViewPermission();
		
		// 构建现有静态租约的查找表，以防止重复
		for (var i = 0; i < hosts.length; i++) {
			var host = hosts[i];

			// 标记所有已配置的MAC地址为已有静态租约
			if (host.mac) {
				var macs = L.toArray(host.mac);
				for (var j = 0; j < macs.length; j++) {
					var mac = macs[j].toUpperCase();
					this.isMACStatic[mac] = true;
				}
			}
			// 标记所有已配置的DUID为已有静态租约
			if (host.duid) {
				var duid = host.duid.toUpperCase();
				this.isDUIDStatic[duid] = true;
			}
		};

		// 创建IPv4 DHCP租约表格
		var table = E('table', { 'id': 'status_leases', 'class': 'table lases' }, [
			E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th' }, _('Hostname')),
				E('th', { 'class': 'th' }, _('IPv4 address')),
				E('th', { 'class': 'th' }, _('MAC address')),
				E('th', { 'class': 'th' }, _('Lease time remaining')),
				isReadonlyView ? E([]) : E('th', { 'class': 'th cbi-section-actions' }, _('Static Lease'))
			])
		]);

		cbi_update_table(table, leases.map(L.bind(function(lease) {
			var exp, rows;

			// 格式化租约过期时间
			if (lease.expires === false)
				exp = E('em', _('unlimited'));
			else if (lease.expires <= 0)
				exp = E('em', _('expired'));
			else
				exp = '%t'.format(lease.expires);

			// 从网络提示信息中获取主机名（如果可用）
			var hint = lease.macaddr ? machints.filter(function(h) { return h[0] == lease.macaddr })[0] : null,
			    host = null;

			// 如果租约主机名和提示信息不同，则同时显示两者
			if (hint && lease.hostname && lease.hostname != hint[1])
				host = '%s (%s)'.format(lease.hostname, hint[1]);
			else if (lease.hostname)
				host = lease.hostname;

			rows = [
				host || '-',
				lease.ipaddr,
				lease.macaddr,
				exp
			];

			// 如果用户有写权限且MAC地址尚未配置静态租约，则添加"设置静态"按钮
			if (!isReadonlyView && lease.macaddr != null) {
				var mac = lease.macaddr.toUpperCase();
				rows.push(E('button', {
					'class': 'cbi-button cbi-button-apply',
					'click': L.bind(this.handleCreateStaticLease, this, lease),
					'disabled': this.isMACStatic[mac]
				}, [ _('Set Static') ]));
			}

			return rows;
		}, this)), E('em', _('There are no active leases')));

		// 创建IPv6 DHCP租约表格
		var table6 = E('table', { 'id': 'status_leases6', 'class': 'table leases6' }, [
			E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th' }, _('Host')),
				E('th', { 'class': 'th' }, _('IPv6 address')),
				E('th', { 'class': 'th' }, _('DUID')),
				E('th', { 'class': 'th' }, _('Lease time remaining')),
				isReadonlyView ? E([]) : E('th', { 'class': 'th cbi-section-actions' }, _('Static Lease'))
			])
		]);

		cbi_update_table(table6, leases6.map(L.bind(function(lease) {
			var exp, rows;

			// 格式化租约过期时间
			if (lease.expires === false)
				exp = E('em', _('unlimited'));
			else if (lease.expires <= 0)
				exp = E('em', _('expired'));
			else
				exp = '%t'.format(lease.expires);

			// 从网络提示信息中获取主机名（如果可用）
			var hint = lease.macaddr ? machints.filter(function(h) { return h[0] == lease.macaddr })[0] : null,
			    host = null;

			// 如果租约主机名和提示信息不同，则同时显示两者
			if (hint && lease.hostname && lease.hostname != hint[1] && lease.ip6addr != hint[1])
				host = '%s (%s)'.format(lease.hostname, hint[1]);
			else if (lease.hostname)
				host = lease.hostname;
			else if (hint)
				host = hint[1];

			rows = [
				host || '-',
				// 如果存在多个IPv6地址，则显示所有地址
				lease.ip6addrs ? lease.ip6addrs.join('<br />') : lease.ip6addr,
				lease.duid,
				exp
			];

			// 如果用户有写权限且DUID尚未配置静态租约，则添加"设置静态"按钮
			if (!isReadonlyView && lease.duid != null) {
				var duid = lease.duid.toUpperCase();
				rows.push(E('button', {
					'class': 'cbi-button cbi-button-apply',
					'click': L.bind(this.handleCreateStaticLease6, this, lease),
					'disabled': this.isDUIDStatic[duid]
				}, [ _('Set Static') ]));
			}

			return rows;
		}, this)), E('em', _('There are no active leases')));

		return E([
			E('h3', _('Active DHCP Leases')),
			table,
			E('h3', _('Active DHCPv6 Leases')),
			table6
		]);
	},

	render: function(data) {
		// 仅在系统具有dnsmasq或odhcpd DHCP服务器时才渲染
		if (L.hasSystemFeature('dnsmasq') || L.hasSystemFeature('odhcpd'))
			return this.renderLeases(data);

		return E([]);
	}
});
