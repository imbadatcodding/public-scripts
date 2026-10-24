--all comments made by claude some code is also made by claude. I dont remove the comments they make the code easier to read. cya

--======================================================================
--  VIOLENCE DISTRICT HUB   (Matcha / Drawing UI)
--  Tabs: Auto Pallet | Auto Skillcheck | Fast Vault | Veil Aim | Settings
--  No calibration. Skillcheck rotation offset is derived from the
--  AbsolutePosition binding at read time -- zero setup. The Veil aimbot
--  measures the projectile's gravity multiplier off your own throws.
--  Stop with:  _G.vdHub.stop()
--======================================================================
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
    version = "2026-10-24.2",
    tab     = "pallet",
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
        ui_round         = 6,
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

local function scRefreshGui(now)
    if now >= scGui.refreshAt then
        scGui.refreshAt = now + 0.25
        local pg = lp:FindFirstChild("PlayerGui")
        local gui = pg and pg:FindFirstChild("SkillCheckPromptGui")
        local check = gui and gui:FindFirstChild("Check")
        local line = check and check:FindFirstChild("Line")
        local goal = check and check:FindFirstChild("Goal")
        local lid, gid = line and line.Address, goal and goal.Address
        if lid ~= scGui.lid or gid ~= scGui.gid then
            scGui.off, scGui.resolveAt = nil, 0
            scTrack = {}
            scStat.offset = nil
        end
        scGui.line, scGui.goal, scGui.lid, scGui.gid = line, goal, lid, gid
    end
    if scGui.line and scGui.goal and not scGui.off and now >= scGui.resolveAt then
        scGui.resolveAt = now + 0.5
        scGui.off = resolveSkillOffset(scGui.line, scGui.goal)
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
    if not lr then
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
local fvFault = nil
local fvCharId, fvLastCount = nil, nil

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
    if type(rows) ~= "table" or #rows ~= 5 then return nil, "Vault module not uniquely resolved" end
    local cache = { rows = rows, byKey = {}, originals = {}, written = {}, job = game.JobId }
    for _, row in ipairs(rows) do
        if type(row) ~= "table" or row.type ~= "number" or type(row.addr) ~= "number"
            or not FV_ORIGINAL[row.key] or cache.byKey[row.key] then
            return nil, "Unexpected vault table layout"
        end
        cache.byKey[row.key] = row
        local value = fvRead(cache, row.key)
        if not fvSame(value, FV_ORIGINAL[row.key]) then return nil, "Vault rules differ from this build" end
        cache.originals[row.key] = value
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
    if fvResolving or fvAttemptedFor == characterId then return end
    fvResolving, fvAttemptedFor = true, characterId
    fvStat.status = "Resolving vault module"
    task.spawn(function()
        task.wait(0.35)
        if not state.running or not state.cfg.fv_enabled then
            fvResolving, fvAttemptedFor = false, nil
            return
        end
        local ok, cache, err = pcall(function()
            if vaultCacheSeed and vaultCacheSeed.job == game.JobId then
                local reused = fvBuildCache(vaultCacheSeed.rows)
                vaultCacheSeed = nil
                if reused then return reused end
            end
            -- A scan is done only on first enable, or after a failed resolve
            -- and a new character. A healthy cache survives ordinary respawns.
            fvStat.scans = fvStat.scans + 1
            local rows = findgc("REPEAT_WINDOW_TIME", {
                DISTANCE="number", REPEAT_DISTANCE="number", DOT="number",
                MIN_SPEED="number", ARRIVE_GRACE="number",
            })
            return fvBuildCache(rows)
        end)
        fvResolving = false
        if not state.running then return end
        if ok and cache then
            fvCache, state._vaultCache = cache, cache
            fvStat.ready, fvStat.error = true, nil
        else
            fvStat.error = tostring(ok and err or cache)
            fvStat.status = "Waiting for survivor module"
        end
    end)
end

local function fvObserveVault()
    local ch = lp.Character
    local id = ch and ch.Address
    if id ~= fvCharId then
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
            if not state.cfg.fv_enabled then
                local restored = fvRestore()
                if restored then fvFault = nil end
                fvStat.status = restored and "Disabled" or "Restore pending: enable Unsafe LuaU"
            elseif not unsafeOn() then
                fvStat.status = fvHasWrites() and "Restore pending: enable Unsafe LuaU" or "Enable Unsafe LuaU"
            elseif not fvCache then
                if id then fvResolve(id) else fvStat.status = "Waiting for character" end
            elseif fvFault then
                fvStat.status = fvFault
            else
                local applied, why = fvApply()
                fvStat.holding = applied
                fvStat.status = applied and "Ready - sprint to vault" or why
                fvStat.error = applied and nil or why
                if not applied then fvFault = why end
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
--  UI  (Drawing immediate-mode)
--======================================================================
local UX, UY    = 60, 120
local UW, UH    = 448, 412
local RAIL      = 118            -- left nav column
local HEAD      = 34             -- title bar height
local minimized = false

