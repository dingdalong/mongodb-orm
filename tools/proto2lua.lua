-- 测试命令 lua tools/proto2lua.lua spec/schema_define.lua proto/

local sformat = string.format

--------------------------------------------------------------------------------
-- Lua Table 序列化（替代 serpent）
--------------------------------------------------------------------------------

local function serialize_value(val, indent)
    local t = type(val)
    if t == "string" then
        return sformat("%q", val)
    elseif t == "number" or t == "boolean" then
        return tostring(val)
    elseif t == "nil" then
        return "nil"
    end
    return nil
end

local function serialize_table(tbl, indent)
    indent = indent or 0
    local spaces = string.rep("  ", indent)
    local inner_spaces = string.rep("  ", indent + 1)
    
    -- 收集并排序 keys
    local keys = {}
    for k in pairs(tbl) do
        table.insert(keys, k)
    end
    table.sort(keys, function(a, b)
        return tostring(a) < tostring(b)
    end)
    
    local lines = {}
    table.insert(lines, "{")
    
    for _, k in ipairs(keys) do
        local v = tbl[k]
        local key_str
        if type(k) == "string" and k:match("^[%a_][%w_]*$") then
            key_str = k
        else
            key_str = "[" .. serialize_value(k) .. "]"
        end
        
        local val_str
        if type(v) == "table" then
            val_str = serialize_table(v, indent + 1)
        else
            val_str = serialize_value(v, indent + 1)
        end
        
        table.insert(lines, inner_spaces .. key_str .. " = " .. val_str .. ",")
    end
    
    table.insert(lines, spaces .. "}")
    return table.concat(lines, "\n")
end

--------------------------------------------------------------------------------
-- Proto 类型到 Lua Schema 类型的映射
--------------------------------------------------------------------------------
local TYPE_MAP = {
    -- 整数类型
    ["uint32"] = "integer",
    ["int32"] = "integer",
    ["uint64"] = "integer",
    ["int64"] = "integer",
    ["sint32"] = "integer",
    ["sint64"] = "integer",
    ["fixed32"] = "integer",
    ["fixed64"] = "integer",
    ["sfixed32"] = "integer",
    ["sfixed64"] = "integer",
    -- 浮点类型
    ["float"] = "number",
    ["double"] = "number",
    -- 其他类型
    ["bool"] = "boolean",
    ["string"] = "string",
    ["bytes"] = "string",
}

--------------------------------------------------------------------------------
-- 工具函数
--------------------------------------------------------------------------------

-- 读取文件内容
local function read_file(filepath)
    local file = io.open(filepath, "r")
    if not file then
        error("Cannot open file: " .. filepath)
    end
    local content = file:read("*a")
    file:close()
    return content
end

-- 去除字符串两端空白
local function trim(s)
    return s:match("^%s*(.-)%s*$")
end

-- 移除单行注释 // ...
local function remove_line_comments(line)
    local result = line:gsub("//.*$", "")
    return result
end

-- 移除块注释 /* ... */
local function remove_block_comments(content)
    return content:gsub("/%*.-%*/", "")
end

-- 获取文件所在目录
local function get_directory(filepath)
    return filepath:match("(.*/)")  or "./"
end

-- 规范化路径（移除 ./ 和多余的 /）
local function normalize_path(path)
    -- 移除 ./
    path = path:gsub("/%./", "/")
    path = path:gsub("^%./", "")
    -- 移除多余的 /
    path = path:gsub("//+", "/")
    return path
end

--------------------------------------------------------------------------------
-- Proto 解析器
--------------------------------------------------------------------------------

local ProtoParser = {}
ProtoParser.__index = ProtoParser

function ProtoParser.new()
    local self = setmetatable({}, ProtoParser)
    self.messages = {}       -- 所有解析的 message
    self.parsed_files = {}   -- 已解析的文件（避免重复解析）
    return self
end

