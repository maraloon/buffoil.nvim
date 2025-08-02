local M = {}

require "logging.file"
local logger = logging.file {
    filename = "debug.log",
}

local paths = {}
local current_buf = nil
local alt_buf = nil
local signcolumn_value = nil
local opened = false
local bufnr_by_type = {
    path = nil,
    file = nil,
    preview = nil,
}
local winid_by_type = {
    path = nil,
    file = nil,
    preview = nil,
}

local default_start_line = 2
local augroup_name = 'OilBuf'

local prev_line_pos = nil
local curr_line_pos = nil
local prev_lines_count = nil
local curr_lines_count = nil

function M.split_paths()
    local left_side = {}
    local right_side = {}
    local left_max_len = 0
    local right_max_len = 0
    for _, name in ipairs(paths) do
        local last_slash_pos = 0
        local start = 1
        while true do
            local pos = name:find("/", start, true)
            if not pos then break end
            last_slash_pos = pos
            start = pos + 1
        end

        local l = name:sub(1, last_slash_pos)
        local r = name:sub(last_slash_pos + 1)
        table.insert(left_side, l)
        table.insert(right_side, r)

        if l:len() > left_max_len then
            left_max_len = l:len()
        end
        if r:len() > right_max_len then
            right_max_len = r:len()
        end
    end
    -- []'path/to/file.md' -> []'path/to/', []'file.md', 8, 7
    return left_side, right_side, left_max_len, right_max_len
end

function M.set_alternate_buffer(bufname)
    if bufname == nil then
        return
    end

    local bufnr = vim.fn.bufnr(bufname, false)
    if bufnr ~= -1 then
        vim.cmd('balt ' .. bufname)
    end
end

function M.get_current_buf()
    local bufname = vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
    if bufname == "" then
        return nil
    end
    return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf()), ":.")
end

function M.get_prev_buf()
    if vim.fn.bufnr('#') ~= -1 then
        local bufname = vim.api.nvim_buf_get_name(vim.fn.bufnr('#'))
        if bufname == "" then
            return nil
        end
        return vim.fn.fnamemodify(bufname, ":.")
    end
    return nil
end

function M.cleanup()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.bo[buf].filetype == 'bufoil' then
            vim.api.nvim_buf_delete(buf, { force = true })
        end
    end

    winid_by_type = { path = nil, file = nil, preview = nil }

    vim.api.nvim_del_augroup_by_name(augroup_name)
    if signcolumn_value ~= nil then
        vim.wo[vim.api.nvim_get_current_win()].signcolumn = signcolumn_value
    end
    opened = false
end

function M.close()
    M.cleanup()
    M.set_alternate_buffer(alt_buf)
end

function M.select()
    local current_line_number = vim.api.nvim_win_get_cursor(0)[1]
    local selected = paths[current_line_number]

    if selected == current_buf then
        M.cleanup()
        M.set_alternate_buffer(alt_buf)
    elseif selected ~= nil then
        vim.api.nvim_open_win(vim.fn.bufnr(selected, false), true, { split = 'right' })
        M.cleanup()
        M.set_alternate_buffer(current_buf)
    end
end

function M.render_preview(path)
    local has_lines, read_res
    -- has_lines, read_res = pcall(vim.fn.readfile, path)
    has_lines, read_res = pcall(vim.fn.readfile, path, "", vim.o.lines) -- so-called "fast_scratch"
    local lines = has_lines and vim.split(table.concat(read_res, "\n"), "\n") or {}

    local ok = pcall(vim.api.nvim_buf_set_lines, bufnr_by_type.preview, 0, -1, false, lines)
    if not ok then
        return
    end
    local ft = vim.filetype.match({ filename = path, buf = bufnr_by_type.preview })
    if ft and ft ~= "" and vim.treesitter.language.get_lang then
        local lang = vim.treesitter.language.get_lang(ft)
        if not pcall(vim.treesitter.start, bufnr_by_type.preview, lang) then
            vim.bo[bufnr_by_type.preview].syntax = ft
        end
    end