--======================================================================
--  THEMES
--  Every palette carries the same key set, and applyTheme copies into the
--  SAME COL table rather than rebinding it -- so every widget below keeps
--  its existing upvalue and the switch is instant with no relayout.
--======================================================================
local function C(r, g, b) return Color3.fromRGB(r, g, b) end

local THEMES = {
    { name = "Midnight",
      bg=C(16,16,24),   bg2=C(23,23,34),  bar=C(40,29,78),  barTo=C(19,17,38),
      panel=C(29,29,44), border=C(52,47,82), accent=C(134,104,255), accent2=C(96,204,255),
      on=C(94,214,142), off=C(70,70,92),  text=C(237,237,249), dim=C(145,145,176),
      warn=C(246,188,94), bad=C(238,102,110), shadow=C(0,0,0), knob=C(247,247,253) },

    { name = "Ember",
      bg=C(20,14,12),   bg2=C(28,20,17),  bar=C(84,32,16),  barTo=C(36,17,11),
      panel=C(35,24,20), border=C(78,49,37), accent=C(255,132,54), accent2=C(255,198,84),
      on=C(232,148,54), off=C(84,62,54),  text=C(251,239,231), dim=C(178,148,133),
      warn=C(255,206,110), bad=C(240,86,72), shadow=C(0,0,0), knob=C(253,246,240) },

    { name = "Toxic",
      bg=C(12,20,14),   bg2=C(17,28,20),  bar=C(24,72,38),  barTo=C(12,32,19),
      panel=C(21,35,25), border=C(42,76,50), accent=C(124,242,120), accent2=C(204,255,118),
      on=C(124,242,120), off=C(58,82,64),  text=C(233,251,235), dim=C(137,177,145),
      warn=C(232,232,110), bad=C(246,110,96), shadow=C(0,0,0), knob=C(244,253,244) },

    { name = "Abyss",
      bg=C(10,16,26),   bg2=C(15,23,36),  bar=C(16,54,90),  barTo=C(10,24,44),
      panel=C(19,29,45), border=C(35,62,93), accent=C(86,196,255), accent2=C(128,240,220),
      on=C(88,214,178), off=C(55,74,98),  text=C(231,243,255), dim=C(131,158,190),
      warn=C(246,198,104), bad=C(240,104,124), shadow=C(0,0,0), knob=C(240,250,255) },

    { name = "Rosewood",
      bg=C(22,12,20),   bg2=C(30,17,28),  bar=C(84,24,60),  barTo=C(38,13,29),
      panel=C(37,21,33), border=C(77,42,66), accent=C(255,110,180), accent2=C(255,172,212),
      on=C(226,122,190), off=C(83,56,74),  text=C(253,235,247), dim=C(185,141,169),
      warn=C(250,196,120), bad=C(246,92,110), shadow=C(0,0,0), knob=C(254,244,250) },

    { name = "Paper",
      bg=C(239,239,246), bg2=C(250,250,253), bar=C(228,228,240), barTo=C(207,207,226),
      panel=C(227,227,239), border=C(198,198,216), accent=C(88,70,220), accent2=C(24,148,198),
      on=C(38,158,88),  off=C(174,174,192), text=C(27,27,40),  dim=C(108,108,130),
      warn=C(176,118,20), bad=C(198,48,58), shadow=C(118,118,142), knob=C(255,255,255) },
}

local COL = {}
-- Copy into the SAME table (never rebind) so every widget's upvalue stays
-- valid, and fall back to Midnight for any key a palette forgets -- a nil
-- Color3 would otherwise throw mid-frame and blank the whole overlay.
local function applyTheme(i)
    local base = THEMES[1]
    local t = THEMES[i] or base
    for k, v in pairs(base) do COL[k] = t[k] or v end
end
applyTheme(state.cfg.theme)

local function lerpC(a, b, t)
    return Color3.fromRGB(
        math.floor(a.R * 255 + (b.R * 255 - a.R * 255) * t + 0.5),
        math.floor(a.G * 255 + (b.G * 255 - a.G * 255) * t + 0.5),
        math.floor(a.B * 255 + (b.B * 255 - a.B * 255) * t + 0.5))
end

