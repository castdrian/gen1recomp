-- Shared layout metrics for the launcher and the save editor.
--
-- Both windows derive one `m` table per frame from the real window size and
-- the platform safe area, and every panel lays itself out in explicit pixels
-- off that table.  Explicit pixels are the point: the old view expressed
-- widths as "100%" and leaned on a layout engine to resolve them, which is
-- where the launcher's layout bugs lived (percentages resolving against a
-- border box instead of a content box, auto-sized children measuring zero
-- height inside an auto-sized parent, flex-shrink compressing text until it
-- overlapped).  None of those failure modes exist when a column is simply
-- `math.floor((contentW - gap) / 2)`.
--
-- REFLOW, not shrink: a narrow window drops to fewer columns rather than
-- scaling the desktop layout down.  Scale has a floor (Kit.layout clamps to
-- 0.9) so tap targets and text stay legible on a phone.

local Kit = require("src.ui.kit.Kit")
local Theme = require("src.ui.kit.Theme")
local Strings = require("src.core.Strings")
local ViewportMetrics = require("src.core.ViewportMetrics")

local Layout = {}

local function paneAxis(panes)
  if #panes < 2 then return nil end
  local primary, secondary = panes[1], panes[2]
  local sameTop = math.abs(primary.y - secondary.y) <= 2
  local sameHeight = math.abs(primary.height - secondary.height) <= 4
  if sameTop and sameHeight then return "vertical" end
  local sameLeft = math.abs(primary.x - secondary.x) <= 2
  local sameWidth = math.abs(primary.width - secondary.width) <= 4
  if sameLeft and sameWidth then return "horizontal" end
  return nil
end

local function headerRowCount(m)
  local gap = math.floor(6 * m.s)
  local width = m.chip
  for _, label in ipairs({ "MODS", "FIND", "ONLINE", "SKINS", "IMPORT" }) do
    width = math.max(width, Kit.textWidth("micro", Strings(label)) + 4)
  end
  local dropW = width + math.floor(24 * m.s)
  local used, rows = dropW, 1
  for _ = 1, 5 do
    if used + gap + width > m.headerContentW then
      rows, used = rows + 1, width
    else
      used = used + gap + width
    end
  end
  return rows
end

local function headerWidth(viewport, x, width)
  local limit = width
  for _, region in ipairs(viewport.regions or {}) do
    local camera = region.kind == "occlusion" or region.kind == "camera"
    local edge = region.x + region.width
    if camera and region.active and region.width >= 8 and region.height >= 8
        and region.y <= 0.5 and region.x > x
        and edge >= viewport.width - 0.5 then
      limit = math.min(limit, region.x - x)
    end
  end
  return math.max(1, limit)
end

local function verticalBar(viewport, safe)
  if viewport.horizontalClass ~= "compact" then return nil end
  local leftInset = safe.x
  local rightInset = viewport.width - safe.x - safe.width
  local edge = viewport.verticalBarEdge
  local side, sideWidth
  if edge == "leading" then
    side, sideWidth = "leading", leftInset
  elseif edge == "trailing" then
    side, sideWidth = "trailing", rightInset
  else
    for _, region in ipairs(viewport.regions or {}) do
      local right = region.x + region.width
      local topRegion = region.active and region.y <= 0.5
        and region.height >= 8 and region.width >= 8
      if topRegion and right >= viewport.width - 0.5
          and rightInset >= 48 then
        side, sideWidth = "trailing", rightInset
        break
      end
      if topRegion and region.x <= 0.5 and leftInset >= 48 then
        side, sideWidth = "leading", leftInset
        break
      end
    end
  end
  if not side or sideWidth < 48 then return nil end
  local x = side == "leading" and 0 or viewport.width - sideWidth
  return {
    x = x,
    y = safe.y,
    width = sideWidth,
    height = safe.height,
    edge = side,
  }
end

local function verticalBarTop(viewport, bar, gap)
  local top = bar.y + gap
  for _, region in ipairs(viewport.regions or {}) do
    local right = region.x + region.width
    local inBar = region.active and region.x < bar.x + bar.width
      and right > bar.x and region.y <= bar.y + 0.5
    if inBar and region.height >= 8 then
      top = math.max(top, region.y + region.height + gap)
    end
  end
  return math.min(top, bar.y + bar.height - gap)
end

