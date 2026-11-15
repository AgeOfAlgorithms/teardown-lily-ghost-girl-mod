-- Ghost: Lily's mind (server; PROJECT.md). She is plain data here - a position, a look, who can see her - that every
-- client draws for itself (ghostview.lua). The loop: dormant -> a scene somewhere out of sight (playing, crying,
-- roaming) -> whoever finds her (or whoever she finds) is haunted for a few minutes by events at uneven intervals
-- -> her laughter turns into a cackle and she hunts -> a kill (or she gives up) -> calm, and all over again.
-- She has no body: she passes through walls and objects and breaks nothing. Shooting or hitting her does no harm
-- to her: she vanishes and comes back somewhere around whoever did it, never closer than BLINK_MIN.

Ghost = {}

LILY_LAYER = 64               -- her hit box's collision layer (the Abyssipede's too): out of every player's mask
LILY_QUERY_MASK = 63          -- our queries skip that layer and Dive's fish (128)
LILY_PUBLISH_HZ = 15
LILY_HEAD = 0.95              -- m above her feet: where players look at her
BLINK_MIN, BLINK_MAX = 7, 11  -- m: how near a player she may reappear in a hunt or after a hit (the user's rule)
CATCH_D = 1.25                -- m: she has you
SIGHT_R = 40                  -- m: how far she sees (a clear line; behind her only within 6 m)
HEAR_RUN = 12                 -- m: she hears anyone moving faster than 3.5 m/s this near
HEAR_PER_VOL = 45             -- m per unit of GetLastSound volume (steps 0.05, a dropped crate 0.2, a shot 0.5), 60 m at most
KILL_TIME = 1.6               -- s: the kill, from her hands on you to your death
LILY_DAY_LIGHT = 0.45         -- Day & Night's daylight (0 night .. 0.88 full sun) from which on she keeps away
LILY_ANYTIME = false          -- (the AUTO TEST copy sets it: its staged scenes run by day)

-- how often things happen: Options (savegame.mod.freq 1 rare, 2 normal, 3 often) scales every waiting time
LILY_FREQ = {1.7, 1.0, 0.55}

-- tools that only reach her from close up; anything else (guns, launchers, other mods' weapons) counts at range
LILY_MELEE = {sledge = true, spraycan = true, extinguisher = true, blowtorch = true, plank = true, wire = true, leafblower = true,
	none = true, [""] = true}

LILY_WHISPERS = {"play with me", "i see you", "don't turn around", "found you", "why did you leave me", "it's so cold",
	"are you scared", "let's play a game", "behind you", "stay with me", "one... two... three...", "ready or not",
	"you can't hide", "shhh", "mine"}

local function rnd(a, b) return a + math.random() * (b - a) end
local function dist(a, b) return VecLength(VecSub(a, b)) end
local function hdist(a, b) local x, z = a[1] - b[1], a[3] - b[3]; return math.sqrt(x * x + z * z) end
local function yawOf(d) return math.deg(math.atan2(d[1], d[3])) end
local function rotY(v, deg)
	local a = math.rad(deg); local c, s = math.cos(a), math.sin(a)
	return Vec(v[1] * c + v[3] * s, v[2], -v[1] * s + v[3] * c)
end
local function flat(v)
	local l = math.sqrt(v[1] * v[1] + v[3] * v[3])
	if l < 1e-4 then return Vec(0, 0, 1) end
	return Vec(v[1] / l, 0, v[3] / l)
end

----- the world: rays, ground, players -----

local function ray(o, d, len)
	QueryRequire("physical static")
	QueryCollisionMask(LILY_QUERY_MASK)
	return QueryRaycast(o, d, len)
end

function lyLos(a, b)
	local d = VecSub(b, a)
	local l = VecLength(d)
	if l < 0.05 then return true end
	local hit = ray(a, VecScale(d, 1 / l), l)
	return not hit
end

-- the ground under p: a ray from `up` above it, `down` below it at most
function lyGround(p, up, down)
	local hit, d = ray(Vec(p[1], p[2] + up, p[3]), Vec(0, -1, 0), up + down)
	if hit and d > 0.05 then return Vec(p[1], p[2] + up - d, p[3]) end
	return nil
end

-- room for her to stand on ground point g, out of water
function lyStandable(g)
	QueryRequire("physical static")
	QueryCollisionMask(LILY_QUERY_MASK)
	if QueryClosestPoint(Vec(g[1], g[2] + 0.75, g[3]), 0.3) then return false end
	if IsPointInWater(Vec(g[1], g[2] + 0.6, g[3])) then return false end
	return true
end

function lyPlayers()
	local out = {}
	for _, p in ipairs(GetAllPlayers()) do
		if GetPlayerHealth(p) > 0 then out[#out + 1] = p end
	end
	return out
end

local function alive(p) return p and p ~= 0 and IsPlayerValid(p) and GetPlayerHealth(p) > 0 end
local function feet(p) return GetPlayerTransform(p).pos end
local function eye(p) return GetPlayerEyeTransform(p) end
local function eyeFwd(p) return TransformToParentVec(eye(p), Vec(0, 0, -1)) end

-- does player p have `point` in front of them (cos of the half angle) with nothing in the way?
function lySees(p, point, cone)
	local e = eye(p)
	local d = VecSub(point, e.pos)
	local l = VecLength(d)
	if l < 0.3 then return true end
	if VecDot(eyeFwd(p), d) / l < (cone or 0.5) then return false end
	return lyLos(e.pos, point)
end

local function head(g) return Vec(g[1], g[2] + LILY_HEAD, g[3]) end

local function nearestPlayer(pos, list)
	local best, bd = 0, 1e9
	for _, p in ipairs(list or lyPlayers()) do
		local d = dist(feet(p), pos)
		if d < bd then best, bd = p, d end
	end
	return best, bd
end

local function farFromAll(g, d)
	for _, p in ipairs(lyPlayers()) do
		if dist(feet(p), g) < d then return false end
	end
	return true
end

local function unseen(g)
	for _, p in ipairs(lyPlayers()) do
		if lySees(p, head(g), 0.25) then return false end
	end
	return true
end

----- her senses: sight and sound -----

-- what she hears this tick: the loudest sound of the frame (her own are not registered) and anything said through
-- Proximity Comms (proxchat.said.*), when it is near enough for how loud it was. ly.sound = {pos, who, t}
function lyListen()
	if ly.sound and ly.T - ly.sound.t > 0.5 then ly.sound = nil end
	if not ly.vis then return end
	local h = head(ly.pos)
	local vol, pos = GetLastSound()
	if vol and vol > 0.03 and pos and dist(pos, h) < math.min(60, vol * HEAR_PER_VOL) then
		local who, wd = nearestPlayer(pos)
		ly.sound = {pos = VecCopy(pos), who = (who ~= 0 and wd < 8) and who or 0, t = ly.T}
	end
	local last = GetInt("proxchat.said.last")
	if last ~= ly.saidSeen then
		if last > ly.saidSeen and last - ly.saidSeen <= 16 then
			for n = ly.saidSeen + 1, last do
				local k = "proxchat.said." .. (n % 16)
				local p = GetInt(k .. ".player")
				local sp = Vec(GetFloat(k .. ".x"), GetFloat(k .. ".y"), GetFloat(k .. ".z"))
				if alive(p) and dist(sp, h) < math.max(4, GetFloat(k .. ".radius")) then ly.sound = {pos = sp, who = p, t = ly.T} end
			end
		end
		ly.saidSeen = last
	end
end

-- does she know where player p is right now: seen (a clear line within `sight`, in front of her or close) or heard
-- (running nearby, or the one who made the sound she just heard)
function lySensePlayer(p, sight)
	local e = eye(p).pos
	local h = head(ly.pos)
	local d = dist(e, h)
	if d < 3 then return true end
	if d < (sight or SIGHT_R) and lyLos(h, e) then
		if d < 6 or VecDot(rotY(Vec(0, 0, 1), ly.yaw), VecNormalize(VecSub(e, h))) > -0.2 then return true end
	end
	if d < HEAR_RUN and VecLength(GetPlayerVelocity(p)) > 3.5 then return true end
	if ly.sound and ly.sound.who == p then return true end
	return false
end

----- where she can be -----

-- a spot rmin..rmax from player p that nobody is looking at: where players have walked before, or open ground
function lyPickHidden(p, rmin, rmax)
	local f = feet(p)
	local cands = {}
	local n = #ly.crumbs
	for i = 1, math.min(n, 25) do
		local c = ly.crumbs[math.random(n)]
		local d = dist(c, f)
		if d >= rmin and d <= rmax then cands[#cands + 1] = c end
	end
	for i = 1, 20 do
		local a = math.random() * 360
		local d = rnd(rmin, rmax)
		local dir = rotY(Vec(0, 0, 1), a)
		local g = lyGround(Vec(f[1] + dir[1] * d, f[2] + rnd(-1, 4), f[3] + dir[3] * d), 2, 10)
		if g then cands[#cands + 1] = g end
	end
	for _, g in ipairs(cands) do
		if farFromAll(g, rmin) and lyStandable(g) and unseen(g) then return VecCopy(g) end
	end
	return nil
end

-- a spot in front of player p, in plain sight, dmin..dmax away
function lyPickInView(p, dmin, dmax)
	local e = eye(p)
	local f = flat(eyeFwd(p))
	for i = 1, 10 do
		local d = rotY(f, rnd(-28, 28))
		local want = rnd(dmin, dmax)
		local hit, hd = ray(e.pos, d, want + 1.2)
		local dd = hit and (hd - 1.2) or want
		if dd >= dmin then
			local g = lyGround(VecAdd(e.pos, VecScale(d, dd)), 0.5, 6)
			if g and lyStandable(g) and lyLos(e.pos, head(g)) and farFromAll(g, dmin * 0.7) then return g end
		end
	end
	return nil
end

-- a spot behind player p (rmin..rmax) that they will see when they turn
function lyPickBehind(p, rmin, rmax)
	local f = feet(p)
	local back = VecScale(flat(eyeFwd(p)), -1)
	for i = 1, 10 do
		local d = rotY(back, rnd(-50, 50))
		local r = rnd(rmin, rmax)
		local g = lyGround(Vec(f[1] + d[1] * r, f[2], f[3] + d[3] * r), 1.2, 2.5)
		if g and lyStandable(g) and lyLos(head(g), eye(p).pos) then return g end
	end
	return nil
end

-- somewhere on a ring round player p: standable if there is such a place, else just there (she is a ghost)
function lyPickRing(p, rmin, rmax, hidden)
	local f = feet(p)
	local fallback = nil
	for i = 1, 14 do
		local d = rotY(Vec(0, 0, 1), math.random() * 360)
		local r = rnd(rmin, rmax)
		local q = Vec(f[1] + d[1] * r, f[2], f[3] + d[3] * r)
		local g = lyGround(q, 2, 4)
		if g and lyStandable(g) and farFromAll(g, rmin) then
			if not hidden or not lySees(p, head(g), 0.3) then return g end
			fallback = fallback or g
		end
	end
	if fallback then return fallback end
	local d = rotY(Vec(0, 0, 1), math.random() * 360)
	return Vec(f[1] + d[1] * rmin, f[2], f[3] + d[3] * rmin)
end

----- what the clients are told -----

function lyPublish()
	ly.seq = ly.seq + 1
	ly.pubT = ly.T
	shared.lily = {n = ly.seq, vis = ly.vis, x = ly.pos[1], y = ly.pos[2], z = ly.pos[3], yaw = ly.yaw, anim = ly.anim,
		face = ly.face, only = ly.only, look = ly.look, state = ly.state, speed = ly.speed}
end

-- (ClientCall needs its function name as a string literal: every effect goes through this one)
function lyFx(p, kind, a, b, c, d, e)
	ClientCall(p, "client.lilyFx", kind, a or 0, b or 0, c or 0, d or 0, e or 0)
end

function lyVoice(kind, pos, vol) lyFx(0, "voice", kind, pos[1], pos[2] + LILY_HEAD, pos[3], vol or 1) end
function lyEar(p, kind, text) lyFx(p, "ear", kind, math.random() < 0.5 and -1 or 1, math.random(), text or "") end

function lyAppear(pos, anim, o)
	o = o or {}
	ly.pos = VecCopy(pos)
	ly.vis = true
	ly.anim = anim or "stand"
	ly.face = o.face or 0
	ly.only = o.only or 0
	ly.look = o.look or 0
	ly.speed = 0
	ly.seen = {}
	if o.yaw then ly.yaw = o.yaw elseif o.look and o.look ~= 0 and alive(o.look) then ly.yaw = yawOf(VecSub(feet(o.look), pos)) end
	lyPublish()
end

function lyVanish()
	if not ly.vis then return end
	ly.vis = false
	ly.look = 0
	ly.speed = 0
	lyPublish()
end

-- glide toward goal at speed: straight, through anything; her feet follow the ground when there is some
function lyMove(dt, goal, speed)
	local d = VecSub(goal, ly.pos)
	local h = math.sqrt(d[1] * d[1] + d[3] * d[3])
	local step = math.min(speed * dt, h)
	if h > 0.01 then
		ly.pos[1] = ly.pos[1] + d[1] / h * step
		ly.pos[3] = ly.pos[3] + d[3] / h * step
		ly.yaw = yawOf(d)
	end
	local g = lyGround(ly.pos, 1.2, 2.5)
	local ty, rate = goal[2], 2
	if g then ty, rate = g[2], 5 end
	local dy = ty - ly.pos[2]
	local m = rate * dt
	if dy > m then dy = m elseif dy < -m then dy = -m end
	ly.pos[2] = ly.pos[2] + dy
	ly.speed = speed
	return h - step
end

----- the omens: lights flicker and go out, loose things rise -----

function lyScanLights()
	local skip = {}
	for _, p in ipairs(GetAllPlayers()) do skip[GetFlashlight(p)] = true end
	ly.lights = {}
	for _, l in ipairs(FindLights(nil, true) or {}) do
		if not skip[l] then ly.lights[#ly.lights + 1] = {h = l, pos = GetLightTransform(l).pos} end
	end
	ly.lightsT = ly.T
end

-- lights within r of c flicker for `flick` seconds, then stay out for `off` more
function lyDarken(c, r, flick, off)
	if not ly.lights or ly.T - ly.lightsT > 30 then lyScanLights() end
	local n = 0
	for _, L in ipairs(ly.lights) do
		if n >= 24 then break end
		if IsHandleValid(L.h) and dist(L.pos, c) < r then
			local e = ly.dark[L.h]
			if e then
				e.flick = math.max(e.flick, ly.T + flick)
				e.off = math.max(e.off, ly.T + flick + (off or 0))
				n = n + 1
			elseif IsLightActive(L.h) then
				ly.dark[L.h] = {flick = ly.T + flick, off = ly.T + flick + (off or 0), next = 0, on = true}
				n = n + 1
			end
		end
	end
	return n
end

function lyDarkTick()
	for h, e in pairs(ly.dark) do
		if not IsHandleValid(h) then
			ly.dark[h] = nil
		elseif ly.T >= e.off then
			SetLightEnabled(h, true)
			ly.dark[h] = nil
		elseif ly.T >= e.flick then
			if e.on then SetLightEnabled(h, false); e.on = false end
		elseif ly.T >= e.next then
			e.on = not e.on
			SetLightEnabled(h, e.on)
			e.next = ly.T + (e.on and rnd(0.03, 0.12) or rnd(0.05, 0.35))
		end
	end
end

function lyRestoreLights()
	for h, e in pairs(ly.dark) do
		if IsHandleValid(h) then SetLightEnabled(h, true) end
	end
	ly.dark = {}
end

-- loose things within r of c rise and hang in the air for dur seconds (fling: thrown at whoever is nearest after)
-- Bodies a player holds, or is grabbing right now (aiming at it with the grab button down: the frame a grab starts).
-- Merely aiming at a floating thing changes nothing. Writing the velocity of a body a player grabs has crashed the
-- game (the user, other mods): such a body is let go at once and never touched again.
function lyHeld(players)
	local held = {}
	for _, p in ipairs(players or lyPlayers()) do
		local g, k = GetPlayerGrabBody(p), GetPlayerPickBody(p)
		if g ~= 0 then held[g] = true end
		if k ~= 0 and InputDown("grab", p) then held[k] = true end
	end
	return held
end

function lyLevitate(c, r, dur, fling)
	local count = 0
	for _ in pairs(ly.float) do count = count + 1 end
	local players = lyPlayers()
	local held = lyHeld(players)
	QueryRequire("physical dynamic")
	local list = QueryAabbBodies(Vec(c[1] - r, c[2] - 1.5, c[3] - r), Vec(c[1] + r, c[2] + 2.5, c[3] + r))
	for _, b in ipairs(list) do
		if count >= 10 then break end
		if not ly.float[b] and not held[b] and IsBodyDynamic(b) and GetBodyVehicle(b) == 0 and math.random() < 0.8 then
			local m = GetBodyMass(b)
			local pos = GetBodyTransform(b).pos
			local _, pd = nearestPlayer(pos, players)
			if m > 0.3 and m < 500 and pd > 1.2 then
				ly.float[b] = {y = pos[2] + rnd(0.5, 1.5), start = ly.T + rnd(0, 0.8), stop = ly.T + dur + rnd(-0.5, 0.5), fling = fling,
					spin = Vec(rnd(-1.2, 1.2), rnd(-1.2, 1.2), rnd(-1.2, 1.2)), ph = rnd(0, 6)}
				count = count + 1
			end
		end
	end
	return count
end

function lyFloatUpdate()
	if next(ly.float) == nil then return end
	local held = lyHeld()
	for b, e in pairs(ly.float) do
		if not IsHandleValid(b) or held[b] then          -- (held: hands off, it drops)
			ly.float[b] = nil
		elseif ly.T >= e.stop then
			if e.fling then
				local pos = GetBodyTransform(b).pos
				local p = nearestPlayer(pos)
				if p ~= 0 then
					local d = VecNormalize(VecSub(eye(p).pos, pos))
					SetBodyVelocity(b, VecAdd(VecScale(d, rnd(5, 8)), Vec(0, 1.5, 0)))
				end
			end
			ly.float[b] = nil
		elseif ly.T >= e.start then
			SetBodyActive(b, true)
			local pos = GetBodyTransform(b).pos
			local v = GetBodyVelocity(b)
			local vy = (e.y - pos[2]) * 2.5 + 0.25 * math.sin(ly.T * 1.7 + e.ph)
			if vy > 1.6 then vy = 1.6 elseif vy < -1.6 then vy = -1.6 end
			SetBodyVelocity(b, Vec(v[1] * 0.9, vy, v[3] * 0.9))
			SetBodyAngularVelocity(b, e.spin)
		end
	end
end

-- the signs that she is near: lights, loose things, the flashlights of everyone close by
function lyOmen(c, r, dur, o)
	o = o or {}
	lyDarken(c, r + 6, dur, o.off or 0)
	if not o.nofloat then lyLevitate(c, r, dur + rnd(0, 1.5), o.fling) end
	for _, p in ipairs(lyPlayers()) do
		if dist(feet(p), c) < r + 6 and math.random() < (o.flash or 0.6) then lyFx(p, "flash", rnd(0.6, dur)) end
	end
end

----- her hit box, and being shot at -----

function lyHitSpawn()
	local ents = Spawn("<body tags='lilyhit'><voxbox tags='invisible unbreakable' pos='-0.25 0 -0.25' size='5 12 5' color='0 0 0'/></body>",
		Transform(Vec(0, -600, 0)))
	for _, e in ipairs(ents or {}) do
		if GetEntityType(e) == "body" then
			ly.hitBody = e
			for _, s in ipairs(GetBodyShapes(e)) do
				SetShapeCollisionFilter(s, LILY_LAYER, 0)
				ly.hitShape = s
			end
		end
	end
end

-- who did it: the player aiming most nearly at the point
local function shooterOf(point)
	local best, bc = 0, -2
	for _, p in ipairs(lyPlayers()) do
		local d = VecSub(point, eye(p).pos)
		local l = VecLength(d)
		local c = l > 0.01 and VecDot(eyeFwd(p), d) / l or 1
		if c > bc then best, bc = p, c end
	end
	return best
end

function lyHitScan()
	local who = 0
	for i = 1, GetEventCount("projectilehit") do
		local shape, point = GetEvent("projectilehit", i)
		if shape == ly.hitShape and point then who = shooterOf(point) end
	end
	for i = 1, GetEventCount("explosion") do
		local point, strength = GetEvent("explosion", i)
		if point and dist(point, head(ly.pos)) < 2.5 + 2 * (strength or 1) then who = nearestPlayer(point) end
	end
	-- a tool used with her in its line: a gun at any range, a hand tool from close up. (Bullets pass through her
	-- box - a shape with mask 0 lets them through, seen in-game - and a box they could hit would also shove loose
	-- things about: so it is the aim that counts.)
	if who == 0 then
		for _, p in ipairs(lyPlayers()) do
			if InputDown("usetool", p) then
				local reach = LILY_MELEE[GetPlayerTool(p)] and 2.8 or 80
				local e, f = eye(p).pos, eyeFwd(p)
				for _, hgt in ipairs({0.25, 0.65, 1.0}) do
					local c = Vec(ly.pos[1], ly.pos[2] + hgt, ly.pos[3])
					local d = VecSub(c, e)
					local along = VecDot(d, f)
					if along > 0 and along < reach and VecLength(VecSub(d, VecScale(f, along))) < 0.4 + 0.012 * along and lyLos(e, c) then who = p end
				end
			end
		end
	end
	if who ~= 0 then lyHit(who) end
end

-- shot or struck: no harm done. She is gone, and a moment later she is somewhere round whoever did it.
function lyHit(p)
	ly.hits = ly.hits + 1
	lyFx(0, "puff", ly.pos[1], ly.pos[2] + 0.6, ly.pos[3])
	lyVanish()
	ly.blink = {t = ly.T + rnd(0.35, 1.0), p = p}
end

function lyBlinkTick()
	local b = ly.blink
	if not b or ly.T < b.t then return end
	ly.blink = nil
	if not alive(b.p) then b.p = nearestPlayer(ly.pos) end
	if b.p == 0 then lySleep(rnd(30, 60)); return end
	local g = lyPickRing(b.p, BLINK_MIN, BLINK_MAX, math.random() < 0.6)
	if ly.state == "hunt" then
		if math.random() < 0.6 then ly.hunt.target = b.p end
		lyAppear(g, "stand", {face = 1, look = b.p})
		ly.hunt.tempoT = ly.T + rnd(0.2, 0.7)                         -- (a beat standing there, then on again)
		ly.hunt.gait, ly.hunt.gaitSpeed = "stand", 0
		ly.hunt.known = VecCopy(feet(b.p)); ly.hunt.lastSeen = VecCopy(ly.hunt.known); ly.hunt.sensedT = ly.T   -- (a shot gives the shooter away)
	else                                                              -- found, the hard way: a stare, then the haunting
		lyAddTarget(b.p)
		lyAppear(g, "stand", {look = b.p})
		ly.state = "scene"
		ly.act = {kind = "stare", p = b.p, stop = ly.T + rnd(1.2, 2.4), angry = true}
	end
end

----- the phases -----

local function F() return LILY_FREQ[ly.freq] or 1 end

function lySleep(seconds)
	lyVanish()
	ly.state = "dormant"
	ly.act = nil
	ly.hunt = nil
	ly.wake = ly.T + seconds
	ly.dayPass = false
	lyPublish()
end

-- Her hours (the user, 2026-11-14), Options "When she is about" (savegame.mod.when): 1 any time (the default), 2 night
-- only, 3 day only. Night = Day & Night's night and the twilight round it, daylight under LILY_DAY_LIGHT (about 17:30 to
-- 6:40 on its clock); day = the rest. Without Day & Night, or while it stands down, any time whatever the option (a map's
-- own sky has no clock). Its keys (daynight/mods/daynight/API.md) are synced, updated once a second.
function lyHerHours()
	if LILY_ANYTIME or ly.when < 2 or not GetBool("daynight.present") or not GetBool("daynight.active") then return true end
	local night = GetBool("daynight.night") or GetFloat("daynight.light") < LILY_DAY_LIGHT
	if ly.when == 2 then return night end
	return not night
end

-- once a second: when her hours begin her waiting starts over (never the moment it gets dark); when they end she is
-- gone, whatever she was doing (a kill in progress ends first). A Lily called by a spawn-menu flag (or a command) has a
-- day pass: she plays her round out by day and keeps the sun's hours after that.
function lyHoursTick()
	if ly.T < ly.hourT then return end
	ly.hourT = ly.T + 1
	local ok = lyHerHours()
	if ok and not ly.hours then ly.wake = math.max(ly.wake, ly.T + rnd(20, 90) * F()) end
	ly.hours = ok
	if not ok and not ly.dayPass and ly.state ~= "dormant" and ly.state ~= "kill" then
		if ly.vis then lyFx(0, "puff", ly.pos[1], ly.pos[2] + 0.6, ly.pos[3]) end
		lyRestoreLights()
		lySleep(30)
	end
end

function lyAddTarget(p)
	for _, q in ipairs(ly.targets) do if q == p then return end end
	ly.targets[#ly.targets + 1] = p
end

local function pickTarget()
	local live = {}
	for _, p in ipairs(ly.targets) do if alive(p) then live[#live + 1] = p end end
	if #live > 0 then return live[math.random(#live)] end
	local all = lyPlayers()
	if #all == 0 then return 0 end
	local p = all[math.random(#all)]
	ly.targets = {p}
	return p
end

--- a scene: she is somewhere out of sight, playing, crying or roaming, and can be heard
function lyStartScene()
	local all = lyPlayers()
	if #all == 0 then lySleep(15); return end
	local p = all[math.random(#all)]
	local near = ly.misses > 0
	local g = lyPickHidden(p, near and 16 or 22, near and 45 or 65)
	if not g then
		ly.tries = ly.tries + 1
		if ly.tries >= 5 then ly.tries = 0; lyStartHaunt({p}) else lySleep(rnd(8, 16)) end
		return
	end
	ly.tries = 0
	lySceneAt(g)
end

-- a scene at ground point g (her own pick, or where a spawn-menu flag was)
function lySceneAt(g)
	local kinds = {"play", "cry", "roam", "roam"}
	local kind = kinds[math.random(#kinds)]
	local _, pd = nearestPlayer(g)
	if pd < 35 and math.random() < 0.7 then lyOmen(g, 6, rnd(1.5, 3)) end
	ly.state = "scene"
	ly.act = {kind = kind, centre = VecCopy(g), stop = ly.T + rnd(100, 220), voiceT = ly.T + rnd(1, 3), ang = rnd(0, 360),
		goal = nil, waitT = 0, hunter = math.random() < 0.35}
	lyAppear(g, kind == "cry" and "sit" or (kind == "play" and "prance" or "walk"), {yaw = rnd(0, 360)})
end

local function sceneFound(dt)
	local a = ly.act
	local h = head(ly.pos)
	for _, p in ipairs(lyPlayers()) do
		local e = eye(p).pos
		local d = dist(e, h)
		if d < 3.5 then return p end
		if d < 11 and lySees(p, h, 0.75) then
			ly.seen[p] = (ly.seen[p] or 0) + dt
			if ly.seen[p] > 0.5 then return p end
		end
		if lySensePlayer(p, a.kind == "cry" and 4 or 12) then return p end   -- she found them: saw them (her face is in her hands when she cries) or heard them
	end
	return 0
end

function lySceneTick(dt)
	local a = ly.act
	if a.kind == "stare" then
		if alive(a.p) then ly.yaw = yawOf(VecSub(feet(a.p), ly.pos)) end
		if ly.T >= a.stop then
			if a.flee then
				lyVanish()
			else
				local r = math.random()
				if r < 0.1 and alive(a.p) and not a.angry then
					lyFx(a.p, "scare")
				elseif r < 0.32 then
					lyVoice("giggle", ly.pos, 1)
				elseif r < 0.45 and alive(a.p) then               -- she runs off, through whatever is behind her
					a.flee = true
					a.stop = ly.T + rnd(1.0, 1.8)
					a.dir = VecScale(flat(VecSub(ly.pos, feet(a.p))), 1)
					ly.anim = "run"; ly.look = 0
					lyPublish()
					return
				end
				lyVanish()
			end
			local list = {a.p}
			for _, p in ipairs(lyPlayers()) do
				if p ~= a.p and dist(feet(p), ly.pos) < 12 and math.random() < 0.5 then list[#list + 1] = p end
			end
			lyStartHaunt(list, a.angry)
		elseif a.flee then
			lyMove(dt, VecAdd(ly.pos, VecScale(a.dir, 10)), 7.5)
		end
		return
	end
	local p = sceneFound(dt)
	if p ~= 0 then
		ly.misses = 0
		ly.anim = "stand"; ly.look = p; ly.speed = 0
		ly.act = {kind = "stare", p = p, stop = ly.T + rnd(1.0, 2.6)}
		lyPublish()
		return
	end
	if ly.T >= a.stop then
		ly.misses = ly.misses + 1
		if ly.misses >= 2 then                                        -- nobody came: she goes and finds someone herself
			ly.misses = 0
			lyVanish()
			local q = nearestPlayer(ly.pos)
			if q ~= 0 then lyStartHaunt({q}) else lySleep(30) end
		else
			lySleep(rnd(20, 60) * F())
		end
		return
	end
	if a.kind == "play" then                                          -- skipping round in a ring
		a.ang = a.ang + dt * 80
		local d = rotY(Vec(0, 0, 1), a.ang)
		lyMove(dt, Vec(a.centre[1] + d[1] * 1.3, a.centre[2], a.centre[3] + d[3] * 1.3), 2.4)
		if ly.T >= a.voiceT then
			local r = math.random()
			lyVoice(r < 0.45 and "hum" or (r < 0.75 and "musicbox" or "giggle"), ly.pos, 1)
			a.voiceT = ly.T + rnd(5, 11)
		end
	elseif a.kind == "cry" then
		if ly.T >= a.voiceT then
			lyVoice("cry", ly.pos, 1)
			a.voiceT = ly.T + rnd(4, 8)
		end
	else                                                              -- roaming
		if a.goal then
			if lyMove(dt, a.goal, a.fast and 2.6 or 1.1) < 0.3 then
				a.goal = nil
				a.waitT = ly.T + rnd(0.5, 4)
				ly.anim = "stand"; ly.speed = 0
			end
		elseif ly.sound and ly.sound.who == 0 and not a.heard then                 -- a noise: she goes to look
			a.heard = true
			a.goal = lyGround(ly.sound.pos, 1.5, 4) or VecCopy(ly.sound.pos)
			a.fast = true
			ly.anim = "walk"
		elseif ly.T >= a.waitT then
			a.heard = false
			local base = ly.pos
			local q, qd = nearestPlayer(ly.pos)
			if a.hunter and q ~= 0 and qd > 9 then base = VecLerp(ly.pos, feet(q), 0.35) end   -- drifting toward someone
			for i = 1, 6 do
				local d = rotY(Vec(0, 0, 1), rnd(0, 360))
				local r = rnd(3, 10)
				local g = lyGround(Vec(base[1] + d[1] * r, base[2], base[3] + d[3] * r), 2, 4)
				if g and lyStandable(g) then a.goal = g; break end
			end
			a.fast = math.random() < 0.2
			if a.goal then ly.anim = a.fast and "prance" or "walk" else a.waitT = ly.T + 1 end
		end
		if ly.T >= a.voiceT then
			local r = math.random()
			lyVoice(r < 0.5 and "hum" or (r < 0.8 and "giggle" or "say"), ly.pos, 1)
			a.voiceT = ly.T + rnd(7, 16)
		end
	end
end

--- the haunting: events at uneven intervals, for a while
local function nextGap()
	local r = math.random()
	local g
	if r < 0.2 then g = rnd(3, 9)                                     -- one thing right after another
	elseif r < 0.36 then g = rnd(45, 80)                             -- a long silence
	else g = rnd(12, 38) end
	return g * F()
end

function lyStartHaunt(list, angry)
	ly.targets = {}
	for _, p in ipairs(list) do if alive(p) then lyAddTarget(p) end end
	ly.state = "haunt"
	ly.act = nil
	local len = rnd(60, 210) * F()
	if angry then len = len * 0.6 end
	ly.haunt = {stop = ly.T + len, start = ly.T, nextT = ly.T + rnd(6, 20) * F(), last = {}, scares = 0, ball = false,
		willHunt = math.random() < 0.82, maxScares = math.random() < 0.35 and 0 or (math.random() < 0.8 and 1 or 2)}
	lyPublish()
end

-- an apparition's shared end: gone when watched long enough, when someone comes close, or when her time is up
local function apparitionDone(a, dt)
	local p = a.p
	if not alive(p) then return true end
	if lySees(p, head(ly.pos), a.cone or 0.8) then a.watched = (a.watched or 0) + dt end
	if (a.watched or 0) >= a.watch then return true, true end
	local _, d = nearestPlayer(ly.pos)
	if d < (a.near or 0) then return true, true end
	return ly.T >= a.stop
end

LILY_EVENTS = {
	whisper = {w = 3, start = function(p)
		lyEar(p, "whisper", LILY_WHISPERS[math.random(#LILY_WHISPERS)])
	end},
	giggle = {w = 3, start = function(p)
		local g = math.random() < 0.5 and lyPickHidden(p, 6, 14) or nil
		if g then lyVoice(math.random() < 0.7 and "giggle" or "hum", g, 1) else lyEar(p, "giggle") end
	end},
	steps = {w = 2, start = function(p) lyEar(p, "steps") end},
	say = {w = 1.5, start = function(p)
		local g = lyPickHidden(p, 7, 15)
		if g then lyVoice("say", g, 1) else lyEar(p, "say") end
	end},
	fake = {w = 1.5, start = function(p) lyOmen(feet(p), 7, rnd(2.5, 5)) end},
	polter = {w = 2, start = function(p)
		lyOmen(feet(p), 8, rnd(5, 9), {fling = math.random() < 0.3})
		if math.random() < 0.3 then return {kind = "wait", stop = ly.T + rnd(4, 7), after = function() lyEar(p, "giggle") end} end
	end},
	dark = {w = 1.5, start = function(p)
		local n = lyDarken(feet(p), 18, rnd(1, 2.5), rnd(12, 25))
		lyFx(p, "flash", rnd(2, 4))
		if n == 0 and math.random() < 0.5 then return nil end
		return {kind = "wait", stop = ly.T + rnd(3, 7), after = function() lyEar(p, math.random() < 0.6 and "whisper" or "breath", LILY_WHISPERS[math.random(#LILY_WHISPERS)]) end}
	end},
	ball = {w = 1, can = function() return not ly.haunt.ball end, start = function(p)
		local g = lyPickBehind(p, 4, 7) or lyPickHidden(p, 6, 10)
		if not g then return nil end
		ly.haunt.ball = true
		local ents = Spawn("<body tags='lilyball' dynamic='true'><vox file='MOD/vox/ball.vox'/></body>", Transform(Vec(g[1], g[2] + 0.35, g[3])))
		for _, e in ipairs(ents or {}) do
			if GetEntityType(e) == "body" then
				local d = flat(VecSub(feet(p), g))
				SetBodyVelocity(e, Vec(d[1] * 3.5, 0.5, d[3] * 3.5))
				ly.balls[#ly.balls + 1] = {b = e, t = ly.T + 90}
			end
		end
		return {kind = "wait", stop = ly.T + rnd(2.5, 4), after = function() lyVoice(math.random() < 0.6 and "say" or "giggle", g, 1) end}
	end},
	scare = {w = 1, can = function()
		local h = ly.haunt
		return h.scares < h.maxScares and ly.T - h.start > 0.4 * (h.stop - h.start)
	end, start = function(p)
		ly.haunt.scares = ly.haunt.scares + 1
		lyFx(p, "scare")
	end},
	-- she stands somewhere in plain sight, far off, and is gone when looked at for a moment
	sight = {w = 2.5, start = function(p)
		local g = lyPickInView(p, 12, 32)
		if not g then return nil end
		local pre = math.random() < 0.7 and rnd(1.2, 2.5) or 0
		if pre > 0 then lyOmen(g, 5, pre + 0.5) end
		return {kind = "sight", p = p, g = g, t0 = ly.T + pre, stop = ly.T + pre + rnd(6, 11), watch = rnd(0.4, 1.6), near = 6,
			only = math.random() < 0.5 and p or 0, anim = math.random() < 0.35 and "point" or "stand"}
	end},
	-- she stands right behind you
	behind = {w = 2, start = function(p)
		local g = lyPickBehind(p, 3, 4.5)
		if not g then return nil end
		if math.random() < 0.5 then lyFx(p, "flash", rnd(0.5, 1.2)) end
		lyEar(p, math.random() < 0.6 and "breath" or "whisper", "")
		return {kind = "sight", p = p, g = g, t0 = ly.T + rnd(0.2, 1), stop = ly.T + rnd(6, 9), watch = rnd(0.15, 0.35), cone = 0.6, near = 0,
			only = math.random() < 0.4 and p or 0, anim = "stand", sting = true}
	end},
	-- she scuttles across your view on all fours, belly up
	crawl = {w = 1.2, start = function(p)
		local g = lyPickInView(p, 9, 20)
		if not g then return nil end
		local side = flat(VecCross(Vec(0, 1, 0), VecSub(g, feet(p))))
		if math.random() < 0.5 then side = VecScale(side, -1) end
		local from = VecAdd(g, VecScale(side, -6))
		return {kind = "run", p = p, from = from, dir = side, t0 = ly.T, stop = ly.T + rnd(1.5, 2.3), anim = math.random() < 0.7 and "crawl" or "run",
			speed = rnd(6.5, 8.5)}
	end},
}

local function pickEvent()
	local h = ly.haunt
	local total, list = 0, {}
	for name, e in pairs(LILY_EVENTS) do
		if name ~= h.last[1] and name ~= h.last[2] and (not e.can or e.can()) then
			total = total + e.w
			list[#list + 1] = name
		end
	end
	table.sort(list)                                                  -- (pairs has no order: keep runs repeatable)
	local r = math.random() * total
	for _, name in ipairs(list) do
		r = r - LILY_EVENTS[name].w
		if r <= 0 then return name end
	end
	return list[#list]
end

function lyDoEvent(name, p)
	local h = ly.haunt
	if h then h.last[2] = h.last[1]; h.last[1] = name end
	ly.lastEvent = name
	ly.act = LILY_EVENTS[name].start(p)
end

function lyHauntTick(dt)
	local h = ly.haunt
	local a = ly.act
	if a then
		if a.kind == "wait" then
			if ly.T >= a.stop then ly.act = nil; a.after() end
		elseif a.kind == "sight" then
			if not ly.vis then
				if ly.T >= a.t0 then
					if alive(a.p) then lyAppear(a.g, a.anim, {only = a.only, look = a.p}) else ly.act = nil end
				end
			else
				local done, caught = apparitionDone(a, dt)
				if done then
					lyVanish()
					ly.act = nil
					if caught and alive(a.p) then
						if a.sting then lyFx(a.p, "sting") elseif math.random() < 0.4 then lyEar(a.p, "giggle") end
						if math.random() < 0.15 then h.nextT = ly.T + rnd(1.5, 4) end   -- ... and it is not over
					end
				end
			end
		elseif a.kind == "run" then
			if not ly.vis then lyAppear(a.from, a.anim, {yaw = yawOf(a.dir)}) end
			lyMove(dt, VecAdd(ly.pos, VecScale(a.dir, 10)), a.speed)
			if ly.T >= a.stop then lyVanish(); ly.act = nil end
		end
		return
	end
	if ly.T >= h.stop then
		if h.willHunt and ly.kills then lyStartHunt() else lySleep(rnd(60, 160) * F()) end
		return
	end
	if ly.T >= h.nextT then
		local p = pickTarget()
		if p == 0 then lySleep(30); return end
		h.nextT = ly.T + nextGap()
		lyDoEvent(pickEvent(), p)
	end
end

--- the hunt
LILY_TEMPO = {                      -- {weight, anim, speed m/s, seconds min, max}: players walk at 7 m/s
	{4, "run", 7.3, 1.5, 3.5}, {3, "crawl", 8.6, 1.0, 2.5}, {2, "stand", 0, 0.3, 0.9}, {1, "prance", 4.2, 1.0, 2.0},
	{1, "walk", 1.5, 1.0, 2.2}, {1.5, "reach", 6.2, 1.5, 3.0},
}

function lyStartHunt()
	local p = pickTarget()
	if p == 0 then lySleep(30); return end
	lyVanish()
	ly.state = "hunt"
	ly.act = nil
	local len = rnd(45, 75)
	ly.hunt = {target = p, t0 = ly.T + rnd(3, 5), stop = ly.T + len + 4, tempoT = 0, gait = "run", gaitSpeed = 7, blinkT = ly.T + rnd(9, 15),
		voiceT = ly.T + rnd(8, 12), flashT = 0}
	lyFx(0, "global", "cackle", math.random())
	for _, q in ipairs(lyPlayers()) do
		lyDarken(feet(q), 25, rnd(2, 4), len)
		lyFx(q, "flash", rnd(2, 4))
	end
	lyLevitate(feet(p), 8, 4, true)
	lyPublish()
end

function lyHuntTick(dt)
	local h = ly.hunt
	if ly.T < h.t0 then return end
	if ly.blink then return end
	if not alive(h.target) then
		h.target = pickTarget()
		if h.target == 0 then lyRestoreLights(); lySleep(60); return end
	end
	local p = h.target
	if not ly.vis then                                                -- she comes
		local g = lyPickHidden(p, 14, 30) or lyPickRing(p, 12, 16, true)
		lyAppear(g, "run", {face = 1, look = p})
		h.tempoT = 0
		h.known = h.known or VecCopy(feet(p))            -- (she knew where her victim was when it began)
		h.lastSeen = h.lastSeen or VecCopy(h.known)
	end
	if ly.T >= h.stop then                                            -- not this time
		lyVoice("shriek", ly.pos, 1)
		lyFx(0, "puff", ly.pos[1], ly.pos[2] + 0.6, ly.pos[3])
		lyRestoreLights()
		lySleep(rnd(60, 150) * F())
		return
	end
	-- she goes by what she sees and hears, nothing else: whoever she senses (her prey first, anyone twice as near
	-- will do), else where she sensed someone last, else a noise. Out of her sight and silent, she has lost you:
	-- she goes to where you were, listens, and searches round there until the hunt runs out.
	local best, bd = 0, 1e9
	for _, r in ipairs(lyPlayers()) do
		local rf = feet(r)
		if hdist(rf, ly.pos) < CATCH_D and math.abs(rf[2] - ly.pos[2]) < 2.2 then lyStartKill(r); return end
		if lySensePlayer(r) then
			local d = dist(rf, ly.pos) * (r == p and 0.5 or 1)
			if d < bd then best, bd = r, d end
		end
	end
	if best ~= 0 then
		h.target = best; p = best
		h.known = VecCopy(feet(p)); h.sensedT = ly.T; h.lastSeen = VecCopy(h.known); h.waitT = nil
	elseif ly.sound and ly.sound.t == ly.T then                       -- a noise with nobody to pin it on
		h.known = VecCopy(ly.sound.pos); h.lastSeen = VecCopy(h.known); h.waitT = nil
	end
	local lost = ly.T - (h.sensedT or -99) > 3
	local f = h.known
	if lost and hdist(f, ly.pos) < 1 then                             -- nobody here: she stands and listens ...
		if not h.waitT then
			h.waitT = ly.T + rnd(1, 2.5)
			ly.anim = "stand"; ly.look = 0
		end
		ly.speed = 0
		if ly.T < h.waitT then return end
		h.waitT = nil                                                   -- ... then looks somewhere near where they were
		local c = h.lastSeen or f
		local d = rotY(Vec(0, 0, 1), rnd(0, 360))
		local r = rnd(5, 14)
		local q = Vec(c[1] + d[1] * r, c[2], c[3] + d[3] * r)
		h.known = lyGround(q, 2, 4) or q
		h.tempoT = 0
		return
	end
	local pd = dist(f, ly.pos)
	if ly.T >= h.blinkT and pd > BLINK_MAX + 2 and not lost then                   -- gone, and back much closer
		h.blinkT = ly.T + rnd(6, 12)
		lyVanish()
		ly.blink = {t = ly.T + rnd(0.5, 1.4), p = p}
		return
	end
	if ly.T >= h.tempoT then
		local total = 0
		for _, t in ipairs(LILY_TEMPO) do total = total + t[1] end
		local r = math.random() * total
		for _, t in ipairs(LILY_TEMPO) do
			r = r - t[1]
			if r <= 0 then
				h.gait, h.gaitSpeed = t[2], t[3]
				h.tempoT = ly.T + rnd(t[4], t[5])
				break
			end
		end
		if h.stop - ly.T < 15 and h.gaitSpeed > 0 then h.gaitSpeed = h.gaitSpeed + 1.5 end   -- the last seconds: frantic
		ly.look = lost and 0 or p
	end
	ly.anim = h.gait
	if h.gaitSpeed > 0 then lyMove(dt, f, h.gaitSpeed) else ly.speed = 0; ly.yaw = yawOf(VecSub(f, ly.pos)) end
	if ly.T >= h.voiceT then
		lyVoice(math.random() < 0.6 and "cackle" or "giggle", ly.pos, 1)
		h.voiceT = ly.T + rnd(5, 10)
	end
	if ly.T >= h.flashT then                                          -- flashlights fail when she is close
		h.flashT = ly.T + rnd(0.8, 1.6)
		for _, r in ipairs(lyPlayers()) do
			if dist(feet(r), ly.pos) < 9 then lyFx(r, "flash", rnd(0.4, 0.9)) end
		end
	end
end

function lyStartKill(p)
	ly.state = "kill"
	ly.kill = {p = p, stop = ly.T + KILL_TIME, hold = VecCopy(feet(p))}
	ly.anim = "reach"; ly.face = 1; ly.look = p; ly.speed = 0
	lyFx(p, "kill", KILL_TIME)
	lyVoice("shriek", ly.pos, 1)
	lyOmen(ly.pos, 10, KILL_TIME + 1, {flash = 1})
	lyPublish()
end

function lyKillTick(dt)
	local k = ly.kill
	local p = k.p
	if IsPlayerValid(p) and GetPlayerHealth(p) > 0 and ly.T < k.stop then
		SetPlayerVelocity(Vec(0, 0, 0), p)
		local e = eye(p)
		local d = flat(eyeFwd(p))
		local g = Vec(e.pos[1] + d[1] * 0.75, feet(p)[2], e.pos[3] + d[3] * 0.75)
		ly.pos = g
		ly.yaw = yawOf(VecScale(d, -1))
		return
	end
	if IsPlayerValid(p) and GetPlayerHealth(p) > 0 then
		SetPlayerVelocity(VecAdd(VecScale(flat(eyeFwd(p)), -6), Vec(0, 4, 0)), p)
		SetPlayerHealth(0, p)
	end
	ly.killCount = ly.killCount + 1
	lyFx(0, "global", "laugh", math.random())
	lyRestoreLights()
	ly.targets = {}
	lySleep(rnd(120, 300) * F())                                      -- calm again
end

----- commands (tests, other mods): SetString("lily.cmd", ...) on the host -----
-- "scene", "haunt", "hunt", "sleep", "ev <name>" (a haunt event on the host / the nearest target)
function lyCommand()
	local c = GetString("lily.cmd")
	if c == "" then return end
	SetString("lily.cmd", "")
	local all = lyPlayers()
	if #all == 0 then return end
	local p = all[1]
	lyVanish(); ly.act = nil; ly.blink = nil
	ly.dayPass = c ~= "sleep"
	if c == "scene" then
		ly.misses = 1
		lyStartScene()
	elseif c == "haunt" then
		lyStartHaunt({p})
		ly.haunt.nextT = ly.T + 2
	elseif c == "hunt" then
		ly.targets = {p}
		lyStartHunt()
	elseif c == "sleep" then
		lyRestoreLights()
		lySleep(rnd(40, 110) * F())
	else
		local name = string.match(c, "^ev (%a+)$")
		if name and LILY_EVENTS[name] then
			if ly.state ~= "haunt" then lyStartHaunt({p}) end
			ly.haunt.nextT = ly.T + 30
			lyDoEvent(name, p)
		end
	end
end

----- the spawn menu (spawn.txt, prefab/spawner.xml): a flag put down counts down, then she is there -----
-- No held buttons (the user): pick "Creatures/Lily", put the flag down, a number counts down over it, at 0 the flag
-- goes and her scene starts where it is by then. There is one Lily: a flag moves her (whatever she was doing) rather
-- than adding another. During a kill the flag waits at 0 until the kill is over.
-- The spawn menu's PREVIEW (held in front of the camera before the click) is a lilyspawn body too: its shapes have
-- collision mask 0 (spawn.lua sets 0, 0), the real one 255. A preview never counts (counting from first sight made
-- Silkmaw and the Abyssipede come out with no flag put down). A marker without shapes counts as placed.
LILY_MARK_T = 7               -- s from putting the flag down to her coming out

local function markPlaced(b)
	local shapes = GetBodyShapes(b) or {}
	if #shapes == 0 then return true end
	for _, sh in ipairs(shapes) do
		local _, mask = GetShapeCollisionFilter(sh)
		if (mask or 0) ~= 0 then return true end
	end
	return false
end

function lySpawnAt(p)
	lyVanish(); ly.act = nil; ly.blink = nil; ly.hunt = nil
	lyRestoreLights()
	ly.misses, ly.tries = 0, 0
	lySceneAt(lyGround(p, 1.5, 4) or VecCopy(p))
	ly.dayPass = true
end

function lySpawnMenu()
	local seen, marks = {}, {}
	for _, b in ipairs(FindBodies("lilyspawn", true) or {}) do
		seen[b] = true
		if not ly.markT0[b] and markPlaced(b) then ly.markT0[b] = ly.T end
		local t0 = ly.markT0[b]
		if t0 then                                                    -- (nil: the spawn menu's preview - nothing yet)
			local p = GetBodyTransform(b).pos
			local left = LILY_MARK_T - (ly.T - t0)
			if left <= 0 and ly.state ~= "kill" then
				Delete(b)
				ly.markT0[b] = nil
				seen[b] = nil
				lySpawnAt(p)
			else
				local k = #marks
				marks[k + 1], marks[k + 2], marks[k + 3], marks[k + 4] = p[1], p[2], p[3], math.max(0, left)
			end
		end
	end
	for b in pairs(ly.markT0) do if not seen[b] then ly.markT0[b] = nil end end
	if #marks > 0 or ly.markN > 0 then shared.lilyMarks = marks end   -- (nothing synced while there are no flags)
	ly.markN = #marks
end

----- the Villagers mod (villagers/mods/villagers/API.md): plain host registry keys, nothing happens without it -----
-- She is one "thing" (lilyghost): villagers who see her fear her, each in their own way; hidden (only heard) while she
-- is invisible or shown to one player alone; gone while she sleeps. Danger 0.2 while she plays and haunts, 0.7 while she
-- hunts (they run at 0.3 or more). News when the hunt begins and when she kills.
LILY_VL = {hesper = "hate", marl = "pity", wren = "curious", ysolde = "wary"}

local function vlNews(text, sense, importance, range)
	local n = GetInt("villagers.news.last") + 1
	local b = "villagers.news." .. (n % 16) .. "."
	SetString(b .. "text", text); SetString(b .. "sense", sense)
	SetFloat(b .. "x", ly.pos[1]); SetFloat(b .. "y", ly.pos[2]); SetFloat(b .. "z", ly.pos[3])
	SetFloat(b .. "range", range); SetInt(b .. "importance", importance)
	SetInt("villagers.news.last", n)
end

function lyVillagers()
	if ly.T < ly.vlT then return end
	ly.vlT = ly.T + 0.5
	if not GetBool("villagers.present") then ly.vlKind = false; return end
	local k = "villagers.kind.lilyghost."
	if not ly.vlKind then
		ly.vlKind = true
		SetString(k .. "name", "Lily"); SetString(k .. "feel", "fear")
		for id, f in pairs(LILY_VL) do SetString(k .. "feel." .. id, f) end
		SetString(k .. "note", "a little ghost girl who plays and cries in the dark, then comes for the living; she walks through walls")
		SetString(k .. "sound", "a child humming, or laughing, close by"); SetFloat(k .. "hear", 18)
	end
	local hunting = ly.state == "hunt" or ly.state == "kill"
	SetFloat(k .. "danger", hunting and 0.7 or 0.2)
	local t = "villagers.thing.lily."
	local there = ly.state ~= "dormant"
	if not there then SetBool(t .. "gone", true); return end
	SetBool(t .. "gone", false)
	SetString(t .. "kind", "lilyghost")
	SetFloat(t .. "x", ly.pos[1]); SetFloat(t .. "y", ly.pos[2] + 0.6); SetFloat(t .. "z", ly.pos[3])
	SetBool(t .. "hidden", not ly.vis or ly.only ~= 0)
	local doing = {scene = "humming to herself", haunt = "haunting the living", hunt = "hunting", kill = "killing someone"}
	SetString(t .. "doing", doing[ly.state] or "standing there")
	if ly.state == "hunt" and not ly.vlHunt then
		ly.vlHunt = true
		vlNews("a child cackling in the dark, coming closer", "heard", 4, 90)
	elseif ly.state == "kill" and not ly.vlKill then
		ly.vlKill = true
		vlNews("a scream, and then a child's laughter", "heard", 5, 120)
	end
	if ly.state ~= "hunt" then ly.vlHunt = false end
	if ly.state ~= "kill" then ly.vlKill = false end
end

----- callbacks -----

function Ghost.serverInit()
	local f = GetInt("savegame.mod.freq")
	if f < 1 or f > 3 then f = 2 end
	ly = {T = 0, state = "dormant", pos = Vec(0, -600, 0), yaw = 0, vis = false, anim = "stand", face = 0, only = 0, look = 0, speed = 0,
		seq = 0, pubT = 0, targets = {}, crumbs = {}, crumbAt = {}, crumbN = 0, dark = {}, float = {}, balls = {}, seen = {},
		misses = 0, tries = 0, hits = 0, saidSeen = GetInt("proxchat.said.last"), killCount = 0, freq = f, kills = not GetBool("savegame.mod.nokill"), maskT = 0, crumbT = 0,
		markT0 = {}, markN = 0, hourT = 0, hours = true, dayPass = false, vlT = 0, vlKind = false, vlHunt = false, vlKill = false,
		when = GetInt("savegame.mod.when")}
	ly.wake = rnd(45, 110) * F()
	lyHitSpawn()
	SetString("lily.cmd", "")
	lyPublish()
end

function Ghost.serverTick(dt)
	if not ly then return end
	ly.T = ly.T + dt
	lyCommand()
	lySpawnMenu()
	lyHoursTick()
	lyVillagers()
	if ly.T >= ly.maskT then                                          -- players pass through her hit box
		ly.maskT = ly.T + 0.25
		for _, p in ipairs(GetAllPlayers()) do
			local m = GetPlayerParam("CollisionMask", p)
			if type(m) == "number" and math.floor(m / LILY_LAYER) % 2 == 1 then SetPlayerParam("CollisionMask", m - LILY_LAYER, p) end
		end
	end
	if ly.T >= ly.crumbT then                                         -- where players have walked: places she can be
		ly.crumbT = ly.T + 1
		for _, p in ipairs(lyPlayers()) do
			if IsPlayerGrounded(p) and GetPlayerVehicle(p) == 0 then
				local f = feet(p)
				local last = ly.crumbAt[p]
				if not last or dist(last, f) > 4 then
					ly.crumbAt[p] = VecCopy(f)
					ly.crumbN = ly.crumbN % 400 + 1
					ly.crumbs[ly.crumbN] = VecCopy(f)
				end
			end
		end
		for i = #ly.balls, 1, -1 do
			if ly.T >= ly.balls[i].t then
				local b = ly.balls[i].b
				if IsHandleValid(b) and lyHeld()[b] then ly.balls[i].t = ly.T + 10   -- (never delete a ball in someone's hands)
				else
					if IsHandleValid(b) then Delete(b) end
					table.remove(ly.balls, i)
				end
			end
		end
	end
	lyListen()
	if ly.vis and ly.state ~= "kill" then lyHitScan() end
	lyBlinkTick()
	if ly.state == "dormant" then
		if ly.T >= ly.wake then
			if ly.hours then lyStartScene() else ly.wake = ly.T + 5 end   -- (the sun is up: she waits for the dark)
		end
	elseif ly.state == "scene" then
		if ly.act then lySceneTick(dt) elseif not ly.blink then lySleep(20) end
	elseif ly.state == "haunt" then
		if not ly.blink then lyHauntTick(dt) end
	elseif ly.state == "hunt" then
		lyHuntTick(dt)
	elseif ly.state == "kill" then
		lyKillTick(dt)
	end
	lyDarkTick()
	if ly.hitBody then
		SetBodyTransform(ly.hitBody, Transform(ly.vis and ly.pos or Vec(0, -600, 0)))
	end
	if ly.vis and ly.T - ly.pubT >= 1 / LILY_PUBLISH_HZ then lyPublish() end
end

function Ghost.serverUpdate(dt)
	if ly then lyFloatUpdate() end
end
