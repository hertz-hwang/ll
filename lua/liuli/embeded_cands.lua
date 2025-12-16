-- 将要被返回的过滤器对象
local embeded_cands_filter = {}
local core = require("liuli.core")


--[[
# xxx.schema.yaml
switches:
  - name: embeded_cands
    states: [ 普通, 嵌入 ]
    reset: 1
engine:
  filters:
    - lua_filter@*liuli.embeded_cands
key_binder:
  bindings:
    - { when: always, accept: "Control+Shift+E", toggle: embeded_cands }
--]]

local index_indicators = { "¹", "²", "³", "⁴", "⁵", "⁶", "⁷", "⁸", "⁹", "⁰" }

-- 首选/非首选格式定义
-- Stash: 延迟候选; Seq: 候选序号; Code: 编码; 候选: 候选文本; Comment: 候选提示
local first_format = "${Stash}[${候选}${Seq}]${Code}${Comment}"
local next_format = "${Stash}${候选}${Seq}${Comment}"
local separator = " "
local stash_placeholder = "~"

local function compile_formatter(format)
    -- "${Stash}[${候选}${Seq}]${Code}${Comment}"
    -- => "%s[%s%s]%s%s"
    -- => {"${Stash}", "${...}", "${...}", ...}
    local pattern = "%$%{[^{}]+%}"
    local verbs = {}
    for s in string.gmatch(format, pattern) do
        table.insert(verbs, s)
    end

    local res = {
        format = string.gsub(format, pattern, "%%s"),
        verbs = verbs,
    }
    local meta = { __index = function() return "" end }

    -- {"${v1}", "${v2}", ...} + {v1: a1, v2: a2, ...} = {a1, a2, ...}
    -- string.format("%s[%s%s]%s%s", a1, a2, ...)
    function res:build(dict)
        setmetatable(dict, meta)
        local args = {}
        for _, pat in ipairs(self.verbs) do
            table.insert(args, dict[pat])
        end
        return string.format(self.format, table.unpack(args))
    end

    return res
end


-- 按命名空间归类方案配置, 而不是按会话, 以减少内存占用
local namespaces = {}

function namespaces:init(env)
    if not namespaces:config(env) then
        -- 读取配置项
        local config = {}
        config.index_indicators = core.parse_conf_str_list(env, "index_indicators", index_indicators)
        config.first_format = core.parse_conf_str(env, "first_format", first_format)
        config.next_format = core.parse_conf_str(env, "next_format", next_format)
        config.separator = core.parse_conf_str(env, "separator", separator)
        config.stash_placeholder = core.parse_conf_str(env, "stash_placeholder", stash_placeholder)

        config.formatter = {}
        config.formatter.first = compile_formatter(config.first_format)
        config.formatter.next = compile_formatter(config.next_format)
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

function embeded_cands_filter.init(env)
    -- 读取配置项
    local ok = pcall(namespaces.init, namespaces, env)
    if not ok then
        local config = {}
        config.index_indicators = index_indicators
        config.first_format = first_format
        config.next_format = next_format
        config.separator = separator
        config.stash_placeholder = stash_placeholder

        config.formatter = {}
        config.formatter.first = compile_formatter(config.first_format)
        config.formatter.next = compile_formatter(config.next_format)
        namespaces:set_config(env, config)
    end

    -- 构造回调函数
    local option_names = {
        [core.switch_names.embeded_cands] = true,
    }
    local handler = core.get_switch_handler(env, option_names)
    -- 初始化为选项实际值, 如果设置了 reset, 则会再次触发 handler
    for name in pairs(option_names) do
        handler(env.engine.context, name)
    end
    -- 注册通知回调
    env.engine.context.option_update_notifier:connect(handler)
end

-- 处理候选文本和延迟串
local function render_stashcand(env, seq, stash, text, digested)
    if string.len(stash) ~= 0 and string.match(text, "^" .. stash) then
        if seq == 1 then
            -- 首选含延迟串, 原样返回
            digested = true
            stash, text = stash, string.sub(text, string.len(stash) + 1)
        elseif not digested then
            -- 首选不含延迟串, 其他候选含延迟串, 标记之
            digested = true
            stash, text = "[" .. stash .. "]", string.sub(text, string.len(stash) + 1)
        else
            -- 非首个候选, 延迟串标记为空
            local placeholder = string.gsub(namespaces:config(env).stash_placeholder, "%${Stash}", stash)
            stash, text = "", placeholder .. string.sub(text, string.len(stash) + 1)
        end
    else
        -- 普通候选, 延迟串标记为空
        stash, text = "", text
    end
    return stash, text, digested