-- 解析类型名称，处理嵌套前缀
function ProtoParser:resolve_type(typename, prefix)
    -- 如果是基础类型，直接映射
    if TYPE_MAP[typename] then
        return TYPE_MAP[typename]
    end
    -- 自定义类型，保持原名（可能是其他 message）
    return typename
end

-- 解析单个字段
function ProtoParser:parse_field(line, prefix)
    line = remove_line_comments(line)
    line = trim(line)
    
    if line == "" or line == "}" then
        return nil
    end
    
    local field = {}
    
    -- 解析 map 类型: map<KeyType, ValueType> name = tag;
    local key_type, value_type, name = line:match("^map%s*<%s*([%w_]+)%s*,%s*([%w_]+)%s*>%s+([%w_]+)%s*=")
    if key_type then
        field.name = name
        field.is_map = true
        field.key_type = self:resolve_type(key_type, prefix)
        field.value_type = self:resolve_type(value_type, prefix)
        return field
    end
    
    -- 解析 repeated 类型: repeated Type name = tag;
    local repeated_type, repeated_name = line:match("^repeated%s+([%w_]+)%s+([%w_]+)%s*=")
    if repeated_type then
        field.name = repeated_name
        field.is_array = true
        field.item_type = self:resolve_type(repeated_type, prefix)
        return field
    end
    
    -- 解析普通字段: Type name = tag;
    local field_type, field_name = line:match("^([%w_]+)%s+([%w_]+)%s*=")
    if field_type then
        field.name = field_name
        field.field_type = self:resolve_type(field_type, prefix)
        return field
    end
    
    return nil
end

-- 解析 message 块（支持嵌套）
function ProtoParser:parse_message_block(content, start_pos, prefix)
    local fields = {}
    local pos = start_pos
    local brace_count = 1
    local line_start = start_pos
    
    while pos <= #content and brace_count > 0 do
        local char = content:sub(pos, pos)
        
        if char == "{" then
            brace_count = brace_count + 1
        elseif char == "}" then
            brace_count = brace_count - 1
        elseif char == "\n" then
            local line = content:sub(line_start, pos - 1)
            line = remove_line_comments(line)
            line = trim(line)
            
            -- 检查是否是嵌套 message
            local nested_name = line:match("^message%s+([%w_]+)%s*{?")
            if nested_name then
                local nested_prefix = prefix .. "_" .. nested_name
                -- 找到嵌套 message 的开始位置
                local nested_start = content:find("{", pos - #line)
                if nested_start then
                    local nested_fields, nested_end = self:parse_message_block(content, nested_start + 1, nested_prefix)
                    self.messages[nested_prefix] = nested_fields
                    pos = nested_end
                    brace_count = brace_count - 1  -- 嵌套 message 的 } 已被消费
                end
            else
                -- 解析普通字段
                local field = self:parse_field(line, prefix)
                if field then
                    table.insert(fields, field)
                end
            end
            line_start = pos + 1
        end
        
        pos = pos + 1
    end
    
    -- 处理最后一行（如果没有换行符）
    if line_start < pos then
        local line = content:sub(line_start, pos - 1)
        local field = self:parse_field(line, prefix)
        if field then
            table.insert(fields, field)
        end
    end
    
    return fields, pos
end

