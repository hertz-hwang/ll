local processor = {}
local core      = require("liuli.core")


local kRejected = 0 -- 拒: 不作响应, 由操作系統做默认处理
local kAccepted = 1 -- 收: 由rime响应该按键
local kNoop     = 2 -- 无: 请下一个processor继续看


local char_a         = string.byte("a") -- 字符: 'a'
local char_z         = string.byte("z") -- 字符: 'z'
local char_a_upper   = string.byte("A") -- 字符: 'A'
local char_z_upper   = string.byte("Z") -- 字符: 'Z'
local char_0         = string.byte("0") -- 字符: '0'
local char_9         = string.byte("9") -- 字符: '9'
local char_space     = 0x20             -- 空格
local char_del       = 0x7f             -- 删除
local char_backspace = 0xff08           -- 退格


-- 按命名空间归类方案配置, 而不是按会话, 以减少内存占用
local namespaces = {}

function namespaces:init(env)
    -- 读取配置项
    if not namespaces:config(env) then
        local config = {}
        config.macros = core.parse_conf_macro_list(env)
        config.funckeys = core.parse_conf_funckeys(env)
        config.accels = core.parse_conf_accel_list(env)
        config.mappers = core.parse_conf_mapper_list(env)
        namespaces:set_config(env, config)
    end
end

function namespaces:set_config(env, config)
    namespaces[env.name_space] = namespaces[env.name_space] or {}
    namespaces[env.name_space].config = config
end

function namespaces:config(env)
    return namespaces[env.name_space] and namespaces[env.name_space].config
end

-- 返回被选中的候选的索引, 来自 librime-lua/sample 示例
local function select_index(key, env)
    local ch = key.keycode
    local index = -1
    local select_keys = env.engine.schema.select_keys
    if select_keys ~= nil and select_keys ~= "" and not key.ctrl() and ch >= 0x20 and ch < 0x7f then
        local pos = string.find(select_keys, string.char(ch))
        if pos ~= nil then index = pos end
    elseif ch >= 0x30 and ch <= 0x39 then
        index = (ch - 0x30 + 9) % 10
    elseif ch >= 0xffb0 and ch < 0xffb9 then
        index = (ch - 0xffb0 + 9) % 10
    elseif ch == 0x20 then
        index = 0
    end
    return index
end


-- 提交候选文本, 并刷新输入串
local function commit_text(env, ctx, text, input)
    ctx:clear()
    if #text ~= 0 then
        env.engine:commit_text(text)
    end
    ctx:push_input(core.input_restore_funckeys(input))
end

-- 整句辅助函数
local function is_sentence_mode(env)
    return env.option and env.option[core.switch_names.sentence]
end

local function handle_macros(env, ctx, macro, args, idx)
    if macro then
        if macro[idx] then
            macro[idx]:trigger(env, ctx, args)
        end
        return kAccepted
    end
    return kNoop
end

-- 处理顶字
local function handle_push(env, ctx, ch)
    if core.valid_liuli_input(ctx.input) then
        -- 获取当前输入串
        local input = ctx.input
        -- 检查是否应该进入整句处理
        if is_sentence_mode(env) then
            -- 在整句模式下，将字符追加到输入串
            ctx:push_input(string.char(ch))
            
            -- 查询当前输入串的候选
            if #ctx.input > 0 then
                local entries = core.dict_lookup(env, core.base_mem, ctx.input, 1)
                if #entries > 0 then
                    local cand = entries[1]
                    -- 创建一个composition来显示候选
                    local composition = ctx.composition
                    if composition:empty() then
                        ctx.composition:insert(0, cand.text)
                    else
                        local segment = composition:back()
                        segment.text = cand.text
                        segment.prompt = ctx.input
                    end
                end
            end
            return kAccepted
        end

        -- 输入串分词列表
        local code_segs, remain = core.get_code_segs(ctx.input)

        -- 纯单三定模式
        if env.option[core.switch_names.single_char] and #code_segs == 1 and #remain == 0 then
            local cands = core.query_cand_list(env, core.base_mem, code_segs)
            if #cands ~= 0 then
                commit_text(env, ctx, cands[1], remain .. string.char(ch))
            end
            return kAccepted
        end

        -- 五三顶模式
        if env.option[core.switch_names.single_char_delay] and #code_segs == 1 and #remain == 1 then
            local cands = core.query_cand_list(env, core.base_mem, code_segs)
            if #cands ~= 0 then
                commit_text(env, ctx, cands[1], remain .. string.char(ch))
            end
            return kAccepted
        end

        -- 智能词延迟顶
        if #remain == 0 and #code_segs > 1 then
            local entries, remain = core.query_cand_list(env, core.base_mem, code_segs)
            if #entries > 1 then
                commit_text(env, ctx, entries[1], remain .. string.char(ch))
                return kAccepted
            end
        end
    end
    return kNoop
