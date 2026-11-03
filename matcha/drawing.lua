--[[
    Serotonin-style immediate-mode `draw` library for Matcha's Drawing API

    Matcha's Drawing is RETAINED mode (Drawing.new once, mutate, :Remove()).
    Serotonin's draw is IMMEDIATE mode (call draw.Rect(...) every frame).
    This wrapper gives you the Serotonin call style while internally:
      * pooling Drawing objects (never calls Drawing.new for something it already has)
      * dirty-checking every property (only writes to Matcha when a value changed)
      * hiding objects you didn't draw this frame (instead of destroying them)
      * assigning ZIndex in call order, so later calls render on top (like Serotonin)

    USAGE
        loadstring(httpget("YOUR_URL"))()   -- NOT `local draw = loadstring(...)()`: Matcha drops
                                            -- return values. The library sets the global `draw`.

        RunService.Heartbeat:Connect(function()
            if example_toggle() then
                draw.text(text, x, y, color, font, alpha)

                for _, v in next, partfolder:GetChildren() do
                    local sx, sy, onScreen = worldtoscreen(v.Position)
                    if onScreen then
                        draw.text(v.Name, sx, sy, color, font, alpha)  -- one text per item
                    end
                end
            end
        end)

    No Begin/End needed. The library runs its own Heartbeat "frame clock": every tick it hides
    whatever you did not draw since the last tick and resets the pool. Just call draw.* each tick.
    If you stop calling draw.* (toggle off), everything is hidden on the next tick.

    On script unload: draw.Shutdown()

    Every function exists as PascalCase, camelCase and snake_case, like Serotonin:
        draw.RectFilled / draw.rectFilled / draw.rect_filled
]]

