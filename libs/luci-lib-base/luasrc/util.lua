-- Copyright 2008 Steven Barth <steven@midlink.org>
-- Licensed to the public under the Apache License 2.0.

local io = require "io"
local math = require "math"
local table = require "table"
local debug = require "debug"
local ldebug = require "luci.debug"
local string = require "string"
local coroutine = require "coroutine"
local tparser = require "luci.template.parser"
local json = require "luci.jsonc"
local lhttp = require "lucihttp"

local _ubus = require "ubus"
local _ubus_connection = nil

local getmetatable, setmetatable = getmetatable, setmetatable
local rawget, rawset, unpack, select = rawget, rawset, unpack, select
local tostring, type, assert, error = tostring, type, assert, error
local ipairs, pairs, next, loadstring = ipairs, pairs, next, loadstring
local require, pcall, xpcall = require, pcall, xpcall
local collectgarbage, get_memory_limit = collectgarbage, get_memory_limit

module "luci.util"

--
-- Pythonic string formatting extension
--

-- 扩展字符串元表 ：为所有字符串添加 % 操作符支持
getmetatable("").__mod = function(a, b)
	local ok, res

	if not b then
		return a
	elseif type(b) == "table" then
		local k, _
		for k, _ in pairs(b) do if type(b[k]) == "userdata" then b[k] = tostring(b[k]) end end

		ok, res = pcall(a.format, a, unpack(b))
		if not ok then
			error(res, 2)
		end
		return res
	else
		if type(b) == "userdata" then b = tostring(b) end

		ok, res = pcall(a.format, a, b)
		if not ok then
			error(res, 2)
		end
		return res
	end
end


--
-- Class helper routines
--

-- Instantiates a class
-- 类实例化函数
local function _instantiate(class, ...)
	local inst = setmetatable({}, {__index = class})

	if inst.__init__ then
		inst:__init__(...)
	end

	return inst
end

-- The class object can be instantiated by calling itself.
-- Any class functions or shared parameters can be attached to this object.
-- Attaching a table to the class object makes this table shared between
-- all instances of this class. For object parameters use the __init__ function.
-- Classes can inherit member functions and values from a base class.
-- Class can be instantiated by calling them. All parameters will be passed
-- to the __init__ function of this class - if such a function exists.
-- The __init__ function must be used to set any object parameters that are not shared
-- with other objects of this class. Any return values will be ignored.

-- 类工厂函数
function class(base)
	return setmetatable({}, {
		__call  = _instantiate,
		__index = base
	})
end

-- 类型检查函数
function instanceof(object, class)
	local meta = getmetatable(object)
	while meta and meta.__index do
		if meta.__index == class then
			return true
		end
		meta = getmetatable(meta.__index)
	end
	return false
end


--
-- Scope manipulation routines
--

function threadlocal(tbl)
	return tbl or {}
end


--
-- Debugging routines
--
-- 错误输出函数
function perror(obj)
	return io.stderr:write(tostring(obj) .. "\n")
end

-- 表结构打印函数
function dumptable(t, maxdepth, i, seen)
	i = i or 0
	seen = seen or setmetatable({}, {__mode="k"})

	for k,v in pairs(t) do
		perror(string.rep("\t", i) .. tostring(k) .. "\t" .. tostring(v))
		if type(v) == "table" and (not maxdepth or i < maxdepth) then
			if not seen[v] then
				seen[v] = true
				dumptable(v, maxdepth, i+1, seen)
			else
				perror(string.rep("\t", i) .. "*** RECURSION ***")
			end
		end
	end
end


--
-- String and data manipulation routines
--

-- compatibility wrapper for xml.pcdata
function pcdata(value)
	local xml = require "luci.xml"

	perror("luci.util.pcdata() has been replaced by luci.xml.pcdata() - Please update your code.")
	return xml.pcdata(value)
end

-- URL编码 - 将任意值转换为 URL 安全的编码格式，用于在 HTTP 请求中安全传输数据
-- 示例：
-- 		urlencode("hello world")     -- 返回: "hello%20world"
--		urlencode("user@domain.com") -- 返回: "user%40domain.com"
--		urlencode("测试")             -- 返回: "%E6%B5%8B%E8%AF%95"
-- 		urlencode(123)               -- 返回: "123"
function urlencode(value)
	if value ~= nil then
		local str = tostring(value)
		return lhttp.urlencode(str, lhttp.ENCODE_IF_NEEDED + lhttp.ENCODE_FULL)
			or str
	end
	return nil