--======================================================================
--  DRAW POOLS
--  The old pools were a hard 64/64 and S()/T() silently returned nil once
--  exhausted -- a richer layout would just stop rendering halfway with no
--  error. They now grow on demand instead, so the layout can never be
--  truncated by its own budget.
--======================================================================
-- Draw order here was implicit, and therefore not portable. Nothing in this file
-- ever set ZIndex, so all 200 squares and all 96 texts tied at 0 and each
-- executor was free to sort that tie however it liked. On this machine the text
-- happened to win; on a shared copy the panel fills painted straight over it and
-- the UI came out with no readable text at all. So layer it explicitly: squares
-- in paint order, every text above every square. No tiebreak left to lose.
--
-- Font INDICES are not portable, so don't hardcode one. Index 2 is SystemBold in
-- Matcha but Plex on Synapse-style builds, and Matcha's table (UI=0, System=1,
-- SystemBold=2, Minecraft=4, Monospace=5, Pixel=7, Fortnite=8,
-- ProximaSoftBold=11) looks nothing like the standard four. An index this build
-- doesn't define can render nothing while squares still draw -- which from the
-- outside is indistinguishable from the ZIndex bug above. So resolve by NAME
-- down a preference list and end at 0 (UI), which every build defines.
local Z_TEXT   = 4096
local FONT     = 0
local FONTNAME = "UI(default 0)"
do
    local fonts = Drawing.Fonts
    if type(fonts) == "table" then
        for _, name in ipairs({ "SystemBold", "System", "UI" }) do
            local v = fonts[name]
            if type(v) == "number" then FONT, FONTNAME = v, name break end
        end
    end
end

local sq, tx = {}, {}
local Z_OK = false
local function newSquare(i)
    local s = Drawing.new("Square")
    s.Filled = true
    s.Visible = false
    if Z_OK then pcall(function() s.ZIndex = i end) end
    return s
end
local function newText(i)
    local t = Drawing.new("Text")
    t.Size = 14
    t.Font = FONT
    t.Visible = false
    if Z_OK then pcall(function() t.ZIndex = Z_TEXT + i end) end
    return t
end
-- Probe ZIndex support on the first real pool object, not a throwaway: a Drawing
-- whose last reference is lost stays on screen for the life of the VM.
sq[1] = newSquare(1)
Z_OK  = pcall(function() sq[1].ZIndex = 1 end)
for i = 2, 200 do sq[i] = newSquare(i) end
for i = 1, 96  do tx[i] = newText(i)   end

local siUse, tiUse = 0, 0
local OPA = 1

-- filled rect (round = corner radius in px)
local function S(x, y, w, h, color, round, trans)
    siUse = siUse + 1
    local o = sq[siUse]
    if not o then o = newSquare(siUse); sq[siUse] = o end
    o.Position = Vector2.new(x, y); o.Size = Vector2.new(w, h)
    o.Color = color; o.Filled = true; o.Thickness = 1
    o.Rounding = round or 0
    o.Transparency = trans or OPA
    o.Visible = true
    return o
end

-- outline rect
local function SO(x, y, w, h, color, round, trans, thick)
    siUse = siUse + 1
    local o = sq[siUse]
    if not o then o = newSquare(siUse); sq[siUse] = o end
    o.Position = Vector2.new(x, y); o.Size = Vector2.new(w, h)
    o.Color = color; o.Filled = false; o.Thickness = thick or 1
    o.Rounding = round or 0
    o.Transparency = trans or OPA
    o.Visible = true
    return o
end

local function T(str, x, y, size, color, center, trans)
    tiUse = tiUse + 1
    local o = tx[tiUse]
    if not o then o = newText(tiUse); tx[tiUse] = o end
    o.Text = str; o.Position = Vector2.new(x, y); o.Size = size or 14
    o.Color = color or COL.text; o.Center = center or false
    o.Transparency = trans or OPA
    o.Visible = true
    return o
end

-- vertical gradient in n bands (cheaper than per-pixel and smooth enough
-- at header scale)
local function grad(x, y, w, h, c1, c2, n, round)
    n = n or 12
    local bh = h / n
    for i = 0, n - 1 do
        local c = lerpC(c1, c2, i / (n - 1))
        S(x, y + i * bh, w, bh + 1, c, (i == 0 or i == n - 1) and round or 0)
    end
end

