-- War Front Night menu: Practice (single player). Copyright (C) 2026 Liam (lacedsc3ne).
-- Page contract: see NightMenu.Home (PAGES). Same settings and start call as the old Solo page
-- (net "play", "solo", settings) through LobbyPages.night.

local Kit = require(script.Parent.Parent:WaitForChild("Kit"))
local BattleSettings = require(script.Parent.Parent:WaitForChild("BattleSettings"))
local LobbyPages = require(script.Parent.Parent.Parent:WaitForChild("LobbyPages"))
local make = Kit.make

return {
	title = "Practice",
	render = function(page, ctx)
		local api = LobbyPages.night
		local body = page.body
		Kit.list(body, false, 14)
		local refresh
		LobbyPages.attach("solo", function()
			if refresh then
				refresh()
			end
		end)
		BattleSettings.muted(body, 0, "Just you and computer players. You can pause or speed up the battle any time.")
		local order
		refresh, order = BattleSettings.build(body, 0, {
			api = api,
			editable = true,
			solo = true,
			pool = ctx.mapPool,
			preview = ctx.preview,
			phone = ctx.layout() == "phone",
		})
		local row = make("Frame", { Name = "Actions", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 58), LayoutOrder = order + 1, Parent = body })
		Kit.list(row, true, 10, { VerticalAlignment = Enum.VerticalAlignment.Center, HorizontalAlignment = Enum.HorizontalAlignment.Right })
		Kit.button("secondary", "Reset", { name = "Reset", icon = "Refresh", height = 50, textSize = 18, layoutOrder = 1, parent = row, onActivated = function()
			api.soloReset()
		end })
		local start
		start = Kit.button("primary", "Start practice", {
			name = "StartPractice",
			height = 58,
			textSize = 26,
			padX = 48,
			size = if ctx.layout() == "phone" then UDim2.new(1, -150, 0, 58) else nil,
			layoutOrder = 2,
			parent = row,
			onActivated = function()
				Kit.setButtonText(start, "Starting…")
				api.soloStart()
				task.delay(4, function()
					if start.Parent then
						Kit.setButtonText(start, "Start practice")
					end
				end)
			end,
		})
	end,
}
