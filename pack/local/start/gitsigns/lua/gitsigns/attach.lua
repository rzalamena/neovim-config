local async = require('gitsigns.async')
local git = require('gitsigns.git')

local manager = require('gitsigns.manager')

local log = require('gitsigns.debug.log')
local dprintf = log.dprintf
local dprint = log.dprint

local gs_cache = require('gitsigns.cache')
local cache = gs_cache.cache
local Status = require('gitsigns.status')

local config = require('gitsigns.config').config

local util = require('gitsigns.util')

local throttle_by_id = require('gitsigns.debounce').throttle_by_id

local api = vim.api
local uv = vim.loop

local M = {}

--- @param name string
--- @return string? buffer
--- @return string? commit
local function parse_fugitive_uri(name)
  if vim.fn.exists('*FugitiveReal') == 0 then
    dprint('Fugitive not installed')
    return
  end

  ---@type string
  local path = vim.fn.FugitiveReal(name)
  ---@type string?
  local commit = vim.fn.FugitiveParse(name)[1]:match('([^:]+):.*')
  if commit == '0' then
    -- '0' means the index so clear commit so we attach normally
    commit = nil
  end
  return path, commit
end

--- @param name string
--- @return string buffer
--- @return string? commit
local function parse_gitsigns_uri(name)
  -- TODO(lewis6991): Support submodules
  --- @type any, any, string?, string?, string
  local _, _, root_path, commit, rel_path = name:find([[^gitsigns://(.*)/%.git/(.*):(.*)]])
  commit = util.norm_base(commit)
  if root_path then
    name = root_path .. '/' .. rel_path
  end
  return name, commit
end

--- @param bufnr integer
--- @return string buffer
--- @return string? commit
--- @return boolean? force_attach
local function get_buf_path(bufnr)
  local file = uv.fs_realpath(api.nvim_buf_get_name(bufnr))
    or api.nvim_buf_call(bufnr, function()
      return vim.fn.expand('%:p')
    end)

  if vim.startswith(file, 'fugitive://') then
    local path, commit = parse_fugitive_uri(file)
    dprintf("Fugitive buffer for file '%s' from path '%s'", path, file)
    if path then
      local realpath = uv.fs_realpath(path)
      if realpath then
        return realpath, commit, true
      end
    end
  end

  if vim.startswith(file, 'gitsigns://') then
    local path, commit = parse_gitsigns_uri(file)
    dprintf("Gitsigns buffer for file '%s' from path '%s' on commit '%s'", path, file, commit)
    local realpath = uv.fs_realpath(path)
    if realpath then
      return realpath, commit, true
    end
  end

  return file
end

local function on_lines(_, bufnr, _, first, last_orig, last_new, byte_count)
  if first == last_orig and last_orig == last_new and byte_count == 0 then
    -- on_lines can be called twice for undo events; ignore the second
    -- call which indicates no changes.
    return
  end
  return manager.on_lines(bufnr, first, last_orig, last_new)
end

--- @param _ 'reload'
--- @param bufnr integer
local function on_reload(_, bufnr)
  local __FUNC__ = 'on_reload'
  cache[bufnr]:invalidate()
  dprint('Reload')
  manager.update_debounced(bufnr)
end

--- @param _ 'detach'
--- @param bufnr integer
local function on_detach(_, bufnr)
  api.nvim_clear_autocmds({ group = 'gitsigns', buffer = bufnr })
  M.detach(bufnr, true)
end

--- @param bufnr integer
--- @return string?
--- @return string?
local function on_attach_pre(bufnr)
  --- @type string?, string?
  local gitdir, toplevel
  if config._on_attach_pre then
    --- @type {gitdir: string?, toplevel: string?}
    local res = async.wait(2, config._on_attach_pre, bufnr)
    dprintf('ran on_attach_pre with result %s', vim.inspect(res))
    if type(res) == 'table' then
      if type(res.gitdir) == 'string' then
        gitdir = res.gitdir
      end
      if type(res.toplevel) == 'string' then
        toplevel = res.toplevel
      end
    end
  end
  return gitdir, toplevel
end

--- @param _bufnr integer
--- @param file string
--- @param revision string?
--- @param encoding string
--- @return Gitsigns.GitObj?
local function try_worktrees(_bufnr, file, revision, encoding)
  if not config.worktrees then
    return
  end

  for _, wt in ipairs(config.worktrees) do
    local git_obj = git.Obj.new(file, revision, encoding, wt.gitdir, wt.toplevel)
    if git_obj and git_obj.object_name then
      dprintf('Using worktree %s', vim.inspect(wt))
      return git_obj
    end
  end
end

local setup = util.once(function()
  manager.setup()

  api.nvim_create_autocmd('OptionSet', {
    group = 'gitsigns',
    pattern = { 'fileformat', 'bomb', 'eol' },
    callback = function()
      local buf = vim.api.nvim_get_current_buf()
      local bcache = cache[buf]
      if not bcache then
        return
      end
      bcache:invalidate(true)
      manager.update(buf)
    end,
  })

  require('gitsigns.current_line_blame').setup()

  api.nvim_create_autocmd('VimLeavePre', {
    group = 'gitsigns',
    callback = M.detach_all,
  })
end)

--- @class Gitsigns.GitContext
--- @field file string
--- @field toplevel? string
--- @field gitdir? string
--- @field base? string

--- @param bufnr integer
--- @return Gitsigns.GitContext? ctx
--- @return string? err
local function get_buf_context(bufnr)
  if api.nvim_buf_line_count(bufnr) > config.max_file_length then
    return nil, 'Exceeds max_file_length'
  end

  local file, commit, force_attach = get_buf_path(bufnr)

  if vim.bo[bufnr].buftype ~= '' and not force_attach then
    return nil, 'Non-normal buffer'
  end

  local file_dir = util.dirname(file)

  if not file_dir or not util.path_exists(file_dir) then
    return nil, 'Not a path'
  end

  local gitdir, toplevel = on_attach_pre(bufnr)

  return {
    file = file,
    gitdir = gitdir,
    toplevel = toplevel,
    -- Commit buffers have there base set back one revision with '^'
    -- Stage buffers always compare against the common ancestor (':1')
    -- :0: index
    -- :1: common ancestor
    -- :2: target commit (HEAD)
    -- :3: commit which is being merged
    base = commit and (commit:match('^:[1-3]') and ':1' or commit .. '^') or nil,
  }
end

--- Ensure attaches cannot be interleaved for the same buffer.
--- Since attaches are asynchronous we need to make sure an attach isn't
--- performed whilst another one is in progress.
--- @param cbuf integer
--- @param ctx? Gitsigns.GitContext
--- @param aucmd? string
local attach_throttled = throttle_by_id(function(cbuf, ctx, aucmd)
  local __FUNC__ = 'attach'
  local passed_ctx = ctx ~= nil

  setup()

  if cache[cbuf] then
    dprint('Already attached')
    return
  end

  if aucmd then
    dprintf('Attaching (trigger=%s)', aucmd)
  else
    dprint('Attaching')
  end

  if not api.nvim_buf_is_loaded(cbuf) then
    dprint('Non-loaded buffer')
    return
  end

  if not ctx then
    local err
    ctx, err = get_buf_context(cbuf)
    if err then
      dprint(err)
      return
    end
    assert(ctx)
  end

  local encoding = vim.bo[cbuf].fileencoding
  if encoding == '' then
    encoding = 'utf-8'
  end

  local file = ctx.file
  if not vim.startswith(file, '/') and ctx.toplevel then
    file = ctx.toplevel .. util.path_sep .. file
  end

  local revision = ctx.base or config.base
  local git_obj = git.Obj.new(file, revision, encoding, ctx.gitdir, ctx.toplevel)

  if not git_obj and not passed_ctx then
    git_obj = try_worktrees(cbuf, file, revision, encoding)
    async.scheduler()
    if not api.nvim_buf_is_valid(cbuf) then
      return
    end
  end

  if not git_obj then
    dprint('Empty git obj')
    return
  end

  async.scheduler()
  if not api.nvim_buf_is_valid(cbuf) then
    return
  end

  Status:update(cbuf, {
    head = git_obj.repo.abbrev_head,
    root = git_obj.repo.toplevel,
    gitdir = git_obj.repo.gitdir,
  })

  if not passed_ctx and (not util.path_exists(file) or uv.fs_stat(file).type == 'directory') then
    dprint('Not a file')
    return
  end

  if not git_obj.relpath then
    dprint('Cannot resolve file in repo')
    return
  end

  if not config.attach_to_untracked and git_obj.object_name == nil then
    dprint('File is untracked')
    return
  end

  -- On windows os.tmpname() crashes in callback threads so initialise this
  -- variable on the main thread.
  async.scheduler()
  if not api.nvim_buf_is_valid(cbuf) then
    return
  end

  if config.on_attach and config.on_attach(cbuf) == false then
    dprint('User on_attach() returned false')
    return
  end

  cache[cbuf] = gs_cache.new({
    bufnr = cbuf,
    file = file,
    git_obj = git_obj,
  })

  if config.watch_gitdir.enable then
    local watcher = require('gitsigns.watcher')
    cache[cbuf].gitdir_watcher = watcher.watch_gitdir(cbuf, git_obj.repo.gitdir)
  end

  if not api.nvim_buf_is_loaded(cbuf) then
    dprint('Un-loaded buffer')
    return
  end

  -- Make sure to attach before the first update (which is async) so we pick up
  -- changes from BufReadCmd.
  api.nvim_buf_attach(cbuf, false, {
    on_lines = on_lines,
    on_reload = on_reload,
    on_detach = on_detach,
  })

  api.nvim_create_autocmd('BufWrite', {
    group = 'gitsigns',
    buffer = cbuf,
    callback = function()
      manager.update_debounced(cbuf)
    end,
  })

  -- Initial update
  manager.update(cbuf)
end)

--- Detach Gitsigns from all buffers it is attached to.
function M.detach_all()
  for k, _ in pairs(cache) do
    M.detach(k)
  end
end

--- Detach Gitsigns from the buffer {bufnr}. If {bufnr} is not
--- provided then the current buffer is used.
---
--- @param bufnr integer Buffer number
--- @param _keep_signs? boolean
function M.detach(bufnr, _keep_signs)
  -- When this is called interactively (with no arguments) we want to remove all
  -- the signs, however if called via a detach event (due to nvim_buf_attach)
  -- then we don't want to clear the signs in case the buffer is just being
  -- updated due to the file externally changing. When this happens a detach and
  -- attach event happen in sequence and so we keep the old signs to stop the
  -- sign column width moving about between updates.
  bufnr = bufnr or api.nvim_get_current_buf()
  dprint('Detached')
  local bcache = cache[bufnr]
  if not bcache then
    dprint('Cache was nil')
    return
  end

  manager.detach(bufnr, _keep_signs)

  -- Clear status variables
  Status:clear(bufnr)

  gs_cache.destroy(bufnr)
end

--- Attach Gitsigns to the buffer.
---
--- Attributes: ~
---     {async}
---
--- @param bufnr integer Buffer number
--- @param ctx Gitsigns.GitContext|nil
---     Git context data that may optionally be used to attach to any
---     buffer that represents a real git object.
---     • {file}: (string)
---       Path to the file represented by the buffer, relative to the
---       top-level.
---     • {toplevel}: (string?)
---       Path to the top-level of the parent git repository.
---     • {gitdir}: (string?)
---       Path to the git directory of the parent git repository
---       (typically the ".git/" directory).
---     • {commit}: (string?)
---       The git revision that the file belongs to.
---     • {base}: (string?)
---       The git revision that the file should be compared to.
--- @param _trigger? string
M.attach = async.create(3, function(bufnr, ctx, _trigger)
  attach_throttled(bufnr or api.nvim_get_current_buf(), ctx, _trigger)
end)

return M