end

-- URL解码
function urldecode(value, decode_plus)
	if value ~= nil then
		local flag = decode_plus and lhttp.DECODE_PLUS or 0
		local str = tostring(value)
		return lhttp.urldecode(str, lhttp.DECODE_IF_NEEDED + flag)
			or str
	end
	return nil
end

-- compatibility wrapper for xml.striptags
function striptags(value)
	local xml = require "luci.xml"

	perror("luci.util.striptags() has been replaced by luci.xml.striptags() - Please update your code.")
	return xml.striptags(value)
end

-- 将任意字符串安全地包装在单引号中，使其可以安全地传递给 shell 命令
-- 示例：
--		构建安全的shell命令： local cmd = "ls " .. shellquote(user_input)
--		文件路径处理 ：处理包含空格或特殊字符的文件路径 local path = shellquote("/path/with spaces/file.txt")
--		shellquote("hello world")     -- 返回: "'hello world'"
--		shellquote("it's working")    -- 返回: "'it'\\''s working'"
--		shellquote("$HOME/file")      -- 返回: "'$HOME/file'"
function shellquote(value)
	return string.format("'%s'", string.gsub(value or "", "'", "'\\''"))
end

-- for bash, ash and similar shells single-quoted strings are taken
-- literally except for single quotes (which terminate the string)
-- (and the exception noted below for dash (-) at the start of a
-- command line parameter).
-- 处理shell单引号字符串中的单引号字符转义问题，确保包含单引号的字符串能够安全地在shell命令中使用
function shellsqescape(value)
   local res
   res, _ = string.gsub(value, "'", "'\\''")
   return res
end

-- bash, ash and other similar shells interpret a dash (-) at the start
-- of a command-line parameters as an option indicator regardless of
-- whether it is inside a single-quoted string.  It must be backlash
-- escaped to resolve this.  This requires in some funky special-case
-- handling.  It may actually be a property of the getopt function
-- rather than the shell proper.
-- 处理shell命令行参数中以破折号（ - ）开头的特殊情况，确保这些参数不会被shell误解为选项标志
function shellstartsqescape(value)
   res, _ = string.gsub(value, "^%-", "\\-")
   return shellsqescape(res)
end

