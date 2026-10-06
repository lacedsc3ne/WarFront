--[[
	War Front - in-match menu (settings, help, terrain view, store, stats, main menu, exit).
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	(client/hud/layers/SettingsModal.ts rows, drawn in the o-modal look of
	components/baseComponents/Modal.ts + components/ui/ModalHeader.ts like the main menu pages).
	Modified version re-implemented in Luau for Roblox; not affiliated with or endorsed by OpenFront.
]]

-- StarterPlayer.StarterPlayerScripts.PauseMenu (ModuleScript), required by MainMenu and HudSidebars.
-- The in-game gear button (HudSidebars), the MENU button and gamepad Start open this menu during
-- a round. It is an OpenFront modal: round back button + uppercase title, then rows. Settings,
-- Help, Store and Stats open the same pages as the main menu (MenuPages) inside the modal; the
-- back button returns to the menu rows.
-- PauseMenu.init(ctx)   ctx.showMainMenu(), ctx.isMainMenuOpen() -> boolean, ctx.onLeave()
-- PauseMenu.open(), PauseMenu.close(), PauseMenu.isOpen(), PauseMenu.showMainMenu()
-- The match keeps running (it's multiplayer): PlayerGui attribute FrontlinesMenuOpen = true while
-- open so the gamepad match controls stop.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local ContextActionService = game:GetService("ContextActionService")

local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
local net = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Net")
local DeviceLayout = require(script.Parent:WaitForChild("DeviceLayout"))
local MenuKit = require(script.Parent:WaitForChild("MenuKit"))
local MenuPages = require(script.Parent:WaitForChild("MenuPages"))
local Replay = require(script.Parent:WaitForChild("Replay"))
local Place = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Place"))

local F = MenuKit.F

local PauseMenu = {}

local ctx = {
	showMainMenu = function() end,
	isMainMenuOpen = function(): boolean
		return false
	end,
	onLeave = function() end,
}

local B_ACTION = "FrontlinesPauseB"

local gui = Instance.new("ScreenGui")
gui.Name = "FrontlinesPause"
gui.DisplayOrder = 15 -- over the match and main menu (10), under the store window (FrontlinesMeta, 20)
gui.IgnoreGuiInset = true
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Enabled = false
gui.Parent = playerGui

local modal = MenuKit.modal(gui, "Panel")
local page = modal.page

local view = "main" -- "main" or a MenuPages kind
local altView = false
local leaveArmed = 0
local lastRow: GuiObject? = nil -- (reserved: row that opened the current sub page)

local function selectIfGamepad(obj: GuiObject?)
	if obj and DeviceLayout.usingGamepad() then
		task.defer(function()
			if gui.Enabled and obj.Visible and obj:IsDescendantOf(gui) then
				GuiService.SelectedObject = obj
			end
		end)
	end
end

local function setAltView(on: boolean)
	altView = on
	pcall(function()
		require(script.Parent:WaitForChild("MapRender")).setAltView(on)
	end)
end

local pageCtx = {
	toast = function(_msg: string) end,
	startTutorial = function()
		PauseMenu.close()
		-- false -> true so the tutorial restarts from step 1 even if it is already showing.
		playerGui:SetAttribute("FrontlinesTutorial", false)
		playerGui:SetAttribute("FrontlinesTutorial", true)
	end,
	getProfile = function()
		return MenuPages.getProfile()
	end,
	close = function()
		PauseMenu.close()
	end,
}

local renderMain

local function openSub(kind: string, from: GuiObject?)
	lastRow = from
	view = kind
	MenuPages.render(kind, page, pageCtx)
	page.body.CanvasPosition = Vector2.zero
	modal.layout()
	selectIfGamepad(page.back)
end

local function exitGame()
	net:FireServer("leave")
	PauseMenu.close()
	ctx.onLeave()
end

renderMain = function()
	view = "main"
	page:setTabs({})
	page:clear()
	page.title.Text = "MENU"
	local coins = page.header:FindFirstChild("StoreCoins")
	if coins then
		coins.Visible = false
	end
	page.storeShowing = false
	local body = page.body
	local resume = MenuKit.button("primary", { Name = "Resume", LayoutOrder = 1, Size = UDim2.new(1, 0, 0, 52), FontFace = F.BOLD, TextSize = 18, Text = "RESUME", Parent = body })
	resume.Activated:Connect(PauseMenu.close)

	-- SettingsModal rows (settings, toggle terrain, exit) plus help / store / stats / main menu.
	local settingsRow = MenuKit.navRow(body, 2, "Gear", "Settings", "Gameplay, graphics, audio and keybind settings")
	settingsRow.Activated:Connect(function()
		openSub("settings", settingsRow)
	end)
	local terrainRow, terrainValue = MenuKit.navRow(body, 3, "Layout", "Toggle Terrain", "Alternate view (terrain/countries)")
	terrainValue.Text = if altView then "On" else "Off"
	terrainRow.Activated:Connect(function()
		setAltView(not altView)
		terrainValue.Text = if altView then "On" else "Off"
	end)
	local helpRow = MenuKit.navRow(body, 4, "Help", "Help", "Hotkeys, controller and touch controls, tutorial")
	helpRow.Activated:Connect(function()
		openSub("help", helpRow)
	end)
	local storeRow = MenuKit.navRow(body, 5, "Building", "Store", "Territory colours, passes and medals")
	storeRow.Activated:Connect(function()
		openSub("store", storeRow)
	end)
	local statsRow = MenuKit.navRow(body, 6, "User", "Stats", "Level, wins and record")
	statsRow.Activated:Connect(function()
		openSub("profile", statsRow)
	end)
	if Replay.available() then
		local replayRow = MenuKit.navRow(body, 7, "PlayTri", "Watch Replay", "Watch the last round again")
		replayRow.Activated:Connect(function()
			PauseMenu.close()
			Replay.start()
		end)
	end
	-- A live match server has no main menu of its own (the menu is the lobby place): only Exit Game.
	if Place.role() ~= "match" or game:GetService("RunService"):IsStudio() then
		local menuRow = MenuKit.navRow(body, 8, "Menu", "Main Menu", "Maps, voting and news (the battle keeps going)")
		menuRow.Activated:Connect(function()
			PauseMenu.close()
			ctx.showMainMenu()
		end)
	end
	local exitRow, exitValue = MenuKit.navRow(body, 9, "X", "Exit Game", "Return to main menu", true)
	exitRow.Activated:Connect(function()
		-- First press arms it; a second press within 3 s leaves (OpenFront asks to confirm).
		if exitValue.Text == "" then
			leaveArmed += 1
			local token = leaveArmed
			exitValue.Text = "Press again"
			task.delay(3, function()
				if leaveArmed == token and exitValue.Parent then
					exitValue.Text = ""
				end
			end)
			return
		end
		exitGame()
	end)
	modal.layout()
	selectIfGamepad(lastRow and lastRow.Parent and lastRow or resume)
	lastRow = nil
end

local function back()
	if view ~= "main" then
		renderMain()
	else
		PauseMenu.close()
	end
end
modal.onBack = back
modal.onClose = function()
	if gui.Enabled then
		PauseMenu.close()
	end
end

function PauseMenu.isOpen(): boolean
	return gui.Enabled
end

function PauseMenu.close()
	if not gui.Enabled then
		return
	end
	gui.Enabled = false
	modal.close()
	playerGui:SetAttribute("FrontlinesMenuOpen", false)
	ContextActionService:UnbindAction(B_ACTION)
	local sel = GuiService.SelectedObject
	if sel and sel:IsDescendantOf(gui) then
		GuiService.SelectedObject = nil
	end
end

function PauseMenu.open()
	if gui.Enabled or ctx.isMainMenuOpen() then
		return
	end
	gui.Enabled = true
	modal.open()
	playerGui:SetAttribute("FrontlinesMenuOpen", true)
	ContextActionService:BindActionAtPriority(B_ACTION, function(_name, inputState)
		if inputState == Enum.UserInputState.Begin then
			back()
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value + 30, Enum.KeyCode.ButtonB)
	lastRow = nil
	renderMain()
end

-- The win modal's "Exit Game" (MatchHud): leave the match (a match server sends us to the lobby).
function PauseMenu.exitGame()
	exitGame()
end

function PauseMenu.showMainMenu()
	PauseMenu.close()
	ctx.showMainMenu()
end

function PauseMenu.init(c)
	for k, v in c do
		(ctx :: any)[k] = v
	end
end

-- Esc: back / close (keyboard players).
UserInputService.InputBegan:Connect(function(input)
	if gui.Enabled and input.KeyCode == Enum.KeyCode.Escape and not UserInputService:GetFocusedTextBox() then
		back()
	end
end)

DeviceLayout.attachScreenGui(gui)
DeviceLayout.Changed:Connect(function()
	if gui.Enabled then
		modal.layout()
	end
end)

return PauseMenu
