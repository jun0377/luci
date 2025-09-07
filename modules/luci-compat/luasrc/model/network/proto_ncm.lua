--[[
LuCI - Network model - NCM protocol extension

Copyright 2015 Cezary Jackiewicz <cezary.jackiewicz@gmail.com>

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

	http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

]]--

-- 导入LuCI网络模型模块
local netmod = luci.model.network

-- 注册NCM协议处理器
local proto = netmod:register_protocol("ncm")
-- 获取网络接口模块引用
local interface = luci.model.network.interface

-- 国际化支持
function proto.get_i18n(self)
	return luci.i18n.translate("NCM")
end

-- NCM协议所需的软件包名称
function proto.package_name(self)
	return "comgt-ncm"
end

-- 检查NCM协议是否安装
function proto.is_installed(self)
	return nixio.fs.access("/lib/netifd/proto/ncm.sh")
end

-- 协议是否为浮动协议（不绑定到特定物理接口）
function proto.is_floating(self)
	return true
end

-- 协议是否为虚拟协议（不需要物理设备）
function proto.is_virtual(self)
	return true
end

-- 获取协议关联的网络接口
function proto.get_interface(self)
	-- 尝试获取接口名称
	local _ifname=netmod.protocol.ifname(self)
	-- 如果未指定接口名称，则默认使用wan
	if not _ifname then
		_ifname = "wan"
	end
	-- 返回接口对象
	return interface(_ifname, self)
end

-- 获取协议支持的接口列表，返回nil表示不支持多接口
function proto.get_interfaces(self)
	return nil
end

-- 检查协议是否包含指定接口
function proto.contains_interface(self, ifc)
	return (netmod:ifnameof(ifc) == self:ifname())
end

-- 注册NCM虚拟接口的命名模式（以ncm-开头）
netmod:register_pattern_virtual("^ncm%-%w")

-- 各种错误码
netmod:register_error_code("CONFIGURE_FAILED",	luci.i18n.translate("Configuration failed"))				-- 配置失败
netmod:register_error_code("DISCONNECT_FAILED",	luci.i18n.translate("Disconnection attempt failed"))		-- 断开连接尝试失败
netmod:register_error_code("FINALIZE_FAILED",	luci.i18n.translate("Finalizing failed"))					-- 完成操作失败
netmod:register_error_code("GETINFO_FAILED",	luci.i18n.translate("Modem information query failed"))		-- 调制解调器信息查询失败
netmod:register_error_code("INITIALIZE_FAILED",	luci.i18n.translate("Initialization failure"))				-- 初始化失败
netmod:register_error_code("SETMODE_FAILED",	luci.i18n.translate("Setting operation mode failed"))		-- 设置操作模式失败
netmod:register_error_code("UNSUPPORTED_MODEM",	luci.i18n.translate("Unsupported modem"))					-- 不支持的调制解调器
