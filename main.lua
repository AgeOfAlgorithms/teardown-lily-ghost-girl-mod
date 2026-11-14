#version 2
-- Lily: a little ghost girl who haunts any map (a global mod; ../../PROJECT.md). The modules are global tables of
-- callbacks: Ghost (her mind, server), GhostView (what each machine sees and hears). GHOST_PARTS / GHOST_SOUNDS are
-- generated.

#include "ghostparts.lua"
#include "ghostsounds.lua"
#include "ghost.lua"
#include "ghostview.lua"

-- (test builds add their modules here)

function server.init()
	math.randomseed(GetInt("savegame.mod.seed") + 1)
	SetInt("savegame.mod.seed", (GetInt("savegame.mod.seed") + 7919) % 100000)
	Ghost.serverInit()
	if LILY_TEST then LILY_TEST.serverInit() end
end

function server.tick(dt)
	Ghost.serverTick(dt)
	if LILY_TEST then LILY_TEST.serverTick(dt) end
end

function server.update(dt)
	Ghost.serverUpdate(dt)
end

function client.init()
	GhostView.clientInit()
	if LILY_TEST then LILY_TEST.clientInit() end
end

function client.tick(dt)
	GhostView.clientTick(dt)
	if LILY_TEST then LILY_TEST.clientTick(dt) end
end

function client.postUpdate()
	GhostView.clientPostUpdate()
end

function client.draw()
	GhostView.clientDraw()
	if LILY_TEST then LILY_TEST.clientDraw() end
end