end

local function register_line_movements()
    prev_line_pos = vim.api.nvim_win_get_cursor(winid_by_type.file)[1]
    curr_line_pos = prev_line_pos

    prev_lines_count = vim.api.nvim_buf_line_count(bufnr_by_type.file)
    curr_lines_count = prev_lines_count

    return function()
        local l = vim.fn.line('.')
        prev_line_pos = curr_line_pos
        curr_line_pos = l

        local c = vim.api.nvim_buf_line_count(bufnr_by_type.file)
        curr_lines_count = c
    end
end

local function delete_buffers()
    return function()
        if curr_lines_count < prev_lines_count then
            local idx = curr_line_pos
            if prev_line_pos ~= curr_line_pos and curr_line_pos == curr_lines_count then -- when delete from the end of list
                idx = curr_line_pos + 1
            end

            local count_delete = prev_lines_count - curr_lines_count
            while count_delete > 0 do
                vim.api.nvim_buf_delete(vim.fn.bufnr(paths[idx]), { force = true })
                table.remove(paths, idx)
                count_delete = count_delete - 1
            end

            prev_lines_count = curr_lines_count

            M.render()
            M.render_preview(paths[vim.fn.line('.')])
        end
    end
end

local function redraw_preview()
    local last_line = vim.api.nvim_win_get_cursor(winid_by_type.file)[1]

    return function()
        local curr_line = vim.fn.line('.')
        if curr_line ~= last_line then
            M.render_preview(paths[curr_line])
            last_line = curr_line
        end
    end
end

function M.register_autocmds()
    vim.api.nvim_create_augroup(augroup_name, { clear = true })

    vim.api.nvim_create_autocmd("CursorMoved", {
        group = augroup_name,
        buffer = bufnr_by_type.file,
        callback = redraw_preview()
    })

    vim.api.nvim_create_autocmd("CursorMoved", {
        group = augroup_name,
        buffer = bufnr_by_type.file,
        callback = register_line_movements()
    })

    vim.api.nvim_create_autocmd("TextChanged", {
        group = augroup_name,
        buffer = bufnr_by_type.file,
        callback = delete_buffers()
    })
end

