-- Copyright 2008 Steven Barth <steven@midlink.org>
-- Copyright 2010-2018 Jo-Philipp Wich <jo@mein.io>
-- Licensed to the public under the Apache License 2.0.

local util  = require "luci.util"
local coroutine = require "coroutine"
local table = require "table"
local lhttp = require "lucihttp"

local L, table, ipairs, pairs, type, error = _G.L, table, ipairs, pairs, type, error

module "luci.http"

HTTP_MAX_CONTENT      = 1024*100		-- 100 kB maximum content size

-- 关闭HTTP连接
function close()
	L.http:close()
end

-- 获取HTTP请求的内容体
function content()
	return L.http:content()
end

-- 获取表单字段的值
function formvalue(name, noparse)
	return L.http:formvalue(name, noparse)
end

-- 获取具有指定前缀的所有表单字段
function formvaluetable(prefix)
	return L.http:formvaluetable(prefix)
end

-- 获取指定名称的Cookie值
function getcookie(name)
	return L.http:getcookie(name)
end

-- or the environment table itself.
-- 获取环境变量或HTTP环境信息
function getenv(name)
	return L.http:getenv(name)
end

-- 设置文件上传处理回调函数
function setfilehandler(callback)
	return L.http:setfilehandler(callback)
end

-- 设置HTTP响应头
function header(key, value)
	L.http:header(key, value)
end

-- 准备响应内容，设置MIME类型
function prepare_content(mime)
	L.http:prepare_content(mime)
end

-- 获取HTTP输入源
function source()
	return L.http.input
end

-- 设置HTTP响应状态码和消息
function status(code, message)
	L.http:status(code, message)
end

-- This function is as a valid LTN12 sink.
-- If the content chunk is nil this function will automatically invoke close.
-- 写入响应内容，作为LTN12 sink使用
function write(content, src_err)
	if src_err then
		error(src_err)
	end

	return L.print(content)
end

-- 高效传输文件描述符内容
function splice(fd, size)
	coroutine.yield(6, fd, size)
end

-- HTTP重定向到指定URL
function redirect(url)
	L.http:redirect(url)
end

-- 构建URL查询字符串
function build_querystring(q)
	local s, n, k, v = {}, 1, nil, nil

	for k, v in pairs(q) do
		s[n+0] = (n == 1) and "?" or "&"
		s[n+1] = util.urlencode(k)
		s[n+2] = "="
		s[n+3] = util.urlencode(v)
		n = n + 4
	end

	return table.concat(s, "")
end

urldecode = util.urldecode

urlencode = util.urlencode

-- 写入JSON格式的响应
function write_json(x)
	L.printf('%J', x)
end

-- separated by "&". Tables are encoded as parameters with multiple values by
-- repeating the parameter name with each value.
-- 将表编码为URL参数格式，支持数组值
function urlencode_params(tbl)
	local k, v
	local n, enc = 1, {}
	for k, v in pairs(tbl) do
		if type(v) == "table" then
			local i, v2
			for i, v2 in ipairs(v) do
				if enc[1] then
					enc[n] = "&"
					n = n + 1
				end

				enc[n+0] = lhttp.urlencode(k)
				enc[n+1] = "="
				enc[n+2] = lhttp.urlencode(v2)
				n = n + 3
			end
		else
			if enc[1] then
				enc[n] = "&"
				n = n + 1
			end

			enc[n+0] = lhttp.urlencode(k)
			enc[n+1] = "="
			enc[n+2] = lhttp.urlencode(v)
			n = n + 3
		end
	end

	return table.concat(enc, "")
end

-- 提供HTTP请求上下文对象
context = {
	request = {
		formvalue      = function(self, ...) return formvalue(...)      end;
		formvaluetable = function(self, ...) return formvaluetable(...) end;
		content        = function(self, ...) return content(...)        end;
		getcookie      = function(self, ...) return getcookie(...)      end;
		setfilehandler = function(self, ...) return setfilehandler(...) end;
		message        = L and L.http.message
	}
}
