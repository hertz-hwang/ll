local core = {}


-- librime-lua: https://github.com/hchunhui/librime-lua
-- wiki: https://github.com/hchunhui/librime-lua/wiki/Scripting


-- 由translator记录输入串, 传递给filter
core.input_code = ''
-- 由translator计算暂存串, 传递给filter
core.stashed_text = ''
-- 由translator初始化基础码表数据
core.base_mem = nil
-- 由translator构造智能词前缀树
core.word_trie = nil
-- 附加词库
core.full_mem = nil


-- 操作系统类型枚举
core.os_types = {
    android = "android",
    ios     = "ios",
    linux   = "linux",
    mac     = "mac",
    windows = "windows",
    unknown = "unknown",
}

-- 当前操作系统平台
-- 定义平台检测函数
local function detect_platform()
    -- 1. 尝试从 RIME API 获取
    if rime_api and rime_api.get_distribution_code_name then
        local dist = rime_api.get_distribution_code_name()
        if dist and type(dist) == "string" then
            local lower_dist = dist:lower()
            if lower_dist == "trime" then return "android" end
            if lower_dist == "hamster" or lower_dist == "hamster3" then return "ios" end
            if lower_dist == "squirrel" then return "mac" end
            if lower_dist == "weasel" then return "windows" end
            if lower_dist == "ibus-rime" or lower_dist == "fcitx-rime" then
                -- 需要进一步区分
            end
        end
    end
    
    -- 2. 使用 LuaJIT 的 jit.os
    if jit and jit.os then
        local jit_os = jit.os:lower()
        if jit_os == "linux" then return "linux" end
        if jit_os == "osx" or jit_os == "macos" then return "mac" end
        if jit_os == "windows" then return "windows" end
    end
    
    -- 3. 初始化
    local is_mac = false
    local is_windows = false
    
    -- 检查路径分隔符
    if package.config:sub(1,1) == "\\" then
        is_windows = true
    end
    
    -- 检查环境变量
    if not is_windows then
        local home = os.getenv("HOME")
        if home and (home:find("/Users/") or home:find("/home/")) then
            -- 检查是否 macOS
            local ok, file = pcall(io.open, "/Applications", "r")
            if ok and file then
                file:close()
                is_mac = true
            end
        end
    end
    
    if is_windows then return "windows" end
    if is_mac then return "mac" end
    
    -- 4. 默认认为是 Linux（因为 RIME 主要用于 Unix-like 系统）
    return "linux"
end

-- 设置平台
local platform = detect_platform()
if platform == "android" then
    core.os_name = core.os_types.android
elseif platform == "ios" then
    core.os_name = core.os_types.ios
elseif platform == "mac" then
    core.os_name = core.os_types.mac
elseif platform == "windows" then
    core.os_name = core.os_types.windows
elseif platform == "linux" then
    core.os_name = core.os_types.linux
end

-- 宏类型枚举
core.macro_types = {
    tip    = "tip",
    switch = "switch",
    radio  = "radio",
    shell  = "shell",
    eval   = "eval",
}


-- 开关枚举
core.switch_names = {
    sentence      = "sentence",
    single_char   = "single_char",
    single_char_delay = "single_char_delay",
    full_word     = "full.word",
    full_char     = "full.char",
    full_off      = "full.off",
    embeded_cands = "embeded_cands",
    completion    = "completion",
}


core.funckeys_map = {
    primary   = " a",
    secondary = " b",
    tertiary  = " c",
}

local funckeys_replacer = {
    a = "1",
    b = "2",
    c = "3",
}

local funckeys_restorer = {
    ["1"] = " a",
    ["2"] = " b",
    ["3"] = " c",
}

---在现有的迭代器上通过 handler 封装一个新的迭代器
---传入处理器 handler 须能正确处理传入迭代器 iterable
---返回的值为简易迭代器, 通过 for v in iter() do ... end 形式迭代
---@param iterable function
---@param handler function
---@return function
local function wrap_iterator(iterable, handler)
    local co = coroutine.wrap(function(iter)
        handler(iter, coroutine.yield)
    end)
    return function()
        return function(iter)
            return co(iter)
        end, iterable
    end
end

---@param input string
function core.input_replace_funckeys(input)
    return string.gsub(input, " ([a-c])", funckeys_replacer)