-- 解析单个 proto 文件
function ProtoParser:parse_file(filepath, base_dir)
    -- 规范化路径后检查是否已解析（避免重复解析）
    local normalized_path = normalize_path(filepath)
    if self.parsed_files[normalized_path] then
        return
    end
    self.parsed_files[normalized_path] = true
    
    local content = read_file(filepath)
    
    -- 移除块注释
    content = remove_block_comments(content)
    
    -- 获取文件目录（用于解析 import）
    local file_dir = get_directory(filepath)
    
    -- 解析 import 语句
    for import_file in content:gmatch('import%s+"([^"]+)"') do
        local import_path = normalize_path((base_dir or file_dir) .. import_file)
        self:parse_file(import_path, base_dir or file_dir)
    end
    
    -- 解析所有 message
    local pos = 1
    while pos <= #content do
        -- 查找 message 定义
        local msg_start, msg_end, msg_name = content:find("message%s+([%w_]+)%s*{", pos)
        if not msg_start then
            break
        end
        
        -- 检查是否在块注释内或嵌套内（简单检查：前面没有未闭合的 {）
        local before = content:sub(pos, msg_start - 1)
        local open_braces = 0
        for _ in before:gmatch("{") do open_braces = open_braces + 1 end
        for _ in before:gmatch("}") do open_braces = open_braces - 1 end
        
        if open_braces == 0 then
            -- 这是顶层 message
            local fields, end_pos = self:parse_message_block(content, msg_end + 1, msg_name)
            self.messages[msg_name] = fields
            pos = end_pos
        else
            pos = msg_end + 1
        end
    end
end

-- 生成 cls_map（与 sproto2lua.lua 输出格式一致）
function ProtoParser:generate_cls_map()
    local cls_map = {}
    
    for msg_name, fields in pairs(self.messages) do
        cls_map[msg_name] = {}
        for _, field in ipairs(fields) do
            if field.is_map then
                cls_map[msg_name][field.name] = {
                    type = "map",
                    key = field.key_type,
                    value = field.value_type,
                }
            elseif field.is_array then
                cls_map[msg_name][field.name] = {
                    type = "array",
                    item = field.item_type,
                }
            else
                cls_map[msg_name][field.name] = {
                    type = field.field_type,
                }
            end
        end
    end
    
    return cls_map
end

--------------------------------------------------------------------------------
-- 扫描目录中的所有 .proto 文件
--------------------------------------------------------------------------------

local function scan_proto_files(dir)
    local files = {}
    
    -- 确保目录路径以 / 结尾
    if not dir:match("/$") then
        dir = dir .. "/"
    end
    
    -- 使用 ls 命令扫描目录（跨平台兼容性：macOS/Linux）
    local cmd = string.format('ls -1 "%s" 2>/dev/null', dir)
    local handle = io.popen(cmd)
    if handle then
        for filename in handle:lines() do
            if filename:match("%.proto$") then
                table.insert(files, dir .. filename)
            end
        end
        handle:close()
    end
    
    return files
end

--------------------------------------------------------------------------------
-- 主程序
--------------------------------------------------------------------------------

-- 读取命令行参数
local outfilename = arg[1]
local proto_dir = arg[2]

-- 检查参数是否提供
if not outfilename or not proto_dir then
    print("Usage: lua proto2lua.lua <output.lua> <proto_folder>")
    print("Example: lua proto2lua.lua spec/schema_define.lua proto/")
    return
end

-- 扫描 proto 文件夹中的所有 .proto 文件
local proto_files = scan_proto_files(proto_dir)

-- 检查是否找到 proto 文件
if #proto_files == 0 then
    print("No .proto files found in directory: " .. proto_dir)
    return
end

table.sort(proto_files)
local str_proto_files = table.concat(proto_files, " ")

print("Found " .. #proto_files .. " proto file(s):")
for _, f in ipairs(proto_files) do
    print("  - " .. f)
end

-- 创建解析器并解析所有文件
local parser = ProtoParser.new()

-- 使用 proto 文件夹作为基础目录
local base_dir = proto_dir
if not base_dir:match("/$") then
    base_dir = base_dir .. "/"
end

for _, filepath in ipairs(proto_files) do
    parser:parse_file(filepath, base_dir)
end

-- 生成 cls_map
local cls_map = parser:generate_cls_map()

-- 打开文件
local outfile = io.open(outfilename, "w")

-- 检查文件是否成功打开
if not outfile then
    print("Cannot open file: " .. outfilename)
    return
end

local fmt_file_header = sformat(
    [[
-- Code generated from %s
-- DO NOT EDIT!
return ]],
    str_proto_files
)

local s = serialize_table(cls_map, 0)
local out_content = table.concat({ fmt_file_header, s }, "")

-- 写入文件内容
outfile:write(out_content)
outfile:close()

print("successfully generated schema define to: " .. outfilename)
