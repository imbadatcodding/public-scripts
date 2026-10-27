--comments are for claude fixed beartrap skillcheck and other stuff


--======================================================================
--  VIOLENCE DISTRICT HUB   (Matcha / Drawing UI)
--  Tabs: Main (all features & collection) | Characters
--  Inventory is a local catalog. It does not grant server ownership.
--  No calibration. Skillcheck rotation offset is derived from the
--  AbsolutePosition binding at read time -- zero setup. The Veil aimbot
--  measures the projectile's gravity multiplier off your own throws.
--  Stop with:  _G.vdHub.stop()
--======================================================================
-- Resolve JDUI before stopping the existing hub, so download failure is recoverable.
local jdOK,jdSource=pcall(function() return game:HttpGet("https://raw.githubusercontent.com/jdev-studio/jdui/refs/heads/main/JDUI") end)
assert(jdOK and type(jdSource)=="string","Unable to download JDUI: "..tostring(jdSource))
local jdFactory,jdError=loadstring(jdSource)
assert(jdFactory,jdError)
local previousHub = _G.vdHub
local vaultCacheSeed = previousHub and previousHub._vaultCache
if previousHub and previousHub.stop then
    local ok, stopped = pcall(previousHub.stop)
    if not ok or stopped == false then
        warn("[vdHub] Enable Unsafe LuaU and stop the previous hub before reloading.")
        return
    end
end

local Players     = game:GetService("Players")
local RunService  = game:GetService("RunService")
local Workspace   = game:GetService("Workspace")
local lp          = Players.LocalPlayer
local mouse       = lp:GetMouse()

--======================================================================
--  STATE / CONFIG
--======================================================================
local state = {
    running = true,
    version = "2026-10-27.2-beartrap",
    tab     = "main",
    cfg = {
        -- auto pallet
        p_enabled        = false,
        interactionRadius= 4,           -- game's DETECTION_RADIUS is 4 (from a PalletPoint)
        stunReach        = 5,           -- studs added to the board's thin (facing) axis = drop depth
        stunWidth        = 3,           -- studs added to the board's width axis
        stunHeight       = 4,           -- studs added to the board's tall axis
        cooldown         = 0.55,        -- MUST exceed the game's SPACE_COOLDOWN (0.5) or presses are eaten
        hz               = 90,
        p_dropKey        = 32,          -- Space. The game's pallet drop is isActionInput = Space.
                                        -- (R is isDropInput = put-down-gift, NOT pallets.)
        -- auto skillcheck
        sc_enabled       = false,
        sc_lead          = 2,           -- degrees before the centre of the success window
        sc_key           = 32,          -- fallback VK; kb_skillcheck follows the game's setting

        -- fast vault: current SurvivorVault movement-history rules
        fv_enabled       = false,      -- any approach angle while sprinting

        -- veil spear aimbot
        --   The throw is fully client-directed. Animations.lua line 308:
        --     Remotes.Killers.Veil.Spearthrow:FireServer(
        --         camera.CFrame.LookVector, speed, camera.CFrame.Position)
        --   So whatever the camera looks at on release IS the throw direction.
        --   Nothing is spoofed -- the spear really flies and the server's own
        --   hit detection resolves it normally. Same class as fast vault:
        --   perfect execution of a legitimate client input.
        --
        --   SPEED is a pure function of hold time (Animations.lua 285-297):
        --     hold >= 2s and not on cooldown -> 165, then a 30s move cooldown
        --     hold >= 1s                     -> 142.5
        --     otherwise                      -> hold * 150
        --     hold >= 7s                     -> auto-release
        --   We mirror that formula and the 30s cooldown, so while you are still
        --   charging the lead is solved against the speed the spear will
        --   ACTUALLY leave at -- the aim re-converges as the tier changes.
        --
        --   FLIGHT is semi-implicit Euler on Heartbeat (ProjectileHandler 36-45):
        --     v += (0, -g*dt*GMult, 0);   p += v*dt
        --   That drops MORE than a true parabola. After n steps the discrete
        --   drop is g*dt^2*n(n+1)/2 against the analytic g*t^2/2, so the excess
        --   is exactly 0.5*g*dt*t (~0.5 studs at t=0.3s -- a miss at range).
        --   So we solve the closed form against g' = g*(1 + dt/t), iterated,
        --   which lands ON the integrator's real trajectory rather than near it.
        --   Base g is read from memory (workspace+0x9C8 = 196.200; the .Gravity
        --   binding reads nil in Matcha). GMult is server-supplied per throw and
        --   never visible to us, so it is MEASURED off your real arcs: every
        --   flight is least-squares fitted for vertical accel and folded back
        --   into va_gmult.
        va_enabled       = false,
        va_fov           = 55,          -- max degrees off your crosshair to consider a target
        va_range         = 260,         -- studs
        va_smooth        = 1,           -- 1 = snap. Values ABOVE 1 are a real TIME
                                        -- CONSTANT, not a per-frame fraction:
                                        -- alpha = 1 - exp(-dt/tau), tau = (n-1)*0.015s.
                                        -- The old per-frame lerp converged inside ~60ms
                                        -- at loop rate however small it was set, which
                                        -- is exactly why it never looked like smoothing.
        va_sticky        = true,        -- once locked, hold that target while it stays
                                        -- alive / in range / solvable, instead of
                                        -- re-picking the nearest every single frame
        va_gmult         = 0.5,         -- gravity multiplier. MEASURED, not assumed: four
                                        -- real arcs fitted to 0.533 then 0.513, i.e. the
                                        -- spear falls at HALF workspace gravity (~98.1
                                        -- studs/s^2). Shipping the naive GMult=1 would have
                                        -- aimed for twice the true drop and sent every long
                                        -- throw high. Auto-cal keeps refining this live.
        va_autocal       = true,        -- fold each measured arc back into va_gmult
        va_los           = true,        -- require an unobstructed line to the target
        va_lead          = true,        -- solve the intercept against target velocity
        va_euler         = true,        -- correct for the discrete integrator's extra drop
        va_holdOnly      = true,        -- only steer while you are charging a throw.
                                        -- The charge is a HOLD binding resolved inside
                                        -- KillerActionController; MouseButton1 is the
                                        -- assumption. If your bind differs, turn this
                                        -- off and it steers whenever spearmode is on.
        va_aimHeight     = 0,           -- studs above the target's root to aim at
        va_originCam     = false,       -- launch origin: false = HRP+look*3+(0,1.5,0)
                                        -- (what ProjectileHandler uses), true = camera pos
                                        -- (what FireServer transmits). Unknown which the
                                        -- SERVER uses, so it is a switch, not a guess.

        -- ui
        theme            = 1,
        ui_opacity       = 1,
        ui_round         = 12,
        ui_scale         = 1,
        ui_motion        = true,
    },
}
_G.vdHub = state
local uiCapture = false          -- shared by the input drivers and Drawing panel

--======================================================================
--  MEMORY HELPERS  (no calibration path anywhere)
--======================================================================
local MEM_BASE = (type(getbase)=="function") and select(2, pcall(getbase)) or nil

-- Real "Unsafe LuaU" detector: read the module's PE header. First byte
-- of a valid PE image is 'M' (77). Reads silently fail when unsafe is off.
local _memOk, _memChk = false, -1
local function unsafeOn()
    local now = tick()
    if now - _memChk > 1 then
        _memChk = now
        if MEM_BASE then
            local ok, b = pcall(memory_read, "byte", MEM_BASE)
            _memOk = ok and b == 77
        else
            _memOk = false
        end
    end
    return _memOk
end

local function rdf(a)
    local ok, v = pcall(memory_read, "float", a)
    if ok and type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge then
        return v
    end
end

