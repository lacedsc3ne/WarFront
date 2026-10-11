-- War Front Night menu: Language. Copyright (C) 2026 Liam (lacedsc3ne).
-- Page contract: see NightMenu.Home (PAGES). Same as the old MenuPages.renderLanguage: English only,
-- clicking it closes the page. The card itself lives in the settings page (its Language tab).

local Kit = require(script.Parent.Parent:WaitForChild("Kit"))

return {
	title = "Language",
	render = function(page, ctx)
		local settingsPage = require(script.Parent:WaitForChild("settings")) :: any
		Kit.list(page.body, false, 14)
		settingsPage.languageCard(page.body, 1, function()
			ctx.close()
		end)
	end,
}