-- containing the resulting substrings. The optional max parameter specifies
-- the number of bytes to process, regardless of the actual length of the given
-- string. The optional last parameter, regex, specifies whether the separator
-- sequence is interpreted as regular expression.
--					pattern as regular expression (optional, default is false)
-- 字符串分割函数
function split(str, pat, max, regex)
	pat = pat or "\n"
	max = max or #str

	local t = {}
	local c = 1

	if #str == 0 then
		return {""}
	end

	if #pat == 0 then
		return nil
	end

	if max == 0 then
		return str
	end

	repeat
		local s, e = str:find(pat, c, not regex)
		max = max - 1
		if s and max < 0 then
			t[#t+1] = str:sub(c)
		else
			t[#t+1] = str:sub(c, s and s - 1)
		end
		c = e and e + 1 or #str + 1
	until not s or max < 0

	return t
end

-- 去除字符串首尾的空白字符
function trim(str)
	return (str:gsub("^%s*(.-)%s*$", "%1"))
end

-- 计算字符串中匹配pat的次数
-- 	统计字符出现次数 count = cmatch("hello world", "l") 	结果3
--	统计单词出现次数 count = cmatch("the cat and the dog", "the") 	结果2
-- 	统计数字出现次数 count = cmatch("abc123def456ghi789", "%d+")	结果: 3
--	统计 IP 地址格式 count = cmatch("192.168.1.1 connected, 10.0.0.1 failed, 172.16.0.1 timeout", "%d+%.%d+%.%d+%.%d+") 结果: 3 
-- 	统计换行符 count = cmatch("line1\nline2\nline3\n", "\n")	结果: 3
function cmatch(str, pat)
	local count = 0
	for _ in str:gmatch(pat) do count = count + 1 end
	return count
end

-- one token per invocation, the tokens are separated by whitespace. If the
-- input value is a table, it is transformed into a string first. A nil value
-- will result in a valid iterator which aborts with the first invocation.
-- 通用的迭代器生成函数，用于处理不同类型的输入值并返回相应的迭代器
function imatch(v)
	if type(v) == "table" then
		local k = nil
		return function()
			k = next(v, k)
			return v[k]
		end

	elseif type(v) == "number" or type(v) == "boolean" then
		local x = true
		return function()
			if x then
				x = false
				return tostring(v)
			end
		end

	elseif type(v) == "userdata" or type(v) == "string" then
		return tostring(v):gmatch("%S+")
	end

	return function() end
end

-- value or 0 if the unit is unknown. Upper- or lower case is irrelevant.
-- Recognized units are:
--	o "y"	- one year   (60*60*24*366)
--  o "m"	- one month  (60*60*24*31)
--  o "w"	- one week   (60*60*24*7)
--  o "d"	- one day    (60*60*24)
--  o "h"	- one hour	 (60*60)
--  o "min"	- one minute (60)
--  o "kb"  - one kilobyte (1024)
--  o "mb"	- one megabyte (1024*1024)
--  o "gb"	- one gigabyte (1024*1024*1024)
--  o "kib" - one si kilobyte (1000)
--  o "mib"	- one si megabyte (1000*1000)
--  o "gib"	- one si gigabyte (1000*1000*1000)
-- 单位解析函数
function parse_units(ustr)

	local val = 0

	-- unit map
	local map = {
		-- date stuff
		y   = 60 * 60 * 24 * 366,
		m   = 60 * 60 * 24 * 31,
		w   = 60 * 60 * 24 * 7,
		d   = 60 * 60 * 24,
		h   = 60 * 60,
		min = 60,

		-- storage sizes
		kb  = 1024,
		mb  = 1024 * 1024,
		gb  = 1024 * 1024 * 1024,

		-- storage sizes (si)
		kib = 1000,
		mib = 1000 * 1000,
		gib = 1000 * 1000 * 1000
	}

	-- parse input string
	for spec in ustr:lower():gmatch("[0-9%.]+[a-zA-Z]*") do

		local num = spec:gsub("[^0-9%.]+$","")
		local spn = spec:gsub("^[0-9%.]+", "")

		if map[spn] or map[spn:sub(1,1)] then
			val = val + num * ( map[spn] or map[spn:sub(1,1)] )
		else
			val = val + num
		end
	end


	return val
end

-- also register functions above in the central string class for convenience
string.split       = split
string.trim        = trim
string.cmatch      = cmatch
string.parse_units = parse_units

-- 表追加函数
function append(src, ...)
	for i, a in ipairs({...}) do
		if type(a) == "table" then
			for j, v in ipairs(a) do
				src[#src+1] = v
			end
		else
			src[#src+1] = a
		end
	end
	return src
end

-- 将多个表或单个值合并成一个新的数组表
function combine(...)
	return append({}, ...)
end

-- 检查表中是否包含指定的值
function contains(table, value)
	for k, v in pairs(table) do
		if value == v then
			return k
		end
	end
	return false
end

-- Both table are - in fact - merged together.
-- 将 updates 表中的所有键值对复制到目标表 t 中，实现表的批量更新
function update(t, updates)
	for k, v in pairs(updates) do
		t[k] = v
	end
end

-- 从给定的表中提取所有键，并以数组形式返回
function keys(t)
	local keys = { }
	if t then
		for k, _ in kspairs(t) do
			keys[#keys+1] = k
		end
	end
	return keys
end

-- 对象克隆函数
function clone(object, deep)
	local copy = {}

	for k, v in pairs(object) do
		if deep and type(v) == "table" then
			v = clone(v, deep)
		end
		copy[k] = v
	end

	return setmetatable(copy, getmetatable(object))
end


-- Serialize the contents of a table value.
-- 表序列化函数
function _serialize_table(t, seen)
	assert(not seen[t], "Recursion detected.")
	seen[t] = true

	local data  = ""
	local idata = ""
	local ilen  = 0

	for k, v in pairs(t) do
		if type(k) ~= "number" or k < 1 or math.floor(k) ~= k or ( k - #t ) > 3 then
			k = serialize_data(k, seen)
			v = serialize_data(v, seen)
			data = data .. ( #data > 0 and ", " or "" ) ..
				'[' .. k .. '] = ' .. v
		elseif k > ilen then
			ilen = k
		end
	end

	for i = 1, ilen do
		local v = serialize_data(t[i], seen)
		idata = idata .. ( #idata > 0 and ", " or "" ) .. v
	end

	return idata .. ( #data > 0 and #idata > 0 and ", " or "" ) .. data
end

-- with loadstring().
-- 数据序列化函数
function serialize_data(val, seen)
	seen = seen or setmetatable({}, {__mode="k"})

	if val == nil then
		return "nil"
	elseif type(val) == "number" then
		return val
	elseif type(val) == "string" then
		return "%q" % val
	elseif type(val) == "boolean" then
		return val and "true" or "false"
	elseif type(val) == "function" then
		return "loadstring(%q)" % get_bytecode(val)
	elseif type(val) == "table" then
		return "{ " .. _serialize_table(val, seen) .. " }"
	else
		return '"[unhandled data type:' .. type(val) .. ']"'
	end
end

function restore_data(str)
	return loadstring("return " .. str)()
end


--
-- Byte code manipulation routines
--

-- will be stripped before it is returned.
-- 将任意Lua值或函数转换为对应的字节码表示
function get_bytecode(val)
	local code

	if type(val) == "function" then
		code = string.dump(val)
	else
		code = string.dump( loadstring( "return " .. serialize_data(val) ) )
	end

	return code -- and strip_bytecode(code)
end

-- numbers and debugging numbers will be discarded. Original version by
-- Peter Cawley (http://lua-users.org/lists/lua-l/2008-02/msg01158.html)
-- 移除Lua字节码中的调试信息，减小编译后代码的体积
function strip_bytecode(code)
	local version, format, endian, int, size, ins, num, lnum = code:byte(5, 12)
	local subint
	if endian == 1 then
		subint = function(code, i, l)
			local val = 0
			for n = l, 1, -1 do
				val = val * 256 + code:byte(i + n - 1)
			end
			return val, i + l
		end
	else
		subint = function(code, i, l)
			local val = 0
			for n = 1, l, 1 do
				val = val * 256 + code:byte(i + n - 1)
			end
			return val, i + l
		end
	end

	local function strip_function(code)
		local count, offset = subint(code, 1, size)
		local stripped = { string.rep("\0", size) }
		local dirty = offset + count
		offset = offset + count + int * 2 + 4
		offset = offset + int + subint(code, offset, int) * ins
		count, offset = subint(code, offset, int)
		for n = 1, count do
			local t
			t, offset = subint(code, offset, 1)
			if t == 1 then
				offset = offset + 1
			elseif t == 4 then
				offset = offset + size + subint(code, offset, size)
			elseif t == 3 then
				offset = offset + num
			elseif t == 254 or t == 9 then
				offset = offset + lnum
			end
		end
		count, offset = subint(code, offset, int)
		stripped[#stripped+1] = code:sub(dirty, offset - 1)
		for n = 1, count do
			local proto, off = strip_function(code:sub(offset, -1))
			stripped[#stripped+1] = proto
			offset = offset + off - 1
		end
		offset = offset + subint(code, offset, int) * int + int
		count, offset = subint(code, offset, int)
		for n = 1, count do
			offset = offset + subint(code, offset, size) + size + int * 2
		end
		count, offset = subint(code, offset, int)
		for n = 1, count do
			offset = offset + subint(code, offset, size) + size
		end
		stripped[#stripped+1] = string.rep("\0", int * 3)
		return table.concat(stripped), offset
	end

	return code:sub(1,12) .. strip_function(code:sub(13,-1))
end


--
-- Sorting iterator functions
--
-- 创建一个排序的表迭代器，支持自定义比较函数
function _sortiter( t, f )
	local keys = { }

	local k, v
	for k, v in pairs(t) do
		keys[#keys+1] = k
	end

	local _pos = 0

	table.sort( keys, f )

	return function()
		_pos = _pos + 1
		if _pos <= #keys then
			return keys[_pos], t[keys[_pos]], _pos
		end
	end
end

-- the provided callback function.
-- 返回一个按自定义比较函数排序的键值对迭代器
function spairs(t,f)
	return _sortiter( t, f )
end

-- The table pairs are sorted by key.
-- 返回一个按表键（key）排序的键值对迭代器
function kspairs(t)
	return _sortiter( t )
end

-- The table pairs are sorted by value.
-- 返回一个按表值（value）排序的键值对迭代器
function vspairs(t)
	return _sortiter( t, function (a,b) return t[a] < t[b] end )
end


--
-- System utility functions
--
-- 检测当前系统的字节序
function bigendian()
	return string.byte(string.dump(function() end), 7) == 0
end

-- 命令执行函数
function exec(command)
	local pp   = io.popen(command)
	local data = pp:read("*a")
	pp:close()

	return data
end

-- 命令迭代器
-- 	逐行处理 ：返回迭代器函数，每次调用返回一行
-- 	内存友好 ：不需要将整个输出加载到内存
-- 	自动清理 ：读取完毕后自动关闭管道
-- 	错误处理 ：popen失败时返回nil
function execi(command)
	local pp = io.popen(command)

	return pp and function()
		local line = pp:read()

		if not line then
			pp:close()
		end

		return line
	end
end

-- Deprecated
function execl(command)
	local pp   = io.popen(command)
	local line = ""
	local data = {}

	while true do
		line = pp:read()
		if (line == nil) then break end
		data[#data+1] = line
	end
	pp:close()

	return data
end


local ubus_codes = {
	"INVALID_COMMAND",
	"INVALID_ARGUMENT",
	"METHOD_NOT_FOUND",
	"NOT_FOUND",
	"NO_DATA",
	"PERMISSION_DENIED",
	"TIMEOUT",
	"NOT_SUPPORTED",
	"UNKNOWN_ERROR",
	"CONNECTION_FAILED"
}

local function ubus_return(...)
	if select('#', ...) == 2 then
		local rv, err = select(1, ...), select(2, ...)
		if rv == nil and type(err) == "number" then
			return nil, err, ubus_codes[err]
		end
	end

	return ...
end

-- ubus接口函数
function ubus(object, method, data, path, timeout)
	if not _ubus_connection then
		_ubus_connection = _ubus.connect(path, timeout)
		assert(_ubus_connection, "Unable to establish ubus connection")
	end

	if object and method then
		if type(data) ~= "table" then
			data = { }
		end
		return ubus_return(_ubus_connection:call(object, method, data))
	elseif object then
		return _ubus_connection:signatures(object)
	else
		return _ubus_connection:objects()
	end
end

-- 将 Lua 数据结构转换为 JSON 字符串
function serialize_json(x, cb)
	local js = json.stringify(x)
	if type(cb) == "function" then
		cb(js)
	else
		return js
	end
end


function libpath()
	return require "nixio.fs".dirname(ldebug.__file__)
end

function checklib(fullpathexe, wantedlib)
	local fs = require "nixio.fs"
	local haveldd = fs.access('/usr/bin/ldd')
	local haveexe = fs.access(fullpathexe)
	if not haveldd or not haveexe then
		return false
	end
	local libs = exec(string.format("/usr/bin/ldd %s", shellquote(fullpathexe)))
	if not libs then
		return false
	end
	for k, v in ipairs(split(libs)) do
		if v:find(wantedlib) then
			return true
		end
	end
	return false
end

-------------------------------------------------------------------------------
-- Coroutine safe xpcall and pcall versions
--
-- Encapsulates the protected calls with a coroutine based loop, so errors can
-- be dealed without the usual Lua 5.x pcall/xpcall issues with coroutines
-- yielding inside the call to pcall or xpcall.
--
-- Authors: Roberto Ierusalimschy and Andre Carregal
-- Contributors: Thomas Harning Jr., Ignacio Burgueño, Fabio Mascarenhas
--
-- Copyright 2005 - Kepler Project
--
-- $Id: coxpcall.lua,v 1.13 2008/05/19 19:20:02 mascarenhas Exp $
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
-- Implements xpcall with coroutines
-------------------------------------------------------------------------------
local coromap = setmetatable({}, { __mode = "k" })

local function handleReturnValue(err, co, status, ...)
	if not status then
		return false, err(debug.traceback(co, (...)), ...)
	end
	if coroutine.status(co) == 'suspended' then
		return performResume(err, co, coroutine.yield(...))
	else
		return true, ...
	end
end

function performResume(err, co, ...)
	return handleReturnValue(err, co, coroutine.resume(co, ...))
end

local function id(trace, ...)
	return trace
end

-- 协程安全的xpcall
function coxpcall(f, err, ...)
	local current = coroutine.running()
	if not current then
		if err == id then
			return pcall(f, ...)
		else
			if select("#", ...) > 0 then
				local oldf, params = f, { ... }
				f = function() return oldf(unpack(params)) end
			end
			return xpcall(f, err)
		end
	else
		local res, co = pcall(coroutine.create, f)
		if not res then
			local newf = function(...) return f(...) end
			co = coroutine.create(newf)
		end
		coromap[co] = current
		return performResume(err, co, ...)
	end
end

function copcall(f, ...)
	return coxpcall(f, id, ...)
end