-- Breakpoints, in safe-area pixels.  Named so panels read intent rather than
-- magic numbers.
Layout.BP = {
  twoCol   = 640,   -- side-by-side columns become possible
  threeCol = 1100,  -- wide desktop: mod list + detail + chrome
}

-- Build the frame's metrics.  `maxAppW` caps the content column on an
-- ultrawide monitor so the UI stays a readable measure instead of stretching.
-- One metrics table, reused.  Every field is a pure function of the window
-- size, the safe area and maxAppW, so the table only has to be rebuilt when
-- one of those changes; the launcher asked for a fresh one 60 times a second
-- and threw all of them away.  Callers must treat `m` as read-only (nothing
-- writes to it today) -- a caller that needs a shifted field should save,
-- assign and restore it around the call, not wrap `m` in a proxy.
local M = {}
local lastW, lastH, lastOx, lastOy, lastSw, lastSh, lastMax, lastGeneration

function Layout.invalidate()
  lastW, lastH, lastOx, lastOy, lastSw, lastSh, lastMax = nil
  lastGeneration = nil
  ViewportMetrics.invalidate()
end

function Layout.metrics(maxAppW)
  local viewport = ViewportMetrics.current()
  local W, H = viewport.width, viewport.height
  local ox, oy = viewport.safe.x, viewport.safe.y
  local sw, sh = viewport.safe.width, viewport.safe.height
  local foldContent, foldControls, foldAxis, panes = ViewportMetrics.foldRects(viewport)
  local safeRect = {
    x = ox, y = oy, width = sw, height = sh,
  }
  local primary = foldContent or safeRect
  local axis = foldAxis or paneAxis(panes)
  local hasDivision = foldContent ~= nil and foldControls ~= nil
  local base = hasDivision and primary or {
    x = ox, y = oy, width = sw, height = sh,
  }
  local s = Kit.layout(base.width, base.height, viewport.textScale)
  if W == lastW and H == lastH and ox == lastOx and oy == lastOy
      and sw == lastSw and sh == lastSh and maxAppW == lastMax
      and viewport.generation == lastGeneration then
    return M
  end
  lastW, lastH, lastOx, lastOy = W, H, ox, oy
  lastSw, lastSh, lastMax = sw, sh, maxAppW
  lastGeneration = viewport.generation

  local appW = math.min(base.width, (maxAppW or 1200) * s)
  local m = M
  m.W, m.H, m.s = W, H, s
  m.fullX, m.fullY, m.fullW, m.fullH = 0, 0, W, H
  m.x = math.floor(base.x + (base.width - appW) / 2)
  m.top = math.floor(base.y)
  m.w = math.floor(appW)
  m.h = math.floor(base.height)
  m.pad = math.floor(Theme.clamp(appW * 0.03, 10, 24))
  m.gap = math.floor(12 * s)
  m.colGap = math.floor(16 * s)
  m.rowH = math.max(Kit.tapMin(), math.floor(44 * s))
  m.btnH = math.max(Kit.tapMin(), math.floor(38 * s))
  m.chip = math.max(Kit.tapMin(), math.floor(40 * s))
  m.railH = math.max(3, math.floor(4 * s))
  m.logoH = math.floor(Theme.clamp(base.height * 0.10, 36, 84))
  m.headerW = headerWidth(viewport, m.x, m.w)
  m.headerTabOffset = 0
  local tabStart = m.top + m.railH + m.logoH + math.floor(12 * s)
    + math.floor(6 * s)
  for _, region in ipairs(viewport.regions or {}) do
    local camera = region.kind == "occlusion" or region.kind == "camera"
    local edge = region.x + region.width
    if camera and region.active and region.width >= 8 and region.height >= 8
        and region.y <= m.top + 0.5
        and edge >= viewport.width - 0.5 then
      m.headerTabOffset = math.max(m.headerTabOffset,
        region.y + region.height + math.floor(6 * s) - tabStart)
    end
  end
  m.headerTabOffset = math.max(0, math.floor(m.headerTabOffset))
  m.headerContentW = m.w - 2 * m.pad
  m.contentX = m.x + m.pad
  m.contentW = m.w - 2 * m.pad
  m.horizontalClass = viewport.horizontalClass
  m.verticalClass = viewport.verticalClass
  m.textScale = viewport.textScale
  m.generation = viewport.generation
  m.safe = viewport.safe
  m.verticalBar = verticalBar(viewport, safeRect)
  if m.verticalBar then
    m.verticalBar.top = verticalBarTop(viewport, m.verticalBar,
      math.floor(6 * s))
    m.verticalBar.gap = math.floor(6 * s)
    m.verticalBar.buttonW = math.max(1, math.min(m.chip,
      m.verticalBar.width - math.floor(8 * s)))
  end
  local modalBase = hasDivision and base or (panes[1] or safeRect)
  m.modalX = modalBase.x
  m.modalY = modalBase.y
  m.modalW = modalBase.width
  m.modalH = modalBase.height
  m.regions = viewport.regions
  m.reservedRegions = viewport.reservedRegions
  m.panes = panes
  m.primaryRect = primary
  m.secondaryRect = foldControls or panes[2]
  m.duoAxis = hasDivision and foldAxis or nil
  m.duoSplit = hasDivision
  m.sidebarRect = nil
  m.internalSidebar = false
  if hasDivision and foldAxis == "vertical" and viewport.horizontalClass == "regular" then
    local sidebar = foldControls
    if sidebar and sidebar.width >= 220 * s and sidebar.height >= 320 * s then
      m.sidebarRect = sidebar
    end
  end
  local headerRows = m.verticalBar and 0 or headerRowCount(m)
  local headerReserve = m.railH + m.logoH + math.floor(12 * s)
    + (m.verticalBar and 0 or math.floor(6 * s))
    + headerRows * (m.chip + Kit.textHeight("micro"))
    + (headerRows > 1 and (headerRows - 1) * math.floor(4 * s) or 0)
    + math.floor(8 * s)
    + (m.verticalBar and 0 or m.headerTabOffset) + 1
  if not m.sidebarRect and not hasDivision
      and viewport.horizontalClass == "regular"
      and base.height - headerReserve >= 220 * s then
    local sidebarW = Theme.clamp(appW * 0.28, 145 * s, 224 * s)
    local sidebarGap = math.floor(16 * s)
    local bodyW = appW - 2 * m.pad - sidebarW - sidebarGap
    if bodyW >= 288 * s then
      m.sidebarRect = {
        x = m.x + m.pad,
        y = base.y + headerReserve + math.floor(8 * s),
        width = sidebarW,
        height = base.height - headerReserve - math.floor(8 * s),
      }
      m.contentX = m.x + m.pad + sidebarW + sidebarGap
      m.contentW = bodyW
      m.internalSidebar = true
    end
  end
  m.cols = viewport.horizontalClass == "compact" and 1
        or (m.contentW >= Layout.BP.threeCol * s and 3)
        or (m.contentW >= 560 * s and 2)
        or 1
  m.twoCol = m.cols >= 2
  m.colW = m.twoCol
    and math.floor((m.contentW - m.colGap) / 2)
    or m.contentW
  m.layoutMode = viewport.horizontalClass == "compact" and "compact"
    or (m.duoSplit and "folded" or "regular")
  return m
