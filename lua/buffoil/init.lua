local M = {}

local paths = {}
local current_buf = nil
local alt_buf = nil
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
            vim.api.nvim_buf_delete(
                buf, { force = true })
        end
    end

    winid_by_type = { path = nil, file = nil, preview = nil }
    vim.api.nvim_del_augroup_by_name(augroup_name)
    opened = false
end

function M.close()
    M.cleanup()
    M.set_alternate_buffer(alt_buf)
end

function M.select()
    local current_line_number = vim.api.nvim_win_get_cursor(0)[1]
    local selected = paths[current_line_number]

    M.cleanup()
    if selected == current_buf then
        M.set_alternate_buffer(alt_buf)
    elseif selected ~= nil then
        vim.cmd('buffer ' .. vim.fn.bufnr(selected, false))
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

function M.preview_renderer_register()
    local last_line = vim.api.nvim_win_get_cursor(winid_by_type.file)[1]
    vim.api.nvim_create_autocmd("CursorMoved", {
        group = augroup_name,
        buffer = bufnr_by_type.file,
        callback = function()
            local curr_line = vim.fn.line('.')
            if curr_line ~= last_line then
                M.render_preview(paths[curr_line])
                last_line = curr_line
            end
        end
    })

    local last_line_count = vim.api.nvim_buf_line_count(bufnr_by_type.file)
    vim.api.nvim_create_autocmd("TextChanged", {
        buffer = bufnr_by_type.file,
        group = augroup_name,
        callback = function()
            local _, file_table = M.split_paths()

            local curr_line_count = vim.api.nvim_buf_line_count(0)
            if curr_line_count < last_line_count then
                local lines = vim.api.nvim_buf_get_lines(bufnr_by_type.file, 0, -1, false)
                local deleted_line_idx = #file_table
                for i, line in ipairs(lines) do
                    if file_table[i] ~= line then
                        deleted_line_idx = i
                        break
                    end
                end

                -- TODO: bug: sometimes it not deleted, just listed down
                vim.api.nvim_buf_delete(vim.fn.bufnr(paths[deleted_line_idx]), { force = true })
                table.remove(paths, deleted_line_idx)

                M.render()
                M.render_preview(paths[vim.fn.line('.')])
            end
            last_line_count = curr_line_count
        end
    })
end

function M.render()
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
    M.render_preview(paths[default_start_line])

    ---- create windows
    --- 1. path
    if winid_by_type.path == nil or not vim.api.nvim_win_is_valid(winid_by_type.path) then
        winid_by_type.path = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(winid_by_type.path, bufnr_by_type.path)
        vim.wo[winid_by_type.path].signcolumn = 'no' -- TODO: bug: сбрасывает на обычных буферах
        vim.cmd('set relativenumber!')
        vim.cmd('%right ' .. path_max_len)
        vim.cmd('vsplit')
        vim.api.nvim_win_set_width(winid_by_type.path, path_max_len)
    end

    --- 2. file
    if winid_by_type.file == nil or not vim.api.nvim_win_is_valid(winid_by_type.file) then
        winid_by_type.file = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(winid_by_type.file, bufnr_by_type.file)

        if vim.api.nvim_buf_line_count(bufnr_by_type.file) > 1 then
            vim.api.nvim_win_set_cursor(winid_by_type.file, { default_start_line, 0 })
        end

        vim.cmd('vsplit')
        vim.api.nvim_win_set_width(winid_by_type.file, file_max_len)
    end

    --- 3. preview
    if winid_by_type.preview == nil or not vim.api.nvim_win_is_valid(winid_by_type.preview) then
        winid_by_type.preview = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(winid_by_type.preview, bufnr_by_type.preview)
        M.preview_renderer_register()
    end

    -- set active file win
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
        if not (name == "" or name:match(".*://.*")) then
            table.insert(paths, vim.fn.fnamemodify(name, ":."))
        end
    end
end

function M.register_keymaps()
    vim.api.nvim_buf_set_keymap(bufnr_by_type.file, 'n', '<cr>', ':lua require("buffoil").select()<cr>',
        { noremap = true, silent = true })
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

    vim.api.nvim_create_augroup(augroup_name, { clear = true })

    current_buf = M.get_current_buf()
    alt_buf = M.get_prev_buf()

    M.refresh_buffer_list()
    M.render()
    M.register_keymaps()
end

--
-- TODO:
-- `raw mode` for editing as you want
-- api methods and set mappings for hipsters:
--      <ctrl-x>: delete selected buffer
--      <ctrl-j>: move selected 1 pos down
--      <ctrl-k>: move selected 1 pos up
-- TODO: floating window and others view options (raw mode, without preview)
-- TODO: ignore /tmp/*

return M
