'use strict';
'require view';
'require dom';
'require poll';
'require fs';
'require network';

// 调用所有 includes 模块的 load 方法，并返回 Promise
function invokeIncludesLoad(includes) {
	var tasks = [], has_load = false;

	// 遍历所有 include 模块, 如果模块有load方法则执行load方法, 如果没有load方法,就只添加null展位
	for (var i = 0; i < includes.length; i++) {
		if (typeof(includes[i].load) == 'function') {
			tasks.push(includes[i].load().catch(L.bind(function() {
				this.failed = true;
			}, includes[i])));

			has_load = true;
		}
		else {
			tasks.push(null);
		}
	}

	// 如果有 load 方法则等待所有 Promise 完成，否则直接返回 resolved Promise
	return has_load ? Promise.all(tasks) : Promise.resolve(null);
}

// 启动轮询机制，定期更新 includes 内容
function startPolling(includes, containers) {
	// 定义轮询步骤函数
	var step = function() {
		// 清空网络缓存
		return network.flushCache().then(function() {
			return invokeIncludesLoad(includes);			// 加载所有 includes 数据
		}).then(function(results) {
			for (var i = 0; i < includes.length; i++) {
				var content = null;

				if (includes[i].failed)
					continue;

				if (typeof(includes[i].render) == 'function')
					content = includes[i].render(results ? results[i] : null);
				else if (includes[i].content != null)
					content = includes[i].content;

				if (content != null) {
					containers[i].parentNode.style.display = '';
					containers[i].parentNode.classList.add('fade-in');

					dom.content(containers[i], content);
				}
			}

			var ssi = document.querySelector('div.includes');
			if (ssi) {
				ssi.style.display = '';
				ssi.classList.add('fade-in');
			}
		});
	};

	return step().then(function() {
		poll.add(step);
	});
}

// 导出视图对象
return view.extend({
	// 加载所有状态页面的 include 模块
	load: function() {
		// 列出 /www/luci-static/resources/view/status/include 目录下的所有文件
		return L.resolveDefault(fs.list('/www' + L.resource('view/status/include')), []).then(function(entries) {
			// 过滤出所有 .js 文件
			return Promise.all(entries.filter(function(e) {
				return (e.type == 'file' && e.name.match(/\.js$/));
			}).map(function(e) {
				// 将文件名转换为模块名格式
				return 'view.status.include.' + e.name.replace(/\.js$/, '');
			}).sort().map(function(n) {
				// 加载所有模块
				return L.require(n);
			}));
		});
	},

	// 渲染状态页面
	render: function(includes) {
		var rv = E([]), containers = [];

		for (var i = 0; i < includes.length; i++) {
			var title = null;

			if (includes[i].title != null)
				title = includes[i].title;
			else
				title = String(includes[i]).replace(/^\[ViewStatusInclude\d+_(.+)Class\]$/,
					function(m, n) { return n.replace(/(^|_)(.)/g,
						function(m, s, c) { return (s ? ' ' : '') + c.toUpperCase() })
					});

			var container = E('div');

			rv.appendChild(E('div', { 'class': 'cbi-section', 'style': 'display:none' }, [
				title != '' ? E('h3', title) : '',
				container
			]));

			containers.push(container);
		}

		// 启动轮询并返回渲染结果
		return startPolling(includes, containers).then(function() {
			return rv;
		});
	},

	// 禁用保存应用、保存和重置功能（状态页面不需要这些操作）
	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
