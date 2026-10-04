-- MX Master 4 extras arrive as F-keys from Logi Options+ (not raw HID).
-- Gesture left/right = F18/F19 (AeroSpace workspaces). Back = F17 (picker).
local M = {}
local function picker()
  local P = package.loaded['window-picker'] or (leanmac and leanmac.picker)
  if P and P.start then P.start(false, false) end
end
M.picker = hs.hotkey.bind({}, 'f17', picker)
return M
