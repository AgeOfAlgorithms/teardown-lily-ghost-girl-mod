-- Lily's options (Mod Manager): how often she acts, whether she kills, the whisper text. In multiplayer the host's
-- first two count; the text is each player's own.

local function pick(label, y, items, cur, set)
	UiPush()
	UiTranslate(0, y)
	UiFont("regular.ttf", 28)
	UiColor(1, 1, 1)
	UiText(label)
	UiTranslate(0, 50)
	UiFont("bold.ttf", 30)
	for i, name in ipairs(items) do
		UiPush()
		UiTranslate((i - (#items + 1) / 2) * 190, 0)
		if i == cur then UiColor(0.75, 0.9, 1) else UiColor(0.55, 0.55, 0.55) end
		if UiTextButton(name, 170, 46) then set(i) end
		UiPop()
	end
	UiPop()
end

function draw()
	local f = GetInt("savegame.mod.freq")
	if f < 1 or f > 3 then f = 2 end
	UiTranslate(UiCenter(), 220)
	UiAlign("center middle")
	UiFont("bold.ttf", 48)
	UiText("Lily")
	pick("How often she acts", 90, {"Rarely", "Sometimes", "Often"}, f, function(i) SetInt("savegame.mod.freq", i) end)
	pick("When she is done playing", 230, {"She hunts", "She only scares"}, GetBool("savegame.mod.nokill") and 2 or 1,
		function(i) SetBool("savegame.mod.nokill", i == 2) end)
	pick("Her whispers as faint text", 370, {"Shown", "Hidden"}, GetBool("savegame.mod.nosubs") and 2 or 1,
		function(i) SetBool("savegame.mod.nosubs", i == 2) end)
	UiTranslate(0, 520)
	UiFont("regular.ttf", 22)
	UiColor(0.7, 0.7, 0.7)
	UiText("The less she does, the less you can tell when.")
	UiTranslate(0, 80)
	UiColor(1, 1, 1)
	UiFont("bold.ttf", 32)
	if UiTextButton("Close", 200, 50) then Menu() end
end
