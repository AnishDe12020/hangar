-- One compiled settings snapshot for every Hammerspoon shortcut owner.
-- The installer validates source TOML and writes hangar-settings.lua atomically.
local C = require('hangar-settings')
function C.bind(action, callback)
  local key = assert(C.hotkeys[action], 'Missing Hangar action: ' .. action)
  local binding = hs.hotkey.bind(key.mods, key.key, callback)
  assert(binding and binding.enabled, 'Could not register Hangar shortcut: ' .. action)
  return binding
end
function C.label(action)
  local key = assert(C.hotkeys[action], 'Missing Hangar action: ' .. action)
  local glyphs, parts = {ctrl='⌃', alt='⌥', cmd='⌘', shift='⇧'}, {}
  for _, modifier in ipairs(key.mods) do parts[#parts+1] = glyphs[modifier] end
  parts[#parts+1] = key.key:upper()
  return table.concat(parts)
end
return C