-- ======================================================================
-- CONFIG (things the Matcha docs don't pin down; tweak if something looks off)
-- ======================================================================
local CONFIG = {
	-- Matcha docs don't say which end of Transparency is opaque. Default follows the usual
	-- Roblox Drawing convention (1 = opaque, 0 = invisible). If everything looks inverted,
	-- set this to true.
	InvertAlpha = false,

	-- Give each draw call an increasing ZIndex so call order == render order (Serotonin behavior).
	AutoZIndex = true,
	ZBase = 0,

	-- Confirmed in Matcha: Text uses `Size` (the docs' property list says `FontSize`, but Matcha
	-- reports "Unknown property FontSize").
	TextSizeProp = "Size",

	-- Serotonin font name -> Matcha Drawing.Fonts key
	FontMap = {
		ConsolasBold  = "Monospace",
		SmallestPixel = "Pixel",
		Verdana       = "System",
		Tahoma        = "System",
	},
	DefaultFont = "UI",
	-- Serotonin has no size parameter, so size is chosen per Matcha font here.
	FontSizes = { UI = 13, Monospace = 13, Pixel = 10, System = 13, SystemBold = 13 },
	DefaultFontSize = 13,

	-- Max number of strips used to emulate draw.Gradient (Matcha has no gradient object)
	GradientSteps = 24,
}

-- ======================================================================
-- Internals
-- ======================================================================
local draw = {}
draw.Config = CONFIG

local pools = {}     -- pools[key] = { n = used this frame, shown = visible last frame, [i] = slot }
local zCounter = CONFIG.ZBase
local warned = {}
local clock = nil
local paintConns = {}
local startClock

local images = {}    -- id -> raw image data
local imageKeys = {} -- id -> pool key
local nextImageId = 0

local function setter(obj, prop, value) obj[prop] = value end

-- Safe property write. Never throws; warns once per kind.prop on failure.
local function trySet(slot, prop, value)
	local ok, err = pcall(setter, slot.obj, prop, value)
	if not ok then
		local wk = slot.kind .. "." .. prop
		if not warned[wk] then
			warned[wk] = true
			print("[draw] could not set " .. wk .. ": " .. tostring(err))
		end
	end
end

-- Scalar property with dirty-check
local function set(slot, prop, value)
	local c = slot.c
	if c[prop] ~= value then
		c[prop] = value
		trySet(slot, prop, value)
	end
end

-- Vector2 property with dirty-check (no Vector2 allocated unless it changed)
local function setVec(slot, prop, x, y)
	local v = slot.vc[prop]
	if v == nil then
		v = {}
		slot.vc[prop] = v
	elseif v[1] == x and v[2] == y then
		return
	end
	v[1], v[2] = x, y
	trySet(slot, prop, Vector2.new(x, y))
end

-- Color with dirty-check. obj is optional (reuses caller's Color3 instead of allocating)
local function setColorRGB(slot, r, g, b, obj)
	local v = slot.vc.Color
	if v == nil then
		v = {}
		slot.vc.Color = v
	elseif v[1] == r and v[2] == g and v[3] == b then
		return
	end
	v[1], v[2], v[3] = r, g, b
	trySet(slot, "Color", obj or Color3.new(r, g, b))
end

local white
local function setColor(slot, color)
	if color == nil then
		white = white or Color3.new(1, 1, 1)
		color = white
	end
	setColorRGB(slot, color.R, color.G, color.B, color)
end

local function toTransparency(alpha)
	if alpha == nil then alpha = 255 end
	if alpha < 0 then alpha = 0 elseif alpha > 255 then alpha = 255 end
	local t = alpha / 255
	if CONFIG.InvertAlpha then return 1 - t end
	return t
end

-- Get the next pooled object of a type for this frame (creates it only if the pool is too small)
local function acquire(kind, key)
	if not clock then startClock() end
	key = key or kind
	local pool = pools[key]
	if not pool then
		pool = { n = 0, shown = 0 }
		pools[key] = pool
	end
	local i = pool.n + 1
	pool.n = i
	local slot = pool[i]
	if not slot then
		slot = { obj = Drawing.new(kind), kind = kind, c = {}, vc = {} }
		pool[i] = slot
	end
	zCounter = zCounter + 1
	return slot, zCounter
end

-- Common per-object style. Visible is last so a new object never shows with default styling.
local function style(slot, z, color, alpha)
	setColor(slot, color)
	set(slot, "Transparency", toTransparency(alpha))
	if CONFIG.AutoZIndex then set(slot, "ZIndex", z) end
	set(slot, "Visible", true)
end

-- ======================================================================
-- Frame clock (automatic; no Begin/End needed)
-- ======================================================================
-- Runs once per Heartbeat. Everything drawn since the last tick is "the frame": objects beyond
-- that count are hidden, then the counters reset so the next draw.* call reuses slot 1, 2, 3...
-- Order vs. your own Heartbeat callbacks doesn't matter. If this runs before yours (usual, since
-- it connects at load), an object you stop drawing disappears ~1 frame later than strictly necessary.
local function finalizeFrame()
	for _, pool in pairs(pools) do
		local n, shown = pool.n, pool.shown
		if shown > n then
			for i = n + 1, shown do set(pool[i], "Visible", false) end
		end
		pool.shown = n
		pool.n = 0
	end
	zCounter = CONFIG.ZBase
end

startClock = function()
	if not clock then
		clock = game:GetService("RunService").Heartbeat:Connect(finalizeFrame)
	end
end

-- Optional: thin stand-in for cheat.register("onPaint", fn). Just a Heartbeat connection.
-- Returns a function that unregisters it.
function draw.OnPaint(fn)
	local conn = game:GetService("RunService").Heartbeat:Connect(fn)
	paintConns[#paintConns + 1] = conn
	return function() conn:Disconnect() end
end

-- Removes every pooled Drawing object.
function draw.Clear()
	for key, pool in pairs(pools) do
		for i = 1, #pool do
			local obj = pool[i].obj
			pcall(function() obj:Remove() end)
		end
		pools[key] = nil
	end
end

-- Stops the frame clock + OnPaint loops and removes all drawings. Call on script unload.
-- (Calling draw.* afterwards quietly restarts the clock.)
function draw.Shutdown()
	if clock then
		clock:Disconnect()
		clock = nil
	end
	for i = 1, #paintConns do pcall(function() paintConns[i]:Disconnect() end) end
	paintConns = {}
	draw.Clear()
end

-- ======================================================================
-- Shapes
-- ======================================================================
function draw.Line(x1, y1, x2, y2, color, thickness, alpha)
	local slot, z = acquire("Line")
	setVec(slot, "From", x1, y1)
	setVec(slot, "To", x2, y2)
	set(slot, "Thickness", thickness or 1)
	style(slot, z, color, alpha)
end

function draw.Rect(x, y, w, h, color, thickness, rounding, alpha)
	local slot, z = acquire("Square")
	setVec(slot, "Position", x, y)
	setVec(slot, "Size", w, h)
	set(slot, "Filled", false)
	set(slot, "Thickness", thickness or 1)
	set(slot, "Corner", rounding or 0)
	style(slot, z, color, alpha)
end

function draw.RectFilled(x, y, w, h, color, rounding, alpha)
	local slot, z = acquire("Square")
	setVec(slot, "Position", x, y)
	setVec(slot, "Size", w, h)
	set(slot, "Filled", true)
	set(slot, "Corner", rounding or 0)
	style(slot, z, color, alpha)
end

function draw.Circle(x, y, radius, color, thickness, segments, alpha)
	local slot, z = acquire("Circle")
	setVec(slot, "Position", x, y)
	set(slot, "Radius", radius)
	set(slot, "NumSides", segments or 12)
	set(slot, "Thickness", thickness or 1)
	set(slot, "Filled", false)
	style(slot, z, color, alpha)
end

function draw.CircleFilled(x, y, radius, color, segments, alpha)
	local slot, z = acquire("Circle")
	setVec(slot, "Position", x, y)
	set(slot, "Radius", radius)
	set(slot, "NumSides", segments or 12)
	set(slot, "Filled", true)
	style(slot, z, color, alpha)
end

function draw.Triangle(x1, y1, x2, y2, x3, y3, color, thickness, alpha)
	local slot, z = acquire("Triangle")
	setVec(slot, "PointA", x1, y1)
	setVec(slot, "PointB", x2, y2)
	setVec(slot, "PointC", x3, y3)
	set(slot, "Thickness", thickness or 1)
	set(slot, "Filled", false)
	style(slot, z, color, alpha)
end

function draw.TriangleFilled(x1, y1, x2, y2, x3, y3, color, alpha)
	local slot, z = acquire("Triangle")
	setVec(slot, "PointA", x1, y1)
	setVec(slot, "PointB", x2, y2)
	setVec(slot, "PointC", x3, y3)
	set(slot, "Filled", true)
	style(slot, z, color, alpha)
end

-- Matcha has no gradient object, so this is emulated with filled rect strips.
function draw.Gradient(x, y, w, h, startColor, endColor, isHorizontal, startAlpha, endAlpha)
	startAlpha = startAlpha or 255
	endAlpha = endAlpha or 255
	local sr, sg, sb = startColor.R, startColor.G, startColor.B
	local er, eg, eb = endColor.R, endColor.G, endColor.B

	local length = isHorizontal and w or h
	local steps = math.min(CONFIG.GradientSteps, math.max(1, math.floor(length)))
	local stepLen = length / steps

	for i = 0, steps - 1 do
		local t = (steps == 1) and 0 or (i / (steps - 1))
		local slot, z = acquire("Square")
		if isHorizontal then
			setVec(slot, "Position", x + i * stepLen, y)
			setVec(slot, "Size", stepLen + 1, h) -- +1 overlap hides seams
		else
			setVec(slot, "Position", x, y + i * stepLen)
			setVec(slot, "Size", w, stepLen + 1)
		end
		set(slot, "Filled", true)
		set(slot, "Corner", 0)
		setColorRGB(slot, sr + (er - sr) * t, sg + (eg - sg) * t, sb + (eb - sb) * t)
		set(slot, "Transparency", toTransparency(startAlpha + (endAlpha - startAlpha) * t))
		if CONFIG.AutoZIndex then set(slot, "ZIndex", z) end
		set(slot, "Visible", true)
	end
end

-- ======================================================================
-- Polygons
-- ======================================================================
-- points: { {x1, y1}, {x2, y2}, ... }
function draw.Polyline(points, color, closed, thickness, alpha)
	local n = #points
	if n < 2 then return end
	for i = 1, n - 1 do
		local a, b = points[i], points[i + 1]
		draw.Line(a[1], a[2], b[1], b[2], color, thickness, alpha)
	end
	if closed and n > 2 then
		local a, b = points[n], points[1]
		draw.Line(a[1], a[2], b[1], b[2], color, thickness, alpha)
	end
end

-- Filled convex polygon, drawn as a triangle fan from the first point.
function draw.ConvexPolyFilled(points, color, alpha)
	local n = #points
	if n < 3 then return end
	local p1 = points[1]
	for i = 2, n - 1 do
		local p2, p3 = points[i], points[i + 1]
		draw.TriangleFilled(p1[1], p1[2], p2[1], p2[2], p3[1], p3[2], color, alpha)
	end
end

-- Andrew's monotone chain. Takes/returns { {x, y}, ... }
function draw.ComputeConvexHull(points)
	local n = #points
	local pts = {}
	for i = 1, n do pts[i] = points[i] end
	if n < 3 then return pts end

	table.sort(pts, function(a, b)
		if a[1] == b[1] then return a[2] < b[2] end
		return a[1] < b[1]
	end)

	local function cross(o, a, b)
		return (a[1] - o[1]) * (b[2] - o[2]) - (a[2] - o[2]) * (b[1] - o[1])
	end

	local lower = {}
	for i = 1, n do
		while #lower >= 2 and cross(lower[#lower - 1], lower[#lower], pts[i]) <= 0 do
			lower[#lower] = nil
		end
		lower[#lower + 1] = pts[i]
	end

	local upper = {}
	for i = n, 1, -1 do
		while #upper >= 2 and cross(upper[#upper - 1], upper[#upper], pts[i]) <= 0 do
			upper[#upper] = nil
		end
		upper[#upper + 1] = pts[i]
	end

	lower[#lower] = nil
	upper[#upper] = nil
	for i = 1, #upper do lower[#lower + 1] = upper[i] end
	return lower
end

-- 8 world-space corners of a part's box (Vector3 list), or nil.
-- Assumes the part exposes .CFrame and .Size and that `cframe * Vector3` works.
function draw.GetPartCorners(part)
	if not part then return nil end
	local ok, corners = pcall(function()
		local cf, s = part.CFrame, part.Size
		local hx, hy, hz = s.X / 2, s.Y / 2, s.Z / 2
		local out = {}
		for ix = -1, 1, 2 do
			for iy = -1, 1, 2 do
				for iz = -1, 1, 2 do
					out[#out + 1] = cf * Vector3.new(ix * hx, iy * hy, iz * hz)
				end
			end
		end
		return out
	end)
	if ok then return corners end
	return nil
end

-- ======================================================================
-- Text
-- ======================================================================
local function resolveFont(name)
	local key = CONFIG.FontMap[name] or CONFIG.DefaultFont
	local fonts = Drawing.Fonts
	return fonts and fonts[key], (CONFIG.FontSizes[key] or CONFIG.DefaultFontSize), key
end

local function drawText(str, x, y, color, font, alpha, outline)
	local slot, z = acquire("Text")
	local fontVal, size = resolveFont(font)
	set(slot, "Text", tostring(str))
	setVec(slot, "Position", x, y)
	set(slot, "Center", false)
	set(slot, "Outline", outline)
	if fontVal ~= nil then set(slot, "Font", fontVal) end
	set(slot, CONFIG.TextSizeProp, size)
	style(slot, z, color, alpha)
end

function draw.Text(str, x, y, color, font, alpha)
	drawText(str, x, y, color, font, alpha, false)
end

function draw.TextOutlined(str, x, y, color, font, alpha)
	drawText(str, x, y, color, font, alpha, true)
end

-- ----------------------------------------------------------------------
-- Text measuring
-- ----------------------------------------------------------------------
-- Matcha's Drawing docs have no measure API; the global `gettextsize` returns width, or
-- width + height. Its argument order isn't documented, so on first use we try the plausible
-- signatures and keep the first one that reacts to the size argument. The choice is printed once.
-- If gettextsize is missing/unusable we fall back to a hidden Text object's TextBounds, then to
-- a rough estimate.
local function unpackSize(a, b)
	if typeof(a) == "Vector2" then return a.X, a.Y end
	if type(a) == "number" then
		return a, (type(b) == "number") and b or nil
	end
	return nil, nil
end

local measureFn, measureProbed = nil, false

local function probeMeasure(fontVal, fontKey, size)
	measureProbed = true
	if type(gettextsize) ~= "function" then
		print("[matcha_draw] gettextsize not found - text widths will be estimated")
		return
	end
	local variants = {
		{ "(text, font, size)",       function(s, fv, fk, z) return gettextsize(s, fv, z) end },
		{ "(text, size, font)",       function(s, fv, fk, z) return gettextsize(s, z, fv) end },
		{ '(text, "FontName", size)', function(s, fv, fk, z) return gettextsize(s, fk, z) end },
		{ "(text, size)",             function(s, fv, fk, z) return gettextsize(s, z) end },
		{ "(text, font)",             function(s, fv) return gettextsize(s, fv) end },
		{ '(text, "FontName")',       function(s, fv, fk) return gettextsize(s, fk) end },
		{ "(text)",                   function(s) return gettextsize(s) end },
	}
	local fallback
	for _, var in ipairs(variants) do
		local ok1, a1, b1 = pcall(var[2], "MMMMMMMM", fontVal, fontKey, size)
		local ok2, a2, b2 = pcall(var[2], "MMMMMMMM", fontVal, fontKey, size * 2)
		local w1 = ok1 and unpackSize(a1, b1) or nil
		local w2 = ok2 and unpackSize(a2, b2) or nil
		if w1 and w1 > 0 then
			if w2 and w2 ~= w1 then
				measureFn = var[2]
				print("[matcha_draw] gettextsize signature detected: " .. var[1])
				return
			end
			fallback = fallback or var
		end
	end
	if fallback then
		measureFn = fallback[2]
		print("[matcha_draw] gettextsize signature (size argument not detected): " .. fallback[1])
	else
		print("[matcha_draw] gettextsize returned nothing usable - text widths will be estimated")
	end
end

local measureObj
local sizeMemo = {}
local sizeMemoCount = 0
function draw.GetTextSize(str, font)
	str = tostring(str)
	local fontVal, size, fontKey = resolveFont(font)
	if str == "" then return 0, size end

	local fkey = font or ""
	local memo = sizeMemo[fkey]
	if not memo then
		memo = {}
		sizeMemo[fkey] = memo
	end
	local hit = memo[str]
	if hit then return hit[1], hit[2] end

	if not measureProbed then probeMeasure(fontVal, fontKey, size) end

	local w, h
	if measureFn then
		local ok, a, b = pcall(measureFn, str, fontVal, fontKey, size)
		if ok then w, h = unpackSize(a, b) end
	end
	if not w or w <= 0 then
		pcall(function()
			if not measureObj then
				measureObj = Drawing.new("Text")
				measureObj.Visible = false
			end
			measureObj.Text = str
			if fontVal ~= nil then measureObj.Font = fontVal end
			measureObj[CONFIG.TextSizeProp] = size
			local bnd = measureObj.TextBounds
			if bnd then w, h = bnd.X, bnd.Y end
		end)
	end
	if not w or w <= 0 then
		w, h = #str * size * 0.5, size -- rough estimate
	end
	h = h or size

	if sizeMemoCount > 512 then
		sizeMemo = {}
		sizeMemoCount = 0
		memo = {}
		sizeMemo[fkey] = memo
	end
	memo[str] = { w, h }
	sizeMemoCount = sizeMemoCount + 1
	return w, h
end

-- ======================================================================
-- Images
-- ======================================================================
-- Serotonin: utility.loadImage(file.read(path)) -> textureId, then draw.Image(textureId, ...)
-- Here:      draw.LoadImage(rawData)            -> textureId, then draw.Image(textureId, ...)
function draw.LoadImage(data)
	if type(data) ~= "string" then return nil end
	nextImageId = nextImageId + 1
	images[nextImageId] = data
	imageKeys[nextImageId] = "Image#" .. nextImageId
	return nextImageId
end

function draw.UnloadImage(id)
	local key = imageKeys[id]
	if not key then return end
	local pool = pools[key]
	if pool then
		for i = 1, #pool do
			local obj = pool[i].obj
			pcall(function() obj:Remove() end)
		end
		pools[key] = nil
	end
	images[id], imageKeys[id] = nil, nil
end

-- r, g, b, a are 0-255 tint/alpha, like Serotonin
function draw.Image(textureId, x, y, w, h, r, g, b, a)
	local key = imageKeys[textureId]
	if not key then return end
	local slot, z = acquire("Image", key)
	set(slot, "Data", images[textureId]) -- set once per pooled object, then cache-hit forever
	setVec(slot, "Position", x, y)
	setVec(slot, "Size", w, h)
	set(slot, "Rounding", 0)
	setColorRGB(slot, (r or 255) / 255, (g or 255) / 255, (b or 255) / 255)
	set(slot, "Transparency", toTransparency(a))
	if CONFIG.AutoZIndex then set(slot, "ZIndex", z) end
	set(slot, "Visible", true)
end

-- ======================================================================
-- Aliases: PascalCase (already), camelCase, snake_case  (matches Serotonin)
-- ======================================================================
local names = {
	"Line", "Rect", "RectFilled", "Circle", "CircleFilled", "Triangle", "TriangleFilled",
	"Gradient", "Polyline", "ConvexPolyFilled", "ComputeConvexHull", "GetPartCorners",
	"Text", "TextOutlined", "GetTextSize", "LoadImage", "UnloadImage", "Image",
	"OnPaint", "Clear", "Shutdown",
}
for _, name in ipairs(names) do
	local fn = draw[name]
	local camel = name:sub(1, 1):lower() .. name:sub(2)
	local snake = (name:gsub("(%l)(%u)", "%1_%2")):lower()
	draw[camel] = fn
	draw[snake] = fn
end

-- ======================================================================
-- Publish as a global
-- ======================================================================
-- Matcha's loadstring() DROPS a chunk's top-level `return` value, so
--     local draw = loadstring(httpget(url))()      --> draw == nil
-- can never work. Instead the library puts itself in the global environment; after
-- loadstring(httpget(url))() just use the global `draw`.
local env = _G or getfenv(0)
local previous = env.draw
if type(previous) == "table" and previous.IsMatchaDraw and previous.Shutdown then
	pcall(previous.Shutdown) -- re-running the script: remove the old clock + old drawings
end
draw.IsMatchaDraw = true
env.draw = draw

-- Start the frame clock NOW (not lazily on the first draw call). If it started mid-frame, that
-- first frame's draws would never be closed out and frame 2 would draw into a second set of
-- slots (double objects + one frame of duplicates).
pcall(startClock)
print("[matcha_draw] loaded - global `draw` is ready")

return draw