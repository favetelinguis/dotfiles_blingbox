local wezterm = require 'wezterm'
local mux = wezterm.mux
local act = wezterm.action

wezterm.on('gui-startup', function()
  local tab, pane, window = mux.spawn_window({})
  window:gui_window():maximize()
end)

local config = wezterm.config_builder()

-- Had issues where mouse cursor wher not shown
-- gsettings get org.gnome.desktop.interface cursor-size -> 32
-- gsettings get org.gnome.desktop.interface cursor-theme -> Adwaita
-- and make sure the theme is avaliaable in the distrobox container
-- /usr/share/icons/Adwaita
config.xcursor_theme = "Adwaita"
config.xcursor_size = 24

config.window_decorations = "RESIZE"
config.hide_tab_bar_if_only_one_tab = true

config.color_scheme = 'Catppuccin Mocha'
-- Default font is Jetbrains Mono Nerd
config.font_size = 12
config.line_height = 1.2

-- TODO: dissable all default bindings 
-- use CTRL hjkl for moving windows and CTRL HJKL for splitting
-- Other keys are prefixed with CTRL ALT 
-- CTRL L debug use in rebind and 
-- command pallet CRTL P also use
-- My project switcher under ALT CTRL p
config.keys = {

  { -- TODO CommandPallete is much nicer, can I use that GUI insted for project switcher?
    mods = "ALT",
    key = "y",
    action = wezterm.action_callback(function(window, pane)
      -- Here you can dynamically construct a longer list if needed
      local home = wezterm.home_dir
      local success, stdout, stderr = wezterm.run_child_process { 'fd','--no-ignore-vcs', '--hidden', '-t', 'f', '--max-depth', '2', '.wezp:', home .. '/projects' }

      local workspaces = {}
      for i, v in ipairs(wezterm.split_by_newlines(stdout)) do
        local parts = {}
        for part in string.gmatch(v, "([^/]+)") do
          table.insert(parts, part)
        end
        table.insert(workspaces, { id = v, label = "-" .. parts[5] .. parts[6] })
      end
      window:perform_action(
        act.InputSelector({
          action = wezterm.action_callback(function(inner_window, inner_pane, id, label)
            if not id and not label then
              wezterm.log_info("cancelled")
            else
              -- last part is only the file name
              local parts = {}
              for part in string.gmatch(label, "([^:]+)") do
                table.insert(parts, part)
              end
              -- path parts
              local path_parts = {}
              for path_part in string.gmatch(id, "([^/]+)") do
                table.insert(path_parts, path_part)
              end
              wezterm.log_info("id = " .. id)
              wezterm.log_info("label = " .. label)
              inner_window:perform_action(
                act.SwitchToWorkspace({
                  name = label,
                  spawn = {
                    label = "Workspace: " .. label,
                    cwd = "/" .. path_parts[1] .. "/" .. path_parts[2] .. "/" .. path_parts[3] .. "/" .. path_parts[4] .. "/" .. path_parts[5],
                    domain = { DomainName = "distrobox:" .. parts[2] },
                  },
                }),
                inner_pane
              )
            end
          end),
          title = "Choose Workspace",
          choices = workspaces,
          fuzzy = true,
          fuzzy_description = "Find and/or make a workspace: ",
        }),
        pane
      )
    end),
  },
  {
    key = 'p',
    mods = 'ALT',
    action = wezterm.action.ShowLauncherArgs { flags = 'FUZZY|TABS' },
  },
  {
    key = 'p',
    mods = 'CTRL',
    action = wezterm.action.ShowLauncherArgs { flags = 'FUZZY|WORKSPACES' },
  },
  { key = 'l', mods = 'ALT', action = wezterm.action.ShowLauncher },
  {
    key = 'P',
    mods = 'CTRL',
    action = wezterm.action.ActivateCommandPalette,
  },
}

-- Function to split a string by a given delimiter
function split(inputstr, sep)
  if sep == nil then
    sep = "%s"
  end
  local t = {}
  for str in string.gmatch(inputstr, "([^" .. sep .. "]+)") do
    table.insert(t, str)
  end
  return t
end

-- Function to trim leading and trailing whitespace from a string
function trim(s)
  return (s:gsub("^%s*(.-)%s*$", "%1"))
end

-- Function to extract the NAME column as a table of strings
function extractNameColumn(inputstr)
  local lines = split(inputstr, "\n")
  local names = {}
  local isHeader = true

  for _, line in ipairs(lines) do
    -- Skip the header line
    if isHeader then
      isHeader = false
    else
      local columns = split(line, "|")
      -- Remove leading and trailing whitespace from each column
      for i = 1, #columns do
        columns[i] = trim(columns[i])
      end
      -- Add the second column (NAME) to the names table
      table.insert(names, columns[2])
    end
  end

  return names
end

function docker_list()
  local docker_list = {}
  local success, stdout, stderr = wezterm.run_child_process {
    "distrobox",
    "list",
  }
  for id, name in ipairs(extractNameColumn(stdout)) do
    if id and name then
      docker_list[id] = name
    end
  end
  return docker_list
end

function make_docker_label_func(name1)
  return function(name)
    return wezterm.format {
      { Foreground = { AnsiColor = 'Green' } },
      { Text = 'distrobox named ' .. name },
    }
  end
end

function make_docker_fixup_func(name)
  return function(cmd)
    cmd.args = cmd.args or { '/bin/bash' }
    local wrapped = {
      'distrobox',
      'enter',
      '-n',
      name,
    }
    -- I have to manually set env vars to get spawned containers to have the same env
    -- it is still unclear what env vars I have to propagate,
    -- the COLORTERM I know i need else helix will not support truecolor,
    -- the future will tell what else I need.
    table.insert(wrapped, "--additional-flags")
    -- local flags = ""
    -- for k, v in pairs(cmd.set_environment_variables) do
    --   flags = flags .. " --env " .. k .. "=" .. v
    -- end
    -- table.insert(wrapped, flags)
    table.insert(wrapped, "--env COLORTERM=truecolor")

    table.insert(wrapped, '-e')
    for _, arg in ipairs(cmd.args) do
      table.insert(wrapped, arg)
    end

    cmd.args = wrapped
    return cmd
  end
end

function compute_exec_domains()
  local exec_domains = {}
  for id, name in pairs(docker_list()) do
    table.insert(
      exec_domains,
      wezterm.exec_domain(
        'distrobox:' .. name,
        make_docker_fixup_func(name),
        make_docker_label_func(name)
      )
    )
  end
  return exec_domains
end

config.exec_domains = compute_exec_domains()

return config
