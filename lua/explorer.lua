local view = {}

local constants = {
  hl = vim.api.nvim_create_namespace('carbon'),
  hl_tmp = vim.api.nvim_create_namespace('carbon:tmp'),
  augroup = vim.api.nvim_create_augroup('carbon', { clear = false }),
  directions = { left = 'h', right = 'l', up = 'k', down = 'j' },
}

---@class explorer.Opts
local Config = {
  sidebar_width = 30,
  sidebar_toggle_focus = true,
  exclude = {},
  indicators = {
    expand = '+',
    collapse = '-',
  },
}

-------------------------------------------------------------------------------

local function get_line(lnum, buffer)
  return vim.api.nvim_buf_get_lines(buffer or 0, lnum - 1, lnum, true)[1]
end

local function is_excluded(path)
  for _, pattern in ipairs(Config.exclude) do
    if string.find(path, pattern) then
      return true
    end
  end
  return false
end

local function set_cursor(row, col) vim.api.nvim_win_set_cursor(0, { row, col - 1 }) end
local function is_directory(path) return (vim.uv.fs_stat(path) or {}).type == 'directory' end
local function plug(name) return ('<plug>(Carbon%s)'):format(name) end
local function add_highlight(buf, ...) vim.api.nvim_buf_add_highlight(buf, constants.hl, ...) end

local function tbl_key(tbl, item)
  for key, tbl_item in pairs(tbl) do
    if tbl_item == item then
      return key
    end
  end
end

local function buf_winid(buf)
  return vim
    .iter(vim.api.nvim_list_wins())
    :find(function(win) return vim.api.nvim_win_get_buf(win) == buf end)
end

local function buf_find_by_name(name)
  return vim
    .iter(vim.api.nvim_list_bufs())
    :find(function(buf) return name == vim.api.nvim_buf_get_name(buf) end)
end

local function buf_create(name)
  local buf = buf_find_by_name(name)
  if not buf then
    buf = vim.api.nvim_create_buf(false, true)
  end

  for k, v in pairs({
    bufhidden = 'wipe',
    buftype = 'nofile',
    filetype = 'carbon.explorer',
    modifiable = false,
    modified = false,
    swapfile = false,
  }) do
    vim.api.nvim_set_option_value(k, v, { buf = buf })
  end

  vim.api.nvim_buf_set_name(buf, name)

  return buf
end

local function toggle_hidden()
  view.execute(function(ctx)
    ctx.view.show_hidden = not ctx.view.show_hidden

    ctx.view:update()
    ctx.view:render()
  end)
end

local function action_toggle_recursive()
  view.execute(function(ctx)
    if ctx.cursor.line.entry.is_directory then
      local function _toggle_recursive(target, value)
        if target.is_directory then
          ctx.view:set_path_attr(target.path, 'open', value)

          if target:has_children() then
            for _, child in ipairs(target:children()) do
              _toggle_recursive(child, value)
            end
          end
        end
      end

      _toggle_recursive(
        ctx.cursor.line.entry,
        not ctx.view:get_path_attr(ctx.cursor.line.entry.path, 'open')
      )

      ctx.view:update()
      ctx.view:render()
    end
  end)
end