end

-- 处理空格分号选字
local function handle_select(env, ctx, ch, funckeys)
    if core.valid_liuli_input(ctx.input) then
        -- 输入串分词列表
        local _, remain = core.get_code_segs(ctx.input)
        if string.match(remain, "^[a-z][a-z]?$") then
            if funckeys.primary[ch] then
                ctx:push_input(core.funckeys_map.primary)
                return kAccepted
            elseif funckeys.secondary[ch] then
                ctx:push_input(core.funckeys_map.secondary)
                return kAccepted
            elseif funckeys.tertiary[ch] then
                ctx:push_input(core.funckeys_map.tertiary)
                return kAccepted
            end
        end
    end
    return kNoop
end

local function handle_fullcode(env, ctx, ch)
    if not env.option[core.switch_names.full_off] and #ctx.input == 4 and not string.match(ctx.input, "[^a-z]") then
        local fullcode_char = env.option[core.switch_names.full_char]
        local entries = core.dict_lookup(env, core.full_mem, ctx.input, 50)
        -- 查找四码首选
        local first
        for _, entry in ipairs(entries) do
            -- 是否单字候选
            if utf8.len(entry.text) == 1 then
                -- 是否启用单字状态
                if fullcode_char then
                    -- 单字模式, 首字上屏
                    first = entry
                    break
                elseif not first then
                    -- 非单字模式, 首字暂存
                    first = entry
                end
            elseif not fullcode_char then
                -- 字词模式, 首词上屏
                first = entry
                break
            end
        end
        -- 上屏暂存的候选
        if first then
            ctx:clear()
            env.engine:commit_text(first.text)
        end
        return kAccepted
    end
    return kNoop
end

local function handle_break(env, ctx, ch)
    if core.valid_liuli_input(ctx.input) then
        -- 输入串分词列表
        local code_segs, remain = core.get_code_segs(ctx.input)
        if #remain == 0 then
            remain = table.remove(code_segs)
        end
        -- 打断施法
        if #code_segs ~= 0 then
            local text_list = core.query_cand_list(env, core.base_mem, code_segs)
            commit_text(env, ctx, table.concat(text_list, ""), remain)
            return kAccepted
        end
    end
    return kNoop
end

local function handle_repeat(env, ctx, ch)
    if core.valid_liuli_input(ctx.input) then
        -- 查询当前首选项
        local code_segs, remain = core.get_code_segs(ctx.input)
        local text_list, _ = core.query_cand_list(env, core.base_mem, code_segs)
        local text = table.concat(text_list, "")
        if #remain ~= 0 then
            local entries = core.dict_lookup(env, core.base_mem, remain, 1)
            text = text .. (entries[1] and entries[1].text or "")
        end
        -- 逐个上屏
        ctx:clear()
        for _, c in utf8.codes(text) do
            env.engine:commit_text(utf8.char(c))
        end
    end
    return kNoop
end

