-- GhostView: what each machine sees and hears of Lily (PROJECT.md). Every client spawns its own copy of her parts
-- (static bodies, 0.025 m voxels, colliding with nothing) and poses them from shared.lily: where she is, how she
-- moves (stand, point, sit, walk, prance, run, crawl - belly up, head first - and reach), which face she wears and
-- who may see her. Private things arrive through client.lilyFx on one machine only: a whisper in one ear, a jump
-- scare, the kill, a failing flashlight. She comes and goes in a flicker, never a fade.

GhostView = {}

LV_PARK = Vec(0, -900, 0)
LV_KINDS = {"giggle", "laugh", "hum", "cry", "whisper", "say", "breath", "steps", "cackle", "scream", "shriek", "musicbox", "sting"}
LV_STAND = 0.51          -- m: the torso's centre above her feet, standing
LV_BASE = {stand = 0.51, point = 0.51, walk = 0.51, prance = 0.51, run = 0.47, sit = 0.2, crawl = 0.34, reach = 0.72}

local function rnd(a, b) return a + math.random() * (b - a) end
local function qx(a) return QuatEuler(a, 0, 0) end
local function qy(a) return QuatEuler(0, a, 0) end
local function qz(a) return QuatEuler(0, 0, a) end
local function qmul(a, b, c)
	local q = QuatRotateQuat(a, b)
	if c then q = QuatRotateQuat(q, c) end
	return q
end
local function V3(t) return Vec(t[1], t[2], t[3]) end

function lvLoadSounds()
	lv.snd = {}
	local S = GHOST_SOUNDS or {}
	for _, k in ipairs(LV_KINDS) do
		lv.snd[k] = {}
		for i, f in ipairs(S[k] or {}) do lv.snd[k][i] = {h = LoadSound(f), file = f} end
	end
end