end

---@param input string
function core.input_restore_funckeys(input)
    return string.gsub(input, "([1-3])", funckeys_restorer)
end

-- 设置开关状态, 并更新保存的配置值
local function set_option(env, ctx, option_name, value)
    ctx:set_option(option_name, value)
    local swt = env.switcher
    if swt then
        if swt:is_auto_save(option_name) and swt.user_config ~= nil then
            swt.user_config:set_bool("var/option/" .. option_name, value)
        end
    end
end


-- 下文的 new_tip, new_switch, new_radio 等是目前已实现的宏类型
-- 其返回类型统一定义为:
-- {
--   type = "string",
--   name = "string",
--   display = function(self, ctx) ... end -> string
--   trigger = function(self, ctx) ... end
-- }
-- 其中:
-- type 字段仅起到标识作用
-- name 字段亦非必须
-- display() 为该宏在候选栏中显示的效果, 通常 name 非空时直接返回 name 的值
-- trigger() 为该宏被选中时, 上屏的文本内容, 返回空即不上屏

---提示语或快捷短语
---显示为 name, 上屏为 text
---@param name string
local function new_tip(name, text)
    local tip = {
        type = core.macro_types.tip,
        name = name,
        text = text,
    }
    function tip:display(env, ctx)
        return #self.name ~= 0 and self.name or self.text
    end

    function tip:trigger(env, ctx)
        if #text ~= 0 then
            env.engine:commit_text(text)
        end
        ctx:clear()
    end

    return tip
end

---开关
---显示 name 开关当前的状态, 并在选中切换状态
---states 分别指定开关状态为 开 和 关 时的显示效果
---@param name string
---@param states table
local function new_switch(name, states)
    local switch = {
        type = core.macro_types.switch,
        name = name,
        states = states,
    }
    function switch:display(env, ctx)
        local state = ""
        local current_value = ctx:get_option(self.name)
        if current_value then
            state = self.states[2]
        else
            state = self.states[1]
        end
        return state
    end

    function switch:trigger(env, ctx)
        local current_value = ctx:get_option(self.name)
        if current_value ~= nil then
            set_option(env, ctx, self.name, not current_value)
        end
    end

    return switch
end

