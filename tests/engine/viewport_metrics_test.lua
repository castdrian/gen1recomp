package.path = "./?.lua;./?/init.lua;" .. package.path

love = love or require("tests.love_stub")
local T = require("tests.harness")
local check, eq = T.check, T.eq
local ViewportMetrics = require("src.core.ViewportMetrics")
local Layout = require("src.ui.kit.Layout")
local Kit = require("src.ui.kit.Kit")

local graphics = love.graphics
local system = love.system
local oldDimensions = graphics.getDimensions
local oldPixelDimensions = graphics.getPixelDimensions
local oldSafeArea = love.window.getSafeArea
local oldOS = system.getOS
local oldWindowMetrics = system.getWindowMetrics

graphics.getDimensions = function() return 1000, 800 end
graphics.getPixelDimensions = function() return 2000, 1600 end
love.window.getSafeArea = function() return 20, 30, 956, 752 end
system.getOS = function() return "iOS" end
system.getWindowMetrics = function()
  return '{"safe":{"left":20,"top":30,"right":24,"bottom":18},'
    .. '"horizontalClass":"regular","verticalClass":"regular",'
    .. '"textScale":1.4,"scene":"inner:1",'
    .. '"regions":[{"kind":"division","x":488,"y":0,"width":24,"height":800},'
    .. '{"kind":"occlusion","x":-20,"y":0,"width":2,"height":2}]}'
end

local first = ViewportMetrics.current()
eq(first.width, 1000, "metrics use logical width")
eq(first.pixelWidth, 2000, "metrics use pixel width")
eq(first.dpiX, 2, "metrics derive horizontal density")
eq(first.safe.left, 20, "metrics preserve left safe inset")
eq(first.safe.top, 30, "metrics preserve top safe inset")
eq(first.safe.right, 24, "metrics preserve right safe inset")
eq(first.safe.bottom, 18, "metrics preserve bottom safe inset")
eq(first.horizontalClass, "regular", "metrics preserve horizontal size class")
eq(first.verticalClass, "regular", "metrics preserve vertical size class")
eq(first.textScale, 1.4, "metrics preserve text scale")
eq(#first.regions, 1, "metrics discard empty clipped regions")
eq(first.regions[1].kind, "division", "metrics retain region kind")

local normalized = ViewportMetrics.normalize({
  width = 720,
  height = 1280,
  pixelWidth = 1440,
  pixelHeight = 2560,
  safe = { left = 12, top = 40, right = 16, bottom = 28 },
  regions = {
    { kind = "division", x = 350, y = 0, width = 20, height = 1280 },
    { kind = "invalid", x = 900, y = 0, width = 20, height = 20 },
  },
})
eq(normalized.safe.width, 692, "normalization converts asymmetric insets")
eq(normalized.safe.height, 1212, "normalization converts vertical insets")
eq(#normalized.regions, 1, "normalization drops out-of-window regions")
eq(normalized.horizontalClass, "regular", "normalization derives regular width class")
eq(normalized.verticalClass, "regular", "normalization derives regular height class")

local layout = Layout.metrics(1200)
eq(layout.horizontalClass, "regular", "layout receives horizontal class")
check(layout.twoCol or layout.duoSplit, "regular layout keeps a pane arrangement")
check(layout.duoSplit and #layout.panes == 2, "layout exposes separate reserved-region panes")
check(layout.sidebarRect and (layout.sidebarRect.x + layout.sidebarRect.width <= 488
    or layout.sidebarRect.x >= 512),
  "regular split layout exposes a sidebar pane")
check(layout.x + layout.w <= 488 or layout.x >= 512,
  "layout primary pane avoids the division region")
eq(Kit.touchTarget, 44, "iOS layout uses 44 point touch targets")
check(Kit.tapMin() >= 44, "iOS minimum hit target is at least 44 points")
eq(Kit.textScale, 1.4, "larger text reaches the text system")

system.getWindowMetrics = function()
  return '{"safe":{"left":20,"top":30,"right":24,"bottom":18},'
    .. '"horizontalClass":"regular","verticalClass":"regular",'
    .. '"textScale":1.4,"scene":"tabletop:1",'
    .. '"regions":[{"kind":"hinge","x":0,"y":388,"width":1000,"height":24}]}'
end
ViewportMetrics.invalidate()
local horizontal = Layout.metrics(1200)
eq(horizontal.duoAxis, "horizontal", "horizontal Duo poses use stacked panes")
check(horizontal.secondaryRect ~= nil, "horizontal Duo poses expose a secondary pane")
eq(horizontal.sidebarRect, nil, "horizontal Duo poses avoid a vertical sidebar")

local generation = first.generation
system.getWindowMetrics = function()
  return '{"safe":{"left":20,"top":48,"right":24,"bottom":18},'
    .. '"horizontalClass":"regular","verticalClass":"regular",'
    .. '"textScale":1.4,"scene":"inner:2","regions":[]}'
end
ViewportMetrics.invalidate()
local second = ViewportMetrics.current()
check(second.generation > generation, "metric generation changes after scene updates")
eq(second.safe.top, 48, "updated scene metrics invalidate the safe area")

graphics.getDimensions = oldDimensions
graphics.getPixelDimensions = oldPixelDimensions
love.window.getSafeArea = oldSafeArea
system.getOS = oldOS
system.getWindowMetrics = oldWindowMetrics
Layout.invalidate()

T.finish("viewport metrics")