--======================================================================
--  INPUT  (immediate mode: this frame's click resolves against LAST
--  frame's rects, which are laid out identically)
--======================================================================
local mDown, mPrev = false, false
local hot, prevHot = {}, {}
local function rect(id, x, y, w, h) hot[id] = {x=x, y=y, w=w, h=h} end
local function inRect(r, mx, my) return mx>=r.x and mx<=r.x+r.w and my>=r.y and my<=r.y+r.h end
local clickedId = nil
local hoverId   = nil
local dragging, dragOff = false, {x=0, y=0}

--======================================================================
--  WIDGETS
--======================================================================
local R = 6      -- refreshed from cfg each frame

local function section(label, x, y, w)
    T(label:upper(), x, y, 11, COL.dim)
    S(x, y + 15, w, 1, COL.border)
    return 22
end

local function card(x, y, w, h)
    S(x, y, w, h, COL.bg2, R)
    SO(x, y, w, h, COL.border, R)
end

local function toggleRow(label, x, y, w, get, set)
    local id  = "tg_" .. label
    local on  = get()
    local hov = (hoverId == id)
    S(x - 6, y - 3, w + 12, 28, hov and COL.panel or COL.bg2, R, hov and OPA or math.min(OPA, 0.55))
    T(label, x, y + 3, 14, on and COL.text or COL.dim)
    local tw, th = 40, 20
    local tx0 = x + w - tw
    S(tx0, y + 1, tw, th, on and COL.accent or COL.off, th / 2)
    if on then SO(tx0 - 2, y - 1, tw + 4, th + 4, COL.accent, (th + 4) / 2, 0.35) end
    S(on and (tx0 + tw - 18) or (tx0 + 2), y + 3, 16, 16, COL.knob, 8)
    rect(id, x - 6, y - 3, w + 12, 28)
    if clickedId == id then set(not on) end
    return 32
end

-- compact 2-per-row on/off pill, for the secondary switches
local function chip(label, x, y, w, get, set)
    local id  = "cp_" .. label
    local on  = get()
    local hov = (hoverId == id)
    S(x, y, w, 24, on and COL.accent or COL.panel, R, on and OPA or math.min(OPA, 0.8))
    if hov then SO(x, y, w, 24, on and COL.accent2 or COL.border, R) end
    S(x + 8, y + 8, 8, 8, on and COL.knob or COL.off, 4)
    T(label, x + 22, y + 4, 12, on and COL.knob or COL.dim)
    rect(id, x, y, w, 24)
    if clickedId == id then set(not on) end
    return 28
end

local function stepper(label, x, y, w, get, set, lo, hi, step, fmt)
    local val = get()
    T(label, x, y + 4, 13, COL.dim)
    local bw = 24
    local mx0 = x + w - bw * 2 - 4
    local px0 = x + w - bw
    -- value sits in its own well so the number is readable at any theme
    S(mx0 - 70, y, 66, 22, COL.panel, R)
    T((fmt or "%s"):format(val), mx0 - 37, y + 3, 13, COL.text, true)
    local hm, hp = (hoverId == "minus_" .. label), (hoverId == "plus_" .. label)
    S(mx0, y, bw, 22, hm and COL.accent or COL.panel, R)
    T("-", mx0 + bw / 2, y + 1, 16, hm and COL.knob or COL.text, true)
    S(px0, y, bw, 22, hp and COL.accent or COL.panel, R)
    T("+", px0 + bw / 2, y + 1, 16, hp and COL.knob or COL.text, true)
    rect("minus_" .. label, mx0, y, bw, 22)
    rect("plus_"  .. label, px0, y, bw, 22)
    if clickedId == "minus_" .. label then set(math.max(lo, val - step)) end
    if clickedId == "plus_"  .. label then set(math.min(hi, val + step)) end
    return 26
end

-- label left, value hard right. Drawing has no right-align, but Text.TextBounds
-- is readable and updates with the string, so the value is measured and then
-- repositioned -- otherwise long values ("0.659s / 42.6") run off the card.
local function statRight(label, value, x, y, w, col)
    T(label, x, y, 12, COL.dim)
    local o = T(value, x, y, 12, col or COL.text)
    if o then
        local bw = 0
        local okb, b = pcall(function() return o.TextBounds end)
        if okb and b then bw = b.X end
        o.Position = Vector2.new(x + w - bw, y)
    end
    return 17
end

local function railItem(label, key, x, y, w)
    local active = (state.tab == key)
    local id  = "tab_" .. key
    local hov = (hoverId == id)
    if active then
        S(x, y, w, 30, COL.accent, R, math.min(OPA, 0.20))
        S(x, y + 5, 3, 20, COL.accent, 2)
    elseif hov then
        S(x, y, w, 30, COL.panel, R)
    end
    T(label, x + 12, y + 7, 14, active and COL.accent or COL.dim)
    rect(id, x, y, w, 30)
    if clickedId == id then state.tab = key end
    return 34
end

local function themeCell(i, x, y, w)
    local t   = THEMES[i]
    local act = (state.cfg.theme == i)
    local id  = "th_" .. i
    local hov = (hoverId == id)
    S(x, y, w, 32, t.panel, R)
    if act then SO(x, y, w, 32, t.accent, R, nil, 2)
    elseif hov then SO(x, y, w, 32, COL.border, R) end
    S(x + 8, y + 10, 12, 12, t.accent, 6)
    S(x + 23, y + 13, 6, 6, t.accent2, 3)
    T(t.name, x + 35, y + 8, 13, act and t.accent or t.text)
    rect(id, x, y, w, 32)
    if clickedId == id then
        state.cfg.theme = i
        applyTheme(i)
    end
    return 36
end

--======================================================================
--  DRAW
--======================================================================
local function draw()
    siUse, tiUse = 0, 0
    hot = {}
    local c = state.cfg
    OPA = math.clamp(c.ui_opacity or 1, 0.35, 1)
    R   = math.floor(c.ui_round or 6)

    local mx, my = mouse.X, mouse.Y
    mPrev = mDown
    mDown = ismouse1pressed() and true or false
    local justPressed = (mDown and not mPrev)

    clickedId, hoverId = nil, nil
    for id, r in pairs(prevHot) do
        if inRect(r, mx, my) then
            hoverId = id
            if justPressed then clickedId = id end
            break
        end
    end

    local bodyH = minimized and 0 or (UH - HEAD)
    local overWindow = mx >= UX and mx <= UX + UW and my >= UY and my <= UY + HEAD + bodyH
    -- tell the aimbot's charge tracker to ignore presses that began on the
    -- panel, or clicking a toggle would read as winding up a throw
    if justPressed and overWindow then uiCapture = true end
    if not mDown then uiCapture = false end

    if clickedId == "min" then minimized = not minimized end
    if clickedId == "cls" then
        -- full teardown, not just a feature stop (the old X left the whole
        -- overlay on screen with the loops dead)
        task.spawn(function() if state.stop then pcall(state.stop) end end)
        return
    end

    -- drag by the header, excluding the buttons
    if justPressed and my >= UY and my <= UY + HEAD and mx >= UX and mx <= UX + UW - 64 then
        dragging = true; dragOff.x = mx - UX; dragOff.y = my - UY
    end
    if not mDown then dragging = false end
    if dragging then UX = mx - dragOff.x; UY = my - dragOff.y end

    ------------------------------------------------------------------
    -- shell: soft shadow, body, header gradient, rail
    ------------------------------------------------------------------
    local totalH = HEAD + bodyH
    for i = 3, 1, -1 do
        S(UX - i * 2, UY - i * 2 + 3, UW + i * 4, totalH + i * 4, COL.shadow, R + i * 2, 0.05 * i)
    end
    S(UX, UY, UW, totalH, COL.bg, R)
    grad(UX, UY, UW, HEAD, COL.bar, COL.barTo, 10, R)

    S(UX + 12, UY + 11, 4, 12, COL.accent, 2)
    S(UX + 18, UY + 14, 4, 6,  COL.accent2, 2)
    local ttl = T("VIOLENCE DISTRICT", UX + 30, UY + 4, 15, COL.text)
    local twid = 150
    if ttl then
        local okb, b = pcall(function() return ttl.TextBounds end)
        if okb and b then twid = b.X end
    end
    T("HUB", UX + 38 + twid, UY + 6, 12, COL.accent)

    local mh, ch = (hoverId == "min"), (hoverId == "cls")
    S(UX + UW - 56, UY + 8, 20, 18, mh and COL.panel or COL.bg2, R, mh and OPA or 0.6)
    S(UX + UW - 51, UY + 20, 10, 2, COL.text, 1)
    rect("min", UX + UW - 56, UY + 8, 20, 18)
    S(UX + UW - 30, UY + 8, 20, 18, ch and COL.bad or COL.bg2, R, ch and OPA or 0.6)
    T("x", UX + UW - 20, UY + 5, 15, ch and COL.knob or COL.bad, true)
    rect("cls", UX + UW - 30, UY + 8, 20, 18)

    if minimized then
        for i = siUse + 1, #sq do sq[i].Visible = false end
        for i = tiUse + 1, #tx do tx[i].Visible = false end
        prevHot = hot
        return
    end

    -- rail
    S(UX, UY + HEAD, RAIL, bodyH, COL.bg2, 0, OPA)
    S(UX + RAIL, UY + HEAD, 1, bodyH, COL.border)

    local ry = UY + HEAD + 10
    ry = ry + railItem("Pallet",     "pallet",   UX + 8, ry, RAIL - 16)
    ry = ry + railItem("Skillcheck", "skill",    UX + 8, ry, RAIL - 16)
    ry = ry + railItem("Vault",      "vault",    UX + 8, ry, RAIL - 16)
    ry = ry + railItem("Veil Aim",   "veil",     UX + 8, ry, RAIL - 16)

    -- settings sits apart at the foot of the rail: the "settings button"
    local sy = UY + totalH - 42
    S(UX + 8, sy - 10, RAIL - 16, 1, COL.border)
    railItem("Settings", "settings", UX + 8, sy, RAIL - 16)

    -- unsafe-memory banner: pallet is the only feature that does not need it
    local unsafe = unsafeOn()
    if not unsafe and state.tab ~= "pallet" and state.tab ~= "settings" then
        T("Unsafe LuaU OFF", UX + 12, UY + totalH - 66, 11, COL.bad)
    end

    ------------------------------------------------------------------
    -- content
    ------------------------------------------------------------------
    local pad    = UX + RAIL + 16
    local innerW = UW - RAIL - 32
    local y      = UY + HEAD + 14

    if state.tab == "pallet" then
        y = y + toggleRow("Auto Pallet", pad, y, innerW,
            function() return c.p_enabled end,
            function(v) c.p_enabled = v end)
        y = y + 6
        y = y + section("Stun box", pad, y, innerW)
        y = y + stepper("Interact radius", pad, y, innerW,
            function() return c.interactionRadius end,
            function(v) c.interactionRadius = v end, 1, 30, 1, "%d")
        y = y + stepper("Stun reach", pad, y, innerW,
            function() return c.stunReach end,
            function(v) c.stunReach = v end, 0, 15, 1, "%d")
        y = y + stepper("Stun width", pad, y, innerW,
            function() return c.stunWidth end,
            function(v) c.stunWidth = v end, 0, 15, 1, "%d")
        y = y + stepper("Stun height", pad, y, innerW,
            function() return c.stunHeight end,
            function(v) c.stunHeight = v end, 0, 15, 1, "%d")
        y = y + 10
        card(pad - 8, y, innerW + 16, 96)
        local cy, cx, cw = y + 10, pad, innerW
        cy = cy + statRight("Pallets tracked", tostring(#pallets), cx, cy, cw, COL.text)
        cy = cy + statRight("Killer visible", #killerRoots > 0 and "YES" or "--", cx, cy, cw,
                #killerRoots > 0 and COL.warn or COL.dim)
        cy = cy + statRight("At a pallet", pStat.elig and "YES" or "--", cx, cy, cw,
                pStat.elig and COL.on or COL.dim)
        cy = cy + statRight("Stun zone", pStat.inZone and "FIRE" or "--", cx, cy, cw,
                pStat.inZone and COL.warn or COL.dim)
        cy = cy + statRight("Range  pallet / killer", ("%s / %s"):format(
                pStat.nearD and ("%.1f"):format(pStat.nearD) or "--",
                pStat.killD and ("%.1f"):format(pStat.killD) or "--"), cx, cy, cw, COL.dim)
        y = y + 104
        T(pStat.hp == false and "Health <= 50 -- the game blocks the drop" or "Key: SPACE",
            pad, y, 11, pStat.hp == false and COL.bad or COL.dim)

    elseif state.tab == "skill" then
        y = y + toggleRow("Auto Skillcheck", pad, y, innerW,
            function() return c.sc_enabled end,
            function(v) c.sc_enabled = v end)
        y = y + 6
        y = y + section("Timing", pad, y, innerW)
        y = y + stepper("Lead (deg)", pad, y, innerW,
            function() return c.sc_lead end,
            function(v) c.sc_lead = v end, 0, 10, 1, "%d")
        y = y + 12
        if not unsafe then
            card(pad - 8, y, innerW + 16, 62)
            T("Unsafe LuaU is disabled", pad, y + 10, 13, COL.bad)
            T("Enable 'Allow Unsafe LuaU' in Matcha", pad, y + 28, 11, COL.warn)
            T("settings to read the skillcheck needle.", pad, y + 42, 11, COL.warn)
            y = y + 70
        else
            card(pad - 8, y, innerW + 16, 116)
            local cy = y + 9
            cy = cy + statRight("Line / Goal", ("%s / %s"):format(
                    scLast.l and ("%.0f"):format(scLast.l) or "--",
                    scLast.g and ("%.0f"):format(scLast.g) or "--"), pad, cy, innerW, COL.text)
            cy = cy + statRight("Success window", tostring(scLast.win or "--"), pad, cy, innerW, COL.dim)
            cy = cy + statRight("Checks / inputs", ("%d / %d"):format(scChecks, scHits),
                    pad, cy, innerW, scHits > 0 and COL.on or COL.dim)
            cy = cy + statRight("Missed windows", tostring(scStat.misses), pad, cy, innerW,
                    scStat.misses > 0 and COL.warn or COL.dim)
            cy = cy + statRight("Game binding", scStat.key, pad, cy, innerW, COL.text)
            cy = cy + statRight("Prompt", scStat.offset and "VERIFIED" or "WAITING", pad, cy, innerW,
                    scStat.offset and COL.on or COL.dim)
            y = y + 124
        end
        T(scStat.status, pad, y, 11, scStat.error and COL.bad or COL.dim)
        y = y + 18
        T("Repair, healing and chained checks.", pad, y, 11, COL.dim)

    elseif state.tab == "vault" then
        y = y + toggleRow("Always Fast Vault", pad, y, innerW,
            function() return c.fv_enabled end,
            function(v) c.fv_enabled = v end)
        y = y + 6
        y = y + section("Approach", pad, y, innerW)
        T("Sprint at a window from any angle.", pad, y, 12, COL.text)
        y = y + 18
        T("Short run-ups and repeat vaults are handled.", pad, y, 11, COL.dim)
        y = y + 18
        T("Sprinting and normal movement are required.", pad, y, 11, COL.dim)
        y = y + 26
        card(pad - 8, y, innerW + 16, 98)
        local cy = y + 9
        cy = cy + statRight("Windows tracked", tostring(#vaults), pad, cy, innerW, COL.text)
        cy = cy + statRight("Assist active", fvStat.holding and "YES" or "--", pad, cy, innerW,
                fvStat.holding and COL.on or COL.dim)
        cy = cy + statRight("Vaults / fast", ("%d / %d"):format(fvStat.vaults, fvStat.fast),
                pad, cy, innerW, fvStat.fast > 0 and COL.on or COL.dim)
        cy = cy + statRight("Last tier", fvStat.tier or "--", pad, cy, innerW,
                fvStat.tier == "fast" and COL.on or COL.dim)
        cy = cy + statRight("Game reason", fvStat.reason or "--", pad, cy, innerW, COL.dim)
        y = y + 106
        T(fvStat.status, pad, y, 11, fvStat.error and COL.warn or COL.dim)
        y = y + 18
        T("Switching off restores the normal vault rules.", pad, y, 11, COL.dim)

    elseif state.tab == "veil" then
        y = y + toggleRow("Veil Spear Aimbot", pad, y, innerW,
            function() return c.va_enabled end,
            function(v) c.va_enabled = v end)
        y = y + 4
        y = y + section("Targeting", pad, y, innerW)
        y = y + stepper("FOV", pad, y, innerW,
            function() return c.va_fov end,
            function(v) c.va_fov = v end, 5, 90, 5, "%d deg")
        y = y + stepper("Range", pad, y, innerW,
            function() return c.va_range end,
            function(v) c.va_range = v end, 40, 400, 20, "%d")
        y = y + stepper("Smoothing", pad, y, innerW,
            function() return c.va_smooth end,
            function(v) c.va_smooth = math.floor(v + 0.5) end,
            1, 20, 1, "%d")
        y = y + 6
        local hw = innerW / 2 - 4
        chip("Lead target",  pad,          y, hw, function() return c.va_lead end,      function(v) c.va_lead = v end)
        chip("Euler fix",    pad + hw + 8, y, hw, function() return c.va_euler end,     function(v) c.va_euler = v end)
        y = y + 28
        -- Matcha has no working raycast (see vaRayUsable), so name the chip after
        -- what it can actually do instead of leaving a dead filter looking live.
        local losLbl = (vaStat.losOK == false) and "LOS: n/a here" or "Line of sight"
        chip(losLbl,          pad,          y, hw, function() return c.va_los end,      function(v) c.va_los = v end)
        chip("Auto-cal",      pad + hw + 8, y, hw, function() return c.va_autocal end,  function(v) c.va_autocal = v end)
        y = y + 28
        chip("Charge only",  pad,          y, hw, function() return c.va_holdOnly end,  function(v) c.va_holdOnly = v end)
        chip("Cam origin",   pad + hw + 8, y, hw, function() return c.va_originCam end, function(v) c.va_originCam = v end)
        y = y + 28
        -- full width: this is the headline targeting behaviour, so give it the row
        chip("Sticky aim (hold target)", pad, y, innerW,
            function() return c.va_sticky end, function(v) c.va_sticky = v end)
        y = y + 34

        card(pad - 8, y, innerW + 16, 112)
        local cy = y + 9
        cy = cy + statRight("Target",
                (vaStat.target or "--") .. (vaStat.held and "   LOCK" or ""),
                pad, cy, innerW,
                vaStat.held and COL.accent or (vaStat.target and COL.on or COL.dim))
        cy = cy + statRight("Distance", vaStat.dist and ("%.0f"):format(vaStat.dist) or "--",
                pad, cy, innerW, COL.text)
        cy = cy + statRight("Charge", ("%.2fs  %s"):format(vaStat.hold or 0,
                vaStat.tier or "--"), pad, cy, innerW,
                (vaStat.tier == "CHARGED") and COL.warn or COL.text)
        cy = cy + statRight("Launch speed", vaStat.speed and ("%.1f"):format(vaStat.speed) or "--",
                pad, cy, innerW, COL.text)
        cy = cy + statRight("Flight / drop", ("%s / %s"):format(
                vaStat.flight and ("%.2fs"):format(vaStat.flight) or "--",
                vaStat.drop   and ("%.1f"):format(vaStat.drop)    or "--"),
                pad, cy, innerW, COL.dim)
        cy = cy + statRight("GMult", vaStat.gmult
                and ("%.3f  (%d arcs)"):format(c.va_gmult or 1, vaStat.measN or 0)
                or ("%.3f  (default)"):format(c.va_gmult or 1),
                pad, cy, innerW, vaStat.gmult and COL.on or COL.warn)
        y = y + 120

        if vaStat.cd and vaStat.cd > 0.5 then
            T(("Charged throw on cooldown: %.0fs"):format(vaStat.cd), pad, y, 11, COL.warn)
        elseif not vaStat.addr and c.va_enabled then
            T("Resolving camera address...", pad, y, 11, COL.warn)
        elseif vaStat.solved then
            T("Solution locked -- release to throw.", pad, y, 11, COL.on)
        else
            T("Hold attack with a spear equipped to aim.", pad, y, 11, COL.dim)
        end

    else  -- settings
        y = y + section("Theme", pad, y, innerW)
        local hw = innerW / 2 - 4
        for i = 1, #THEMES do
            local col = (i - 1) % 2
            local row = math.floor((i - 1) / 2)
            themeCell(i, pad + col * (hw + 8), y + row * 36, hw)
        end
        y = y + math.ceil(#THEMES / 2) * 36 + 8
        y = y + section("Panel", pad, y, innerW)
        y = y + stepper("Opacity", pad, y, innerW,
            function() return c.ui_opacity end,
            function(v) c.ui_opacity = math.floor(v * 20 + 0.5) / 20 end,
            0.35, 1, 0.05, "%.2f")
        y = y + stepper("Corner radius", pad, y, innerW,
            function() return c.ui_round end,
            function(v) c.ui_round = v end, 0, 14, 2, "%d px")
        y = y + 12
        T("Settings are not persisted -- a reload resets", pad, y, 11, COL.dim); y = y + 14
        T("every toggle on every tab.", pad, y, 11, COL.dim); y = y + 18
        T("Stop the hub:  _G.vdHub.stop()", pad, y, 11, COL.accent)
    end

    for i = siUse + 1, #sq do sq[i].Visible = false end
    for i = tiUse + 1, #tx do tx[i].Visible = false end
    prevHot = hot
end


local renderConn
renderConn = RunService.RenderStepped:Connect(draw)

--======================================================================
--  STOP
--======================================================================
state.stop = function()
    state.running = false
    scReleaseInput()
    local restored = fvRestore()
    if renderConn then renderConn:Disconnect() end
    for i=1,#sq do pcall(function() sq[i]:Remove() end) end
    for i=1,#tx do pcall(function() tx[i]:Remove() end) end
    if restored then
        if _G.vdHub == state then _G.vdHub = nil end
    else
        warn("[vdHub] Vault restore pending. Enable Unsafe LuaU, then call _G.vdHub.stop() again.")
    end
    return restored
end

-- live introspection (pallets is REBOUND on every scan, so this must be a
-- function -- holding a reference to the table would go stale each round)
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
        theme       = (THEMES[state.cfg.theme] or {}).name,
    }
end

-- force a fresh camera-offset resolve (after a respawn or a Roblox update)
state.veilRecal = function()
    vaRot, vaRotFor, vaWarmAt = nil, nil, 0
    return vaRotAddr()
end

-- Portability report, for when this script is running on someone else's
-- executor and the UI looks wrong. "Text invisible but the panel draws" is
-- almost always one of the first two lines: no ZIndex support (so the fills
-- win the tie) or a font index this build does not define. Run it there and
-- send back what it prints.
state.uiDiag = function()
    print("---- vdHub UI diagnostic ----")
    print(("ZIndex writable : %s   (false = draw order is up to the executor)")
        :format(tostring(Z_OK)))
    print(("Font in use     : %d (%s)  resolved by name, not index")
        :format(FONT, FONTNAME))
    local fonts = Drawing.Fonts
    if type(fonts) == "table" then
        local parts = {}
        for k, v in pairs(fonts) do parts[#parts + 1] = tostring(k) .. "=" .. tostring(v) end
        table.sort(parts)
        print("Drawing.Fonts   : " .. table.concat(parts, ", "))
    else
        print("Drawing.Fonts   : " .. type(fonts) .. " (not a table)")
    end
    print(("pools           : %d squares, %d texts"):format(#sq, #tx))
    local t = tx[1]
    if t then
        local okB, b = pcall(function() return t.TextBounds end)
        print(("TextBounds      : %s  (false breaks right-aligned values)")
            :format(okB and tostring(b) or "unsupported"))
        local okT, tv = pcall(function() return t.Transparency end)
        print(("Text.Transparency reads back: %s  (expect 1 = opaque)")
            :format(okT and tostring(tv) or "unsupported"))
        local okZ, zv = pcall(function() return t.ZIndex end)
        print(("Text[1].ZIndex  : %s  (expect %d)")
            :format(okZ and tostring(zv) or "unsupported", Z_TEXT + 1))
    end
    -- the whole point of the fix: every text must outrank every square
    local function zOf(o)
        if not o then return "nil" end
        local k, v = pcall(function() return o.ZIndex end)
        return k and tostring(v) or "unsupported"
    end
    print(("layering        : squares %s..%s   texts %s..%s")
        :format(zOf(sq[1]), zOf(sq[#sq]), zOf(tx[1]), zOf(tx[#tx])))
    print(("panel           : %d,%d  %dx%d   theme=%d  opacity=%.2f")
        :format(UX, UY, UW, UH, state.cfg.theme or 1, state.cfg.ui_opacity or 1))
    print("-----------------------------")
    return { zindex = Z_OK, font = FONT, squares = #sq, texts = #tx }
end

-- theme control from the console as well as the Settings tab
state.themes = function()
    local out = {}
    for i, t in ipairs(THEMES) do out[i] = t.name end
    return out
end

state.setTheme = function(i)
    if type(i) == "string" then
        for j, t in ipairs(THEMES) do
            if t.name:lower() == i:lower() then i = j break end
        end
    end
    if not THEMES[i] then return nil end
    state.cfg.theme = i
    applyTheme(i)
    return THEMES[i].name
end

notify("Violence District Hub", "Loaded. No calibration needed.", 4)
print("[vdHub] loaded -- stop with _G.vdHub.stop()")
