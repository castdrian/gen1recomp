package.path = "./?.lua;./?/init.lua;" .. package.path

love = love or require("tests.love_stub")
local T = require("tests.harness")
local check, eq = T.check, T.eq
local ViewportMetrics = require("src.core.ViewportMetrics")
local TouchControls = require("src.core.TouchControls")
local GameViewport = require("src.render.GameViewport")

local split = ViewportMetrics.normalize({
  width = 1000,
  height = 800,
  safe = { left = 20, top = 12, right = 24, bottom = 18 },
  horizontalClass = "regular",
  verticalClass = "regular",
  regions = {
    { kind = "division", x = 488, y = 0, width = 24, height = 800 },
    { kind = "occlusion", x = 0, y = 0, width = 2, height = 2 },
    { kind = "division", x = 0, y = 0, width = 0, height = 0,
      active = false },
  },
})
local panes = ViewportMetrics.usableRects(split)
eq(#panes, 2, "active reserved regions divide the safe rect")
eq(panes[1].x, 20, "left pane begins at the asymmetric safe inset")
eq(panes[1].width, 468, "left pane stops before the division region")
eq(panes[2].x, 512, "right pane begins after the division region")
eq(panes[2].width, 464, "right pane preserves the right safe inset")
local gamePane, controlsPane = ViewportMetrics.gameplayRects(split)
eq(gamePane.x, panes[2].x, "gameplay uses the trailing usable pane")
eq(controlsPane.x, panes[1].x, "controls use the leading usable pane")

local foldContent, foldControls, foldAxis = ViewportMetrics.foldRects(split)
eq(foldAxis, "vertical", "vertical fold reports its axis")
eq(foldContent.x, panes[2].x, "fold content stays on the trailing pane")
eq(foldControls.x, panes[1].x, "fold controls stay on the leading pane")

local stacked = ViewportMetrics.normalize({
  width = 800,
  height = 1000,
  safe = { left = 12, top = 20, right = 16, bottom = 24 },
  horizontalClass = "regular",
  verticalClass = "regular",
  regions = { { kind = "division", x = 0, y = 488, width = 800, height = 24 } },
})
local topPane, bottomPane = ViewportMetrics.gameplayRects(stacked)
eq(topPane.height, 468, "tabletop gameplay uses the top pane")
eq(bottomPane.y, 512, "tabletop controls start below the division")
local tabletopContent = ViewportMetrics.foldRects(stacked)
eq(tabletopContent.y, topPane.y, "tabletop fold content uses the top pane")

local inactive = ViewportMetrics.normalize({
  width = 600,
  height = 400,
  regions = { { kind = "division", x = 290, y = 0, width = 20, height = 400,
               active = false } },
})
eq(#ViewportMetrics.usableRects(inactive), 1, "inactive division leaves one pane")
eq(#inactive.reservedRegions, 1, "inactive division remains available for pose invalidation")
local flatGame, flatControls = ViewportMetrics.gameplayRects(inactive)
eq(flatGame, nil, "flat pose keeps gameplay in one surface")
eq(flatControls, nil, "flat pose has no separate controls pane")

local occluded = ViewportMetrics.normalize({
  width = 600,
  height = 400,
  regions = { { kind = "occlusion", x = 0, y = 0, width = 48, height = 400 } },
})
local occlusionPane = ViewportMetrics.usableRects(occluded)[1]
eq(occlusionPane.x, 48, "occlusion keeps the touch surface out of the camera")
eq(occlusionPane.width, 552, "occlusion preserves the usable touch width")

local outer = ViewportMetrics.normalize({
  width = 466,
  height = 678,
  safe = { left = 0, top = 0, right = 84, bottom = 34 },
  regions = {
    { kind = "occlusion", x = 382, y = 0, width = 84, height = 82 },
  },
})
eq(outer.safe.right, 84, "outer display keeps its right-side system rail")
local outerPane = ViewportMetrics.usableRects(outer)[1]
eq(outerPane.y, 0, "outer content starts in the app safe area")
eq(outerPane.width, 382, "outer content stays out of the right-side rail")

local book = ViewportMetrics.normalize({
  width = 803,
  height = 515,
  safe = { left = 34, top = 20, right = 34, bottom = 20 },
  horizontalClass = "regular",
  verticalClass = "regular",
  hinge = { status = "partiallyOpen", angle = 1.57 },
})
local bookGame, bookControls = ViewportMetrics.gameplayRects(book)
local _, _, bookAxis = ViewportMetrics.foldRects(book)
eq(bookAxis, "vertical", "partially open landscape derives a vertical division")
check(bookGame.x > bookControls.x, "book gameplay stays on the trailing pane")
check(bookControls.x + bookControls.width < bookGame.x,
  "book controls stay away from the division")

local tabletop = ViewportMetrics.normalize({
  width = 515,
  height = 803,
  safe = { left = 20, top = 34, right = 20, bottom = 34 },
  horizontalClass = "compact",
  verticalClass = "regular",
  hinge = { status = "partiallyOpen" },
})
local tabletopGame, tabletopControls = ViewportMetrics.gameplayRects(tabletop)
local _, _, tabletopAxis = ViewportMetrics.foldRects(tabletop)
eq(tabletopAxis, "horizontal", "partially open portrait derives a horizontal division")
check(tabletopGame.y < tabletopControls.y,
  "tabletop gameplay stays above the stable control pane")

local layout = TouchControls.defaultLayout(320, 520, 120, 40, 1)
for _, name in ipairs({ "dpad", "a", "b", "start", "select", "hotbar" }) do
  local zone = layout[name]
  check(zone.cx - zone.w / 2 >= 120, name .. " stays inside the pane on the left")
  check(zone.cx + zone.w / 2 <= 440, name .. " stays inside the pane on the right")
  check(zone.cy - zone.w / 2 >= 40, name .. " stays inside the pane at the top")
  check(zone.cy + zone.w / 2 <= 560, name .. " stays inside the pane at the bottom")
  check(zone.w >= 44, name .. " keeps the minimum touch target")
end

local oldDimensions = love.graphics.getDimensions
local oldPixelDimensions = love.graphics.getPixelDimensions
local oldSafeArea = love.window.getSafeArea
local oldWindowMetrics = love.system.getWindowMetrics
love.graphics.getDimensions = function() return 1000, 800 end
love.graphics.getPixelDimensions = function() return 1000, 800 end
love.window.getSafeArea = function() return 0, 0, 1000, 800 end
love.system.getWindowMetrics = function()
  return '{"horizontalClass":"regular","verticalClass":"regular",'
    .. '"regions":[{"kind":"division","x":488,"y":0,'
    .. '"width":24,"height":800}]}'
end
ViewportMetrics.invalidate()
GameViewport.reset()
local gameRect = GameViewport.begin(1)
eq(gameRect.x, 512, "gameplay moves to the trailing divided pane")
eq(gameRect.width, 488, "gameplay keeps the divided pane width")
eq(GameViewport.controlRect().x, 0, "touch controls move to the leading pane")
eq(GameViewport.dimensions(), 488, "gameplay dimensions follow the divided pane")
GameViewport.reset()
love.graphics.getDimensions = oldDimensions
love.graphics.getPixelDimensions = oldPixelDimensions
love.window.getSafeArea = oldSafeArea
love.system.getWindowMetrics = oldWindowMetrics
ViewportMetrics.invalidate()

local Layout = require("src.ui.kit.Layout")
love.graphics.getDimensions = function() return 669, 951 end
love.graphics.getPixelDimensions = function() return 2007, 2853 end
love.window.getSafeArea = function() return 0, 0, 669, 951 end
love.system.getWindowMetrics = function()
  return '{"horizontalClass":"regular","verticalClass":"regular"}'
end
ViewportMetrics.invalidate()
Layout.invalidate()
local innerLayout = Layout.metrics(1200)
check(innerLayout.internalSidebar, "regular inner display gets a sidebar layout")
check(innerLayout.sidebarRect.width > 0, "inner sidebar has usable width")
check(innerLayout.contentX > innerLayout.sidebarRect.x,
  "inner content starts beside the sidebar")
check(innerLayout.contentW >= 288 * innerLayout.s,
  "inner content keeps a readable minimum width")
love.graphics.getDimensions = function() return 803, 515 end
love.graphics.getPixelDimensions = function() return 2409, 1545 end
love.window.getSafeArea = function() return 34, 20, 735, 475 end
love.system.getWindowMetrics = function()
  return '{"safe":{"left":34,"top":20,"right":34,"bottom":20},'
    .. '"horizontalClass":"regular","verticalClass":"regular"}'
end
ViewportMetrics.invalidate()
Layout.invalidate()
local openLayout = Layout.metrics(1200)
check(openLayout.internalSidebar, "open inner display keeps a sidebar layout")
eq(openLayout.duoSplit, false, "open inner display has no fold split")
check(openLayout.contentW >= 288 * openLayout.s,
  "open inner content keeps a readable minimum width")
love.graphics.getDimensions = function() return 669, 951 end
love.graphics.getPixelDimensions = function() return 2007, 2853 end
love.window.getSafeArea = function() return 0, 0, 669, 951 end
love.system.getWindowMetrics = function()
  return '{"safe":{"left":0,"top":0,"right":84,"bottom":34},'
    .. '"horizontalClass":"regular","verticalClass":"regular",'
    .. '"regions":[{"kind":"division","x":455.5,"y":0,'
    .. '"width":40,"height":669}]}'
end
ViewportMetrics.invalidate()
Layout.invalidate()
local foldedLayout = Layout.metrics(1200)
check(foldedLayout.duoSplit, "folded inner display uses a split layout")
eq(foldedLayout.x, 0, "uneven folded content uses the larger pane")
eq(foldedLayout.modalX, 0, "folded modals stay in the content pane")
eq(foldedLayout.secondaryRect.x, 495.5, "folded controls use the narrow pane")
eq(foldedLayout.contentW < 500, true, "folded content keeps the larger pane bounded")
eq(foldedLayout.paneHorizontalClass, "compact", "uneven folded content uses compact reflow")
love.graphics.getDimensions = function() return 466, 678 end
love.graphics.getPixelDimensions = function() return 1398, 2034 end
love.window.getSafeArea = function() return 0, 0, 382, 644 end
love.system.getWindowMetrics = function()
  return '{"safe":{"left":0,"top":0,"right":84,"bottom":34},'
    .. '"horizontalClass":"compact","verticalClass":"regular",'
    .. '"regions":[{"kind":"occlusion","x":382,"y":0,'
    .. '"width":84,"height":82}]}'
end
ViewportMetrics.invalidate()
Layout.invalidate()
local outerLayout = Layout.metrics(1200)
eq(outerLayout.top, 0, "outer launcher starts at the top of the display")
eq(outerLayout.w, 382, "outer launcher content stays left of the system rail")
eq(outerLayout.modalY, 0, "outer modals stay in the safe content frame")
eq(outerLayout.verticalBar.x, 382, "outer controls use the trailing rail")
eq(outerLayout.verticalBar.width, 84, "outer controls preserve the rail width")
eq(outerLayout.verticalBar.top, 89, "outer controls start below the camera")
eq(outerLayout.fullW, 466, "outer metrics retain the full display width")
eq(outerLayout.contentW, outerLayout.headerContentW,
  "outer body uses the content width")
love.graphics.getDimensions = oldDimensions
love.graphics.getPixelDimensions = oldPixelDimensions
love.window.getSafeArea = oldSafeArea
love.system.getWindowMetrics = oldWindowMetrics
ViewportMetrics.invalidate()
Layout.invalidate()

T.finish("duo adaptive layout")
