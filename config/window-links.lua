-- User-created associations for the overview, not a replacement AeroSpace tree.
local L = {pairs = hs.settings.get('leanmac.linkedPairs.v1') or {}}
if type(L.pairs) ~= 'table' then L.pairs = {} end
local function save() hs.settings.set('leanmac.linkedPairs.v1', L.pairs) end
local function samePairs(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do
    local x, y = a[i], b[i]
    if type(x) ~= 'table' or type(y) ~= 'table' or type(x.a) ~= 'table' or type(y.a) ~= 'table'
      or type(x.b) ~= 'table' or type(y.b) ~= 'table'
      or x.a.id ~= y.a.id or x.a.pid ~= y.a.pid or x.b.id ~= y.b.id or x.b.pid ~= y.b.pid then
      return false
    end
  end
  return true
end
local function store(pairs)
  local changed = not samePairs(pairs, L.pairs)
  L.pairs = pairs
  if changed then save() end
end
function L.unlink(id)
  local keep = {}
  for _, pair in ipairs(L.pairs) do
    if type(pair)=='table' and type(pair.a)=='table' and type(pair.b)=='table' and pair.a.id~=id and pair.b.id~=id then keep[#keep+1]=pair end
  end
  store(keep)
end
function L.link(a,b)
  L.unlink(a.id); L.unlink(b.id)
  L.pairs[#L.pairs+1]={a={id=a.id,pid=a.pid},b={id=b.id,pid=b.pid}}
  save()
end
function L.reconcile(rows)
  local byID, workspaces = {}, {}
  for _, row in ipairs(rows) do
    if type(row)=='table' and row.id~=nil and row.workspace~=nil then
      byID[row.id]=row
      workspaces[row.workspace]=workspaces[row.workspace] or {}
      if row.layout~='floating' then table.insert(workspaces[row.workspace],row) end
    end
  end
  local keep, used = {}, {}
  for _, pair in ipairs(L.pairs) do
    local a=type(pair)=='table' and type(pair.a)=='table' and byID[pair.a.id]
    local b=type(pair)=='table' and type(pair.b)=='table' and byID[pair.b.id]
    if a and b and a.id~=b.id and a.pid==pair.a.pid and b.pid==pair.b.pid
      and a.workspace==b.workspace and a.layout==b.layout and (a.layout=='h_tiles' or a.layout=='h_accordion')
      and not used[a.id] and not used[b.id] then
      keep[#keep+1]=pair; used[a.id]=true; used[b.id]=true
    end
  end
  -- An entire workspace with exactly two horizontal tiled leaves is unambiguous.
  -- Do not guess arbitrary nested groups from matching parent-layout strings.
  for _, group in pairs(workspaces) do
    if #group==2 then
      local a,b=group[1],group[2]
      if a.layout=='h_tiles' and b.layout=='h_tiles' and a.root=='h_tiles' and b.root=='h_tiles'
        and not used[a.id] and not used[b.id] then
        keep[#keep+1]={a={id=a.id,pid=a.pid},b={id=b.id,pid=b.pid}}
        used[a.id]=true; used[b.id]=true
      end
    end
  end
  store(keep)
  return keep
end
function L.containing(id)
  for _, pair in ipairs(L.pairs) do if pair.a.id==id or pair.b.id==id then return pair end end
end
return L