---单选
---显示一组 names 开关当前的状态, 并在选中切换关闭当前开启项, 并打开下一项
---states 指定各组开关的 name 和当前开启的开关时的显示效果
---@param states table
local function new_radio(states)
    local radio = {
        type   = core.macro_types.radio,
        states = states,
    }
    function radio:display(env, ctx)
        local state = ""
        for _, op in ipairs(self.states) do
            local value = ctx:get_option(op.name)
            if value then
                state = op.display
                break
            end
        end
        return state
    end

    function radio:trigger(env, ctx)
        for i, op in ipairs(self.states) do
            local value = ctx:get_option(op.name)
            if value then
                -- 关闭当前选项, 开启下一选项
                set_option(env, ctx, op.name, not value)
                set_option(env, ctx, self.states[i % #self.states + 1].name, value)
                return
            end
        end
        -- 全都没开, 那就开一下第一个吧
        set_option(env, ctx, self.states[1].name, true)
    end

    return radio
end

---Shell 命令, 仅支持 Linux/Mac 系统, 其他平台可通过下文提供的 eval 宏自行扩展
---name 非空时显示其值, 为空则显示实时的 cmd 执行结果
---cmd 为待执行的命令内容
---text 为 true 时, 命令执行结果上屏, 否则仅执行
---@param name string
---@param cmd string
---@param text boolean
local function new_shell(name, cmd, text)
    local supported_os = {
        [core.os_types.android] = true,
        [core.os_types.mac]     = true,
        [core.os_types.linux]   = true,
    }
    if not supported_os[core.os_name] then
        return new_tip(name, cmd)
    end

    local template = "__macrowrapper() { %s ; }; __macrowrapper %s <<<''"
    local function get_fd(args)
        local cmdargs = {}
        for _, arg in ipairs(args) do
            table.insert(cmdargs, '"' .. arg .. '"')
        end
        return io.popen(string.format(template, cmd, table.concat(cmdargs, " ")), 'r')
    end

    local shell = {
        type = core.macro_types.tip,
        name = name,
        text = text,
    }

    function shell:display(env, ctx, args)
        return #self.name ~= 0 and self.name or self.text and get_fd(args):read('a')
    end

    function shell:trigger(env, ctx, args)
        local fd = get_fd(args)
        if self.text then
            local t = fd:read('a')
            fd:close()
            if #t ~= 0 then
                env.engine:commit_text(t)
            end
        end
        ctx:clear()
    end

    return shell
end

---Evaluate 宏, 执行给定的 lua 表达式
---name 非空时显示其值, 否则显示实时调用结果
---expr 必须 return 一个值, 其类型可以是 string, function 或 table
---返回 function 时, 该 function 接受一个 table 参数, 返回 string
---返回 table 时, 该 table 成员方法 peek 和 eval 接受 self 和 table 参数, 返回 string, 分别指定显示效果和上屏文本
---@param name string
---@param expr string
local function new_eval(name, expr)
    local f = load(expr)
    if not f then
        return nil
    end

    local eval = {
        type = core.macro_types.eval,
        name = name,
        expr = f,
    }

    function eval:get_text(args, env, getter)
        if type(self.expr) == "function" then
            local res = self.expr(args, env)
            if type(res) == "string" then
                return res
            elseif type(res) == "function" or type(res) == "table" then
                self.expr = res
            else
                return ""
            end
        end

        local res
        if type(self.expr) == "function" then
            res = self.expr(args, env)
        elseif type(self.expr) == "table" then
            local get_text = self.expr[getter]
            res = type(get_text) == "function" and get_text(self.expr, args, env) or nil
        end
        return type(res) == "string" and res or ""
    end

    function eval:display(env, ctx, args)
        if #self.name ~= 0 then
            return self.name
        else
            local _, res = pcall(self.get_text, self, args, env, "peek")
            return res
        end
    end

    function eval:trigger(env, ctx, args)
        local ok, res = pcall(self.get_text, self, args, env, "eval")
        if ok and #res ~= 0 then
            env.engine:commit_text(res)
        end
        ctx:clear()
    end

    return eval
end


---Evaluate 捷径, 执行给定的 lua 表达式
local function new_accel_eval(expr)
    local f = load(expr)
    if not f then
        return nil
    end

    local eval = {
        type = core.macro_types.eval,
        expr = f,
    }

    function eval:get_text(cand, env, getter)
        if type(self.expr) == "function" then
            local res = self.expr(cand, env)
            if type(res) == "string" then
                return res
            elseif type(res) == "function" or type(res) == "table" then
                self.expr = res
            else
                return ""
            end
        end

        local res
        if type(self.expr) == "function" then
            res = self.expr(cand, env)
        elseif type(self.expr) == "table" then
            local get_text = self.expr[getter]
            res = type(get_text) == "function" and get_text(self.expr, cand, env) or nil
        end
        return type(res) == "string" and res or ""
    end

    function eval:trigger(env, ctx, cand)
        local ok, res = pcall(self.get_text, self, cand, env, "eval")
        _, _ = ok, res
    end

    return eval
end


---字符过滤器
---@param option_name string
---@param mapper_expr string
local function new_mapper(option_name, mapper_expr)
    local f = load(mapper_expr)
    f = f and f() or nil
    if type(f) ~= "function" then
        return nil
    end

    local mapper = {
        option = option_name,
        mapper = f,
    }

    setmetatable(mapper, {
        __call = function(self, iter, env, yield)
            local option = #self.option ~= 0 and env.option[self.option] or false
            return self.mapper(iter, option, yield)
        end,
    })

    return mapper
end


-- ######## 工具函数 ########

---@param input string
---@param keylist table
function core.get_macro_args(input, keylist)
    local sepset = ""
    for key in pairs(keylist) do
        -- only ascii keys
        sepset = key >= 0x20 and key <= 0x7f and sepset .. string.char(key) or sepset
    end
    -- matches "[^/]"
    local pattern = "[^" .. (#sepset ~= 0 and sepset or " ") .. "]*"
    local args = {}
    -- "echo/hello/world" -> "/hello", "/world"
    for str in string.gmatch(input, "/" .. pattern) do
        table.insert(args, string.sub(str, 2))
    end
    -- "echo/hello/world" -> "echo"
    return string.match(input, pattern) or "", args
end

-- 从方案配置中读取布尔值
function core.parse_conf_bool(env, path)
    local value = env.engine.schema.config:get_bool(env.name_space .. "/" .. path)
    return value and true or false
end

-- 从方案配置中读取字符串
function core.parse_conf_str(env, path, default)
    local str = env.engine.schema.config:get_string(env.name_space .. "/" .. path)
    if not str and default and #default ~= 0 then
        str = default
    end
    return str
end

-- 从方案配置中读取字符串列表
function core.parse_conf_str_list(env, path, default)
    local list = {}
    local conf_list = env.engine.schema.config:get_list(env.name_space .. "/" .. path)
    if conf_list then
        for i = 0, conf_list.size - 1 do
            table.insert(list, conf_list:get_value_at(i):get_string())
        end
    elseif default then
        list = default
    end
    return list
end

-- 从方案配置中读取宏配置
function core.parse_conf_macro_list(env)
    local macros = {}
    local macro_map = env.engine.schema.config:get_map(env.name_space .. "/macros")
    -- macros:
    for _, key in ipairs(macro_map and macro_map:keys() or {}) do
        local cands = {}
        local cand_list = macro_map:get(key):get_list() or { size = 0 }
        -- macros/help:
        for i = 0, cand_list.size - 1 do
            local key_map = cand_list:get_at(i):get_map()
            -- macros/help[1]/type:
            local type = key_map and key_map:has_key("type") and key_map:get_value("type"):get_string() or ""
            if type == core.macro_types.tip then
                -- {type: tip, name: foo}
                if key_map:has_key("name") or key_map:has_key("text") then
                    local name = key_map:has_key("name") and key_map:get_value("name"):get_string() or ""
                    local text = key_map:has_key("text") and key_map:get_value("text"):get_string() or ""
                    table.insert(cands, new_tip(name, text))
                end
            elseif type == core.macro_types.switch then
                -- {type: switch, name: single_char, states: []}
                if key_map:has_key("name") and key_map:has_key("states") then
                    local name = key_map:get_value("name"):get_string()
                    local states = {}
                    local state_list = key_map:get("states"):get_list() or { size = 0 }
                    for idx = 0, state_list.size - 1 do
                        table.insert(states, state_list:get_value_at(idx):get_string())
                    end
                    if #name ~= 0 and #states > 1 then
                        table.insert(cands, new_switch(name, states))
                    end
                end
            elseif type == core.macro_types.radio then
                -- {type: radio, names: [], states: []}
                if key_map:has_key("names") and key_map:has_key("states") then
                    local names, states = {}, {}
                    local name_list = key_map:get("names"):get_list() or { size = 0 }
                    for idx = 0, name_list.size - 1 do
                        table.insert(names, name_list:get_value_at(idx):get_string())
                    end
                    local state_list = key_map:get("states"):get_list() or { size = 0 }
                    for idx = 0, state_list.size - 1 do
                        table.insert(states, state_list:get_value_at(idx):get_string())
                    end
                    if #names > 1 and #names == #states then
                        local radio = {}
                        for idx, name in ipairs(names) do
                            if #name ~= 0 and #states[idx] ~= 0 then
                                table.insert(radio, { name = name, display = states[idx] })
                            end
                        end
                        table.insert(cands, new_radio(radio))
                    end
                end
            elseif type == core.macro_types.shell then
                -- {type: shell, name: foo, cmd: "echo hello"}
                if key_map:has_key("cmd") and (key_map:has_key("name") or key_map:has_key("text")) then
                    local cmd = key_map:get_value("cmd"):get_string()
                    local name = key_map:has_key("name") and key_map:get_value("name"):get_string() or ""
                    local text = key_map:has_key("text") and key_map:get_value("text"):get_bool() or false
                    local hijack = key_map:has_key("hijack") and key_map:get_value("hijack"):get_bool() or false
                    if #cmd ~= 0 and (#name ~= 0 or text) then
                        table.insert(cands, new_shell(name, cmd, text))
                        cands.hijack = cands.hijack or hijack
                    end
                end
            elseif type == core.macro_types.eval then
                -- {type: eval, name: foo, expr: "os.date()"}
                if key_map:has_key("expr") then
                    local name = key_map:has_key("name") and key_map:get_value("name"):get_string() or ""
                    local expr = key_map:get_value("expr"):get_string()
                    local hijack = key_map:has_key("hijack") and key_map:get_value("hijack"):get_bool() or false
                    if #expr ~= 0 then
                        table.insert(cands, new_eval(name, expr))
                        cands.hijack = cands.hijack or hijack
                    end
                end
            end
        end
        if #cands ~= 0 then
            macros[key] = cands
        end
    end
    return macros
end

-- 从方案配置中读取过滤器列表
function core.parse_conf_mapper_list(env)
    local mappers = {}
    local mapper_list = env.engine.schema.config:get_list(env.name_space .. "/mappers")
    -- mappers:
    for i = 0, mapper_list.size - 1 do
        local key_map = mapper_list:get_at(i):get_map()
        -- mappers[1]/expr:
        if key_map and key_map:has_key("expr") then
            local expr = key_map:get_value("expr"):get_string() or ""
            local option_name = key_map:has_key("option_name") and key_map:get_value("option_name"):get_string() or ""
            if #expr ~= 0 then
                table.insert(mappers, new_mapper(option_name, expr))
            end
        end
    end
    return mappers
end

-- 从方案配置中读取功能键配置
function core.parse_conf_funckeys(env)
    local funckeys = {
        macro      = {},
        primary    = {},
        secondary  = {},
        tertiary   = {},
        fullci     = {},
        ["break"]  = {},
        ["repeat"] = {},
        clearact   = {},
    }
    local keys_map = env.engine.schema.config:get_map(env.name_space .. "/funckeys")
    for _, key in ipairs(keys_map and keys_map:keys() or {}) do
        if funckeys[key] then
            local char_list = keys_map:get(key):get_list() or { size = 0 }
            for i = 0, char_list.size - 1 do
                funckeys[key][char_list:get_value_at(i):get_int() or 0] = true
            end
        end
    end
    return funckeys
end

-- 从方案配置中读取宏配置
function core.parse_conf_accel_list(env)
    local accel = {}
    local accel_list = env.engine.schema.config:get_list(env.name_space .. "/accel") or { size = 0 }
    for i = 0, accel_list.size - 1 do
        local key_map = accel_list:get_at(i):get_map()
        local type = key_map and key_map:has_key("type") and key_map:get_value("type"):get_string() or ""
        if type == core.macro_types.shell then
            -- not implemented yet
        elseif type == core.macro_types.eval then
            if key_map:has_key("key") and key_map:has_key("expr") then
                local key = key_map:get_value("key"):get_int() or 0
                local expr = key_map:get_value("expr"):get_string()
                accel[key] = new_accel_eval(expr)
            end
        end
    end
    return accel
end

-- 构造智能词前缀树
function core.gen_smart_trie(base_rev, db_name)
    local result = {
        base_rev  = base_rev,
        db_path   = rime_api.get_user_data_dir() .. "/" .. db_name,
        dict_path = rime_api.get_user_data_dir() .. "/" .. db_name .. ".txt",
    }

    -- 获取db对象
    function result:db()
        if not self.userdb then
            -- 使用 pcall 尝试两种 LevelDb 传参方式
            local ok
            ok, self.userdb = pcall(LevelDb, db_name)
            if not ok then
                _, self.userdb = pcall(LevelDb, self.db_path, db_name)
            end
        end
        if self.userdb and not self.userdb:loaded() then
            self.userdb:open()
        end
        return self.userdb
    end

    -- 查询对应的智能候选词
    function result:query(code, first_chars, count)
        local words = {}
        if #code == 0 then
            return words
        end
        if type(code) == "table" then
            local segs = code
            code = table.concat(code)
            -- 末位单字简码补空格
            if string.match(segs[#segs], "^[a-z][a-z]?$") then
                code = code .. "1"
            end
        end
        if self:db() then
            local prefix = string.format(":%s:", code)
            local accessor = self:db():query(prefix)
            local weights = {}
            -- 最多返回 count 个结果
            count = count or 1
            local index = 0
            for key, value in accessor:iter() do
                if index >= count then
                    break
                end
                index = index + 1
                -- 查得词条和权重
                local word = string.sub(key, #prefix + 1, -1)
                local weight = tonumber(value)
                table.insert(words, word)
                weights[word] = weight
            end
            -- 按词条权重降序排
            table.sort(words, function(a, b) return weights[a] > weights[b] end)
            -- 过滤与单字首选相同的唯一候选词
            if #words == 1 and words[1] == table.concat(first_chars or {}) then
                table.remove(words)
            end
        end
        return words
    end

    -- 更新词条记录
    function result:update(code, word, weight)
        if self:db() then
            -- insert { ":jgarjk:时间" -> weight }
            local key = string.format(":%s:%s", code, word)
            local value = tostring(weight or 0)
            self:db():update(key, value)
        end
    end

    -- 删除词条记录
    function result:delete(code, word)
        if self:db() then
            -- delete ":jgarjk:时间"
            local key = string.format(":%s:%s", code, word)
            self:db():erase(key)
        end
    end

    function result:clear_dict()
        if self:db() then
            local db = self:db()
            local accessor = db:query(":")
            local count = 0
            for key, _ in accessor:iter() do
                count = count + 1
                db:erase(key)
            end
            return string.format("cleared %d phrases", count)
        else
            return "cannot open smart db"
        end
    end

    -- 从字典文件读取词条, 录入到 leveldb 中
    function result:load_dict()
        if not self.base_rev then
            return "cannot open reverse db"
        elseif self:db() then
            -- 试图打开文件
            local file, err = io.open(self.dict_path, "r")
            if not file then
                return err
            end
            local weight = os.time()
            for line in file:lines() do
                local chars = {}
                -- "时间轴" => ["时:jga", "间:rjk", "轴:rpb"]
                for _, c in utf8.codes(line) do
                    local char = utf8.char(c)
                    local code = core.rev_lookup(self.base_rev, char)
                    if #code == 0 then
                        -- 反查失败, 下一个
                        break
                    end
                    table.insert(chars, { char = char, code = code })
                end
                -- 1 <= i <= n-1; i+1 <= j <= n
                -- (i, j): (1, 2) -> (1, 3) -> (2, 3)
                -- "时间", "时间轴", "间轴"
                for i = 1, #chars - 1, 1 do
                    local code, word = chars[i].code, chars[i].char
                    for j = i + 1, #chars, 1 do
                        -- 连字成词
                        code = code .. chars[j].code
                        word = word .. chars[j].char
                        -- insert: { "jgarjk:时间" -> weight }
                        self:update(code, word, weight)
                    end
                end
                weight = weight - 1
            end
            file:close()
            return ""
        else
            return "cannot open smart db"
        end
    end

    -- 用户字典为空时, 尝试加载词典
    if result:db() then
        local accessor = result:db():query(":")
        local empty = true
        for _ in accessor:iter() do
            empty = false
            break
        end
        if empty then
            result:load_dict()
        end
    end
    return result
end

-- 是否合法琉璃分词串
function core.valid_liuli_input(input)
    -- 输入串完全由 [a-z_] 构成, 且不以 [_] 开头
    return string.match(input, "^[a-z ]*$") and not string.match(input, "^[ ]")
end

-- 构造开关变更回调函数
---@param option_names table
function core.get_switch_handler(env, option_names)
    env.option = env.option or {}
    local option = env.option
    local name_set = {}
    if option_names then
        for name in pairs(option_names) do
            name_set[name] = true
        end
    end
    -- 返回通知回调, 当改变选项值时更新暂存的值
    ---@param name string
    return function(ctx, name)
        if name_set[name] then
            option[name] = ctx:get_option(name)
            if option[name] == nil then
                -- 当选项不存在时默认为启用状态
                option[name] = true
            end
            -- 刷新, 使 lua 组件读取最新开关状态
            ctx:refresh_non_confirmed_composition()
        end
    end
end

-- 计算分词列表
-- "dkdqgxfvt;" -> ["dkd","qgx","fvt"], ";"
-- "d;nua"     -> ["d;", "nua"]
function core.get_code_segs(input)
    input = core.input_replace_funckeys(input)
    local code_segs = {}
    while string.len(input) ~= 0 do
        if string.match(string.sub(input, 1, 2), "[a-z][1-3]") then
            -- 匹配到一简
            table.insert(code_segs, string.sub(input, 1, 2))
            input = string.sub(input, 3)
        elseif string.match(string.sub(input, 1, 3), "[a-z][a-z][a-z1-3]") then
            -- 匹配到全码或二简
            table.insert(code_segs, string.sub(input, 1, 3))
            input = string.sub(input, 4)
        else
            -- 不完整或不合法分词输入串
            return code_segs, input
        end
    end
    return code_segs, input
end

-- 根据字符反查最短编码
function core.rev_lookup(rev, char)
    local result = ""
    if not rev then
        return result
    end
    -- rev:lookup("他") => "e1 eso"
    local rev_code = rev:lookup_stems(char)
    if #rev_code == 0 then
        rev_code = rev:lookup(char)
    end
    for code in string.gmatch(rev_code, "[^ ]+") do
        if string.match(code, "^[a-z][1-3]$") then
            -- "a1", 直接结束
            result = code
            break
        elseif not string.match(code, "^[a-z][a-z]?$") then
            -- 非 "a", "ab"
            if #result == 0 or string.match(code, "^[a-z][a-z][1-3]$") then
                result = code
            end
        end
    end
    return result
end

-- 查询编码对应候选列表
-- "dkd" -> ["南", "电"]
function core.dict_lookup(env, mem, code, count, comp)
    -- 是否补全编码
    count = count or 1
    comp = comp or false
    local result = {}
    if not mem then
        return result
    end
    if mem:dict_lookup(code, comp, 100) then
        -- 封装初始迭代器
        local iterator = wrap_iterator(mem, function(iter, yield)
            for entry in iter:iter_dict() do
                yield(entry)
            end
        end)
        if #env.config.mappers ~= 0 then
            -- 使用方案定义的映射器对迭代器层层包装
            for _, mapper in pairs(env.config.mappers) do
                iterator = wrap_iterator(iterator, function(iter, yield)
                    mapper(iter, env, yield)
                end)
            end
        end

        -- 根据 entry.text 聚合去重
        local res_set = {}
        local index = 1
        for entry in iterator() do
            if index > count then
                break
            end

            -- 剩余编码大于一, 则不收
            if entry.remaining_code_length <= 1 then
                local exist = res_set[entry.text]
                if not exist then
                    -- 候选去重, 但未完成编码提示取有
                    res_set[entry.text] = entry
                    table.insert(result, entry)
                    index = index + 1
                elseif #exist.comment == 0 then
                    exist.comment = entry.comment
                end
            end
        end
    end
    return result
end

-- 查询分词首选列表
function core.query_first_cand_list(env, mem, code_segs)
    local cand_list = {}
    for _, code in ipairs(code_segs) do
        local entries = core.dict_lookup(env, mem, code)
        table.insert(cand_list, entries[1] and entries[1].text or "")
    end
    return cand_list
end

-- 最大匹配查询分词候选列表
-- ["dkd", "qgx", "fvt"] -> ["电动", "杨"]
-- ["dkd", "qgx"]        -> ["南", "动"]
function core.query_cand_list(env, mem, code_segs, skipfull)
    local index = 1
    local cand_list = {}
    local code = table.concat(code_segs, "", index)
    while index <= #code_segs do
        -- 最大匹配
        for viewport = #code_segs, index, -1 do
            if skipfull and viewport - index + 1 >= #code_segs and #code_segs > 1 then
                -- continue
            else
                code = table.concat(code_segs, "", index, viewport)
                -- TODO: 优化智能词查询
                local entries = {}
                if index == viewport then
                    entries = core.dict_lookup(env, mem, code)
                else
                    local segs = {}
                    for i = index, viewport, 1 do
                        table.insert(segs, code_segs[i])
                    end
                    local chars = core.query_first_cand_list(env, mem, segs)
                    local words = core.word_trie:query(segs, chars, 1)
                    for _, word in ipairs(words) do
                        table.insert(entries, { text = word, comment = "💭" })
                    end
                end
                if entries[1] then
                    -- 当前viewport有候选, 择之并进入下一轮
                    table.insert(cand_list, entries[1].text)
                    index = viewport + 1
                    break
                elseif viewport == index then
                    -- 最小viewport无候选, 以空串作为候选
                    table.insert(cand_list, "")
                    index = viewport + 1
                    break
                end
            end
        end
    end
    -- 返回候选字列表及末候选编码
    return cand_list, code
end

-- 导出为全局模块
LlCore = core
return core