function M.render()
    if signcolumn_value == nil then
        signcolumn_value = vim.wo[vim.api.nvim_get_current_win()].signcolumn
    end

    local path_table, file_table, path_max_len, file_max_len = M.split_paths()

    ---- check not existed plugin buffers
    local buf_exists = {
        path = false,
        file = false,
        preview = false,
    }

    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.bo[bufnr].filetype == 'bufoil' then
            local buftype = vim.api.nvim_buf_get_var(bufnr, 'buftype')
            if buftype == 'path' then
                buf_exists.path = true
            elseif buftype == 'file' then
                buf_exists.file = true
            elseif buftype == 'preview' then
                buf_exists.preview = true
            end
        end
    end

    ---- create buffers
    for buftype, exists in pairs(buf_exists) do
        if exists == false then
            local bufnr = vim.api.nvim_create_buf(false, true)
            bufnr_by_type[buftype] = bufnr
            vim.bo[bufnr].buftype = 'nofile'
            vim.bo[bufnr].modifiable = true
            vim.bo[bufnr].buflisted = false
            vim.bo[bufnr].bufhidden = 'wipe'
            vim.bo[bufnr].filetype = 'bufoil'
            vim.api.nvim_buf_set_var(bufnr, 'buftype', buftype)
        end
    end

    ---- fill buffers with content
    vim.api.nvim_buf_set_lines(bufnr_by_type.path, 0, -1, false, path_table)
    vim.api.nvim_buf_set_lines(bufnr_by_type.file, 0, -1, false, file_table)
    M.render_preview(paths[default_start_line] or paths[1])

    ---- create windows
    if winid_by_type.path == nil or not vim.api.nvim_win_is_valid(winid_by_type.path) then
        winid_by_type.path = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(winid_by_type.path, bufnr_by_type.path)
    end

    if winid_by_type.file == nil or not vim.api.nvim_win_is_valid(winid_by_type.file) then
        winid_by_type.file = vim.api.nvim_open_win(bufnr_by_type.file, true, { split = 'right' })
    end

    if winid_by_type.preview == nil or not vim.api.nvim_win_is_valid(winid_by_type.preview) then
        winid_by_type.preview = vim.api.nvim_open_win(bufnr_by_type.preview, true, { split = 'right' })

        if vim.api.nvim_buf_line_count(bufnr_by_type.file) > 1 then
            vim.api.nvim_win_set_cursor(winid_by_type.file, { default_start_line, 0 })
            vim.defer_fn(function() vim.fn.feedkeys('zb') end, 0)
        end
    end

    vim.api.nvim_win_set_width(winid_by_type.path, path_max_len)
    vim.api.nvim_win_set_width(winid_by_type.file, file_max_len + 3)

    vim.wo[winid_by_type.path].signcolumn = 'no'
    vim.wo[winid_by_type.file].signcolumn = 'no'
    vim.wo[winid_by_type.preview].signcolumn = 'no'
    vim.wo[winid_by_type.path].winbar = 'Paths'
    vim.wo[winid_by_type.file].winbar = 'Filenames'
    vim.wo[winid_by_type.preview].winbar = 'Preview'
    -- vim.opt.statusline = 'buffoil.nvim'

    vim.api.nvim_set_current_win(winid_by_type.path)
    vim.cmd('set nornu')
    vim.cmd('%right ' .. path_max_len)
    -- set cursor on 'file' window
    vim.api.nvim_set_current_win(winid_by_type.file)
end

function M.refresh_buffer_list()
    paths = {}

    local bufnrs = vim.tbl_filter(function(bufnr)
        return vim.fn.buflisted(bufnr) == 1
    end, vim.api.nvim_list_bufs())

    table.sort(bufnrs, function(a, b)
        return vim.fn.getbufinfo(a)[1].lastused > vim.fn.getbufinfo(b)[1].lastused
    end)

    for _, bufnr in ipairs(bufnrs) do
        local name = vim.api.nvim_buf_get_name(bufnr)
        if not (name == "" or name:match(".*://.*") or name:match("^/tmp/")) then
            table.insert(paths, vim.fn.fnamemodify(name, ":."))
        end
    end
end

M.search = function()
    vim.fn.inputsave()
    local input = vim.fn.input('/')
    vim.fn.inputrestore()

    vim.api.nvim_del_augroup_by_name(augroup_name)

    for i = #paths, 1, -1 do
        if not paths[i]:find(input) then
            table.remove(paths, i)
        end
    end

    M.render()
    M.register_autocmds()
end

function M.register_keymaps()
    vim.api.nvim_buf_set_keymap(bufnr_by_type.file, 'n', '<cr>', ':lua require("buffoil").select()<cr>',
        {})
    vim.api.nvim_buf_set_keymap(bufnr_by_type.file, 'n', '/', ':lua require("buffoil").search()<cr>',
        {})
    vim.api.nvim_buf_set_keymap(bufnr_by_type.file, 'n', '<esc>', ':lua require("buffoil").close()<cr>',
        { noremap = true, silent = true })
    vim.api.nvim_buf_set_keymap(bufnr_by_type.file, 'n', '<C-c>', ':lua require("buffoil").close()<cr>',
        { noremap = true, silent = true })
end

function M.show()
    if opened then
        return
    end
    opened = true

    current_buf = M.get_current_buf()
    alt_buf = M.get_prev_buf()

    M.refresh_buffer_list()
    M.render()
    M.register_autocmds()
    M.register_keymaps()
end

return M
