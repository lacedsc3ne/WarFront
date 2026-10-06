--[[
	War Front - in-match interaction modules, wired up in one place.
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	Modified version re-implemented in Luau for Roblox; not affiliated with or endorsed by OpenFront.
]]

-- StarterPlayer.StarterPlayerScripts.Interact (ModuleScript), used by GameClient (one local there).
--   Interact.radial  RadialMenu   right-click / long-press / gamepad X menu
--   Interact.panel   PlayerPanel  player info panel, send troops / gold, emoji table
--   Interact.hud     MatchHud     attacks display, spawn timer, heads-up message, win modal, emojis
--   Interact.keys    Keybinds     OpenFront keyboard shortcuts
--   Interact.build   BuildMenu    Ctrl + click build grid, build / upgrade rules
--   Interact.chat    QuickChat    quick chat modal + incoming chat lines
--   Interact.side    HudSidebars  top-right timer / settings / exit, immunity bar, in-game menu
-- Interact.setup(ctx) passes one context table (see each module's header for the fields it reads).
-- Interact.openMenu(sx, sy, tile, startIn?) opens the radial menu (openContextMenuAt).

local Interact = {}

Interact.radial = require(script.Parent:WaitForChild("RadialMenu"))
Interact.panel = require(script.Parent:WaitForChild("PlayerPanel"))
Interact.hud = require(script.Parent:WaitForChild("MatchHud"))
Interact.keys = require(script.Parent:WaitForChild("Keybinds"))
Interact.build = require(script.Parent:WaitForChild("BuildMenu"))
Interact.chat = require(script.Parent:WaitForChild("QuickChatMenu"))
Interact.side = require(script.Parent:WaitForChild("HudSidebars"))

local ready = false

function Interact.setup(ctx)
	ctx.playerPanel = Interact.panel
	ctx.buildMenu = Interact.build
	ctx.quickChat = Interact.chat
	ctx.toast = ctx.toast or Interact.hud.toast
	ctx.exitGame = ctx.exitGame
		or function()
			local ok, PauseMenu = pcall(require, script.Parent:WaitForChild("PauseMenu", 5))
			if ok and PauseMenu and PauseMenu.exitGame then
				PauseMenu.exitGame() -- "leave": back to the lobby place (Studio: the menu)
			end
		end
	Interact.build.setup(ctx)
	Interact.chat.setup(ctx)
	Interact.panel.setup(ctx)
	Interact.radial.setup(ctx)
	Interact.hud.setup(ctx)
	Interact.keys.setup(ctx)
	Interact.side.setup(ctx)
	ready = true
end

function Interact.openMenu(sx: number, sy: number, tile: number, startIn: string?)
	if ready then
		Interact.radial.open(sx, sy, tile, startIn)
	end
end

-- Ctrl + click (OpenFront buildMenuModifier): the build menu grid for that tile.
function Interact.openBuildMenu(tile: number)
	if ready then
		Interact.radial.close()
		Interact.build.show(tile)
	end
end

return Interact
