local ViewportMetrics = {}
local cached
local lastKey
local generation = 0

local function finite(value)
  return type(value) == "number" and value == value
    and value > -math.huge and value < math.huge
end

local function number(value, fallback)
  return finite(value) and value or fallback
end

local function clamp(value, low, high)
  return math.max(low, math.min(value, high))
end

local function decodeJSON(source)
  if type(source) ~= "string" then return nil end
  local index, length = 1, #source
  local parseValue

  local function skipSpace()
    while index <= length and source:sub(index, index):match("%s") do
      index = index + 1
    end
  end

  local function parseString()
    if source:sub(index, index) ~= '"' then return nil end
    index = index + 1
    local result = {}
    while index <= length do
      local char = source:sub(index, index)
      index = index + 1
      if char == '"' then return table.concat(result) end
      if char == "\\" then
        local escaped = source:sub(index, index)
        index = index + 1
        if escaped == "n" then
          result[#result + 1] = "\n"
        elseif escaped == "r" then
          result[#result + 1] = "\r"
        elseif escaped == "t" then
          result[#result + 1] = "\t"
        elseif escaped == "b" then
          result[#result + 1] = "\b"
        elseif escaped == "f" then
          result[#result + 1] = "\f"
        elseif escaped == "u" then
          index = math.min(length + 1, index + 4)
          result[#result + 1] = "?"
        else
          result[#result + 1] = escaped
        end
      else
        result[#result + 1] = char
      end
    end
    return nil
  end

  local function parseNumber()
    local start = index
    while index <= length and source:sub(index, index):match("[%d%+%-%e%E%.]") do
      index = index + 1
    end
    return tonumber(source:sub(start, index - 1))
  end

  local function parseArray()
    index = index + 1
    local result = {}
    skipSpace()
    if source:sub(index, index) == "]" then
      index = index + 1
      return result
    end
    while index <= length do
      local value = parseValue()
      if value == nil then return nil end
      result[#result + 1] = value
      skipSpace()
      local char = source:sub(index, index)
      if char == "]" then
        index = index + 1
        return result
      end
      if char ~= "," then return nil end
      index = index + 1
      skipSpace()
    end
    return nil
  end

  local function parseObject()
    index = index + 1
    local result = {}
    skipSpace()
    if source:sub(index, index) == "}" then
      index = index + 1
      return result
    end
    while index <= length do
      local key = parseString()
      if key == nil then return nil end
      skipSpace()
      if source:sub(index, index) ~= ":" then return nil end
      index = index + 1
      skipSpace()
      local value = parseValue()
      if value == nil then return nil end
      result[key] = value
      skipSpace()
      local char = source:sub(index, index)
      if char == "}" then
        index = index + 1
        return result
      end
      if char ~= "," then return nil end
      index = index + 1
      skipSpace()
    end
    return nil
  end

  parseValue = function()
    skipSpace()
    local char = source:sub(index, index)
    if char == '"' then return parseString() end
    if char == "{" then return parseObject() end
    if char == "[" then return parseArray() end
    if source:sub(index, index + 3) == "true" then
      index = index + 4
      return true
    end
    if source:sub(index, index + 4) == "false" then
      index = index + 5
      return false
    end
    if source:sub(index, index + 3) == "null" then
      index = index + 4
      return false
    end
    return parseNumber()
  end

  local value = parseValue()
  skipSpace()
  if index <= length then return nil end
  return value
end

local function nativeMetrics()
  if not (love and love.system and type(love.system.getWindowMetrics) == "function") then
    return {}
  end
  local ok, value = pcall(love.system.getWindowMetrics)
  if not ok then return {} end
  if type(value) == "table" then return value end
  return decodeJSON(value) or {}
end

local function safeValues(value, fallback, fullWidth, fullHeight)
  value = type(value) == "table" and value or {}
  if finite(value.x) or finite(value.y) or finite(value.width) or finite(value.height) then
    local x = number(value.x, fallback.x)
    local y = number(value.y, fallback.y)
    local width = number(value.width or value.w, fallback.width)
    local height = number(value.height or value.h, fallback.height)
    return x, y, width, height
  end
  local left = number(value.left, fallback.left)
  local top = number(value.top, fallback.top)
  local right = number(value.right, fallback.right)
  local bottom = number(value.bottom, fallback.bottom)
  return left, top, fullWidth - left - right, fullHeight - top - bottom
end

local function regionValues(value)
  if type(value) ~= "table" then return nil end
  local frame = type(value.frame) == "table" and value.frame or value
  local x = number(frame.x, nil)
  local y = number(frame.y, nil)
  local width = number(frame.width or frame.w, nil)
  local height = number(frame.height or frame.h, nil)
  if not (x and y and width and height) then return nil end
  return {
    kind = tostring(value.kind or "reserved"),
    x = x,
    y = y,
    width = width,
    height = height,
    active = value.active ~= false,
  }
end

local function rawSafeRect(width, height, pixelWidth, pixelHeight)
  local x, y, w, h = 0, 0, width, height
  if love and love.window and type(love.window.getSafeArea) == "function" then
    local ok, rx, ry, rw, rh = pcall(love.window.getSafeArea)
    if ok and type(rx) == "number" and type(ry) == "number"
        and type(rw) == "number" and type(rh) == "number"
        and rw > 0 and rh > 0 then
      x, y, w, h = rx, ry, rw, rh
      if (w > width + 0.5 or h > height + 0.5)
          and pixelWidth > width and pixelHeight > height then
        local dx = pixelWidth / width
        local dy = pixelHeight / height
        if dx > 1.01 or dy > 1.01 then
          x, w = x / dx, w / dx
          y, h = y / dy, h / dy
        end
      end
    end
  end
  x = clamp(x, 0, width)
  y = clamp(y, 0, height)
  w = clamp(w, 1, width - x)
  h = clamp(h, 1, height - y)
  return x, y, w, h
end

local function normalize(source)
  source = type(source) == "table" and source or {}
  local native = type(source.native) == "table" and source.native or {}
  local width = math.max(1, number(source.width, 1))
  local height = math.max(1, number(source.height, 1))
  local pixelWidth = math.max(1, number(source.pixelWidth, width))
  local pixelHeight = math.max(1, number(source.pixelHeight, height))
  local fallbackSafe = {
    x = number(source.safeX, 0),
    y = number(source.safeY, 0),
    width = number(source.safeWidth, width),
    height = number(source.safeHeight, height),
    left = number(source.safeLeft, 0),
    top = number(source.safeTop, 0),
    right = number(source.safeRight, 0),
    bottom = number(source.safeBottom, 0),
  }
  fallbackSafe.width = math.max(1, fallbackSafe.width)
  fallbackSafe.height = math.max(1, fallbackSafe.height)
  local safeSource = native.safe or native.safeArea or native.safeInsets
    or source.safe
  local x, y, safeWidth, safeHeight = safeValues(
    safeSource, fallbackSafe, width, height)
  x = clamp(x, 0, width)
  y = clamp(y, 0, height)
  safeWidth = clamp(safeWidth, 1, width - x)
  safeHeight = clamp(safeHeight, 1, height - y)
  local safe = {
    x = x,
    y = y,
    width = safeWidth,
    height = safeHeight,
    left = x,
    top = y,
    right = math.max(0, width - x - safeWidth),
    bottom = math.max(0, height - y - safeHeight),
  }
  local horizontalClass = native.horizontalClass or source.horizontalClass
  local verticalClass = native.verticalClass or source.verticalClass
  if horizontalClass ~= "compact" and horizontalClass ~= "regular" then
    horizontalClass = safeWidth >= 600 and "regular" or "compact"
  end
  if verticalClass ~= "compact" and verticalClass ~= "regular" then
    verticalClass = safeHeight >= 600 and "regular" or "compact"
  end
  local textScale = number(native.textScale or source.textScale, 1)
  textScale = clamp(textScale, 0.75, 3)
  local verticalBarEdge = tostring(native.verticalBarEdge
    or source.verticalBarEdge or "unspecified")
  local hinge = type(native.hinge) == "table" and native.hinge
    or type(source.hinge) == "table" and source.hinge or {}
  local hingeStatus = tostring(hinge.status or source.hingeStatus or "unknown")
  local hingeAngle = number(hinge.angle or source.hingeAngle, 0)
  local dpiX = number(native.dpiX or source.dpiX, pixelWidth / width)
  local dpiY = number(native.dpiY or source.dpiY, pixelHeight / height)
  local regions = {}
  local reservedRegions = {}
  local inputRegions = native.regions or source.regions or source.reservedRegions
  if type(inputRegions) == "table" then
    for _, input in ipairs(inputRegions) do
      local region = regionValues(input)
      if region then
        local x1 = clamp(region.x, 0, width)
        local y1 = clamp(region.y, 0, height)
        local x2 = clamp(region.x + region.width, 0, width)
        local y2 = clamp(region.y + region.height, 0, height)
        if x2 >= x1 and y2 >= y1 then
          region.x, region.y = x1, y1
          region.width, region.height = x2 - x1, y2 - y1
          reservedRegions[#reservedRegions + 1] = region
          if region.active and x2 > x1 and y2 > y1 then
            regions[#regions + 1] = region
          end
        end
      end
    end
  end
  local hasFold = false
  for _, region in ipairs(regions) do
    if (region.kind == "division" or region.kind == "hinge")
        and region.width > 0 and region.height > 0 then
      hasFold = true
      break
    end
  end
  if not hasFold and (hingeStatus == "partiallyOpen"
      or hingeStatus == "partially_open" or hingeStatus == "partial") then
    local gap = math.max(8, math.min(24, math.floor(math.min(width, height) * 0.02)))
    local region
    if width >= height then
      region = {
        kind = "division",
        x = math.floor((width - gap) / 2), y = safe.y,
        width = gap, height = safe.height, active = true,
      }
    else
      region = {
        kind = "division",
        x = safe.x, y = math.floor((height - gap) / 2),
        width = safe.width, height = gap, active = true,
      }
    end
    regions[#regions + 1] = region
    reservedRegions[#reservedRegions + 1] = region
  end
  table.sort(regions, function(a, b)
    if a.x == b.x then
      if a.y == b.y then return a.kind < b.kind end
      return a.y < b.y
    end
    return a.x < b.x
  end)
  local key = table.concat({
    string.format("%.4f", width), string.format("%.4f", height),
    string.format("%.4f", pixelWidth), string.format("%.4f", pixelHeight),
    string.format("%.4f", safe.left), string.format("%.4f", safe.top),
    string.format("%.4f", safe.right), string.format("%.4f", safe.bottom),
    horizontalClass, verticalClass, string.format("%.4f", textScale),
    verticalBarEdge, hingeStatus, string.format("%.4f", hingeAngle),
    tostring(native.scene or source.scene or ""),
    tostring(native.generation or source.generation or ""),
  }, "|")
  for _, region in ipairs(reservedRegions) do
    key = key .. string.format("|%s:%s:%.4f:%.4f:%.4f:%.4f",
      region.kind, tostring(region.active), region.x, region.y,
      region.width, region.height)
  end
  return {
    width = width,
    height = height,
    pixelWidth = pixelWidth,
    pixelHeight = pixelHeight,
    dpiX = math.max(0.01, dpiX),
    dpiY = math.max(0.01, dpiY),
    safe = safe,
    horizontalClass = horizontalClass,
    verticalClass = verticalClass,
    regions = regions,
    reservedRegions = reservedRegions,
    textScale = textScale,
    verticalBarEdge = verticalBarEdge,
    hinge = { status = hingeStatus, angle = hingeAngle },
    key = key,
  }
end

function ViewportMetrics.normalize(source)
  return normalize(source)
end

function ViewportMetrics.current()
  local native = nativeMetrics()
  local width, height = 1, 1
  local pixelWidth, pixelHeight = 1, 1
  if love and love.graphics and love.graphics.getDimensions then
    width, height = love.graphics.getDimensions()
    if love.graphics.getPixelDimensions then
      pixelWidth, pixelHeight = love.graphics.getPixelDimensions()
    else
      pixelWidth, pixelHeight = width, height
    end
  end
  width, height = math.max(1, width), math.max(1, height)
  pixelWidth, pixelHeight = math.max(1, pixelWidth), math.max(1, pixelHeight)
  local safeX, safeY, safeWidth, safeHeight = rawSafeRect(
    width, height, pixelWidth, pixelHeight)
  local value = normalize({
    width = width,
    height = height,
    pixelWidth = pixelWidth,
    pixelHeight = pixelHeight,
    safeX = safeX,
    safeY = safeY,
    safeWidth = safeWidth,
    safeHeight = safeHeight,
    safe = { x = safeX, y = safeY, width = safeWidth, height = safeHeight },
    native = native,
  })
  if not cached or value.key ~= lastKey then
    generation = generation + 1
    value.generation = generation
    cached = value
    lastKey = value.key
  end
  return cached
end

function ViewportMetrics.invalidate()
  cached = nil
end

local function splitRect(rect, cut)
  local left = math.max(rect.x, cut.x)
  local top = math.max(rect.y, cut.y)
  local right = math.min(rect.x + rect.width, cut.x + cut.width)
  local bottom = math.min(rect.y + rect.height, cut.y + cut.height)
  if right <= left or bottom <= top then return { rect } end
  local pieces = {}
  local rectRight = rect.x + rect.width
  local rectBottom = rect.y + rect.height
  if top > rect.y then
    pieces[#pieces + 1] = {
      x = rect.x, y = rect.y, width = rect.width, height = top - rect.y,
    }
  end
  if bottom < rectBottom then
    pieces[#pieces + 1] = {
      x = rect.x, y = bottom, width = rect.width,
      height = rectBottom - bottom,
    }
  end
  if left > rect.x then
    pieces[#pieces + 1] = {
      x = rect.x, y = top, width = left - rect.x, height = bottom - top,
    }
  end
  if right < rectRight then
    pieces[#pieces + 1] = {
      x = right, y = top, width = rectRight - right, height = bottom - top,
    }
  end
  return pieces
end

function ViewportMetrics.usableRects(viewport)
  viewport = viewport or ViewportMetrics.current()
  local panes = {
    {
      x = viewport.safe.x,
      y = viewport.safe.y,
      width = viewport.safe.width,
      height = viewport.safe.height,
    },
  }
  for _, region in ipairs(viewport.regions or {}) do
    local nextPanes = {}
    for _, pane in ipairs(panes) do
      for _, piece in ipairs(splitRect(pane, region)) do
        if piece.width >= 1 and piece.height >= 1 then
          nextPanes[#nextPanes + 1] = piece
        end
      end
    end
    panes = nextPanes
  end
  table.sort(panes, function(a, b)
    local areaA, areaB = a.width * a.height, b.width * b.height
    if areaA == areaB then
      if a.y == b.y then return a.x < b.x end
      return a.y < b.y
    end
    return areaA > areaB
  end)
  return panes
end

local function activeFold(viewport)
  local chosen
  for _, region in ipairs(viewport.regions or {}) do
    if (region.kind == "division" or region.kind == "hinge")
        and region.active ~= false
        and region.width > 0 and region.height > 0 then
      if not chosen or region.width * region.height > chosen.width * chosen.height then
        chosen = region
      end
    end
  end
  if not chosen then return nil end
  return chosen, chosen.height >= chosen.width and "vertical" or "horizontal"
end

local function largestPane(panes, axis, boundary, leading)
  local best
  for _, pane in ipairs(panes) do
    local center = axis == "vertical"
      and pane.x + pane.width / 2 or pane.y + pane.height / 2
    local matches
    if leading then
      matches = center < boundary
    else
      matches = center > boundary
    end
    if matches and (not best or pane.width * pane.height > best.width * best.height) then
      best = pane
    end
  end
  return best
end

function ViewportMetrics.foldRects(viewport)
  viewport = viewport or ViewportMetrics.current()
  local fold, axis = activeFold(viewport)
  local panes = ViewportMetrics.usableRects(viewport)
  if not fold or #panes < 2 then return nil, nil, nil, panes end
  local boundary = axis == "vertical"
    and fold.x + fold.width / 2 or fold.y + fold.height / 2
  local leading = largestPane(panes, axis, boundary, true)
  local trailing = largestPane(panes, axis, boundary, false)
  if not leading or not trailing then return nil, nil, nil, panes end
  local content = axis == "vertical" and trailing or leading
  local controls = axis == "vertical" and leading or trailing
  return content, controls, axis, panes
end

function ViewportMetrics.gameplayRects(viewport)
  viewport = viewport or ViewportMetrics.current()
  local content, controls, _, panes = ViewportMetrics.foldRects(viewport)
  return content, controls, panes
end

return ViewportMetrics