--======================================================================
--  AUTO PALLET  (presses SPACE when a killer is in the board's stun zone)
--  Verified against SurvivorController.v_u_97 (the isActionInput handler):
--    priority is vault -> palletSlide -> palletDrop, and it bails early on
--    Health <= 50, a "doing action" tag, or the 0.5s SPACE_COOLDOWN.
--  So we gate the press the same way:
--   1. Health > 50
--   2. within interactionRadius of a PalletPoint (game's DETECTION_RADIUS 4)
--   3. a killer inside the PrimaryPartPallet board's stun box
--   4. per-pallet cooldown > the game's 0.5s space cooldown
--======================================================================
local pallets      = {}
local blockers     = {}          -- VaultPoint / PalletPointSlide: they steal the Space press
local vaults       = {}          -- VaultTrigger parts: {x,y,z,flatLookX,flatLookZ}
local killerRoots  = {}
local lastDrop     = {}          -- per-pallet id -> tick of last R press
local pStat        = { elig = false, inZone = false, hp = true, nearD = nil, killD = nil }

local function myRoot()
    local ch = lp.Character
    return ch and ch:FindFirstChild("HumanoidRootPart")
end

-- the game refuses the drop below 50 HP, so don't waste presses
local function healthOk()
    local ch = lp.Character
    local hum = ch and ch:FindFirstChild("Humanoid")
    if not hum then return true end
    local h = hum.Health
    return (type(h) ~= "number") or h > 50
end

-- already mid-drop? the game sets this attribute on its own LocalScript
local function busy()
    local ch = lp.Character
    local sc = ch and ch:FindFirstChild("CheckInterractable")
    if not sc then return false end
    local ok, v = pcall(function() return sc:GetAttribute("isDroppingPallet") end)
    return ok and v == true
end

-- would this Space press get eaten by a vault / slide instead?
-- takes raw components + reads cached number triples: no property reads in here,
-- this runs inside the hot loop.
local function blockedNearby(mx, my, mz, r)
    local r2 = r * r
    for _, b in ipairs(blockers) do
        local dx, dy, dz = mx-b[1], my-b[2], mz-b[3]
        if (dx*dx + dy*dy + dz*dz) <= r2 then return true end
    end
    return false
end

-- Structure-agnostic pallet discovery.
-- Map layouts differ between rounds: on some, a pallet is a Model directly
-- under Map; on others it is Map > Model > Palletwrong(MeshPart) > parts, and
-- the container's own Size/CFrame are not readable. The ONE constant is a Part
-- named "PalletPoint" (what the game itself tags and scans for), so we anchor
-- on those and group them by their parent container.
-- NOTE: there is also a StringValue named "PalletPoint" nested inside the real
-- Part, hence the explicit ClassName == "Part" filter.
local function refreshPallets()
    local out, byParent, blocks, vaultPts = {}, {}, {}, {}
    local map = Workspace:FindFirstChild("Map")
    if not map then pallets = {} blockers = {} vaults = {} return end
    for _, d in ipairs(map:GetDescendants()) do
        local nm = d.Name
        if nm == "PalletPoint" and d.ClassName == "Part" then
            local par = d.Parent
            if par then
                local key = par.Address
                local e = byParent[key]
                if not e then
                    -- the physical board defines the stun zone; fall back to the
                    -- point itself if this layout has no PrimaryPartPallet
                    local board = par:FindFirstChild("PrimaryPartPallet")
                    if not board or not board.Size then board = d end
                    e = { board = board, pts = {}, id = board.Address }
                    byParent[key] = e
                    out[#out+1] = e
                end
                -- cache the point position as raw numbers: these never move
                -- mid-round, so the driver does pure arithmetic instead of a
                -- VM property read per point per frame.
                local p = d.Position
                if p then e.pts[#e.pts+1] = { p.X, p.Y, p.Z } end
            end
        elseif nm == "VaultPoint" or nm == "PalletPointSlide" then
            -- Space is shared: the game checks vault -> slide -> drop, so if one
            -- of these is in range the press vaults/slides INSTEAD of dropping.
            --
            -- These names are usually StringValue MARKERS, not geometry -- the
            -- real Part is the parent (e.g. VaultPoint lives inside VaultTrigger).
            -- Take the marker's own Position if it has one, else the parent's.
            -- Matching only on the name found nothing on maps that use
            -- VaultTrigger, which silently disabled this suppression entirely.
            local p = d.Position
            if not p then
                local par = d.Parent
                p = par and par.Position or nil
            end
            if p then
                blocks[#blocks+1] = { p.X, p.Y, p.Z }
            end
        end
        -- Fast vault needs the VaultTrigger PART, not the VaultPoint marker:
        -- the angle test is measured against the trigger's own CFrame. Cache
        -- its position and flat (horizontal) look vector as raw numbers --
        -- triggers never move mid-round, so the driver does no property reads.
        -- Each window has two antiparallel triggers, one per side; the bowtie
        -- means aligning to either one satisfies the test for both, so we do
        -- not need to know which side the server picked.
        if nm == "VaultTrigger" and d.ClassName == "Part" then
            local cf = d.CFrame
            if cf then
                local lv = cf.LookVector
                local fx, fz = lv.X, lv.Z
                local mag = math.sqrt(fx*fx + fz*fz)
                if mag > 1e-4 then
                    local pp = cf.Position
                    vaultPts[#vaultPts+1] = { pp.X, pp.Y, pp.Z, fx/mag, fz/mag }
                end
            end
        end
    end
    pallets = out
    blockers = blocks
    vaults   = vaultPts
    -- precompute each board's half-extents and which margin applies per axis
    for _, e in ipairs(out) do
        local ok, s = pcall(function() return e.board.Size end)
        if ok and s then
            local n = { s.X, s.Y, s.Z }
            local order = { 1, 2, 3 }
            table.sort(order, function(i, j) return n[i] < n[j] end)
            -- slot[axis] = 1 reach (thinnest) | 2 width (middle) | 3 height (largest)
            local slot = {}
            slot[order[1]], slot[order[2]], slot[order[3]] = 1, 2, 3
            e.ax = { n[1]*0.5, n[2]*0.5, n[3]*0.5, slot[1], slot[2], slot[3] }
        end
    end
end

-- Players:GetPlayers() is not always resolvable on this VM (the binding can go
-- missing on a stale service handle across rounds/respawns). Re-resolve the
-- service each call and fall back to GetChildren(), which returns the same
-- Player objects.
local function getPlayers()
    local svc = Players
    local ok, s = pcall(game.GetService, game, "Players")
    if ok and s then svc = s end
    if not svc then return {} end

    local ok2, list = pcall(function() return svc:GetPlayers() end)
    if ok2 and type(list) == "table" and #list > 0 then return list end

    local ok3, kids = pcall(function() return svc:GetChildren() end)
    if not ok3 or type(kids) ~= "table" then return {} end
    local out = {}
    for _, p in ipairs(kids) do
        if p.ClassName == "Player" then out[#out+1] = p end
    end
    return out
end

-- Am I actually playing right now? Between rounds (and while dead) the game
-- parks you on the Spectator team far from the map, which is why the HUD used
-- to report a pallet 7570 studs away and a permanent killer -- both readings
-- were true, just meaningless. Gate the status readouts on this.
local function roundLive()
    local ok, t = pcall(function() return lp.Team end)
    if not ok or not t then return false end
    local n = string.lower(tostring(t.Name or ""))
    if n:find("spectator") or n:find("lobby") then return false end
    return true
end

local function refreshKiller()
    local killers, others = {}, {}
    -- instance handles do NOT compare equal on this VM, so identify self by
    -- UserId/Name rather than `plr ~= lp`
    local myId, myName = nil, nil
    pcall(function() myId = lp.UserId end)
    pcall(function() myName = lp.Name end)
    for _, plr in ipairs(getPlayers()) do
        local isSelf = (myId and plr.UserId == myId) or (myName and plr.Name == myName)
        if not isSelf then
            local ch = plr.Character
            local root = ch and ch:FindFirstChild("HumanoidRootPart")
            if root then
                local tn = plr.Team and string.lower(tostring(plr.Team.Name or "")) or ""
                if tn:find("killer") or tn:find("jason") or tn:find("hunter") then
                    killers[#killers+1] = root
                else
                    others[#others+1] = root
                end
            end
        end
    end
    -- Prefer team-identified killers. The fallback to `others` exists for maps
    -- or modes where the Killer team isn't set yet -- but it must NOT fire when
    -- there simply is no opponent: pre-round (everyone Spectator, or a solo
    -- server) `others` is full of untagged non-killers, which made the HUD read
    -- "Killer: YES" permanently. Only fall back once a round is actually live.
    if #killers > 0 then
        killerRoots = killers
    elseif roundLive() then
        killerRoots = others
    else
        killerRoots = {}
    end

    -- killer distance is a STATUS READOUT only, never a trigger input, so it is
    -- computed here at 2Hz instead of in the driver. Each .Position read costs
    -- ~0.08ms on this VM -- far too expensive to do 90x a second for a label.
    local me = myRoot()
    local mp = me and me.Position
    if not mp then pStat.killD = nil return end
    local best = nil
    for i = 1, #killerRoots do
        local kp = killerRoots[i].Position
        if kp then
            local dx, dy, dz = mp.X-kp.X, mp.Y-kp.Y, mp.Z-kp.Z
            local d2 = dx*dx + dy*dy + dz*dz
            if not best or d2 < best then best = d2 end
        end
    end
    pStat.killD = best and math.sqrt(best) or nil
    if pStat.killD and pStat.killD > 200 then pStat.killD = nil end
end

-- collectors (slow)
-- NOTE: there is deliberately NO periodic pallet rescan. Pallets do not move
-- mid-round, so the ~120ms Map:GetDescendants() runs ONCE per round, driven by
-- the round watcher below. Re-scanning on a timer was pure overhead.

-- ROUND WATCHER
-- Map's contents are wiped and repopulated on every round start (the Folder
-- itself may or may not be reused). Holding pallets from the previous round
-- means reading destroyed instances, so drop the list the moment the map
-- clears and rebuild it as soon as the new one is in.
-- Cheap by design: FindFirstChild + one child-count read, nothing recursive.
task.spawn(function()
    local lastAddr, lastCount = nil, -1
    local armed = false          -- true once we've seen the map go empty/new
    while state.running do
        local map   = Workspace:FindFirstChild("Map")
        local addr  = map and map.Address or nil
        local count = map and #map:GetChildren() or 0

        if count == 0 then
            -- between rounds: nothing valid to act on
            if #pallets > 0 or #blockers > 0 then
                pallets, blockers, vaults, lastDrop = {}, {}, {}, {}
            end
            armed = true
        elseif addr ~= lastAddr or lastCount <= 0 or armed then
            -- new map instance, or the old one just repopulated -> round start
            pallets, blockers, vaults, lastDrop = {}, {}, {}, {}
            task.wait(1)               -- let the map finish streaming in
            pcall(refreshPallets)
            armed = false
        end

        lastAddr, lastCount = addr, count
        task.wait(1)
    end
end)
task.spawn(function()
    while state.running do
        pcall(refreshKiller)   -- never let one bad frame kill the collector
        task.wait(0.5)
    end
end)

-- Is a world position inside the pallet board's stun zone?
-- We transform the point into the board's own space and test it against the
-- board's half-extents plus per-axis margins. The board is a thin tall wall:
--   thinnest Size axis  = facing  (the direction the board sweeps when dropped)
--   largest  Size axis  = height  (vertical)
--   remaining axis      = width   (along the board)
-- Using the board's real Size + CFrame makes this correct at any orientation,
-- so "in stun range" tracks the physical board, not the survivor's position.
-- The axis classification is computed ONCE per pallet at scan time (pal.ax),
-- so the hot path is just a transform plus three compares.
local function inStunZone(pal, worldPos, m)
    local ax = pal.ax
    if not ax then return false end
    local ok, rel = pcall(function() return pal.board.CFrame:PointToObjectSpace(worldPos) end)
    if not ok or not rel then return false end
    if math.abs(rel.X) > ax[1] + m[ax[4]] then return false end
    if math.abs(rel.Y) > ax[2] + m[ax[5]] then return false end
    if math.abs(rel.Z) > ax[3] + m[ax[6]] then return false end
    return true
end

-- reused every frame so the hot loop never allocates. [1]=reach [2]=width [3]=height,
-- matching the slot indices baked into pal.ax by refreshPallets().
local marginBuf = { 0, 0, 0 }
local atBuf     = {}   -- pallets I'm standing at this frame (pass 1 -> pass 2)
local kposBuf   = {}   -- killer positions, read only when pass 1 found something

-- driver (fast)
task.spawn(function()
    while state.running do
        local c = state.cfg
        local elig, zone = false, false
        local nearD = nil
        if c.p_enabled then
            local root = myRoot()
            local hpOk = healthOk()
            if root and hpOk then
                local myp = root.Position
                local mx, my, mz = myp.X, myp.Y, myp.Z
                local now = tick()
                local ir2 = c.interactionRadius * c.interactionRadius
                marginBuf[1] = c.stunReach
                marginBuf[2] = c.stunWidth
                marginBuf[3] = c.stunHeight

                -- PASS 1 (cheap): pure arithmetic on cached numbers, zero VM
                -- property reads. Finds which pallets I'm actually standing at.
                -- Almost every frame this finds none and we stop right here.
                local atCount = 0
                for i = 1, #pallets do
                    local pal = pallets[i]
                    local pts = pal.pts
                    local near = false
                    for j = 1, #pts do
                        local pp = pts[j]
                        local dx, dy, dz = mx-pp[1], my-pp[2], mz-pp[3]
                        local d2 = dx*dx + dy*dy + dz*dz
                        if not nearD or d2 < nearD then nearD = d2 end
                        if d2 <= ir2 then near = true end
                    end
                    if near then
                        atCount = atCount + 1
                        atBuf[atCount] = pal
                    end
                end

                -- PASS 2 (expensive): only now do we touch the VM. Killer
                -- .Position reads cost ~0.08ms EACH, so they are gated behind
                -- pass 1 -- no point tracking the killer from 6000 studs away.
                if atCount > 0 then
                    elig = true
                    local kn = 0
                    for i = 1, #killerRoots do
                        local kp = killerRoots[i].Position
                        if kp then
                            kn = kn + 1
                            kposBuf[kn] = kp
                        end
                    end
                    for i = 1, atCount do
                        local pal = atBuf[i]
                        for j = 1, kn do
                            if inStunZone(pal, kposBuf[j], marginBuf) then
                                zone = true
                                if (now - (lastDrop[pal.id] or 0)) >= c.cooldown
                                   and not busy()
                                   and not blockedNearby(mx, my, mz, c.interactionRadius) then
                                    keypress(c.p_dropKey); task.wait(0.02); keyrelease(c.p_dropKey)
                                    lastDrop[pal.id] = tick()
                                end
                                break
                            end
                        end
                    end
                end
            end
            pStat.hp = hpOk
        end
        pStat.elig, pStat.inZone = elig, zone
        -- A pallet thousands of studs away is not "the nearest pallet", it's
        -- noise from the lobby/spectator spawn. Report a distance only when it
        -- could plausibly matter this round.
        local nd = nearD and math.sqrt(nearD) or nil
        pStat.nearD = (nd and nd <= 200) and nd or nil
        task.wait(1 / state.cfg.hz)
    end
end)

--======================================================================
--  AUTO SKILLCHECK
--  The grader still uses Goal+102 .. Goal+116. GUI Rotation moved from
--  +0xE8 to +0xD8 in the current build; +0xE8 is now the screen centre Y.
--  Resolve the rotation/sin/cos/geometry layout together, never a bare float.
--======================================================================
local scHits, scChecks = 0, 0
local scLast = { l = nil, g = nil, win = nil }
local scStat = { status = "Disabled", key = "Space", misses = 0, errors = 0 }
state.skillcheck = { status = scStat, timing = scLast }
local scGui = { refreshAt = 0, resolveAt = 0 }
local scTrack = {}
local scHeld, scInput, scInputAt, scWasEnabled = nil, nil, 0, false

local function scFinite(v)
    return type(v) == "number" and v == v and math.abs(v) < 1000000
end

local function scRotationSignature(inst, off, ap)
    if not inst or not ap or not scFinite(ap.X) or not scFinite(ap.Y) then return false end
    local a = inst.Address + off
    -- AbsoluteSize's binding is stale in this build too. Check the actual
    -- geometry against AbsolutePosition, then its centre and rotation cache.
    local x, y, w, h = rdf(a + 0x24), rdf(a + 0x28), rdf(a + 0x2C), rdf(a + 0x30)
    if not x or not y or not w or not h or w <= 0 or h <= 0 or w > 16384 or h > 16384 then return false end
    if math.abs(x - ap.X) > 0.75 or math.abs(y - ap.Y) > 0.75 then return false end
    local cx, cy = rdf(a + 0x0C), rdf(a + 0x10)
    if not cx or not cy or math.abs(cx - x - w * 0.5) > 1 or math.abs(cy - y - h * 0.5) > 1 then return false end
    local angle, sn, cs = rdf(a), rdf(a + 4), rdf(a + 8)
    if not scFinite(angle) or not sn or not cs then return false end
    local rad = math.rad(angle % 360)
    return math.abs(sn - math.sin(rad)) < 0.035 and math.abs(cs - math.cos(rad)) < 0.035
end

local function resolveSkillOffset(line, goal)
    local lap, gap = line.AbsolutePosition, goal.AbsolutePosition
    local function matches(off)
        return scRotationSignature(line, off, lap) and scRotationSignature(goal, off, gap)
    end
    for _, off in ipairs({ 0xD8, 0xE8 }) do
        if matches(off) then return off end
    end
    for off = 0x80, 0x240, 4 do
        if off ~= 0xD8 and off ~= 0xE8 and matches(off) then return off end
    end
end

local function readSkillRots(line, goal, off)
    if not off then return nil end
    local lr, gr = rdf(line.Address + off), rdf(goal.Address + off)
    if not scFinite(lr) or not scFinite(gr) or lr < -3600 or gr < -3600 then return nil end
    return lr, gr
end

-- Separate sampling from input so a reset, chained goal, or held physical key
-- cannot produce repeated presses. A stationary/hidden needle never arms.
local function scAdvance(t, lr, gr, now, lead)
    local previous = t.line
    local reset = t.goal == nil or math.abs(gr - t.goal) > 0.5
        or (previous ~= nil and lr < previous - 2)
    if reset then
        t.fired, t.counted, t.missed = false, false, false
        t.motionAt, t.motionLine, t.rate = nil, nil, nil
    end
    local moved = previous ~= nil and lr > previous + 0.001
    if moved then
        if t.motionAt then
            local dt = now - t.motionAt
            if dt > 0 and dt < 0.5 then
                local rate = (lr - t.motionLine) / dt
                if rate > 0 and rate < 10000 then
                    t.rate = t.rate and (t.rate * 0.5 + rate * 0.5) or rate
                end
            end
        end
        t.motionAt, t.motionLine = now, lr
    end
    t.line, t.goal = lr, gr
    local active = lr > 0.05 and t.motionAt ~= nil and now - t.motionAt <= 0.12
    local newCheck = active and not t.counted
    if newCheck then t.counted = true end
    local lo, hi = gr + 102, gr + 116
    local threshold = math.clamp(gr + 109 - math.clamp(lead or 0, 0, 10)
        - (t.rate or 0) / 120, lo + 0.25, hi - 0.25)
    local missed = active and not t.fired and not t.missed and lr > hi
    if missed then t.missed = true end
    return active and not t.fired and lr >= threshold and lr <= hi, newCheck, missed, lo, hi
end

local SC_KEYS = {
    Space=32, Tab=9, Return=13, Enter=13, Escape=27, Backspace=8,
    Insert=45, Delete=46, Home=36, End=35, PageUp=33, PageDown=34,
    Left=37, Up=38, Right=39, Down=40, CapsLock=20,
    LeftShift=160, RightShift=161, LeftControl=162, RightControl=163,
    LeftAlt=164, RightAlt=165, Minus=189, Equals=187, LeftBracket=219,
    RightBracket=221, BackSlash=220, Semicolon=186, Quote=222,
    Comma=188, Period=190, Slash=191, Backquote=192,
    KeypadZero=96, KeypadOne=97, KeypadTwo=98, KeypadThree=99,
    KeypadFour=100, KeypadFive=101, KeypadSix=102, KeypadSeven=103,
    KeypadEight=104, KeypadNine=105, KeypadMultiply=106, KeypadPlus=107,
    KeypadMinus=109, KeypadPeriod=110, KeypadDivide=111, KeypadEnter=13,
}
local function scInputFor(name, fallback)
    if type(name) ~= "string" or name == "" then
        local code = tonumber(fallback) or 32
        return { code = code, name = code == 32 and "Space" or ("VK " .. tostring(code)) }
    end
    if name == "MouseButton1" or name == "MouseButton2" then
        return { mouse = name == "MouseButton1" and 1 or 2, name = name }
    end
    local code = SC_KEYS[name]
    if not code and #name == 1 and name:match("[%w]") then code = string.byte(name:upper()) end
    local f = tonumber(name:match("^F(%d+)$"))
    if not code and f and f >= 1 and f <= 24 then code = 111 + f end
    return code and { code = code, name = name } or nil
end

local function scReleaseInput()
    local held = scHeld
    scHeld = nil
    if not held then return end
    if held.mouse == 1 then pcall(mouse1release)
    elseif held.mouse == 2 then pcall(mouse2release)
    else pcall(keyrelease, held.code) end
end

local function scInputDown(input)
    if input.mouse == 1 then return ismouse1pressed() end
    if input.mouse == 2 then return ismouse2pressed() end
    return iskeypressed(input.code)
end

local function scPress(input)
    scHeld = input
    local ok, err
    if input.mouse == 1 then ok, err = pcall(mouse1press)
    elseif input.mouse == 2 then ok, err = pcall(mouse2press)
    else ok, err = pcall(keypress, input.code) end
    if ok then task.wait(0.025) end
    scReleaseInput()
    return ok, err
end

-- Escape starts with TrapPerfect at needle+168, then advances TrapGoal
-- after each result. The needle accumulates rotations across the chain.
local function scTrapGoal(lr, perfect, goal)
    if not scFinite(lr) or not scFinite(perfect) then return nil end
    if lr <= perfect + 116 then return perfect end
    if scFinite(goal) and goal > perfect + 116 then return goal end
    return perfect
end

local function scRefreshGui(now)
    if now >= scGui.refreshAt then
        scGui.refreshAt = now + 0.25
        local pg = lp:FindFirstChild("PlayerGui")
        local gui = pg and pg:FindFirstChild("SkillCheckPromptGui")
        local check = gui and gui:FindFirstChild("Check")
        local line = check and check:FindFirstChild("Line")
        local char = lp.Character
        local trapped = char and char:GetAttribute("Trapped") == true
        local goal = check and check:FindFirstChild(trapped and "TrapPerfect" or "Goal")
        local trapGoal = trapped and check and check:FindFirstChild("TrapGoal") or nil
        local tid = trapGoal and trapGoal.Address
        local lid, gid = line and line.Address, goal and goal.Address
        if lid ~= scGui.lid or gid ~= scGui.gid or trapped ~= scGui.trapped or tid ~= scGui.tid then
            scGui.off, scGui.resolveAt = nil, 0
            scTrack = {}
            scStat.offset = nil
        end
        scGui.line, scGui.goal, scGui.lid, scGui.gid = line, goal, lid, gid
        scGui.trapped, scGui.trapGoal, scGui.tid = trapped, trapGoal, tid
        scStat.mode = trapped and "Beartrap escape" or "Generator / healing"
    end
    if scGui.line and scGui.goal and not scGui.off and now >= scGui.resolveAt then
        scGui.resolveAt = now + 0.5
        scGui.off = resolveSkillOffset(scGui.line, scGui.goal)
        if scGui.off and scGui.trapped then
            if not scGui.trapGoal or not scRotationSignature(scGui.trapGoal, scGui.off, scGui.trapGoal.AbsolutePosition) then
                scGui.off = nil
            end
        end
        scStat.offset = scGui.off
    end
end

local function scStep()
    local c = state.cfg
    if not c.sc_enabled or not unsafeOn() then
        scWasEnabled = false
        scStat.status = c.sc_enabled and "Enable Unsafe LuaU" or "Disabled"
        scReleaseInput()
        return
    end
    if not scWasEnabled then
        scWasEnabled = true
        scTrack = {}
        scGui.refreshAt, scInputAt = 0, 0
    end
    if uiCapture or (type(isrbxactive) == "function" and not isrbxactive()) then
        scTrack = {}
        scStat.status = "Waiting for game focus"
        return
    end
    local now = os.clock()
    scRefreshGui(now)
    if now >= scInputAt then
        scInputAt = now + 0.5
        local name = lp:GetAttribute("kb_skillcheck")
        scInput = scInputFor(name, c.sc_key)
        scStat.key = scInput and scInput.name or tostring(name)
    end
    if not scGui.line or not scGui.goal then
        scStat.status = "Waiting for prompt"
        return
    end
    if not scGui.off then
        scStat.status = "Resolving GUI layout"
        return
    end
    local lr, gr = readSkillRots(scGui.line, scGui.goal, scGui.off)
    if lr and scGui.trapped then
        local trapRotation = scGui.trapGoal and rdf(scGui.trapGoal.Address + scGui.off)
        gr = scTrapGoal(lr, gr, trapRotation)
    end
    if not lr or not gr then
        scGui.off, scStat.offset, scTrack = nil, nil, {}
        scStat.status = "Refreshing GUI layout"
        return
    end
    local fire, newCheck, missed, lo, hi = scAdvance(scTrack, lr, gr, now, c.sc_lead)
    scLast.l, scLast.g = lr, gr
    scLast.win = string.format("%.0f..%.0f", lo, hi)
    if newCheck then scChecks = scChecks + 1 end
    if missed then scStat.misses = scStat.misses + 1 end
    if fire then
        if not scInput then
            scStat.status = "Unsupported skillcheck bind"
        elseif scInputDown(scInput) then
            scStat.status = "Release " .. scInput.name
        else
            scTrack.fired = true
            local ok, err = scPress(scInput)
            if ok then
                scHits = scHits + 1
                scStat.status, scStat.error = "Pressed " .. scInput.name, nil
            else
                scTrack.fired = false
                error(err)
            end
        end
    elseif scTrack.fired then scStat.status = "Input sent"
    elseif scTrack.missed then scStat.status = "Window passed"
    elseif scTrack.motionAt and now - scTrack.motionAt <= 0.12 then scStat.status = "Following needle"
    else scStat.status = "Waiting for check" end
end

task.spawn(function()
    while state.running do
        local ok, err = pcall(scStep)
        if not ok then
            scReleaseInput()
            scTrack = {}
            scStat.error, scStat.status = tostring(err), "Retrying after read error"
            scStat.errors = scStat.errors + 1
        end
        task.wait(not ok and 0.1 or (state.cfg.sc_enabled and 1 / 240 or 0.1))
    end
    scReleaseInput()
end)

--======================================================================
--  ALWAYS FAST VAULT
--  The current controller calls SurvivorVault.evaluate on recent movement
--  samples, then sends its chosen tier with the normal vault request. Its old
--  40-degree yaw test is no longer the decision point.
--
--  Resolve ONLY that module's five-field signature once and cache its slots.
--  Relax the approach distance/pace/direction rules while enabled. Sprinting,
--  grounding, movement locks and the game's allowed-speed gate still apply.
--  No per-frame rotation or velocity writes are needed.
--======================================================================
local FV_ORIGINAL = {
    DISTANCE = 3, REPEAT_DISTANCE = 3.5, DOT = 0.7071067811865476,
    MIN_SPEED = 12.5, ARRIVE_GRACE = 0.12,
}
-- A vault can sample zero displacement immediately before its windup.
-- A negative pace threshold accepts that sample and keeps the sampler's
-- distance / MIN_SPEED history calculation finite (zero would make 0/0).
local FV_PATCH = { DISTANCE = 0, REPEAT_DISTANCE = 0, DOT = -1, MIN_SPEED = -1 }
local FV_KEYS = { "DISTANCE", "REPEAT_DISTANCE", "DOT", "MIN_SPEED" }
local fvStat = { status = "Disabled", ready = false, holding = false, vaults = 0, fast = 0, scans = 0 }
local fvCache, fvResolving, fvAttemptedFor = nil, false, nil
local fvResolveGeneration, fvNextResolveAt, fvRetryDelay = 0, 0, 5
local fvEnabled = state.cfg.fv_enabled
local fvFault = nil
local fvCharId, fvLastCount = nil, nil

local function fvCancelResolve()
    fvResolveGeneration = fvResolveGeneration + 1
    fvAttemptedFor, fvNextResolveAt, fvRetryDelay = nil, 0, 5
    -- Keep the in-flight flag until its worker exits; scans must not overlap.
end

local function fvSetEnabled(enabled)
    state.cfg.fv_enabled = enabled
    if fvEnabled ~= enabled then
        fvEnabled = enabled
        fvCancelResolve()
        fvStat.error = nil
    end
end

local function fvSurvivorReady()
    local team = lp.Team
    return not team or team.Name == "Survivors"
end

local function fvSame(a, b)
    return scFinite(a) and type(b) == "number" and math.abs(a - b) <= math.max(1, math.abs(b)) * 0.000001
end

local function fvRead(cache, key)
    local row = cache and cache.byKey[key]
    if not row then return nil end
    local ok, v = pcall(memory_read, "double", row.addr)
    return ok and scFinite(v) and v or nil
end

local function fvBuildCache(rows)
    if type(rows) ~= "table" or #rows == 0 then return nil, "Survivor module not loaded yet" end
    if #rows ~= 5 then return nil, "Multiple vault tables found; waiting for a unique match" end
    local cache = { rows = rows, byKey = {}, originals = {}, written = {}, job = game.JobId }
    for _, row in ipairs(rows) do
        if type(row) ~= "table" or row.type ~= "number" or type(row.addr) ~= "number"
            or not FV_ORIGINAL[row.key] or cache.byKey[row.key] then
            return nil, "Unexpected vault table layout"
        end
        cache.byKey[row.key] = row
        local value = fvRead(cache, row.key)
        local original = FV_ORIGINAL[row.key]
        local patched = FV_PATCH[row.key] ~= nil and fvSame(value, FV_PATCH[row.key])
        if not fvSame(value, original) and not patched then return nil, "Unexpected vault rule: " .. row.key end
        -- A previous run can leave a partial or complete patch behind.
        -- Adopt only our exact known values, retaining the real restore values.
        cache.originals[row.key] = original
        cache.written[row.key] = patched and not fvSame(value, original)
    end
    for key in pairs(FV_ORIGINAL) do
        if not cache.byKey[key] then return nil, "Incomplete vault table" end
    end
    return cache
end

local function fvSetKey(cache, key, value)
    local ok, changed = pcall(applygc, cache.rows, key, value)
    local verified = fvSame(fvRead(cache, key), value)
    if verified then cache.written[key] = not fvSame(value, cache.originals[key]) end
    return ok and changed == 1 and verified
end

local function fvHasWrites()
    if fvCache then
        for _, key in ipairs(FV_KEYS) do if fvCache.written[key] then return true end end
    end
    return false
end

local function fvRestore()
    if not fvHasWrites() then fvStat.holding = false return true end
    if fvCache.job ~= game.JobId then
        -- The old DataModel is gone. Never write its addresses into a new game.
        fvCache, state._vaultCache = nil, nil
        fvStat.holding, fvStat.ready = false, false
        return true
    end
    if not unsafeOn() or not fvSame(fvRead(fvCache, "ARRIVE_GRACE"), fvCache.originals.ARRIVE_GRACE) then
        return false
    end
    local restored = true
    for _, key in ipairs(FV_KEYS) do
        if fvCache.written[key] then
            local current = fvRead(fvCache, key)
            if fvSame(current, FV_PATCH[key]) then
                if not fvSetKey(fvCache, key, fvCache.originals[key]) then restored = false end
            elseif scFinite(current) then
                -- The game or another script already replaced our value.
                fvCache.written[key] = false
            else
                restored = false
            end
        end
    end
    fvStat.holding = fvHasWrites()
    return restored and not fvStat.holding
end

local function fvApply()
    if not fvCache or fvCache.job ~= game.JobId then return false, "Rejoin detected; reload the hub" end
    if not fvSame(fvRead(fvCache, "ARRIVE_GRACE"), fvCache.originals.ARRIVE_GRACE) then
        return false, "Vault cache needs refreshing"
    end
    for _, key in ipairs(FV_KEYS) do
        local value = fvRead(fvCache, key)
        if not fvSame(value, fvCache.originals[key])
            and not (fvCache.written[key] and fvSame(value, FV_PATCH[key])) then
            return false, "Vault rules changed"
        end
    end
    for _, key in ipairs(FV_KEYS) do
        if not fvSame(fvRead(fvCache, key), FV_PATCH[key]) then
            if not fvSetKey(fvCache, key, FV_PATCH[key]) then
                fvRestore()
                return false, "Could not apply vault rules"
            end
        end
    end
    return true
end

local function fvResolve(characterId)
    if fvResolving then
        fvStat.status = "Resolving vault module"
        return
    end
    if fvAttemptedFor == characterId and tick() < fvNextResolveAt then
        fvStat.status = string.format("Retrying vault in %ds", math.max(1, math.ceil(fvNextResolveAt - tick())))
        return
    end
    fvResolving, fvAttemptedFor = true, characterId
    local generation, job = fvResolveGeneration, game.JobId
    local function current()
        local ch = lp.Character
        return state.running and state.cfg.fv_enabled
            and generation == fvResolveGeneration and game.JobId == job
            and ch and ch.Address == characterId and fvSurvivorReady() and unsafeOn()
    end
    fvStat.status = "Resolving vault module"
    task.spawn(function()
        task.wait(0.35)
        if not current() then
            fvResolving = false
            return
        end
        local ok, cache, err = pcall(function()
            if vaultCacheSeed and vaultCacheSeed.job == game.JobId then
                local reused = fvBuildCache(vaultCacheSeed.rows)
                vaultCacheSeed = nil
                if reused then return reused end
            end
            -- Retry only unresolved modules, with backoff after each miss.
            -- A healthy cache survives toggles and ordinary respawns.
            fvStat.scans = fvStat.scans + 1
            local rows = findgc("REPEAT_WINDOW_TIME", {
                DISTANCE="number", REPEAT_DISTANCE="number", DOT="number",
                MIN_SPEED="number", ARRIVE_GRACE="number",
            })
            return fvBuildCache(rows)
        end)
        fvResolving = false
        if not current() then return end
        if ok and cache then
            fvCache, state._vaultCache = cache, cache
            fvStat.ready, fvStat.error = true, nil
            fvFault, fvNextResolveAt, fvRetryDelay = nil, 0, 5
        else
            fvNextResolveAt = tick() + fvRetryDelay
            fvRetryDelay = math.min(fvRetryDelay * 2, 30)
            fvStat.error = tostring(ok and err or cache)
            fvStat.status = "Vault lookup failed; retry scheduled"
        end
    end)
end

local function fvObserveVault()
    local ch = lp.Character
    local id = ch and ch.Address
    if id ~= fvCharId then
        fvCancelResolve()
        fvCharId, fvLastCount = id, nil
        fvStat.tier, fvStat.reason = nil, nil
    end
    if not ch then return nil end
    local count = ch:GetAttribute("__VaultFireCount")
    local tier, reason = ch:GetAttribute("VaultTier"), ch:GetAttribute("VaultReason")
    if type(count) == "number" then
        if fvLastCount and count > fvLastCount then
            local delta = count - fvLastCount
            fvStat.vaults = fvStat.vaults + delta
            if tier == "fast" then fvStat.fast = fvStat.fast + delta end
        end
        fvLastCount = count
    end
    if type(tier) == "string" then fvStat.tier = tier end
    if type(reason) == "string" then fvStat.reason = reason end
    return id
end

task.spawn(function()
    while state.running do
        local ok, err = pcall(function()
            local id = fvObserveVault()
            fvSetEnabled(state.cfg.fv_enabled)
            if not state.cfg.fv_enabled then
                local restored = fvRestore()
                if restored then fvFault = nil end
                fvStat.status = restored and "Disabled" or "Restore pending: enable Unsafe LuaU"
            elseif not unsafeOn() then
                fvStat.status = fvHasWrites() and "Restore pending: enable Unsafe LuaU" or "Enable Unsafe LuaU"
            elseif not fvCache then
                if not id then
                    fvStat.status = "Waiting for character"
                elseif not fvSurvivorReady() then
                    fvStat.status = "Waiting for Survivor team"
                else
                    fvResolve(id)
                end
            elseif fvFault and tick() < fvNextResolveAt then
                fvStat.status = string.format("Recovering vault in %ds", math.max(1, math.ceil(fvNextResolveAt - tick())))
            else
                local applied, why = fvApply()
                fvStat.holding = applied
                fvStat.status = applied and "Ready - sprint to vault" or why
                fvStat.error = applied and nil or why
                if not applied then
                    fvFault = why
                    fvNextResolveAt = tick() + 5
                    local stale = fvCache.job ~= game.JobId
                        or not fvSame(fvRead(fvCache, "ARRIVE_GRACE"), fvCache.originals.ARRIVE_GRACE)
                    -- Never restore through stale addresses. Re-resolve the live
                    -- table; known leftover patch values can be adopted above.
                    if stale or fvRestore() then
                        fvCache, state._vaultCache = nil, nil
                        fvStat.ready, fvStat.holding = false, false
                        fvAttemptedFor = id
                    end
                else
                    fvFault = nil
                end
            end
        end)
        if not ok then
            fvStat.error, fvStat.status = tostring(err), "Retrying after read error"
        end
        task.wait(0.2)
    end
end)

--======================================================================
--  VEIL SPEAR AIMBOT
--
--  Everything here is derived from the game's own two scripts, not probed:
--
--   Workspace.<killer>.Animations  (the throw)
--     line 308:  Spearthrow:FireServer(cam.CFrame.LookVector, speed,
--                                      cam.CFrame.Position)
--     The DIRECTION is a client argument. Point the camera and the spear
--     goes there -- no state is faked, the server resolves the hit itself.
--     lines 285-297 give speed purely from hold time; line ~400 auto-
--     releases at 7s; a 165 throw starts a 30s move cooldown.
--
--   PlayerScripts.Mechanics.Veil.ProjectileHandler  (the flight)
--     lines 36-45:  v += (0, -g*dt*GMult, 0);  p += v*dt   on Heartbeat
--     line 65:      origin = HRP.Position + HRP.LookVector*3 + (0,1.5,0)
--
--  So the aim is a boundary-value problem: fixed launch speed, known
--  gravity, solve the launch angle that puts the spear where the target
--  will BE, against the discrete integrator the game actually runs.
--======================================================================

-- The camera's rotation matrix. Camera.CFrame is READ-ONLY through the
-- Matcha property bridge -- the write returns true and silently no-ops
-- (FieldOfView writes fine, and Part.CFrame writes fine, so it is specific
-- to this one property). Memory is the only channel.
--
-- Layout mirrors a Part's Primitive: row-major 3x3 then the position triple
-- 0x24 later. Currently at Camera+0xD8, but Roblox moves these between
-- versions (HRP's Primitive pointer already moved 0x128 -> 0x188), so it is
-- resolved by matching the live CFrame instead of trusted as a constant.
-- Three copies of the block exist; only the first is authoritative -- writes
-- to +0x184 and +0x244 had no effect on cam.CFrame.LookVector.
local vaRot, vaRotFor, vaWarmAt = nil, nil, 0

local function vaRotAddr()
    local cam = Workspace.CurrentCamera
    if not cam then return nil end
    local base = cam.Address
    if not base then return nil end
    if vaRotFor == base and vaRot then return vaRot end

    local now = os.clock()
    if now < vaWarmAt then return nil end
    vaWarmAt = now + 0.1

    local ok, res = pcall(function()
        local cf  = cam.CFrame
        if not cf then return nil end
        local lv, pos = cf.LookVector, cf.Position
        local function near(a, b, tol) return a and math.abs(a - b) <= tol end
        -- known-good slot first, then a sweep
        local cand = { 0xD8 }
        for o = 0x40, 0x400, 4 do cand[#cand+1] = o end
        for _, o in ipairs(cand) do
            -- column 2 of the rotation is -LookVector; position sits at +0x24
            if near(rdf(base + o +  8), -lv.X, 0.01)
           and near(rdf(base + o + 20), -lv.Y, 0.01)
           and near(rdf(base + o + 32), -lv.Z, 0.01)
           and near(rdf(base + o + 36), pos.X, 0.05)
           and near(rdf(base + o + 40), pos.Y, 0.05)
           and near(rdf(base + o + 44), pos.Z, 0.05) then
                return o
            end
        end
        return nil
    end)
    if ok and res then
        vaRot, vaRotFor = base + res, base
        return vaRot
    end
end

-- Write a look direction as an orthonormal basis. Column 0 = right,
-- column 1 = up, column 2 = -look, stored in row-major order.
local UP = Vector3.new(0, 1, 0)
local function vaWriteLook(addr, f)
    if not addr or not f then return false end
    local zv = -f
    local xv = UP:Cross(zv)
    if xv.Magnitude < 1e-4 then return false end        -- looking straight up/down
    xv = xv.Unit
    local yv = zv:Cross(xv)
    local ok = pcall(function()
        memory_write("float", addr +  0, xv.X)
        memory_write("float", addr +  4, yv.X)
        memory_write("float", addr +  8, zv.X)
        memory_write("float", addr + 12, xv.Y)
        memory_write("float", addr + 16, yv.Y)
        memory_write("float", addr + 20, zv.Y)
        memory_write("float", addr + 24, xv.Z)
        memory_write("float", addr + 28, yv.Z)
        memory_write("float", addr + 32, zv.Z)
    end)
    return ok
end

-- workspace.Gravity reads nil in Matcha (unsupported binding). It lives at
-- Workspace+0x9C8 -- verified as the single float/double hit across 0..0x1200.
-- Validated per read so a moved offset falls back instead of poisoning the solve.
local VA_G_DEFAULT = 196.2
local function vaBaseG()
    local a = Workspace.Address
    if a then
        local g = rdf(a + 0x9C8)
        if g and g > 20 and g < 2000 then return g end
    end
    return VA_G_DEFAULT
end

-- The game's Heartbeat step. Only used for the discrete-drop correction.
local VA_DT = 1 / 60

local vaStat = {
    target = nil, dist = nil, speed = nil, flight = nil, hold = 0,
    solved = false, tier = nil, cd = 0, drop = nil,
    measG = nil, measN = 0, gmult = nil, charging = false, addr = false,
}
local vaCdUntil = 0

--  Closed form for a fixed launch speed: solve for tan(theta) from
--    y = x*tan - g*x^2 / (2*s^2*cos^2)   ->   quadratic in tan
--  Two roots; take the low/flat arc (the fast one, and the one that stays
--  under ceilings). disc < 0 means the target is simply out of range.
local function vaAngle(ox, oy, oz, px, py, pz, s, g)
    local dx, dy, dz = px - ox, py - oy, pz - oz
    local flat = math.sqrt(dx * dx + dz * dz)
    if flat < 1e-3 then return nil end
    local s2 = s * s
    local disc = s2 * s2 - g * (g * flat * flat + 2 * dy * s2)
    if disc < 0 then return nil end
    local tan = (s2 - math.sqrt(disc)) / (g * flat)
    local ang = math.atan(tan)
    local ca, sa = math.cos(ang), math.sin(ang)
    if ca < 1e-4 then return nil end
    return Vector3.new(dx / flat * ca, sa, dz / flat * ca), flat / (s * ca)
end

-- Same solve, but against the integrator's effective gravity. Semi-implicit
-- Euler's excess drop is 0.5*g*dt*t, i.e. exactly what g*(1 + dt/t) produces
-- in the closed form -- so a couple of fixed-point steps put the analytic
-- solution onto the discrete curve.
local function vaSolve(ox, oy, oz, px, py, pz, s, g, euler)
    local dir, ft = vaAngle(ox, oy, oz, px, py, pz, s, g)
    if not dir then return nil end
    if euler then
        for _ = 1, 4 do
            local ge = g * (1 + VA_DT / math.max(ft, 1e-3))
            local d2, f2 = vaAngle(ox, oy, oz, px, py, pz, s, ge)
            if not d2 then break end
            local done = math.abs(f2 - ft) < 1e-4
            dir, ft = d2, f2
            if done then break end
        end
    end
    return dir, ft
end

-- Lead: the flight time depends on where the target will be, which depends
-- on the flight time. Iterate to the fixed point.
local function vaIntercept(o, tp, tv, s, g, euler)
    local dir, ft = vaSolve(o.X, o.Y, o.Z, tp.X, tp.Y, tp.Z, s, g, euler)
    if not dir then return nil end
    if tv then
        for _ = 1, 6 do
            local d2, f2 = vaSolve(o.X, o.Y, o.Z,
                tp.X + tv.X * ft, tp.Y + tv.Y * ft, tp.Z + tv.Z * ft, s, g, euler)
            if not d2 then break end
            local done = math.abs(f2 - ft) < 0.002
            dir, ft = d2, f2
            if done then break end
        end
    end
    return dir, ft
end

-- Speed the spear will leave at for a given hold, mirroring Animations 285-297
-- including the 30s lockout that follows a charged (165) throw.
local function vaSpeedFor(hold, now)
    if hold >= 2 and now >= vaCdUntil then return 165, "CHARGED" end
    if hold >= 1 then return 142.5, "FULL" end
    return math.max(hold * 150, 1), "PARTIAL"
end

--  Target tracking. Velocity is differenced from position history rather than
--  read off a .Velocity binding -- differencing is guaranteed to work here and
--  it also smooths the 1-frame jitter that would otherwise swing the lead.
local vaHist = {}

local function vaTrack(key, pos, now)
    local h = vaHist[key]
    if not h then
        vaHist[key] = { p = pos, t = now, v = Vector3.new(0, 0, 0) }
        return Vector3.new(0, 0, 0)
    end
    local dt = now - h.t
    if dt >= 0.02 then
        local inst = (pos - h.p) / dt
        -- clamp to something a survivor can physically do, then EMA
        if inst.Magnitude > 60 then inst = inst.Unit * 60 end
        h.v = h.v + (inst - h.v) * 0.35
        h.p, h.t = pos, now
    end
    return h.v
end

local vaRP = RaycastParams.new()
vaRP.FilterType = Enum.RaycastFilterType.Exclude

-- Matcha's workspace:Raycast is a STUB. It is a real function, it never errors,
-- and it returns nil for every cast -- verified by casting 40 studs straight
-- down into the floor we were standing on, both with and without RaycastParams:
-- nil each time. Blockcast pcalls false and Spherecast is absent, so this VM has
-- NO geometry probe at all.
--
-- That is a trap, because "nil hit" is exactly how a raycast reports "clear".
-- A naive LOS test therefore passes every single shot while looking like it
-- filters -- a toggle that cannot do what its label claims. So probe the binding
-- once against a ray that CANNOT miss (downward through our own character) and
-- latch the answer; the UI reads vaStat.losOK and says "unavailable" rather than
-- pretending the filter is live.
local vaRayCap = nil                -- nil = not yet probed, true = real, false = stub
local function vaRayUsable(myChar)
    if vaRayCap ~= nil then return vaRayCap end
    local hrp = myChar and myChar:FindFirstChild("HumanoidRootPart")
    if not hrp then return true end -- nothing to probe against yet; don't latch
    local ok, hit = pcall(function()
        local from = hrp.CFrame.Position + Vector3.new(0, 6, 0)
        return Workspace:Raycast(from, Vector3.new(0, -12, 0))
    end)
    vaRayCap = (ok and hit ~= nil) and true or false
    vaStat.losOK = vaRayCap
    return vaRayCap
end

local function vaLineOfSight(o, p, myChar, theirChar)
    if not vaRayUsable(myChar) then return true end
    local d = p - o
    local dist = d.Magnitude
    if dist < 1 then return true end
    local ok, hit = pcall(function()
        vaRP.FilterDescendantsInstances = { myChar, theirChar }
        return Workspace:Raycast(o, d, vaRP)
    end)
    if not ok then return true end          -- can't test -> don't block the shot
    return hit == nil
end

--======================================================================
--  ARC MEASUREMENT  (turns real throws into a calibrated GMult)
--
--  GMult is chosen server-side per throw and handed to the client only as a
--  `visualize` argument -- and RemoteEvent.OnClientEvent is nil in Matcha, so
--  it cannot be intercepted. But the client's own projectile is integrated
--  with that exact GMult, so watching one flight measures it directly.
--
--  y_n under the discrete scheme is
--     y0 + v0*t - 0.5*g*t^2 - 0.5*g*dt*t
--  which is an exact quadratic in t whose curvature is -0.5*g. So a plain
--  least-squares quadratic recovers g*GMult unbiased -- the half-step bias
--  lands entirely in the linear term.
--======================================================================
local vaFit = nil

local function vaFitReset() vaFit = nil end

local function vaFitPush(t, y)
    if not vaFit then
        vaFit = { n = 0, t0 = t, s0 = 0, s1 = 0, s2 = 0, s3 = 0, s4 = 0, y0 = 0, y1 = 0, y2 = 0 }
    end
    local f = vaFit
    local x  = t - f.t0
    local x2 = x * x
    f.n  = f.n + 1
    f.s0 = f.s0 + 1
    f.s1 = f.s1 + x
    f.s2 = f.s2 + x2
    f.s3 = f.s3 + x2 * x
    f.s4 = f.s4 + x2 * x2
    f.y0 = f.y0 + y
    f.y1 = f.y1 + y * x
    f.y2 = f.y2 + y * x2
    f.span = x
end

-- returns measured downward accel, or nil
local function vaFitSolve()
    local f = vaFit
    if not f or f.n < 8 or (f.span or 0) < 0.12 then return nil end
    local a11, a12, a13 = f.s0, f.s1, f.s2
    local a21, a22, a23 = f.s1, f.s2, f.s3
    local a31, a32, a33 = f.s2, f.s3, f.s4
    local function det3(b11,b12,b13, b21,b22,b23, b31,b32,b33)
        return b11*(b22*b33 - b23*b32) - b12*(b21*b33 - b23*b31) + b13*(b21*b32 - b22*b31)
    end
    local D = det3(a11,a12,a13, a21,a22,a23, a31,a32,a33)
    if math.abs(D) < 1e-12 then return nil end
    -- only the quadratic coefficient is needed: c2 = -0.5*g
    local D2 = det3(a11,a12,f.y0, a21,a22,f.y1, a31,a32,f.y2)
    local c2 = D2 / D
    local g = -2 * c2
    if g < 20 or g > 3000 then return nil end
    return g
end

--======================================================================
--  DRIVER
--======================================================================
task.spawn(function()
    local gateAt, isKiller, spearmode = 0, false, false
    local myChar, myHum = nil, nil
    local pressT, wasDown, releaseArmed = nil, false, false
    local prevProj = false
    local lastT, lockName = nil, nil

    while state.running do
        local c   = state.cfg
        local now = os.clock()
        -- Real frame delta. Smoothing needs this to be a time constant rather than
        -- a per-iteration fraction, or its feel changes with the loop rate. Clamped
        -- so a stall cannot produce alpha ~= 1 and teleport the aim.
        local dt = (lastT and (now - lastT)) or VA_DT
        lastT = now
        if dt <= 0 then dt = VA_DT elseif dt > 0.25 then dt = 0.25 end

        --------------------------------------------------------------
        -- cheap gate, refreshed at 10Hz (attribute + team reads are the
        -- expensive part, and neither changes inside 100ms)
        --------------------------------------------------------------
        if now >= gateAt then
            gateAt = now + 0.1
            local okg = pcall(function()
                myChar = lp.Character
                local team = lp.Team
                isKiller = (team and team.Name == "Killer") and true or false
                myHum  = myChar and myChar:FindFirstChild("Humanoid")
                spearmode = myChar and myChar:GetAttribute("spearmode") == true
                -- latch the raycast-capability probe as soon as there is a body to
                -- cast through, so the LOS chip tells the truth before the first
                -- target is ever evaluated
                if myChar then vaRayUsable(myChar) end
            end)
            if not okg then isKiller, spearmode = false, false end
        end

        --------------------------------------------------------------
        -- charge timing. The game measures hold from its own input-begin,
        -- so pressing and holding the same button gives us the same clock.
        -- Presses that started on the hub's own panel are ignored.
        --------------------------------------------------------------
        local down = false
        if not uiCapture then
            local okm, v = pcall(ismouse1pressed)
            down = okm and v and true or false
        end
        if down and not wasDown then
            pressT, releaseArmed = now, true
        elseif (not down) and wasDown and releaseArmed then
            -- mirror the 30s lockout a charged throw starts
            local held = pressT and (now - pressT) or 0
            if held >= 2 and now >= vaCdUntil then vaCdUntil = now + 30 end
            pressT, releaseArmed = nil, false
        end
        wasDown = down
        local hold = pressT and math.min(now - pressT, 7) or 0
        vaStat.hold     = hold
        vaStat.cd       = math.max(0, vaCdUntil - now)
        vaStat.charging = (pressT ~= nil)

        --------------------------------------------------------------
        -- arc measurement: sample the live projectile while it exists
        --------------------------------------------------------------
        if c.va_autocal or true then
            local proj = nil
            pcall(function() proj = Workspace:FindFirstChild("Spearprojectile") end)
            if proj then
                if not prevProj then vaFitReset() end
                prevProj = true
                pcall(function()
                    local pp = proj.PrimaryPart or proj:FindFirstChild("Spear1")
                    if pp then vaFitPush(now, pp.Position.Y) end
                end)
            elseif prevProj then
                prevProj = false
                local g = vaFitSolve()
                if g then
                    local base = vaBaseG()
                    vaStat.measG = g
                    vaStat.measN = (vaStat.measN or 0) + 1
                    vaStat.gmult = g / base
                    if c.va_autocal then
                        -- snap on the first arc of a session, then EMA so one
                        -- bad fit can't wrench the aim
                        local cur = c.va_gmult or 1
                        local w = ((vaStat.measN or 0) <= 1) and 1 or 0.6
                        c.va_gmult = cur + (vaStat.gmult - cur) * w
                    end
                end
                vaFitReset()
            end
        end

        --------------------------------------------------------------
        -- aim
        --------------------------------------------------------------
        local armed = c.va_enabled and isKiller and spearmode and unsafeOn()
        if armed and c.va_holdOnly and not vaStat.charging then armed = false end

        if not armed then
            vaStat.target, vaStat.solved, vaStat.dist = nil, false, nil
            vaStat.speed, vaStat.flight, vaStat.drop, vaStat.tier = nil, nil, nil, nil
            lockName, vaStat.held = nil, false
        else
            local addr = vaRotAddr()
            vaStat.addr = addr ~= nil
            local cam = Workspace.CurrentCamera
            local hrp = myChar and myChar:FindFirstChild("HumanoidRootPart")
            if addr and cam and hrp then
                local okAim = pcall(function()
                    local ccf  = cam.CFrame
                    local look = ccf.LookVector
                    local hcf  = hrp.CFrame

                    -- launch origin
                    local origin
                    if c.va_originCam then
                        origin = ccf.Position
                    else
                        origin = hcf.Position + hcf.LookVector * 3 + Vector3.new(0, 1.5, 0)
                    end

                    local speed, tier = vaSpeedFor(hold, now)
                    local g = vaBaseG() * (c.va_gmult or 1)
                    local cosFov = math.cos(math.rad(c.va_fov))

                    --------------------------------------------------
                    -- Pick a target. NEAREST enemy wins (was: closest to
                    -- the crosshair), among survivors that are alive, in
                    -- range, in FOV and actually reachable at this speed.
                    --
                    -- Sticky aim then overrides that: the target we already
                    -- hold keeps the lock for as long as it still passes
                    -- every one of those gates. Without it, a survivor
                    -- jogging past closer than your real target steals the
                    -- aim mid-charge and the spear leaves on the flick.
                    -- The lock is dropped when the target dies, leaves
                    -- range, or the throw ends (see the disarm branch).
                    --------------------------------------------------
                    local best, bestSol, bestFt, bestDist
                    local heldSol, heldFt, heldDist
                    for _, pl in ipairs(Players:GetPlayers()) do
                        if pl ~= lp then
                            local tm = pl.Team
                            if tm and tm.Name == "Survivors" then
                                local ch  = pl.Character
                                local thr = ch and ch:FindFirstChild("HumanoidRootPart")
                                local hum = ch and ch:FindFirstChild("Humanoid")
                                local hp  = hum and hum.Health
                                if thr and (type(hp) ~= "number" or hp > 0) then
                                    local tp = thr.Position + Vector3.new(0, c.va_aimHeight or 0, 0)
                                    local off = tp - origin
                                    local dist = off.Magnitude
                                    if dist > 1 and dist <= c.va_range then
                                        local isHeld = c.va_sticky and lockName == pl.Name
                                        local dot = off.Unit:Dot(look)
                                        -- solving is the expensive part, so only solve
                                        -- for a candidate that could actually win
                                        if dot >= cosFov
                                           and ((not best or dist < bestDist) or isHeld) then
                                            local tv = c.va_lead and vaTrack(pl.Name, thr.Position, now) or nil
                                            local dir, ft = vaIntercept(origin, tp, tv, speed, g, c.va_euler)
                                            if dir and ((not c.va_los)
                                                or vaLineOfSight(origin, tp, myChar, ch)) then
                                                if isHeld then
                                                    heldSol, heldFt, heldDist = dir, ft, dist
                                                end
                                                if not best or dist < bestDist then
                                                    best = pl.Name
                                                    bestSol, bestFt, bestDist = dir, ft, dist
                                                end
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end

                    -- the held target survived every gate -> keep it
                    if heldSol then
                        best = lockName
                        bestSol, bestFt, bestDist = heldSol, heldFt, heldDist
                    end
                    lockName    = best
                    vaStat.held = heldSol ~= nil

                    vaStat.target = best
                    vaStat.speed  = speed
                    vaStat.tier   = tier
                    vaStat.dist   = bestDist
                    vaStat.flight = bestFt
                    vaStat.solved = bestSol ~= nil
                    -- how far above the straight line we are holding, in studs
                    vaStat.drop = bestFt and (0.5 * g * bestFt * bestFt + 0.5 * g * VA_DT * bestFt) or nil

                    if bestSol then
                        local want = bestSol
                        local sm = c.va_smooth or 1
                        if sm > 1 then
                            -- Exponential approach on a real time constant, so the feel
                            -- is identical at 60Hz and at 144Hz. Smoothing from the
                            -- camera's ACTUAL direction (not from our own last command)
                            -- is deliberate: it lets your mouse move the camera and
                            -- have the assist ease in from wherever you left it,
                            -- instead of fighting you frame by frame.
                            local tau   = (sm - 1) * 0.015
                            local a     = 1 - math.exp(-dt / tau)
                            local blend = look + (want - look) * a
                            if blend.Magnitude > 1e-4 then want = blend.Unit end
                        end
                        vaWriteLook(addr, want)
                    end
                end)
                if not okAim then vaStat.solved = false end
            else
                vaStat.solved = false
            end
        end

        task.wait(1 / 144)
    end
end)

--======================================================================
--  LOCAL INVENTORY CATALOG
--  Read catalog assets once, on request. Never infer ownership from a
--  Matcha InvokeServer return: Hybrid reports dispatch, not the response.
--======================================================================
local inventory = {
    categories = {
        { key = "killers", label = "Killers" },
        { key = "items", label = "Items" },
        { key = "emotes", label = "Emotes" },
        { key = "skins", label = "Killer skins" },
        { key = "itemskins", label = "Item skins" },
    },
    category = 1, owner = 1, page = 1, pageSize = 6,
    catalog = {}, rows = {}, owners = { "All" }, total = 0,
    loaded = false, attempted = false, busy = false,
}
state.inventory = inventory

function inventory.filter()
    local category = inventory.categories[inventory.category]
    local list = inventory.catalog[category.key] or {}
    local owner = inventory.owners[inventory.owner] or "All"
    local rows = {}
    for _, entry in ipairs(list) do
        if owner == "All" or entry.owner == owner then rows[#rows + 1] = entry end
    end
    inventory.rows = rows
    inventory.page = 1
    inventory.selected = nil
end

function inventory.setCategory(index)
    index = math.clamp(math.floor(tonumber(index) or 1), 1, #inventory.categories)
    inventory.category = index
    inventory.owner = 1
    local list = inventory.catalog[inventory.categories[index].key] or {}
    local seen, owners = {}, {}
    for _, entry in ipairs(list) do
        if entry.owner and not seen[entry.owner] then
            seen[entry.owner] = true
            owners[#owners + 1] = entry.owner
        end
    end
    table.sort(owners)
    table.insert(owners, 1, "All")
    inventory.owners = owners
    inventory.filter()
end

function inventory.setOwner(index)
    inventory.owner = math.clamp(math.floor(tonumber(index) or 1), 1, #inventory.owners)
    inventory.filter()
end

function inventory.setPage(page)
    local pages = math.max(1, math.ceil(#inventory.rows / inventory.pageSize))
    inventory.page = math.clamp(math.floor(tonumber(page) or 1), 1, pages)
end

function inventory.refresh()
    if inventory.busy or not state.running then return false end
    inventory.busy, inventory.attempted, inventory.error = true, true, nil
    task.spawn(function()
        local ok, catalog = pcall(function()
            local rs = game:GetService("ReplicatedStorage")
            local killers = rs:FindFirstChild("Killers")
            local items = rs:FindFirstChild("Items")
            local emotes = rs:FindFirstChild("Emotes")
            if not killers or not items or not emotes then error("Catalog assets are not loaded yet") end
            local out = { killers = {}, items = {}, skins = {}, itemskins = {}, emotes = {} }
            local function add(kind, obj, owner, detail)
                local name = obj.Name
                out[kind][#out[kind] + 1] = {
                    name = name, label = kind == "killers" and name == "Hidden" and "The Hidden" or name,
                    owner = owner, detail = detail,
                }
            end
            for _, killer in ipairs(killers:GetChildren()) do
                if killer.ClassName == "Folder" and killer:FindFirstChild("Model") then
                    add("killers", killer, nil, "Killer")
                    local skins = killer:FindFirstChild("Skins")
                    if skins then
                        for _, skin in ipairs(skins:GetChildren()) do
                            if skin.ClassName == "Folder" then
                                local parts = {}
                                for _, slot in ipairs({ "Head", "Torso", "Legs", "Weapon" }) do
                                    if skin:FindFirstChild(slot) then parts[#parts + 1] = slot end
                                end
                                add("skins", skin, killer.Name, #parts > 0 and table.concat(parts, ", ") or "Outfit")
                            end
                        end
                    end
                    task.wait()
                    if not state.running then return nil end
                end
            end
            for _, item in ipairs(items:GetChildren()) do
                if item.ClassName == "Decal" then
                    add("items", item, nil, "Item")
                    local skins = item:FindFirstChild("Skins")
                    if skins then
                        for _, skin in ipairs(skins:GetChildren()) do
                            if skin.ClassName == "Decal" then add("itemskins", skin, item.Name, "Item skin") end
                        end
                    end
                    task.wait()
                    if not state.running then return nil end
                end
            end
            for _, emote in ipairs(emotes:GetChildren()) do
                if emote.ClassName == "Folder" then add("emotes", emote, nil, "Emote") end
            end
            for _, list in pairs(out) do
                table.sort(list, function(a, b)
                    if (a.owner or "") ~= (b.owner or "") then return (a.owner or "") < (b.owner or "") end
                    return a.name < b.name
                end)
            end
            return out
        end)
        inventory.busy = false
        if not state.running or _G.vdHub ~= state then return end
        if not ok or type(catalog) ~= "table" then
            inventory.error = "Catalog unavailable. Try Refresh."
            warn("[vdHub inventory] " .. tostring(catalog))
            return
        end
        inventory.catalog, inventory.loaded, inventory.total = catalog, true, 0
        for _, list in pairs(catalog) do inventory.total = inventory.total + #list end
        inventory.setCategory(inventory.category)
        print("[vdHub inventory] Loaded " .. inventory.total .. " local catalog entries; server ownership unchanged.")
    end)
    return true
end



-- Object discovery and lifecycle; Drawing rendering is independent of native NPC ESP.
local function createVisuals(ws, cfg, register, alive)
    local v={entries={},counts={},total=0,error=nil,scanning=false,scanAt=0}
    local names={pallets="Pallet",windows="Window",generators="Generator",beartraps="Beartrap",pumpkins="Pumpkin"}
    local function part(o)
        if not o then return false end
        local c=o.ClassName
        return c=="Part" or c=="MeshPart" or c=="UnionOperation" or c=="WedgePart"
    end
    local function rootOf(o,preferred)
        if part(o) then return o end
        if not o then return end
        for _,n in ipairs(preferred or {}) do local p=o:FindFirstChild(n) if part(p) then return p end end
        local p=o.PrimaryPart
        if part(p) then return p end
        for _,child in ipairs(o:GetChildren()) do
            if part(child) then return child end
        end
    end
    function v.classify(o,map)
        local n=string.lower(o.Name or "")
        local category
        if n=="beartrap" or n=="bear_trap" then category="beartraps"
        elseif n=="pumpkin" or n:match("^pumpkin%d+$") then category="pumpkins" end
        if not category and n~="palletpoint" and n~="vaulttrigger" and n~="generatorbody" then return end
        local par=o.Parent
        if not par then return end
        if n=="palletpoint" and part(o) and map and o:IsDescendantOf(map) then
            local model=par
            local owner=model.Name=="Intact" and model.Parent or model
            if owner and owner:GetAttribute("PalletState")=="Broken" then return end
            local root=rootOf(model,{"Pallet","PrimaryPartPallet","RootPart"}) or o
            return "pallets",model,root
        elseif n=="vaulttrigger" and part(o) and map and o:IsDescendantOf(map) then
            if par:FindFirstChild("Bottom") or string.lower(par.Name)=="window" then
                return "windows",par,rootOf(par,{"Bottom","VaultTrigger"}) or o
            end
        elseif n=="generatorbody" and part(o) and map and o:IsDescendantOf(map) then
            return "generators",par,o
        end
        local node
        if not category then return end
        if category=="pumpkins" and (not map or not o:IsDescendantOf(map)) then return end
        if o.ClassName=="StringValue" then o=o.Parent end
        if not o or (o.ClassName~="Model" and not part(o)) then return end
        if part(o) and o.Parent and o.Parent.ClassName=="Model" then
            local pn=string.lower(o.Parent.Name)
            if pn=="beartrap" or pn:find("pumpkin",1,true) then o=o.Parent end
        end
        -- Exclude held weapons, preview ghosts and camera viewmodels.
        node=o
        for _=1,16 do
            if not node or node.Address==ws.Address then break end
            local nn=string.lower(node.Name or "")
            if node.ClassName=="Camera" or node:FindFirstChild("Humanoid") or
                nn:find("preview",1,true) or nn:find("ghost",1,true) then return end
            node=node.Parent
        end
        local root=rootOf(o,{"hitbox","HitBox","Pumpkin","RootPart"})
        if root then return category,o,root end
    end
    function v.remove(key)
        local e=v.entries[key]
        if not e then return end
        e.active=false
        if e.handle then pcall(function() e.handle:Remove() end) end
        v.entries[key]=nil
    end
    function v.clear()
        for key in pairs(v.entries) do v.remove(key) end
        v.total=0
    end
    function v.reconcile(list,map)
        local sliceStart=os.clock()
        local seen={}
        local counts={pallets=0,windows=0,generators=0,beartraps=0,pumpkins=0}
        local total=0
        for i,o in ipairs(list) do
            if not alive() then v.clear() return end
            local category,model,root=v.classify(o,map)
            if category and model and root then
                local key=tostring(model.Address)
                if not seen[key] then
                    seen[key]=true counts[category]=counts[category]+1
                    local wanted=cfg.esp_enabled and cfg["esp_"..category]
                    local e=v.entries[key]
                    if wanted and total<128 then
                        total=total+1
                        if e and e.root.Address~=root.Address then v.remove(key) e=nil end
                        if not e then
                            e={model=model,root=root,category=category,active=true}
                            local current=e
                            local ok,handle=pcall(register,{
                                entry=model,
                                ShouldDraw=function()
                                    return alive() and current.active and cfg.esp_enabled and cfg["esp_"..category]
                                        and current.model.Parent~=nil and current.model:IsDescendantOf(ws)
                                end,
                                GetHead=function() return current.root end,
                                GetRoot=function() return current.root end,
                                GetDisplayName=function() return names[category] end,
                                GetHealth=function() return 100 end,
                                GetMaxHealth=function() return 100 end,
                            })
                            if ok and handle then e.handle=handle v.entries[key]=e
                            else v.error=tostring(handle or "Object tracking unavailable") end
                        else e.model=model e.root=root end
                    elseif e then v.remove(key) end
                end
            end
            if v.yield and (i%100==0 or os.clock()-sliceStart>0.002) then v.yield() sliceStart=os.clock() end
        end
        for key in pairs(v.entries) do if not seen[key] then v.remove(key) end end
        v.counts=counts v.total=0
        for _ in pairs(v.entries) do v.total=v.total+1 end
    end
    function v.refresh()
        if v.scanning or not alive() then return end
        v.scanning=true v.error=nil
        local ok,err=pcall(function()
            if not cfg.esp_enabled then v.clear() return end
            local map=ws:FindFirstChild("Map")
            if not map then v.clear() v.counts={} return end
            local found={} local stack={ws} local first=1
            local start=os.clock()
            while first<=#stack do
                if not alive() or not cfg.esp_enabled then return end
                local parent=stack[first] first=first+1
                local seasonal=parent.Name=="Pumpkins" and parent:IsDescendantOf(map)
                for _,child in ipairs(parent:GetChildren()) do
                    local class,name=child.ClassName,string.lower(child.Name or "")
                    if seasonal and (class=="Model" or class=="Part" or class=="MeshPart") then
                        -- Preserve anonymous pumpkin models without an ancestry walk on every part.
                        local root=rootOf(child,{"Pumpkin","hitbox","RootPart"})
                        if root then
                            found[#found+1]={Name="Pumpkin",ClassName=child.ClassName,Parent=child.Parent,Address=child.Address,PrimaryPart=root,
                                FindFirstChild=function(_,n) return child:FindFirstChild(n) end,
                                GetChildren=function() return child:GetChildren() end,
                                IsDescendantOf=function(_,p) return child:IsDescendantOf(p) end}
                        end
                    else
                        if name=="palletpoint" or name=="vaulttrigger" or name=="generatorbody" or name=="beartrap" or name=="bear_trap" or name=="pumpkin" or name:match("^pumpkin%d+$") then found[#found+1]=child end
                        local container=class=="Model" or class=="Folder" or class=="Part" or class=="MeshPart" or class=="UnionOperation"
                        if container and class~="Camera" and name~="lobby" and not name:find("preview",1,true) and not name:find("ghost",1,true) then
                            if class~="Model" or not child:FindFirstChild("Humanoid") then stack[#stack+1]=child end
                        end
                    end
                end
                if v.yield and (first%64==0 or os.clock()-start>0.002) then v.yield() start=os.clock() end
            end
            v.reconcile(found,map)
        end)
        if not ok then v.error=tostring(err) end
        v.scanning=false
    end
    function v.changed()
        for key,e in pairs(v.entries) do
            if not cfg.esp_enabled or not cfg["esp_"..e.category] then v.remove(key) end
        end
        v.total=0 for _ in pairs(v.entries) do v.total=v.total+1 end
        if v.renderer then v.renderer.hideAll() end
        v.scanAt=0
    end
    return v
end

-- Filled oriented bounds, drawn through walls without native model registration.
local function createObjectRenderer(v,ws,cfg,run,alive)
    local r={pool={},targets={},drawn=0,stopped=false,error=nil}
    local colors={
        pallets=Color3.fromRGB(95,235,153),windows=Color3.fromRGB(92,195,255),
        generators=Color3.fromRGB(255,222,101),beartraps=Color3.fromRGB(255,100,115),
        pumpkins=Color3.fromRGB(255,154,65)}
    local names={pallets="Pallet",windows="Window",generators="Generator",beartraps="Beartrap",pumpkins="Pumpkin"}
    local corners={{-1,-1,-1},{1,-1,-1},{1,1,-1},{-1,1,-1},
        {-1,-1,1},{1,-1,1},{1,1,1},{-1,1,1}}
    local faces={{1,4,8,5},{2,6,7,3},{1,5,6,2},{4,3,7,8},{1,2,3,4},{5,8,7,6}}
    local function hide(slot)
        if not slot.visible then return end
        for _,o in ipairs(slot.objects) do o.Visible=false end
        slot.visible=false slot.tagVisible=false
    end
    function r.hideAll()
        for i=1,r.drawn do hide(r.pool[i]) end
        r.drawn=0
    end
    function r.stop()
        if r.stopped then return end
        r.stopped=true
        if r.connection then r.connection:Disconnect() end
        for _,slot in ipairs(r.pool) do
            for _,o in ipairs(slot.objects) do pcall(function() o:Remove() end) end
        end
        r.targets={} r.drawn=0
    end
    local ok,err=pcall(function()
        for i=1,128 do
            local slot={fills={},edges={},objects={},visible=false,xy={},projected={}}
            r.pool[i]=slot
            for j=1,3 do
                local fill=Drawing.new("Quad")
                table.insert(slot.objects,fill) slot.fills[j]=fill
                fill.Visible=false fill.Filled=true fill.Transparency=0.16 fill.ZIndex=1
                local edge=Drawing.new("Quad")
                table.insert(slot.objects,edge) slot.edges[j]=edge
                edge.Visible=false edge.Filled=false edge.Thickness=1 edge.Transparency=0.65 edge.ZIndex=2
            end
            local tag=Drawing.new("Text")
            table.insert(slot.objects,tag) slot.tag=tag
            tag.Visible=false tag.Size=13 tag.Font=(Drawing.Fonts or {}).System or 1
            tag.Center=true tag.Outline=true tag.Transparency=1 tag.ZIndex=3
        end
    end)
    if not ok then r.stop() r.error=tostring(err) return r end
    local function finite(n) return type(n)=="number" and n==n and math.abs(n)<1e7 end
    function r.collect()
        if not cfg.esp_enabled or not alive() or r.stopped then if #r.targets>0 then r.targets={} end return end
        local camera=ws.CurrentCamera
        local cf=camera and camera.CFrame
        local cameraPosition=cf and cf.Position
        if not cameraPosition or not cfg.esp_enabled or not alive() or r.stopped then r.targets={} return end
        local out={}
        for _,e in pairs(v.entries) do
            if e.active and cfg["esp_"..e.category] then
                local good,target=pcall(function()
                    if not e.model.Parent or not e.model:IsDescendantOf(ws) or not e.root.Parent then return end
                    local frame,size=e.root.CFrame,e.root.Size
                    if not frame or not size then return end
                    local p=frame.Position
                    if not finite(p.X) or not finite(p.Y) or not finite(p.Z) then return end
                    if not finite(size.X) or not finite(size.Y) or not finite(size.Z) then return end
                    if size.X<=0 or size.Y<=0 or size.Z<=0 or math.max(size.X,size.Y,size.Z)>300 then return end
                    local distance=(p-cameraPosition).Magnitude
                    if distance>cfg.esp_distance then return end
                    local right,up,look=frame.RightVector,frame.UpVector,frame.LookVector
                    local geometry=e.geometry
                    local signature={p.X,p.Y,p.Z,size.X,size.Y,size.Z,right.X,right.Y,right.Z,up.X,up.Y,up.Z,look.X,look.Y,look.Z}
                    local changed=not geometry
                    if geometry then for i,value in ipairs(signature) do if geometry.signature[i]~=value then changed=true break end end end
                    if changed then
                        local points={}
                        for i,c in ipairs(corners) do
                            local dx,dy,dz=c[1]*size.X*0.5,c[2]*size.Y*0.5,c[3]*size.Z*0.5
                            points[i]=Vector3.new(p.X+right.X*dx+up.X*dy-look.X*dz,p.Y+right.Y*dx+up.Y*dy-look.Y*dz,p.Z+right.Z*dx+up.Z*dy-look.Z*dz)
                        end
                        geometry={signature=signature,points=points} e.geometry=geometry
                    end
                    local points=geometry.points
                    local delta=cameraPosition-p
                    local view={X=delta.X*right.X+delta.Y*right.Y+delta.Z*right.Z,Y=delta.X*up.X+delta.Y*up.Y+delta.Z*up.Z,Z=-(delta.X*look.X+delta.Y*look.Y+delta.Z*look.Z)}
                    return {entry=e,points=points,faces={view.X<0 and 1 or 2,view.Y<0 and 3 or 4,view.Z<0 and 5 or 6},
                        color=colors[e.category],distance=distance,text=string.format("%s  %dm",names[e.category],math.floor(distance/3.57))}
                end)
                if good and target then out[#out+1]=target end
            end
        end
        table.sort(out,function(a,b) return a.distance<b.distance end)
        while #out>128 do table.remove(out) end
        if not alive() or r.stopped then return end
        r.targets=out
    end
    local elapsed=0
    r.connection=run.RenderStepped:Connect(function(dt)
        if r.stopped or not alive() then return end
        elapsed=elapsed+(tonumber(dt) or 1/60)
        if elapsed<1/30 then return end
        elapsed=0
        if not cfg.esp_enabled or #r.targets==0 then if r.drawn>0 then r.hideAll() end return end
        local okRender,renderError=pcall(function()
            local used=0
            if cfg.esp_enabled then
                for _,t in ipairs(r.targets) do
                    if t.entry.active and cfg["esp_"..t.entry.category] then
                        local slot=r.pool[used+1]
                        local projected=slot.projected local valid=true local minY=math.huge local sumX=0
                        local geometryChanged=false
                        for i,p in ipairs(t.points) do
                            local xy,onScreen=WorldToScreen(p)
                            if not onScreen or not finite(xy.X) or not finite(xy.Y) then valid=false break end
                            projected[i]=xy minY=math.min(minY,xy.Y) sumX=sumX+xy.X
                            local j=i*2
                            if slot.xy[j-1]~=xy.X or slot.xy[j]~=xy.Y then geometryChanged=true end
                        end
                        if valid then
                            used=used+1
                            for j,face in ipairs(t.faces) do
                                local fill,edge=slot.fills[j],slot.edges[j]
                                if geometryChanged or slot["face"..j]~=face then
                                    local indexes=faces[face]
                                    local a,b,c,d=projected[indexes[1]],projected[indexes[2]],projected[indexes[3]],projected[indexes[4]]
                                    fill.PointA=a fill.PointB=b fill.PointC=c fill.PointD=d
                                    edge.PointA=a edge.PointB=b edge.PointC=c edge.PointD=d
                                    slot["face"..j]=face
                                end
                                if slot.color~=t.color then fill.Color=t.color edge.Color=t.color end
                                if not slot.visible then fill.Visible=true edge.Visible=true end
                                if slot.opacity~=cfg.esp_opacity then fill.Transparency=cfg.esp_opacity end
                            end
                            local tag=slot.tag
                            if slot.text~=t.text then tag.Text=t.text slot.text=t.text end
                            local tx,ty=sumX/8,minY-17
                            if slot.tx~=tx or slot.ty~=ty then tag.Position=Vector2.new(tx,ty) slot.tx=tx slot.ty=ty end
                            if slot.color~=t.color then tag.Color=t.color end
                            if slot.tagVisible~=cfg.esp_names then tag.Visible=cfg.esp_names slot.tagVisible=cfg.esp_names end
                            slot.color=t.color slot.opacity=cfg.esp_opacity slot.visible=true
                            for i,xy in ipairs(projected) do slot.xy[i*2-1]=xy.X slot.xy[i*2]=xy.Y end
                        end
                    end
                end
            end
            for i=used+1,r.drawn do hide(r.pool[i]) end
            r.drawn=used
        end)
        if not okRender then r.error=tostring(renderError) r.hideAll() end
    end)
    task.spawn(function()
        while alive() and not r.stopped do
            local okCollect,collectError=pcall(r.collect)
            if not okCollect then r.error=tostring(collectError) r.targets={} end
            task.wait(0.2)
        end
        r.stop()
    end)
    return r
end

state.cfg.esp_names=true
state.cfg.esp_distance=1500
state.cfg.esp_opacity=0.18
state.cfg.esp_enabled=false
for _,key in ipairs({"pallets","windows","generators","beartraps","pumpkins"}) do state.cfg["esp_"..key]=true end
if previousHub and previousHub.cfg then
    for key,value in pairs(previousHub.cfg) do if state.cfg[key]~=nil then state.cfg[key]=value end end
end
local visuals=createVisuals(Workspace,state.cfg,function() return {Remove=function() end} end,function() return state.running end)
state.visuals=visuals
visuals.yield=function() task.wait() end
task.spawn(function()
    while state.running do
        if tick()>=visuals.scanAt then
            visuals.refresh()
            visuals.scanAt=tick()+5
        end
        task.wait(0.15)
    end
    visuals.clear()
end)

-- JDUI presentation. Gameplay configuration and callbacks remain unchanged.
local ui = jdFactory() or _G.JDUI
assert(type(ui)=="table" and ui.AddTab, "JDUI did not return its UI API")
state.ui=ui
local nativeDestroy=ui.Destroy
local stopping=false
state.stop=function()
    if stopping then return false end
    stopping=true
    state.running=false uiCapture=false
    if visuals.renderer then visuals.renderer.stop() end
    visuals.clear()
    fvCancelResolve() scReleaseInput()
    local restored=fvRestore()
    nativeDestroy(ui)
    if restored and _G.vdHub==state then _G.vdHub=nil end
    stopping=false
    return restored
end
ui.Destroy=function(self) return state.stop() end
local function setupJDUI()
visuals.renderer=createObjectRenderer(visuals,Workspace,state.cfg,RunService,function() return state.running end)
ui:SetTitle("VD Hub")
ui:SetSubtitle("Violence District")
ui:SetKeybind(0x4C)
ui:SetLayout("Compact")
ui:SetOverflow("Scroll")
ui.StartupSound=false
local main=ui.Home
main.Title="Main" main.Icon="home" main.Controls={}
main:SetColumns(2)
local c=state.cfg
local controls={}
state.controls=controls
local function toggle(panel,title,key,callback,description)
    local control=panel:AddToggle({Title=title,Description=description or "",Default=c[key],Save=false,
        Callback=function(value)
            if not state.running then return end
            if callback then callback(value) else c[key]=value end
        end})
    controls[key]=control
    return control
end
local function slider(panel,title,key,lo,hi,step,suffix)
    local control=panel:AddSlider({Title=title,Default=c[key],Min=lo,Max=hi,Step=step,Suffix=suffix,Save=false,
        Callback=function(value) if state.running then c[key]=value end end})
    controls[key]=control
    return control
end
local function info(panel,title,provider)
    panel:AddDivider({Title=title}) return panel:AddLabel({Title=provider,Tooltip=title,Save=false})
end
local p=main:AddIsland({Title="Auto Pallet",Column=1})
toggle(p,"Auto Pallet","p_enabled",nil,"Drop when a killer enters the stun zone.")
slider(p,"Interact radius","interactionRadius",1,30,1," studs")
slider(p,"Stun reach","stunReach",0,15,1," studs")
slider(p,"Stun width","stunWidth",0,15,1," studs")
slider(p,"Stun height","stunHeight",0,15,1," studs")
info(p,"Pallet status",function()
 return string.format("%d tracked / Killer %s / %s",#pallets,#killerRoots>0 and "visible" or "--",pStat.inZone and "READY" or "Waiting")
end)
info(p,"Drop key: SPACE",function() return pStat.hp==false and "Health must be above 50." or
 string.format("At pallet: %s / Distance: %s",pStat.elig and "YES" or "--",pStat.nearD and string.format("%.1f",pStat.nearD) or "--") end)
local sc=main:AddIsland({Title="Skillchecks",Column=2})
toggle(sc,"Auto Skillcheck","sc_enabled")
slider(sc,"Timing lead","sc_lead",0,10,1," deg")
info(sc,"Live timing",function() return string.format("%d checks / %d inputs / %d misses",scChecks,scHits,scStat.misses or 0) end)
info(sc,"Skillcheck status",function() return unsafeOn() and scStat.status or "Enable Allow Unsafe LuaU in Matcha." end)
info(sc,"Needle / goal / window",function() return string.format("%s / %s / %s",scLast.l and string.format("%.0f",scLast.l) or "--",scLast.g and string.format("%.0f",scLast.g) or "--",tostring(scLast.win or "--")) end)
info(sc,"Game binding",function() return tostring(scStat.key or "--") end)
info(sc,"Check type",function() return scStat.mode or "Waiting for prompt" end)
local fv=main:AddIsland({Title="Fast Vault",Column=2})
toggle(fv,"Always Fast Vault","fv_enabled",fvSetEnabled,"Sprint at a window from any angle.")
info(fv,"Vault status",function() return fvStat.status end)
info(fv,"Vault recovery",function() return fvStat.error or "Module verified" end)
info(fv,"Vaults / fast",function() return string.format("%d / %d / Tier: %s",fvStat.vaults,fvStat.fast,fvStat.tier or "--") end)
info(fv,"Windows / reason",function() return tostring(#vaults).." / "..tostring(fvStat.reason or "--") end)
local va=main:AddIsland({Title="Veil Aim",Column=1})
toggle(va,"Veil Spear Aimbot","va_enabled")
slider(va,"Field of view","va_fov",5,90,5," deg")
slider(va,"Range","va_range",40,400,20," studs")
slider(va,"Smoothing","va_smooth",1,20,1)
for _,v in ipairs({{"Lead target","va_lead"},{"Euler fix","va_euler"},{"Line of sight","va_los"},
 {"Auto-calibration","va_autocal"},{"Charge only","va_holdOnly"},{"Camera origin","va_originCam"},{"Sticky aim","va_sticky"}}) do toggle(va,v[1],v[2]) end
info(va,"Target",function() return (vaStat.target or "--")..(vaStat.held and " / LOCK" or "") end)
info(va,"Distance / launch speed",function() return string.format("%.0f / %.1f",vaStat.dist or 0,vaStat.speed or 0) end)
info(va,"Charge",function() return string.format("%.2fs / %s",vaStat.hold or 0,vaStat.tier or "--") end)
info(va,"Flight / drop",function() return string.format("%.2fs / %.1f",vaStat.flight or 0,vaStat.drop or 0) end)
info(va,"Gravity / measured arcs",function() return string.format("%.3f / %d",c.va_gmult,vaStat.measN or 0) end)
info(va,"Aim status",function()
 if vaStat.losOK==false then return "Line of sight unavailable" end
 if vaStat.cd and vaStat.cd>0.5 then return string.format("Charged throw cooldown: %.0fs",vaStat.cd) end
 return vaStat.solved and "Solution locked. Release to throw." or "Hold attack with a spear equipped."
end)
local catalog=main:AddIsland({Title="Collection",Column=2})
local categoryNames={}
for i,v in ipairs(inventory.categories) do categoryNames[i]=v.label end
local ownerControl,entryControl
local mapping={}
local function syncEntries()
    local options={} mapping={}
    for i,entry in ipairs(inventory.rows) do
        local label=string.format("%03d | %s%s",i,entry.owner and entry.owner.." / " or "",entry.label)
        options[#options+1]=label mapping[label]=entry
    end
    if #options==0 then options={"No entries loaded"} end
    entryControl.Options=options
    entryControl:SetValue(options[1],true)
    inventory.selected=mapping[options[1]]
end
local function syncOwners()
    ownerControl.Options=inventory.owners
    ownerControl:SetValue(inventory.owners[inventory.owner] or "All",true)
    syncEntries()
end
catalog:AddDropdown({Title="Category",Options=categoryNames,Default=categoryNames[1],Save=false,Callback=function(value)
    for i,name in ipairs(categoryNames) do if name==value then inventory.setCategory(i) break end end
    syncOwners()
end})
ownerControl=catalog:AddDropdown({Title="Owner",Options={"All"},Save=false,Searchable=true,Callback=function(value)
    for i,name in ipairs(inventory.owners) do if name==value then inventory.setOwner(i) break end end
    syncEntries()
end})
entryControl=catalog:AddDropdown({Title="Entry",Options={"No entries loaded"},Searchable=true,Save=false,Callback=function(value) inventory.selected=mapping[value] end})
catalog:AddButton({Title="Refresh collection",ButtonText="Refresh",Callback=function() inventory.refresh() end})
info(catalog,"Selection",function() return inventory.selected and inventory.selected.label or "Choose an entry." end)
info(catalog,"Details",function() return inventory.selected and inventory.selected.detail or "Local catalog preview." end)
info(catalog,"Catalog status",function() return inventory.error or (inventory.busy and "Refreshing..." or tostring(#inventory.rows).." entries") end)
task.spawn(function()
    inventory.refresh()
    local lastRows,lastOwners
    while state.running and ui.Alive do
        if lastRows~=inventory.rows or lastOwners~=inventory.owners then
            lastRows,lastOwners=inventory.rows,inventory.owners
            syncOwners()
        end
        task.wait(0.25)
    end
end)

local vis=ui:AddTab({Title="Visuals",Icon="eye",Columns=1})
local visGroup=vis:AddIsland({Title="Object ESP / Chams",Column=1})
toggle(visGroup,"Enable object ESP","esp_enabled",function(value) c.esp_enabled=value visuals.changed() end)
for _,item in ipairs({{"Pallets","pallets"},{"Windows","windows"},{"Generators","generators"},{"Beartraps","beartraps"},{"Pumpkins","pumpkins"}}) do
    local key="esp_"..item[2]
    toggle(visGroup,item[1],key,function(value) c[key]=value visuals.changed() end)
end
toggle(visGroup,"Object labels","esp_names")
slider(visGroup,"Maximum distance","esp_distance",100,3000,100," studs")
slider(visGroup,"Fill opacity","esp_opacity",0.05,0.5,0.01)
vis:AddLabel({Title="Object highlights",Description="Colored filled bounds through walls."})
vis:AddLabel({Title=function() return string.format("Pallets %d / Windows %d / Generators %d",
 visuals.counts.pallets or 0,visuals.counts.windows or 0,visuals.counts.generators or 0) end})
vis:AddLabel({Title=function() return string.format("Beartraps %d / Pumpkins %d",
 visuals.counts.beartraps or 0,visuals.counts.pumpkins or 0) end})
vis:AddLabel({Title=function() return (visuals.error or visuals.renderer.error) and "ESP: "..tostring(visuals.error or visuals.renderer.error) or "Refreshes automatically as objects spawn." end})
vis:AddButton({Title="Refresh objects",ButtonText="Refresh",Callback=function() visuals.scanAt=0 end})
state.visualsTab=vis
-- Keep the everyday navigation order: Main, Visuals, Settings.
ui.Tabs={main,vis,ui.Settings}

-- Native JDUI settings retain theme, keybind and overflow controls.
ui.Settings.Controls={}
ui.Settings:AddDropdown({Title="Theme",Options={"Purple","Green","Blue","Black"},Default="Purple",Callback=function(v) ui:SetTheme(v) end})
ui.Settings:AddKeybind({Title="Menu key",Default=0x4C,Callback=function(v) if v then ui:SetKeybind(v) end end})
ui.Settings:AddDropdown({Title="Content layout",Options={"Scroll","Pages"},Default="Scroll",Callback=function(v) ui:SetOverflow(v) end})
ui.Settings:AddSlider({Title="UI scale",Min=0.5,Max=1.5,Step=0.05,Default=1,Callback=function(v) ui:SetScale(v) end})
ui.Settings:AddSlider({Title="Opacity",Min=0.35,Max=1,Step=0.05,Default=1,Callback=function(v) ui:SetOpacity(v) end})
ui.Settings:AddToggle({Title="Reduced motion",Default=false,Callback=function(v) ui.ReducedMotion=v end})
ui.Settings:AddToggle({Title="Visual effects",Default=true,Callback=function(v) ui.Effects=v end})
ui.Settings:AddButton({Title="Unload hub",ButtonText="Unload",Callback=function() state.stop() end})
main:Select() ui:Center()
state.setVisible=function(v) ui:SetOpen(v) return ui:IsOpen() end
state.setTheme=function(v) return ui:SetTheme(v) end
state.themes=function() return {"Purple","Green","Blue","Black"} end
state.uiInfo=function() return {library="JDUI",version=ui.Version,hidden=not ui:IsOpen(),theme=ui.Theme,running=state.running,controls=#ui:FindControls(""),toggleKey=ui.Keybind} end
state.uiDiag=function() print(game:GetService("HttpService"):JSONEncode(state.uiInfo())) end
-- Block automation inputs while interacting with JDUI, including popups.
task.spawn(function()
    while state.running and ui.Alive do
        uiCapture=ui:IsOpen() and isrbxactive() and ismouse1pressed() or false
        task.wait(0.025)
    end
    uiCapture=false
end)
ui:Notify({Title="VD Hub",Content="All features are in Main. Press L to toggle.",Type="success",Duration=4})
end
local setupOK,setupError=pcall(setupJDUI)
if not setupOK then state.stop() error(setupError) end

state.debug = function()
    return {
        pallets     = #pallets,
        blockers    = #blockers,
        killerRoots = #killerRoots,
        stat        = pStat,
        scHits      = scHits,
        scChecks    = scChecks,
        scLine      = scLast.l,
        scGoal      = scLast.g,
        scWin       = scLast.win,
        skill       = scStat,
        version     = state.version,
        vaults      = #vaults,
        fv          = fvStat,
        veil        = vaStat,
        camAddr     = vaRot,
        baseG       = vaBaseG(),
        theme       = ui.Theme,
    }
end

-- force a fresh camera-offset resolve (after a respawn or a Roblox update)
state.veilRecal = function()
    vaRot, vaRotFor, vaWarmAt = nil, nil, 0
    return vaRotAddr()
end


print("[vdHub] JDUI loaded -- stop with _G.vdHub.stop()")