end

-- 渲染提示, 因为提示经常有可能为空, 抽取为函数更易操作
local function render_comment(comment)
    if string.match(comment, "^~") then
        -- 丢弃以"~"开头的提示串, 这通常是补全提示
        comment = ""
    else
        -- 自定义提示串格式
        -- comment = "<"..comment..">"
    end
    return comment
end

-- 渲染单个候选项
local function render_cand(env, seq, code, stashed, text, comment, digested)
    local formatter
    -- 选择渲染格式
    if seq == 1 then
        formatter = namespaces:config(env).formatter.first
    else
        formatter = namespaces:config(env).formatter.next
    end
    -- 渲染延迟串与候选文字
    stashed, text, digested = render_stashcand(env, seq, stashed, text, digested)
    if seq ~= 1 and text == "" then
        return "", digested
    end
    -- 渲染提示串
    comment = render_comment(comment)
    local cand = formatter:build({
        ["${Seq}"] = namespaces:config(env).index_indicators[seq],
        ["${Code}"] = code,
        ["${Stash}"] = stashed,
        ["${候选}"] = text,
        ["${Comment}"] = comment,
    })
    return cand, digested
end


-- 过滤器
function embeded_cands_filter.func(input, env)
    if not env.option[core.switch_names.embeded_cands] then
        for cand in input:iter() do
            yield(cand)
        end
        return
    end

    -- 要显示的候选数量
    local page_size = env.engine.schema.page_size
    -- 暂存当前页候选, 然后批次送出
    local page_cands, page_rendered = {}, {}
    -- 暂存索引, 首选和预编辑文本
    local index, first_cand, preedit = 0, nil, ""
    local digested = false

    local function refresh_preedit()
        first_cand.preedit = table.concat(page_rendered, namespaces:config(env).separator)
        -- 将暂存的一页候选批次送出
        for _, c in ipairs(page_cands) do
            yield(c)
        end
        -- 清空暂存
        first_cand, preedit = nil, ""
        page_cands, page_rendered = {}, {}
        digested = false
    end

    -- 迭代器
    local iter, obj = input:iter()
    -- 迭代由翻译器输入的候选列表
    local next = iter(obj)
    -- local first_stash = true
    while next do
        -- 页索引自增, 满足 1 <= index <= page_size
        index = index + 1
        -- 当前遍历候选项
        local cand = Candidate(next.type, next.start, next._end, next.text, next.comment) -- next
        cand.quality = next.quality
        cand.preedit = next.preedit

        if index == 1 then
            -- 把首选捉出来
            first_cand = cand:get_genuine()
        end

        -- 活动输入串
        local input_code = ""
        if string.len(core.input_code) == 0 then
            input_code = cand.preedit
        else
            input_code = core.input_code
        end

        -- 展开 IVD selector
        if #input_code == 0 then
            for _, c in utf8.codes(cand.text) do
                if c >= 0xE0100 and c <= 0xE01FF then
                    cand.comment = string.format("(%X)", c)
                end
            end
        end

        -- 带有暂存串的候选合并同类项
        preedit, digested = render_cand(env, index, input_code, core.stashed_text, cand.text, cand.comment, digested)

        -- 存入候选
        table.insert(page_cands, cand)
        if #preedit ~= 0 then
            table.insert(page_rendered, preedit)
        end

        -- 遍历完一页候选后, 刷新预编辑文本
        if index == page_size then
            refresh_preedit()
        end

        -- 当前候选处理完毕, 查询下一个
        next = iter(obj)

        -- 如果当前暂存候选不足page_size但没有更多候选, 则需要刷新预编辑并送出
        if not next and index < page_size then
            refresh_preedit()
        end

        -- 下一页, index归零
        index = index % page_size
    end
end

function embeded_cands_filter.fini(env)
    env.option = nil
end

return embeded_cands_filter