-- play one of a kind (r 0..1 picks which, so the server can name the same take for everyone); returns its words
function lvPlay(kind, pos, vol, r)
	local l = lv.snd[kind]
	if not l or #l == 0 then return nil end
	local s = l[math.min(#l, 1 + math.floor((r or math.random()) * #l))]
	PlaySound(s.h, pos, vol or 1, false)
	return GHOST_TEXT and GHOST_TEXT[s.file] or nil
end

function lvSpawn()
	local P = GHOST_PARTS
	local function body(def)
		local xml = "<body tags='lilyview nocull'><vox tags='nocull' file='" .. def.file .. "' scale='0.25'/></body>"
		local ents = Spawn(xml, Transform(LV_PARK), true)
		for _, e in ipairs(ents or {}) do
			if GetEntityType(e) == "body" then
				for _, s in ipairs(GetBodyShapes(e)) do SetShapeCollisionFilter(s, 64, 0) end
				return e
			end
		end
		return 0
	end
	lv.b = {torso = body(P.torso), head = body(P.head), scream = body(P.head_scream), arm_l = body(P.arm), arm_r = body(P.arm),
		leg_l = body(P.leg), leg_r = body(P.leg)}
	lv.parked = true
end

function lvPark()
	if lv.parked then return end
	for _, b in pairs(lv.b) do
		if b ~= 0 then SetBodyTransform(b, Transform(LV_PARK)) end
	end
	lv.parked = true
end

-- a limb hung by `pivot` (its own frame) on `joint` (the torso's frame), turned by rot there
local function hang(base, joint, rot, pivot, b)
	if b == 0 then return end
	local j = TransformToParentTransform(base, Transform(V3(joint), rot))
	SetBodyTransform(b, TransformToParentTransform(j, Transform(Vec(-pivot[1], -pivot[2], -pivot[3]))))
end

-- pose every part: feet at g, facing yaw, in animation `anim`; ph = stride phase (radians), t = time, look = a world
-- point her head turns to (or nil), scream = which face
function lvPose(g, yaw, anim, ph, t, look, scream, shake)
	local P = GHOST_PARTS
	local T = P.torso
	local s, c = math.sin(ph), math.cos(ph)
	local bob, lean, roll = 0, 0, 0
	local aL, aR = qz(4), qz(-4)                      -- arms: hanging, a little out
	local lL, lR = Quat(), Quat()
	local hq = qz(14)                                 -- her head always a little to one side
	local torsoQ = nil
	if anim == "walk" then
		bob = 0.012 * math.abs(s)
		aL, aR = qmul(qz(4), qx(8 * s)), qmul(qz(-4), qx(-8 * s))
		lL, lR = qx(-24 * s), qx(24 * s)
	elseif anim == "prance" then                      -- skipping: high knees, arms flung out
		bob = 0.13 * math.abs(s)
		roll = 6 * s
		aL, aR = qz(55 + 25 * c), qz(-55 + 25 * c)
		lL, lR = qx(-55 * math.max(0, s)), qx(-55 * math.max(0, -s))
		hq = qz(22 * s)
	elseif anim == "run" then                         -- bent forward, arms trailing straight back
		bob = 0.03 * math.abs(s)
		lean = 24
		aL, aR = qmul(qz(10), qx(62 + 6 * s)), qmul(qz(-10), qx(62 - 6 * s))
		lL, lR = qx(-58 * s - 10), qx(58 * s - 10)
		hq = qmul(qx(-20), qz(18 * math.sin(t * 23)))
	elseif anim == "sit" then                         -- on the floor, face in her hands, shaking
		lean = 16 + 2 * math.sin(t * 9)
		aL, aR = qmul(qy(-30), qx(-128)), qmul(qy(30), qx(-128))
		lL, lR = qx(-88), qx(-88)
		hq = qx(50 + 3 * math.sin(t * 9))
		look = nil
	elseif anim == "point" then
		aR = qx(-84)
		hq = qz(20)
	elseif anim == "reach" then                       -- afloat, arms out for you, legs limp
		bob = 0.04 * math.sin(t * 2.2)
		lean = 10
		aL, aR = qmul(qz(8), qx(-86 + 5 * math.sin(t * 17))), qmul(qz(-8), qx(-86 + 5 * math.sin(t * 19 + 1)))
		lL, lR = qx(12), qx(16)
		hq = qmul(qx(-10), qz(24 * math.sin(t * 27)))
		look = nil
	elseif anim == "crawl" then                       -- on hands and feet, belly up, head first, head hanging back
		torsoQ = qmul(qx(90), qy(180))
		bob = 0.02 * math.abs(s)
		aL, aR = qmul(qz(-26), qx(90 + 30 * s)), qmul(qz(26), qx(90 - 30 * s))
		lL, lR = qmul(qz(-22), qx(90 - 30 * s)), qmul(qz(22), qx(90 + 30 * s))
		hq = qmul(qx(-90), qz(12 * math.sin(t * 21)))
		look = nil
	else                                              -- standing: a slow sway, now and then a twitch
		roll = 2 * math.sin(t * 0.8)
		lean = 1.5 * math.sin(t * 0.55)
	end
	local base = Transform(Vec(g[1], g[2] + (LV_BASE[anim] or LV_STAND) + bob, g[3]), qmul(qy(yaw), torsoQ or qmul(qx(lean), qz(roll))))
	if shake and shake > 0 then
		base.pos = VecAdd(base.pos, Vec(rnd(-shake, shake), rnd(-shake, shake), rnd(-shake, shake)))
	end
	if look then                                      -- the head turns to whoever she is looking at - all the way round if it must
		local d = TransformToLocalVec(base, VecSub(look, TransformToParentPoint(base, V3(T.neck))))
		local l = VecLength(d)
		if l > 0.01 then
			local ya = math.deg(math.atan2(d[1], d[3]))
			local pa = -math.deg(math.asin(math.max(-1, math.min(1, d[2] / l))))
			hq = qmul(qy(ya), qx(pa), hq)
		end
	end
	if lv.twitchT and t < lv.twitchT then hq = qmul(hq, qz(lv.twitchA)) end
	if lv.b.torso ~= 0 then SetBodyTransform(lv.b.torso, base) end
	local hb, other = lv.b.head, lv.b.scream
	if scream then hb, other = other, hb end
	hang(base, T.neck, hq, P.head.neck, hb)
	if other ~= 0 then SetBodyTransform(other, Transform(LV_PARK)) end
	hang(base, T.shoulder_l, aL, P.arm.pivot, lv.b.arm_l)
	hang(base, T.shoulder_r, aR, P.arm.pivot, lv.b.arm_r)
	hang(base, T.hip_l, lL, P.leg.pivot, lv.b.leg_l)
	hang(base, T.hip_r, lR, P.leg.pivot, lv.b.leg_r)
	for _, sh in ipairs(GetBodyShapes(lv.b.torso)) do SetShapeEmissiveScale(sh, scream and 0.9 or 0.45) end
	lv.parked = false
	return base
end

function GhostView.clientInit()
	lv = {t = 0, pos = Vec(0, 0, 0), yaw = 0, ph = 0, shown = false, strobe = 0, seq = -1, s = nil, flash = 0, flashOn = true, flashNext = 0,
		over = nil, text = nil, twitchNext = 3, red = 0}
	lvLoadSounds()
	if GHOST_PARTS then lvSpawn() end
end

-- the one door for everything the server sends (ClientCall needs a literal name)
function client.lilyFx(kind, a, b, c, d, e)
	if not lv then return end
	local cam = GetCameraTransform()
	if kind == "voice" then                                         -- (kind, x, y, z, volume): out in the world
		lvPlay(a, Vec(b, c, d), e, nil)
	elseif kind == "ear" then                                       -- (kind, side, r, words): right behind one ear
		local pos = TransformToParentPoint(cam, Vec(0.5 * b, 0, 0.35))
		local words = lvPlay(a, pos, 0.9, c)
		if type(d) == "string" and d ~= "" then words = d end
		if words and a ~= "breath" then lvSay(words) end
	elseif kind == "global" then                                    -- (kind, r): from everywhere
		lvPlay(a, cam.pos, 1, b)
	elseif kind == "sting" then
		lvPlay("sting", cam.pos, 1)
		lv.red = 0.5
	elseif kind == "scare" then
		lv.over = {t0 = lv.t, stop = lv.t + 0.85, d0 = 0.95, d1 = 0.62}
		lvPlay("scream", cam.pos, 0.6)                                  -- (the user: 30 % quieter, then 15 % more)
		lvPlay("sting", cam.pos, 0.6)
		lv.flash = math.max(lv.flash, lv.t + 1.5)
	elseif kind == "kill" then                                      -- (seconds)
		lv.over = {t0 = lv.t, stop = lv.t + a, d0 = 1.2, d1 = 0.5, kill = true}
		lvPlay("scream", cam.pos, 1)
		lvPlay("sting", cam.pos, 1)
		lv.flash = math.max(lv.flash, lv.t + a)
	elseif kind == "flash" then                                     -- (seconds): this player's flashlight fails
		lv.flash = math.max(lv.flash, lv.t + a)
	elseif kind == "puff" then                                      -- (x, y, z): where she was
		ParticleReset()
		ParticleType("smoke")
		ParticleColor(0.75, 0.8, 0.85, 0.3, 0.3, 0.35)
		ParticleRadius(0.25, 0.7)
		ParticleAlpha(0.5, 0)
		ParticleGravity(0.4)
		ParticleDrag(0.6)
		for i = 1, 8 do
			SpawnParticle(Vec(a + rnd(-0.2, 0.2), b + rnd(-0.5, 0.5), c + rnd(-0.2, 0.2)), Vec(rnd(-0.6, 0.6), rnd(0, 0.8), rnd(-0.6, 0.6)), rnd(0.6, 1.3))
		end
	end
end

function lvSay(words)
	if GetBool("savegame.mod.nosubs") then return end
	lv.text = {s = words, t0 = lv.t, stop = lv.t + 2.2 + 0.05 * #words}
end

function lvFlashlight()
	if lv.t >= lv.flash then
		if not lv.flashOn then lv.flashOn = true end
		return
	end
	if lv.t >= lv.flashNext then
		lv.flashOn = not lv.flashOn
		lv.flashNext = lv.t + (lv.flashOn and rnd(0.03, 0.14) or rnd(0.06, 0.4))
	end
	if not lv.flashOn then
		local f = GetFlashlight(GetLocalPlayer())
		if f and f ~= 0 then SetLightEnabled(f, false) end
	end
end

function GhostView.clientTick(dt)
	if not lv then return end
	lv.t = lv.t + dt
	lvFlashlight()
	if not lv.b then return end
	local t = lv.t
	if t >= lv.twitchNext then                                      -- her head jerks, at no rhythm
		lv.twitchNext = t + rnd(1.5, 7)
		lv.twitchT = t + rnd(0.06, 0.16)
		lv.twitchA = rnd(-40, 40)
	end
	local cam = GetCameraTransform()
	local o = lv.over
	if o then                                                       -- in this player's face, whatever the server says
		if t >= o.stop then
			lv.over = nil
			lvPark()
			lv.shown = false
			if o.kill then lv.black = t + 2.5 end
		else
			local k = (t - o.t0) / (o.stop - o.t0)
			local d = o.d0 + (o.d1 - o.d0) * math.min(1, k * 1.6)
			local f = TransformToParentVec(cam, Vec(0, 0, -1))
			local fl = math.sqrt(f[1] * f[1] + f[3] * f[3])
			local fx, fz = 0, -1
			if fl > 0.05 then fx, fz = f[1] / fl, f[3] / fl end
			local neck = VecAdd(cam.pos, VecScale(f, d))
			local g = Vec(neck[1], neck[2] - 0.2 - (LV_BASE.reach + GHOST_PARTS.torso.neck[2]), neck[3])
			lvPose(g, math.deg(math.atan2(-fx, -fz)), "reach", 0, t, nil, true, 0.012 + 0.02 * k)
			PointLight(VecAdd(cam.pos, VecScale(f, d * 0.4)), 0.8, 0.86, 1.0, 0.5)
			ShakeCamera(0.5 + 0.5 * k)
			return
		end
	end
	local s = shared.lily
	if not s or not s.vis or (s.only ~= 0 and s.only ~= GetLocalPlayer()) then
		if lv.shown then lv.shown = false; lv.strobe = t + 0.22 end
		if t < lv.strobe and math.random() < 0.5 and lv.last then
			lvPose(lv.pos, lv.yaw, lv.last.anim, lv.ph, t, nil, lv.last.scream)
		else
			lvPark()
		end
		return
	end
	local target = Vec(s.x, s.y, s.z)
	if not lv.shown then
		lv.shown = true
		lv.strobe = t + 0.3
		lv.pos = target
		lv.yaw = s.yaw
	end
	local d = VecSub(target, lv.pos)
	local l = VecLength(d)
	if l > 3 then
		lv.pos = target
	else                                                            -- (ease after the 15 Hz updates)
		local k = math.min(1, dt * 14)
		lv.pos = VecAdd(lv.pos, VecScale(d, k))
		local stride = (s.anim == "crawl" and 9 or (s.anim == "run" and 6.5 or (s.anim == "prance" and 4.2 or 7)))
		lv.ph = lv.ph + l * k * stride
	end
	local dy = (s.yaw - lv.yaw + 540) % 360 - 180
	lv.yaw = lv.yaw + dy * math.min(1, dt * 12)
	local scream = s.face == 1
	lv.last = {anim = s.anim, scream = scream}
	if t < lv.strobe and math.random() < 0.45 then lvPark(); return end
	-- she is never quite there: gone for a blink again and again (still where she is, still dangerous); in bursts,
	-- most of all when she hunts. Each machine rolls its own blinks: everyone sees it, nobody the same instants.
	local hunting = s.state == "hunt"
	if t >= (lv.flickNext or 0) then
		lv.flickOut = t + (hunting and rnd(0.06, 0.4) or rnd(0.05, 0.22))
		local burst = math.random() < (hunting and 0.45 or 0.3)
		lv.flickNext = lv.flickOut + (burst and rnd(0.05, 0.16) or (hunting and rnd(0.5, 2.2) or rnd(1.5, 5)))
	end
	if t < (lv.flickOut or 0) then lvPark(); return end
	local look = nil
	if s.look ~= 0 and IsPlayerValid(s.look) then
		look = (s.look == GetLocalPlayer()) and cam.pos or GetPlayerEyeTransform(s.look).pos
	end
	local base = lvPose(lv.pos, lv.yaw, s.anim, lv.ph, t, look, scream, scream and 0.006 or 0)
	local glow = scream and (0.35 + 0.3 * math.random()) or 0.16
	PointLight(TransformToParentPoint(base, Vec(0, 0.3, 0.35)), 0.72, 0.82, 1.0, glow)
end

function GhostView.clientPostUpdate()
	if lv then lvFlashlight() end
end

function GhostView.clientDraw()
	if not lv then return end
	local t = lv.t
	local o = lv.over
	local a = 0
	if o then                                                       -- the world goes dark round her face
		local k = (t - o.t0) / (o.stop - o.t0)
		a = 0.25 + 0.2 * math.random()
		if o.kill then a = math.max(a, k * k) end
		lv.red = 0.6
	elseif lv.black and t < lv.black then
		a = math.min(1, (lv.black - t) / 1.2)
	end
	if a > 0.01 then
		UiPush()
		UiColor(0, 0, 0, a)
		UiRect(UiWidth(), UiHeight())
		UiPop()
	end
	if lv.red > 0.01 then
		UiPush()
		UiColor(0.35, 0, 0, lv.red * 0.45)
		UiRect(UiWidth(), UiHeight())
		UiPop()
		lv.red = lv.red - GetTimeStep() * 1.2
	end
	local x = lv.text
	if x then
		if t >= x.stop then
			lv.text = nil
		else
			local fade = math.min(1, (t - x.t0) / 0.5, (x.stop - t) / 0.7)
			UiPush()
			UiTranslate(UiCenter() + rnd(-1, 1), UiHeight() * 0.76 + rnd(-1, 1))
			UiAlign("center middle")
			UiFont("regular.ttf", 26)
			UiColor(0.82, 0.86, 0.92, 0.55 * fade)
			UiText(x.s)
			UiPop()
		end
	end
	local marks = shared.lilyMarks                                  -- spawn-menu flags: the seconds left over each
	if marks then
		for i = 1, #marks, 4 do
			local px, py, d = UiWorldToPixel(Vec(marks[i], marks[i + 1] + 0.7, marks[i + 2]))
			if d > 0 and d < 80 then
				local n = tostring(math.ceil(marks[i + 3]))
				UiPush()
				UiTranslate(px, py)
				UiAlign("center middle")
				UiFont("bold.ttf", 44)
				UiColor(0, 0, 0, 0.8)
				UiTranslate(2, 2)
				UiText(n)
				UiTranslate(-2, -2)
				UiColor(1, 1, 1, 0.6 + 0.4 * math.sin(t * 8))
				UiText(n)
				UiPop()
			end
		end
	end
end