end

-- A vertical cursor for stacking blocks down a column.  Immediate mode has
-- no layout pass, so panels advance a y by hand; this makes that explicit
-- and keeps the arithmetic in one place.
local Cursor = {}
Cursor.__index = Cursor

function Layout.cursor(x, y, w)
  return setmetatable({ x = x, y = y, w = w, y0 = y }, Cursor)
end

-- Reserve `h` pixels and return the rect that was reserved.
function Cursor:take(h, gapAfter)
  local x, y = self.x, self.y
  self.y = self.y + h + (gapAfter or 0)
  return x, y, self.w, h
end

function Cursor:skip(h)
  self.y = self.y + h
end

function Cursor:height()
  return self.y - self.y0
end

-- Split the cursor's width into `n` equal columns with `gap` between them,
-- returning a function that yields the i-th column's x and width.
function Layout.columns(x, w, n, gap)
  n = math.max(1, n)
  local cw = math.floor((w - gap * (n - 1)) / n)
  return function(i)
    return x + (i - 1) * (cw + gap), cw
  end
end

-- Lay a row of buttons out right-aligned within [x, x+w], returning a
-- function that yields each button's x as it is consumed right to left.
function Layout.rightCluster(x, w, gap)
  local cursor = x + w
  return function(bw)
    cursor = cursor - bw
    local bx = cursor
    cursor = cursor - gap
    return bx
  end
end

return Layout
