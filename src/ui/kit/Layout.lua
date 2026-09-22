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
local ViewportMetrics = require("src.core.ViewportMetrics")

local Layout = {}

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

local function usableRects(viewport)
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
    return a.width * a.height > b.width * b.height
  end)
  return panes
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
  local s = Kit.layout(sw, sh, viewport.textScale)
  if W == lastW and H == lastH and ox == lastOx and oy == lastOy
      and sw == lastSw and sh == lastSh and maxAppW == lastMax
      and viewport.generation == lastGeneration then
    return M
  end
  lastW, lastH, lastOx, lastOy = W, H, ox, oy
  lastSw, lastSh, lastMax = sw, sh, maxAppW
  lastGeneration = viewport.generation

  local panes = usableRects(viewport)
  local primary = panes[1] or {
    x = ox, y = oy, width = sw, height = sh,
  }
  local appW = math.min(primary.width, (maxAppW or 1200) * s)
  local m = M
  m.W, m.H, m.s = W, H, s
  m.x = math.floor(primary.x + (primary.width - appW) / 2)
  m.top = math.floor(primary.y)
  m.w = math.floor(appW)
  m.h = math.floor(primary.height)
  m.pad = math.floor(Theme.clamp(appW * 0.03, 10, 24))
  m.gap = math.floor(12 * s)
  m.colGap = math.floor(16 * s)
  m.rowH = math.max(Kit.tapMin(), math.floor(44 * s))
  m.btnH = math.max(Kit.tapMin(), math.floor(38 * s))
  m.chip = math.max(Kit.tapMin(), math.floor(40 * s))
  m.railH = math.max(3, math.floor(4 * s))
  m.logoH = math.floor(Theme.clamp(sh * 0.10, 36, 84))
  m.cols = viewport.horizontalClass == "compact" and 1
        or (appW >= Layout.BP.threeCol * s and 3)
        or (appW >= 560 * s and 2)
        or 1
  m.twoCol = m.cols >= 2
  m.contentW = m.w - 2 * m.pad
  m.colW = m.twoCol
    and math.floor((m.contentW - m.colGap) / 2)
    or m.contentW
  m.contentX = m.x + m.pad
  m.horizontalClass = viewport.horizontalClass
  m.verticalClass = viewport.verticalClass
  m.textScale = viewport.textScale
  m.generation = viewport.generation
  m.safe = viewport.safe
  m.regions = viewport.regions
  m.panes = panes
  m.primaryRect = primary
  m.duoSplit = #panes > 1
  m.sidebarRect = nil
  if m.duoSplit and viewport.horizontalClass == "regular" then
    local sidebar = panes[2]
    if sidebar and sidebar.width >= 220 * s and sidebar.height >= 420 * s then
      m.sidebarRect = sidebar
    end
  end
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