-- 清理活动串
local function handle_clean(env, ctx, ch)
    if not core.valid_liuli_input(ctx.input) then
        return kNoop
    end

    -- 输入串分词列表
    local code_segs, remain = core.get_code_segs(ctx.input)
    -- 取出活动串
    if #remain == 0 then
        remain = table.remove(code_segs)
    end

    -- 回删活动串
    ctx:pop_input(#core.input_restore_funckeys(remain))
    return kAccepted
end


function processor.init(env)
    if Switcher then
        env.switcher = Switcher(env.engine)
    end

    -- 读取配置项
    local ok = pcall(namespaces.init, namespaces, env)
    if not ok then
        local config = {}
        config.macros = {}
        config.funckeys = {}
        config.mappers = {}
        namespaces:set_config(env, config)
    end
    env.config = namespaces:config(env)

    -- 构造回调函数
    local option_names = {
        [core.switch_names.sentence] = true,
        [core.switch_names.single_char] = true,
        [core.switch_names.single_char_delay] = true,
        [core.switch_names.full_char]   = true,
        [core.switch_names.full_off]    = true,
    }
    for _, mapper in ipairs(env.config.mappers) do
        option_names[mapper.option] = true
    end
    local handler = core.get_switch_handler(env, option_names)
    -- 初始化为选项实际值, 如果设置了 reset, 则会再次触发 handler
    for name in pairs(option_names) do
        handler(env.engine.context, name)
    end
    -- 注册通知回调
    env.engine.context.option_update_notifier:connect(handler)
end

function processor.func(key_event, env)
    local ctx = env.engine.context
    if #ctx.input == 0 or key_event:release() or key_event:alt() then
        -- 当前无输入, 或不是我关注的键按下事件, 弃之
        return kNoop
    end

    local ch = key_event.keycode
    if key_event:ctrl() then
        -- ctrl-x 自定义 lua 捷径
        local accel = namespaces:config(env).accels[ch]
        if accel then
            local cand = ctx:get_selected_candidate()
            accel:trigger(env, ctx, cand)
            return kAccepted
        end
        return kNoop
    end

    local funckeys = namespaces:config(env).funckeys
    if funckeys.macro[string.byte(string.sub(ctx.input, 1, 1))] then
        -- starts with funckeys/macro set
        local name, args = core.get_macro_args(string.sub(ctx.input, 2), namespaces:config(env).funckeys.macro)
        local macro = namespaces:config(env).macros[name]
        if macro then
            if macro.hijack and ch > char_space and ch < char_del then
                ctx:push_input(string.char(ch))
                return kAccepted
            else
                local idx = select_index(key_event, env)
                if funckeys.clearact[ch] then
                    ctx:clear()
                    return kAccepted
                elseif idx >= 0 then
                    return handle_macros(env, ctx, macro, args, idx + 1)
                end
            end
            return kNoop
        end
    end

    if ch >= char_a and ch <= char_z then
        -- 'a'~'z'
        return handle_push(env, ctx, ch)
    end

    if ch == char_backspace then
        if string.match(ctx.input, " [a-c]$") then
            ctx:pop_input(1)
        end
        return kNoop
    end

    local res = kNoop
    if res == kNoop and (funckeys.primary[ch] or funckeys.secondary[ch] or funckeys.tertiary[ch]) then
        res = handle_select(env, ctx, ch, funckeys)
    end
    if res == kNoop and funckeys.fullci[ch] then
        -- 四码单字
        res = handle_fullcode(env, ctx, ch)
    end
    if res == kNoop and funckeys["break"][ch] then
        -- 打断施法
        res = handle_break(env, ctx, ch)
    end
    if res == kNoop and funckeys["repeat"][ch] then
        -- 重复上屏
        res = handle_repeat(env, ctx, ch)
    end
    if res == kNoop and funckeys.clearact[ch] then
        -- 清除活动编码
        res = handle_clean(env, ctx, ch)
    end
    return res
end

function processor.fini(env)
    env.switcher = nil
    env.option = nil
end

return processor