local function action_tabedit()
  view.execute(function(ctx)
    view.handle_sidebar()
    vim.cmd.tabedit({
      vim.fn.fnameescape(ctx.cursor.line.entry.path),
      mods = { keepalt = #vim.fn.getreg('#') ~= 0 },
    })
  end)
end

---@param cmd "split" | "vsplit" | nil
local function action_edit(cmd)
  view.execute(function(ctx)
    if ctx.cursor.line.entry.is_directory then
      local open = ctx.view:get_path_attr(ctx.cursor.line.entry.path, 'open')

      ctx.view:set_path_attr(ctx.cursor.line.entry.path, 'open', not open)
      ctx.view:update()
      ctx.view:render()
      return
    end

    view.handle_sidebar()
    vim.cmd({
      cmd = cmd or 'edit',
      args = { vim.fn.fnameescape(ctx.cursor.line.entry.path) },
      mods = { keepalt = #vim.fn.getreg('#') ~= 0 },
    })
  end)
end

---@param action "up" | "down" | "reset"
local function action_on_view(action)
  view.execute(function(ctx)
    local ok

    if action == 'up' then
      ok = ctx.view:up()
    elseif action == 'down' then
      ok = ctx.view:down()
    else
      ok = ctx.view:reset()
    end

    if ok then
      ctx.view:update()
      ctx.view:render()
      set_cursor(1, 1)
    end
  end)
end

---@param action "create" | "delete" | "move"
local function action_on_entry(action)
  view.execute(function(ctx)
    if action == 'create' then
      ctx.view:create()
    elseif action == 'delete' then
      ctx.view:delete()
    else
      ctx.view:move()
    end
  end)
end

local function action_quit()
  if #vim.api.nvim_list_wins() > 1 then
    vim.api.nvim_win_close(0, true)
  elseif #vim.api.nvim_list_bufs() > 1 then
    pcall(vim.cmd.bprevious)
  end
end

local function action_close_parent()
  view.execute(function(ctx)
    local count = 0
    local lines = { unpack(ctx.view:current_lines(), 2) }
    local entry_ = ctx.cursor.line.entry
    local line

    while count < vim.v.count1 do
      line = vim.iter(lines):find(
        function(current)
          return current.entry == entry_.parent or vim.tbl_contains(current.path, entry_.parent)
        end
      )

      if line then
        count = count + 1
        entry_ = line.path[1] and line.path[1].parent or line.entry

        ctx.view:set_path_attr(entry_.path, 'open', false)
      else
        break
      end
    end

    line = vim.iter(lines):find(
      function(current) return current.entry == entry_ or vim.tbl_contains(current.path, entry_) end
    )

    if line then
      vim.fn.cursor(line.lnum, (line.depth + 1) * 2 + 1)
    end

    ctx.view:update()
    ctx.view:render()
  end)
end

local function buf_init_mappings(buf)
  --- @nodoc
  --- @class explorer.Action
  --- @field key string
  --- @field fn function
  ---
  --- @type table<string, explorer.Action>
  local actions = {
    close_parent = { key = '-', fn = action_close_parent },
    create = { key = 'c', fn = function() action_on_entry('create') end },
    delete = { key = 'd', fn = function() action_on_entry('delete') end },
    down = { key = ']', fn = function() action_on_view('down') end },
    edit = { key = '<cr>', fn = action_edit },
    move = { key = 'm', fn = function() action_on_entry('move') end },
    quit = { key = 'q', fn = action_quit },
    reset = { key = 'u', fn = function() action_on_view('reset') end },
    split = { key = 's', fn = function() action_edit('split') end },
    tabedit = { key = 't', fn = action_tabedit },
    toggle_hidden = { key = 'gh', fn = toggle_hidden },
    toggle_recursive = { key = '!', fn = action_toggle_recursive },
    up = { key = '[', fn = function() action_on_view('up') end },
    vsplit = { key = 'v', fn = function() action_edit('vsplit') end },
  }

  for name, action in pairs(actions) do
    vim.keymap.set('', plug(name), action.fn, { buffer = buf, nowait = true })
    vim.keymap.set('n', action.key, plug(name), { buffer = buf, nowait = true })
  end
end

local function extmarks_clear(buf, ...)
  local extmarks = vim.api.nvim_buf_get_extmarks(buf, constants.hl, ...)

  for _, extmark in ipairs(extmarks) do
    vim.api.nvim_buf_del_extmark(buf, constants.hl, extmark[1])
  end
end

local function win_neightbors(window_id, sides)
  local original_window = vim.api.nvim_get_current_win()
  local result = {}

  for _, side in ipairs(sides or {}) do
    vim.api.nvim_set_current_win(window_id)
    vim.cmd.wincmd(constants.directions[side])

    local side_id = vim.api.nvim_get_current_win()
    local result_id = window_id ~= side_id and side_id or nil

    if result_id then
      result[#result + 1] = {
        origin = window_id,
        position = side,
        target = result_id,
      }
    end
  end

  vim.api.nvim_set_current_win(original_window)

  return result
end

-------------------------------------------------------------------------------

local watcher = {}

watcher.listeners = {}
watcher.events = {}

function watcher.keep(callback)
  for path in pairs(watcher.listeners) do
    if not callback(path) then
      watcher.release(path)
    end
  end
end

function watcher.release(path)
  if not path then
    for listener_path in pairs(watcher.listeners) do
      watcher.release(listener_path)
    end
  elseif watcher.listeners[path] then
    watcher.listeners[path]:stop()

    watcher.listeners[path] = nil
  end
end

function watcher.register(path)
  if not watcher.listeners[path] then
    watcher.listeners[path] = vim.uv.new_fs_event()

    watcher.listeners[path]:start(
      path,
      {},
      vim.schedule_wrap(
        function(error, filename) watcher.emit('carbon:synchronize', path, filename, error) end
      )
    )
  end
end

function watcher.emit(event, ...)
  for callback in pairs(watcher.events[event] or {}) do
    callback(event, ...)
  end

  for callback in pairs(watcher.events['*'] or {}) do
    callback(event, ...)
  end
end

function watcher.on(event, callback)
  if type(event) == 'table' then
    for _, key in ipairs(event) do
      watcher.on(key, callback)
    end
  elseif event then
    watcher.events[event] = watcher.events[event] or {}
    watcher.events[event][callback] = callback
  end
end

function watcher.off(event, callback)
  if not event then
    watcher.events = {}
  elseif type(event) == 'table' then
    for _, key in ipairs(event) do
      watcher.off(key, callback)
    end
  elseif watcher.events[event] and callback then
    watcher.events[event][callback] = nil
  elseif watcher.events[event] then
    watcher.events[event] = {}
  else
    watcher.events[event] = nil
  end
end

function watcher.has(event, callback)
  return watcher.events[event] and watcher.events[event][callback] and true or false
end

function watcher.registered() return vim.tbl_keys(watcher.listeners) end

-------------------------------------------------------------------------------

local entry = {}

entry.items = {}
entry.__index = entry
entry.__lt = function(a, b)
  if a.is_directory and b.is_directory then
    return string.lower(a.name) < string.lower(b.name)
  elseif a.is_directory then
    return true
  elseif b.is_directory then
    return false
  end

  return string.lower(a.name) < string.lower(b.name)
end

function entry.new(path, parent)
  local raw_path = path == '' and '/' or path
  local clean = string.gsub(raw_path, '/+$', '')
  local lstat = select(2, pcall(vim.uv.fs_lstat, raw_path)) or {}
  local is_exe = lstat.mode == 33261
  local is_dir = lstat.type == 'directory'
  local is_sym = lstat.type == 'link' and 1

  if is_sym then
    local stat = select(2, pcall(vim.uv.fs_stat, raw_path))

    if stat then
      is_exe = lstat.mode == 33261
      is_dir = stat.type == 'directory'
      is_sym = 1
    else
      is_sym = 2
    end
  end

  return setmetatable({
    raw_path = raw_path,
    path = clean,
    name = vim.fn.fnamemodify(clean, ':t'),
    parent = parent,
    is_directory = is_dir,
    is_executable = is_exe,
    is_symlink = is_sym,
  }, entry)
end

function entry.find(path)
  for _, children in pairs(entry.items) do
    for _, child in ipairs(children) do
      if child.path == path then
        return child
      end
    end
  end
end

function entry:synchronize(paths)
  if not self.is_directory then
    return
  end

  paths = paths or {}

  if paths[self.path] then
    paths[self.path] = nil

    local all_paths = {}
    local current_paths = {}
    local previous_paths = {}
    local previous_children = entry.items[self.path] or {}

    self:set_children(nil)

    for _, previous in ipairs(previous_children) do
      all_paths[previous.path] = true
      previous_paths[previous.path] = previous
    end

    for _, current in ipairs(self:children()) do
      all_paths[current.path] = true
      current_paths[current.path] = current
    end

    for path in pairs(all_paths) do
      local current = current_paths[path]
      local previous = previous_paths[path]

      if previous and current then
        if current.is_directory then
          current:synchronize(paths)
        end
      elseif previous then
        previous:terminate()
      end
    end
  elseif self:has_children() then
    for _, child in ipairs(self:children()) do
      if child.is_directory then
        child:synchronize(paths)
      end
    end
  end
end

function entry:terminate()
  watcher.release(self.path)

  if self:has_children() then
    for _, child in ipairs(self:children()) do
      child:terminate()
    end

    self:set_children(nil)
  end

  if self.parent and self.parent:has_children() then
    self.parent:set_children(
      vim.tbl_filter(
        function(sibling) return sibling.path ~= self.path end,
        entry.items[self.parent.path]
      )
    )
  end
end

function entry:children()
  if self.is_directory and not self:has_children() then
    self:set_children(self:get_children())
  end

  return entry.items[self.path] or {}
end

function entry:has_children() return entry.items[self.path] and true or false end

function entry:set_children(children) entry.items[self.path] = children end

function entry:get_children()
  local entries = {}
  local handle = vim.uv.fs_scandir(self.raw_path)

  if type(handle) == 'userdata' then
    local function iterator() return vim.uv.fs_scandir_next(handle) end

    for name in iterator do
      table.insert(entries, entry.new(vim.fs.joinpath(self.path, name), self))
    end

    table.sort(entries)
  end

  return entries
end

function entry:highlight_group()
  if self.is_symlink == 1 then
    return 'CarbonSymlink'
  elseif self.is_symlink == 2 then
    return 'CarbonBrokenSymlink'
  elseif self.is_directory then
    return 'CarbonDir'
  elseif self.is_executable then
    return 'CarbonExe'
  else
    return 'CarbonFile'
  end
end

-------------------------------------------------------------------------------

view.__index = view
view.sidebar = { origin = -1, target = -1 }
view.items = {}
view.resync_paths = {}
view.last_index = 0

local function create_leave(ctx)
  vim.cmd.stopinsert()
  ctx.view:set_path_attr(ctx.target.path, 'compressible', ctx.prev_compressible)
  set_cursor(ctx.target_line.lnum, 1)
  vim.keymap.del('i', '<cr>', { buffer = 0 })
  vim.keymap.del('i', '<esc>', { buffer = 0 })

  vim.api.nvim_clear_autocmds({
    buffer = 0,
    event = 'CursorMovedI',
    group = constants.augroup,
  })

  ctx.view:update()
  ctx.view:render()
end

local function create_confirm(ctx)
  return function()
    local text = vim.trim(string.sub(get_line(vim.fn.line('.')), ctx.edit_col))
    local name = vim.fn.fnamemodify(text, ':t')
    local parent_directory = vim.fs.joinpath(ctx.target.path, vim.fs.dirname(text))

    vim.fn.mkdir(parent_directory, 'p')

    if name ~= '' then
      vim.fn.writefile({}, vim.fs.joinpath(parent_directory, name))
    end

    create_leave(ctx)
    view.resync(vim.fn.fnamemodify(parent_directory, ':h'))
  end
end

local function create_cancel(ctx)
  return function()
    ctx.view:set_path_attr(ctx.target.path, 'open', ctx.prev_open)
    create_leave(ctx)
  end
end

local function create_insert_move(ctx)
  return function()
    local text = ctx.edit_prefix .. vim.trim(string.sub(get_line(vim.fn.line('.')), ctx.edit_col))
    local last_slash_col = vim.fn.strridx(text, '/') + 1

    vim.api.nvim_buf_set_lines(0, ctx.edit_lnum, ctx.edit_lnum + 1, true, { text })
    extmarks_clear(0, { ctx.edit_lnum, 0 }, { ctx.edit_lnum, -1 }, {})
    add_highlight(0, 'CarbonDir', ctx.edit_lnum, 0, last_slash_col)
    add_highlight(0, 'CarbonFile', ctx.edit_lnum, last_slash_col, -1)
    set_cursor(ctx.edit_lnum + 1, math.max(ctx.edit_col, vim.fn.col('.')))
  end
end

function view.get_sorted_items()
  local active_views = {}

  for _, current_view in pairs(view.items) do
    if current_view then
      active_views[#active_views + 1] = current_view
    end
  end

  table.sort(active_views, function(v1, v2) return v1.index < v2.index end)

  return active_views
end

function view.find(path)
  local resolved = vim.fs.normalize(path)

  return vim
    .iter(view.items)
    :find(function(target_view) return target_view.root.path == resolved end)
end

function view.get(path)
  local found_view = view.find(path)

  if found_view then
    return found_view
  end

  view.last_index = view.last_index + 1

  local resolved = vim.fs.normalize(path)
  local instance = setmetatable({
    index = view.last_index,
    initial = resolved,
    states = {},
    show_hidden = false,
    root = entry.new(resolved),
  }, view)

  view.items[instance.index] = instance

  return instance
end

function view.activate(options_param)
  local options = options_param or {}
  local original_window = vim.api.nvim_get_current_win()
  local current_view = (options.path and view.get(options.path))
    or view.current()
    or view.get(vim.uv.cwd())

  current_view:expand_to_path(vim.fn.expand('%'))

  if options.sidebar then
    if vim.api.nvim_win_is_valid(view.sidebar.origin) then
      vim.api.nvim_set_current_win(view.sidebar.origin)
    else
      local split = options.sidebar == 'right' and 'botright' or 'topleft'
      local target_side = options.sidebar == 'right' and 'left' or 'right'

      vim.cmd.split({ mods = { vertical = true, split = split } })

      local origin_id = vim.api.nvim_get_current_win()
      local neighbor = win_neightbors(origin_id, { target_side })[1]
      local target = neighbor and neighbor.target or original_window

      view.sidebar = {
        position = options.sidebar,
        origin = origin_id,
        target = target,
      }
    end

    vim.api.nvim_win_set_width(view.sidebar.origin, Config.sidebar_width)
    vim.api.nvim_win_set_buf(view.sidebar.origin, current_view:buffer())
  else
    vim.api.nvim_win_set_buf(0, current_view:buffer())
  end
  vim.api.nvim_set_option_value('filetype', 'carbon.explorer', { buf = current_view:buffer() })
end

function view.close_sidebar()
  if vim.api.nvim_win_is_valid(view.sidebar.origin) then
    vim.api.nvim_win_close(view.sidebar.origin, true)
  end

  view.sidebar = { origin = -1, target = -1 }
end

function view.handle_sidebar()
  local current_window = vim.api.nvim_get_current_win()

  if current_window == view.sidebar.origin then
    if vim.api.nvim_win_is_valid(view.sidebar.target) then
      vim.api.nvim_set_current_win(view.sidebar.target)
    else
      local split = view.sidebar.position == 'right' and 'topleft' or 'botright'
      local target_side = view.sidebar.position == 'right' and 'left' or 'right'
      local neighbor = win_neightbors(view.sidebar.origin, { target_side })[1]

      if neighbor then
        view.sidebar.target = neighbor.target
        vim.api.nvim_set_current_win(neighbor.target)
      else
        vim.cmd.split({ mods = { vertical = true, split = split } })

        view.sidebar.target = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_width(view.sidebar.origin, Config.sidebar_width)
      end
    end
  end
end

function view.current()
  local bufnr = vim.api.nvim_get_current_buf()
  local ref = select(2, pcall(vim.api.nvim_buf_get_var, bufnr, 'carbon'))

  return ref and view.items[ref.index] or false
end

function view.execute(callback)
  local current_view = view.current()

  if current_view then
    return callback({ cursor = current_view:cursor(), view = current_view })
  end
end

function view.resync(path)
  view.resync_paths[path] = true

  if view.resync_timer and not view.resync_timer:is_closing() then
    view.resync_timer:close()
  end

  view.resync_timer = vim.defer_fn(function()
    for _, current_view in pairs(view.items) do
      if is_directory(current_view.root.path) then
        current_view.root:synchronize(view.resync_paths)
        current_view:update()
        current_view:render()
      else
        current_view:terminate()
      end
    end

    if not view.resync_timer:is_closing() then
      view.resync_timer:close()
    end

    view.resync_timer = nil
    view.resync_paths = {}
  end, 20)
end

function view:expand_to_path(path)
  local resolved = vim.fs.normalize(path)

  if vim.startswith(resolved, self.root.path) then
    local dirs = vim.split(string.sub(resolved, #self.root.path + 2), '/')
    local current = self.root

    for _, dir in ipairs(dirs) do
      current:children()

      current = entry.find(string.format('%s/%s', current.path, dir))

      if current then
        self:set_path_attr(current.path, 'open', true)
      else
        break
      end
    end

    if current and current.path == resolved then
      self.flash = current

      self:update()

      return true
    end

    return false
  end
end

function view:get_path_attr(path, attr)
  local state = self.states[path]
  local value = state and state[attr]

  if attr == 'compressible' and value == nil then
    return true
  end

  return value
end

function view:set_path_attr(path, attr, value)
  if not self.states[path] then
    self.states[path] = {}
  end

  self.states[path][attr] = value

  return value
end

function view:buffers()
  return vim.tbl_filter(function(bufnr)
    local ref = select(2, pcall(vim.api.nvim_buf_get_var, bufnr, 'carbon'))

    return ref and ref.index == self.index
  end, vim.api.nvim_list_bufs())
end

function view:terminate()
  local reopen = #vim.api.nvim_list_wins() == 1

  for _, bufnr in ipairs(self:buffers()) do
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end

  if not is_directory(self.root.path) then
    self.root:terminate()
  end

  if reopen then
    vim.cmd.Carbon()
  end

  view.items[self.index] = nil
end

function view:update() self.cached_lines = nil end

function view:render()
  local cursor
  local lines = {}
  local hls = {}

  for lnum, line_data in ipairs(self:current_lines()) do
    lines[#lines + 1] = line_data.line

    if self.flash and self.flash.path == line_data.entry.path then
      cursor = { lnum = lnum, col = 1 + (line_data.depth + 1) * 2 }
    end

    for _, hl in ipairs(line_data.highlights) do
      hls[#hls + 1] = { hl[1], lnum - 1, hl[2], hl[3] }
    end
  end

  local buf = self:buffer()
  local current_mode = string.lower(vim.api.nvim_get_mode().mode)

  vim.api.nvim_buf_clear_namespace(buf, constants.hl, 0, -1)
  vim.api.nvim_set_option_value('modifiable', true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, true, lines)
  vim.api.nvim_set_option_value('modifiable', false, { buf = buf })

  if not string.find(current_mode, 'i') then
    vim.api.nvim_set_option_value('modifiable', false, { buf = buf })
  end

  for _, hl in ipairs(hls) do
    add_highlight(buf, hl[1], hl[2], hl[3], hl[4])
  end

  if cursor then
    set_cursor(cursor.lnum, cursor.col)

    vim.defer_fn(
      function()
        self:focus_flash(
          500,
          'CarbonFlash',
          { cursor.lnum - 1, cursor.col - 1 },
          { cursor.lnum - 1, -1 }
        )
      end,
      50
    )
  end

  self.flash = nil
end

function view:focus_flash(duration, group, start, finish)
  local buf = self:buffer()

  vim.highlight.range(buf, constants.hl_tmp, group, start, finish, {})

  vim.defer_fn(function()
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_clear_namespace(buf, constants.hl_tmp, 0, -1)
    end
  end, duration)
end

function view:buffer()
  local buffers = self:buffers()

  if buffers[1] then
    return buffers[1]
  end

  local buf = buf_create(self.root.path)
  buf_init_mappings(buf)

  for event, cb in pairs({
    BufHidden = function() self:hide() end,
    BufWinEnter = function() self:show() end,
  }) do
    vim.api.nvim_create_autocmd(event, {
      buffer = buf,
      group = constants.augroup,
      callback = cb,
    })
  end

  vim.api.nvim_buf_set_var(buf, 'carbon', {
    index = self.index,
    path = self.root.path,
  })

  return buf
end

function view:hide() -- luacheck:ignore unused argument self
  vim.opt_local.wrap = vim.opt_global.wrap:get()
  vim.opt_local.spell = vim.opt_global.spell:get()
  vim.opt_local.fillchars = vim.opt_global.fillchars:get()

  view.sidebar = { origin = -1, target = -1 }
end

function view:show()
  vim.opt_local.wrap = false
  vim.opt_local.spell = false
  vim.opt_local.fillchars = { eob = ' ' }

  self:render()
end

function view:up(count)
  local parents = self:parents(count)
  local destination = parents[#parents]

  if destination and self:switch_to_existing_view(destination.path) then
    return true
  end

  for idx, parent_entry in ipairs(parents) do
    self:set_path_attr(self.root.path, 'open', true)
    self:set_root(parent_entry, { rename = idx == #parents })
  end

  return #parents ~= 0
end

function view:reset() return self:cd(self.initial) end

function view:cd(path)
  if path == self.root.path then
    return false
  elseif vim.startswith(self.root.path, path) then
    local new_depth = select(2, string.gsub(path, '/', ''))
    local current_depth = select(2, string.gsub(self.root.path, '/', ''))

    if current_depth - new_depth > 0 then
      return self:up(current_depth - new_depth)
    end
  elseif self:switch_to_existing_view(path) then
    return true
  else
    return self:set_root(entry.find(path) or entry.new(path))
  end
end

function view:down(count)
  local cursor = self:cursor()
  local new_root = cursor.line.path[count or vim.v.count1] or cursor.line.entry

  if not new_root.is_directory then
    new_root = new_root.parent
  end

  if not new_root or new_root.path == self.root.path then
    return false
  end

  if self:switch_to_existing_view(new_root.path) then
    return true
  else
    self:set_path_attr(self.root.path, 'open', true)

    return self:set_root(new_root)
  end
end

function view:set_root(target, opts)
  opts = opts or {}

  if type(target) == 'string' then
    target = entry.new(target)
  end

  if target.path == self.root.path then
    return false
  end

  self.root = target

  if opts.rename ~= false then
    vim.api.nvim_buf_set_name(self:buffer(), self.root.raw_path)
  end

  vim.api.nvim_buf_set_var(self:buffer(), 'carbon', { index = self.index, path = self.root.path })

  watcher.keep(function(path)
    for _, v in ipairs(view.items) do
      if vim.startswith(path, v.root.path) then
        return true
      end
    end
    return false
  end)

  return true
end

function view:current_lines()
  if not self.cached_lines then
    self.cached_lines = self:lines()
  end

  return self.cached_lines
end

function view:entry_children(target)
  if self.show_hidden then
    return target:children()
  else
    return vim.tbl_filter(
      function(child) return not is_excluded(vim.fn.fnamemodify(child.path, ':.')) end,
      target:children()
    )
  end
end

function view:lines(input_target, lines, depth)
  lines = lines or {}
  depth = depth or 0
  local target = input_target or self.root
  local expand_indicator = ' '
  local collapse_indicator = ' '

  if type(Config.indicators) == 'table' then
    expand_indicator = Config.indicators.expand or expand_indicator
    collapse_indicator = Config.indicators.collapse or collapse_indicator
  end

  if not input_target and #lines == 0 then
    lines[#lines + 1] = {
      lnum = 1,
      depth = -1,
      entry = self.root,
      line = self.root.name .. '/',
      highlights = { { 'CarbonDir', 0, -1 } },
      path = {},
    }

    watcher.register(self.root.path)
  end

  for _, child in ipairs(self:entry_children(target)) do
    local tmp = child
    local hls = {}
    local path = {}
    local lnum = 1 + #lines
    local indent = string.rep('  ', depth)
    local is_empty = true
    local indicator = ''
    local path_suffix = ''

    if tmp.is_directory then
      watcher.register(tmp.path)

      is_empty = #self:entry_children(tmp) == 0
      path_suffix = '/'

      if not is_empty and self:get_path_attr(tmp.path, 'open') then
        indicator = collapse_indicator
      elseif not is_empty then
        indicator = expand_indicator
      else
        indent = indent .. '  '
      end
    else
      indent = indent .. '  '
    end

    local full_path = tmp.name .. path_suffix
    local indent_end = #indent
    local indicator_width = #indicator ~= 0 and #indicator + 1 or 0
    local path_start = indent_end + indicator_width
    local dir_path = table.concat(vim.tbl_map(function(parent) return parent.name end, path), '/')

    if path[1] then
      full_path = vim.fs.joinpath(dir_path, full_path)
    end

    if indicator_width ~= 0 and not is_empty then
      hls[#hls + 1] = { 'CarbonIndicator', indent_end, indent_end + indicator_width }
    end

    local entries = { unpack(path) }
    entries[#entries + 1] = tmp

    for _, current_entry in ipairs(entries) do
      local part = current_entry.name .. '/'
      local path_end = path_start + #part
      local highlight_group = 'CarbonFile'

      if current_entry.is_symlink == 1 then
        highlight_group = 'CarbonSymlink'
      elseif current_entry.is_symlink == 2 then
        highlight_group = 'CarbonBrokenSymlink'
      elseif current_entry.is_directory then
        highlight_group = 'CarbonDir'
      elseif current_entry.is_executable then
        highlight_group = 'CarbonExe'
      end

      hls[#hls + 1] = { highlight_group, path_start, path_end }
      path_start = path_end
    end

    local line_prefix = indent

    if indicator_width ~= 0 then
      line_prefix = line_prefix .. indicator .. ' '
    end

    lines[#lines + 1] = {
      lnum = lnum,
      depth = depth,
      entry = tmp,
      line = line_prefix .. full_path,
      highlights = hls,
      path = path,
    }

    if tmp.is_directory and self:get_path_attr(tmp.path, 'open') then
      self:lines(tmp, lines, depth + 1)
    end
  end

  return lines
end

function view:cursor(opts)
  local options = opts or {}
  local lines = self:current_lines()
  local line = lines[vim.fn.line('.')]
  local target = line.entry
  local target_line

  if options.target_directory_only and not target.is_directory then
    target = target.parent
  end

  target = line.path[vim.v.count] or target
  target_line = vim.iter(lines):find(function(current)
    if current.entry.path == target.path then
      return true
    end

    return vim.iter(current.path):find(function(parent)
      if parent.path == target.path then
        return true
      end
    end)
  end)

  return { line = line, target = target, target_line = target_line }
end

function view:create()
  local ctx = self:cursor({ target_directory_only = true })

  ctx.view = self
  ctx.compact = ctx.target.is_directory and #ctx.target:children() == 0
  ctx.prev_open = self:get_path_attr(ctx.target.path, 'open')
  ctx.prev_compressible = self:get_path_attr(ctx.target.path, 'compressible')

  self:set_path_attr(ctx.target.path, 'open', true)
  self:set_path_attr(ctx.target.path, 'compressible', false)

  if ctx.compact then
    ctx.edit_prefix = ctx.line.line
    ctx.edit_lnum = ctx.line.lnum - 1
    ctx.edit_col = #ctx.edit_prefix + 1
    ctx.init_end_lnum = ctx.edit_lnum + 1
  else
    ctx.edit_prefix = string.rep('  ', ctx.target_line.depth + 2)
    ctx.edit_lnum = ctx.target_line.lnum + #self:lines(ctx.target)
    ctx.edit_col = #ctx.edit_prefix + 1
    ctx.init_end_lnum = ctx.edit_lnum
  end

  self:update()
  self:render()

  vim.api.nvim_create_autocmd('CursorMovedI', {
    buffer = 0,
    group = constants.augroup,
    callback = create_insert_move(ctx),
  })

  vim.keymap.set('i', '<cr>', create_confirm(ctx), { buffer = 0 })
  vim.keymap.set('i', '<esc>', create_cancel(ctx), { buffer = 0 })
  vim.cmd.startinsert({ bang = true })
  vim.api.nvim_set_option_value('modifiable', true, { buf = 0 })
  vim.api.nvim_buf_set_lines(0, ctx.edit_lnum, ctx.init_end_lnum, true, { ctx.edit_prefix })
  set_cursor(ctx.edit_lnum + 1, ctx.edit_col)
end

function view:delete()
  local cursor = self:cursor()
  local targets = vim.list_extend({ unpack(cursor.line.path) }, { cursor.line.entry })

  local lnum_idx = cursor.line.lnum - 1
  local count = vim.v.count == 0 and #targets or vim.v.count1
  local path_idx = math.min(count, #targets)
  local target = targets[path_idx]
  local highlight = {
    'CarbonFile',
    cursor.line.depth * 2 + 2,
    lnum_idx,
  }

  if targets[path_idx].path == self.root.path then
    return
  end

  if target.is_directory then
    highlight[1] = 'CarbonDir'
  end

  for idx = 1, path_idx - 1 do
    highlight[2] = highlight[2] + #cursor.line.path[idx].name + 1
  end

  extmarks_clear(0, { lnum_idx, highlight[2] }, { lnum_idx, -1 }, {})
  add_highlight(0, 'CarbonDanger', lnum_idx, highlight[2], -1)

  vim.cmd.redraw()

  vim.ui.input({ prompt = 'Confirm deletion of specified path [Y/n]? ' }, function(input)
    if input ~= '' and vim.fn.tolower(input) ~= 'y' then
      extmarks_clear(0, { lnum_idx, 0 }, { lnum_idx, -1 }, {})
      for _, lhl in ipairs(cursor.line.highlights) do
        add_highlight(0, lhl[1], lnum_idx, lhl[2], lhl[3])
      end
      self:render()
      return
    end

    local result = vim.fn.delete(target.path, target.is_directory and 'rf' or '')
    if result == -1 then
      vim.notify(
        ('Failed to delete: %q'):format(vim.fn.fnamemodify(target.path, ':.')),
        vim.log.levels.ERROR
      )
      return
    end

    view.resync(vim.fn.fnamemodify(target.path, ':h'))
  end)
end

function view:move()
  local ctx = self:cursor()
  local target_line = ctx.target_line
  local targets = vim.list_extend({ unpack(target_line.path) }, { target_line.entry })
  local target_names = vim.tbl_map(function(part) return part.name end, targets)

  if ctx.target.path == self.root.path then
    return
  end

  local path_start = target_line.depth * 2 + 2
  local lnum_idx = target_line.lnum - 1
  local target_idx = tbl_key(targets, ctx.target)
  local clamped_names = { unpack(target_names, 1, target_idx - 1) }
  local start_hl = path_start + #table.concat(clamped_names, '/')

  if target_idx > 1 then
    start_hl = start_hl + 1
  end

  extmarks_clear(0, { lnum_idx, start_hl }, { lnum_idx, -1 }, {})
  add_highlight(0, 'CarbonPending', lnum_idx, start_hl, -1)
  vim.cmd.redraw({ bang = true })

  vim.ui.input({
    prompt = 'destination: ',
    default = ctx.target.path,
    complete = 'file',
  }, function(input)
    if vim.fn.empty(input) == 1 then
      self:render()
      return
    end

    if vim.uv.fs_stat(input) then
      self:render()
      vim.notify(
        ('Failed to move: %q => %q (destination exists)'):format(
          vim.fn.fnamemodify(ctx.target.path, ':.'),
          vim.fn.fnamemodify(input, ':.')
        ),
        vim.log.levels.ERROR
      )
      return
    end

    local dirname = vim.fs.dirname(input)
    local tmp_path = ctx.target.path

    if vim.startswith(input, tmp_path) then
      tmp_path = vim.fn.tempname()
      vim.uv.fs_rename(ctx.target.path, tmp_path)
    end

    vim.fn.mkdir(dirname, 'p')
    vim.uv.fs_rename(tmp_path, input)
    view.resync(vim.fs.dirname(ctx.target.path))
  end)
end

function view:parents(count)
  local path = self.root.path
  local parents = {}

  if path ~= '' then
    for _ = count or vim.v.count1, 1, -1 do
      path = vim.fs.dirname(path)
      parents[#parents + 1] = entry.new(path)

      if path == '/' then
        break
      end
    end
  end

  return parents
end

function view:switch_to_existing_view(path)
  local destination_view = view.find(path)

  if destination_view then
    vim.api.nvim_win_set_buf(0, destination_view:buffer())

    if self.root.path == vim.uv.cwd() then
      vim.api.nvim_set_current_dir(destination_view.root.path)
    end

    return true
  end
end

-------------------------------------------------------------------------------

local M = {}

---@param opts explorer.Opts? When omitted or `nil`, retrieve the current
---       configuration. Otherwise, a configuration table (see |pack.Opts|).
---@return explorer.Opts? : Current pack config if {opts} is omitted.
function M.config(opts)
  vim.validate('opts', opts, 'table', true)

  if not opts then
    return vim.deepcopy(Config, true)
  end

  Config = vim.tbl_extend('force', Config, opts)
end

local function explore_sidebar(opts)
  opts = opts or {}
  local sidebar = opts.sidebar or 'left'
  local path = opts.fargs and opts.fargs[1] or vim.uv.cwd() --[[@as string]]
  path = vim.fs.normalize(path)

  view.activate({ path = path, reveal = opts.bang, sidebar = sidebar })
end

do
  watcher.on('carbon:synchronize', function(_, path) view.resync(path) end)

  vim.api.nvim_create_user_command('Carbon', function(opts)
    opts = opts or {}

    local path = opts.fargs and opts.fargs[1] or vim.uv.cwd() --[[@as string]]
    path = vim.fs.normalize(path)

    view.activate({ path = path, reveal = opts.bang })
  end, { bang = true, nargs = '?', complete = 'dir' })

  vim.api.nvim_create_user_command('Lcarbon', function(opts)
    if view.sidebar.position ~= 'left' then
      view.close_sidebar()
    end
    explore_sidebar(vim.tbl_extend('force', opts or {}, { sidebar = 'left' }))
  end, { bang = true, nargs = '?', complete = 'dir' })

  vim.api.nvim_create_user_command('Rcarbon', function(opts)
    if view.sidebar.position ~= 'right' then
      view.close_sidebar()
    end
    explore_sidebar(vim.tbl_extend('force', opts or {}, { sidebar = 'right' }))
  end, { bang = true, nargs = '?', complete = 'dir' })

  vim.api.nvim_create_user_command('ToggleSidebarCarbon', function(opts)
    local current_win = vim.api.nvim_get_current_win()

    if vim.api.nvim_win_is_valid(view.sidebar.origin) then
      vim.api.nvim_win_close(view.sidebar.origin, true)
    else
      local explore_options = vim.tbl_extend('force', opts or {}, { sidebar = 'left' })

      explore_sidebar(explore_options)

      if not Config.sidebar_toggle_focus then
        vim.api.nvim_set_current_win(current_win)
      end
    end
  end, { bang = true, nargs = '?', complete = 'dir' })

  vim.api.nvim_create_autocmd('BufWinEnter', {
    pattern = '*',
    group = constants.augroup,
    callback = function(args)
      if vim.bo.filetype == 'carbon.explorer' then
        return
      end

      if args and args.file and is_directory(args.file) then
        view.activate({ path = args.file })
        view.execute(function(ctx) ctx.view:show() end)
      end
    end,
  })

  vim.api.nvim_create_autocmd('DirChanged', {
    pattern = 'global',
    group = constants.augroup,
    callback = function(args)
      view.execute(function(ctx)
        local destination = args and args.file or vim.v.event.cwd

        if ctx.view:cd(destination) then
          ctx.view:update()
          ctx.view:render()
          set_cursor(1, 1)
        end
      end)
    end,
  })

  vim.api.nvim_create_autocmd('WinResized', {
    pattern = '*',
    group = constants.augroup,
    callback = function()
      if not vim.api.nvim_win_is_valid(view.sidebar.origin) then
        return
      end

      local window_width = vim.api.nvim_win_get_width(view.sidebar.origin)

      if window_width ~= Config.sidebar_width then
        vim.api.nvim_win_set_width(view.sidebar.origin, Config.sidebar_width)
      end
    end,
  })

  vim.api.nvim_create_autocmd('SessionLoadPost', {
    pattern = '*',
    group = constants.augroup,
    callback = function(args)
      if not is_directory(args.file) then
        return
      end

      local window_id = buf_winid(args.buf)
      local window_width = vim.api.nvim_win_get_width(window_id)
      local is_sidebar = window_width == Config.sidebar_width

      view.activate({ path = args.file })
      view.execute(function(ctx) ctx.view:show() end)

      if is_sidebar then
        local neighbor = vim
          .iter(win_neightbors(window_id, { 'left', 'right' }))
          :find(function(neighbor) return neighbor.target end)

        if neighbor then
          view.sidebar = neighbor
        end
      end
    end,
  })

  for group, val in pairs({
    CarbonDir = { link = 'Directory' },
    CarbonFile = { link = 'Text' },
    CarbonExe = { link = '@function.builtin' },
    CarbonSymlink = { link = '@include' },
    CarbonBrokenSymlink = { link = 'DiagnosticError' },
    CarbonIndicator = { fg = 'Gray', ctermfg = 'DarkGray', bold = true },
    CarbonDanger = { link = 'Error' },
    CarbonPending = { link = 'Search' },
    CarbonFlash = { link = 'Visual' },
  }) do
    val.default = true
    vim.api.nvim_set_hl(0, group, val)
  end
end
