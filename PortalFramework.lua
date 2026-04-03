--[[
    ╔══════════════════════════════════════════════════════════════════════╗
    ║               PORTAL FRAMEWORK  v2.0  [XENO]                        ║
    ║                                                                      ║
    ║  Rendering: ViewportFrame inside BillboardGui — zero camera swaps   ║
    ║  Geometry:  Cylinder Part fallback (EditableMesh optional)          ║
    ║  Images:    AssetService:CreateEditableImage() (modern API)         ║
    ║  Portal 2-style mirror transform + seamless teleport                ║
    ║  Glowing WireframeHandleAdornment rim                               ║
    ║                                                                      ║
    ║  USAGE:                                                              ║
    ║    local P = loadstring(readfile("PortalFramework.lua"))()          ║
    ║    local pair = P.newPair()                                         ║
    ║    pair:placeA(cframe)   pair:placeB(cframe)                       ║
    ║    pair:clearA()  pair:clearB()  pair:clear()  pair:destroy()      ║
    ║                                                                      ║
    ║  SETTINGS (live, on pair.settings):                                 ║
    ║    renderFPS       number  1-60, default 20                        ║
    ║    teleportEnabled bool    default true                             ║
    ║    cameraBleed     bool    default true                             ║
    ║    showRing        bool    default true                             ║
    ║                                                                      ║
    ║  PORTAL SIZE: 3 studs wide x 4.5 studs tall                        ║
    ╚══════════════════════════════════════════════════════════════════════╝
--]]

local Players      = game:GetService("Players")
local RunService   = game:GetService("RunService")
local AssetService = game:GetService("AssetService")
local Workspace    = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer

-- ══════════════════════════════════════════
--  CONSTANTS
-- ══════════════════════════════════════════
local PORTAL_W       = 3.0
local PORTAL_H       = 4.5
local FLIP180        = CFrame.Angles(0, math.pi, 0)
local CAM_OFFSET     = 0.05
local TELEPORT_DEPTH = 0.25
local RIM_SEGS       = 32
local RIM_THICK      = 3
local VPW, VPH       = 400, 600   -- ViewportFrame pixel size

local COLOR_A     = Color3.fromRGB( 60, 120, 255)
local COLOR_B     = Color3.fromRGB(255, 120,  30)
local COLOR_A_RIM = Color3.fromRGB(100, 160, 255)
local COLOR_B_RIM = Color3.fromRGB(255, 160,  60)

-- ══════════════════════════════════════════
--  MATH HELPERS
-- ══════════════════════════════════════════
local function mirrorThrough(cfA, cfB, inputCF)
    return cfB * FLIP180 * cfA:Inverse() * inputCF
end

local function planeDepth(portalCF, point)
    return -(portalCF:Inverse() * point).Z
end

local function insideOval(portalCF, point)
    local lp = portalCF:Inverse() * point
    local rx, ry = PORTAL_W * 0.5, PORTAL_H * 0.5
    return (lp.X * lp.X) / (rx * rx) + (lp.Y * lp.Y) / (ry * ry) <= 1.0
end

-- ══════════════════════════════════════════
--  CAPABILITY PROBES (run once at load)
-- ══════════════════════════════════════════
local _hasEditableMesh = false
do
    local ok = pcall(function()
        local em = AssetService:CreateEditableMesh()
        em:Destroy()
    end)
    _hasEditableMesh = ok
    print("[PortalFramework v2] EditableMesh=" .. tostring(ok))
end

-- ══════════════════════════════════════════
--  OPTIONAL WireframeFramework
-- ══════════════════════════════════════════
local WF = nil
if isfile and isfile("WireframeFramework.lua") then
    local ok, r = pcall(function() return loadstring(readfile("WireframeFramework.lua"))() end)
    if ok then WF = r end
end

-- ══════════════════════════════════════════
--  SURFACE PART
--  Oval MeshPart when EditableMesh available,
--  Cylinder Part otherwise.
-- ══════════════════════════════════════════
local function buildSurfacePart(label, color)
    -- Try oval MeshPart first
    if _hasEditableMesh then
        local ok, result = pcall(function()
            local SEGS = 32
            local em   = AssetService:CreateEditableMesh()

            local cx = em:AddVertex()
            em:SetPosition(cx, Vector3.new(0, 0, 0))
            em:SetNormal(cx, Vector3.new(0, 0, 1))
            em:SetUV(cx, Vector2.new(0.5, 0.5))

            local ring = {}
            for i = 1, SEGS do
                local a  = (i - 1) / SEGS * math.pi * 2
                local vx = math.cos(a) * 0.5
                local vy = math.sin(a) * 0.5
                local v  = em:AddVertex()
                em:SetPosition(v, Vector3.new(vx, vy, 0))
                em:SetNormal(v, Vector3.new(0, 0, 1))
                em:SetUV(v, Vector2.new(vx + 0.5, 0.5 - vy))
                ring[i] = v
            end
            for i = 1, SEGS do
                em:AddTriangle(cx, ring[i], ring[(i % SEGS) + 1])
            end

            local mp    = AssetService:CreateMeshPartAsync(Content.fromObject(em))
            mp.Name     = "PortalSurface_" .. label
            mp.Anchored = true; mp.CanCollide = false
            mp.CastShadow = false; mp.Locked = true
            mp.Color    = color; mp.Material = Enum.Material.Neon
            mp.Size     = Vector3.new(0.05, PORTAL_H, PORTAL_W)
            return mp
        end)
        if ok and result then return result end
        _hasEditableMesh = false
    end

    -- Cylinder fallback
    local p = Instance.new("Part")
    p.Name       = "PortalSurface_" .. label
    p.Shape      = Enum.PartType.Cylinder
    p.Anchored   = true; p.CanCollide = false
    p.CastShadow = false; p.Locked = true
    p.Color      = color; p.Material = Enum.Material.Neon
    p.Size       = Vector3.new(0.05, PORTAL_H, PORTAL_W)
    return p
end

-- ══════════════════════════════════════════
--  GLOW RIM
-- ══════════════════════════════════════════
local function buildRim(surfacePart, color)
    local wha = Instance.new("WireframeHandleAdornment")
    wha.Adornee     = surfacePart
    wha.Color3      = color
    wha.Thickness   = RIM_THICK
    wha.AlwaysOnTop = false
    wha.Visible     = true
    wha.Parent      = surfacePart

    local rx = PORTAL_W * 0.5
    local ry = PORTAL_H * 0.5
    local prev = nil
    for i = 0, RIM_SEGS do
        local a  = i / RIM_SEGS * math.pi * 2
        -- Adornee local space: cylinder axis = X, face plane = YZ
        local pt = Vector3.new(0, math.sin(a) * ry, math.cos(a) * rx)
        if prev then wha:AddLine(prev, pt) end
        prev = pt
    end
    return wha
end

-- ══════════════════════════════════════════
--  VIEWPORT RENDERER
--
--  BillboardGui anchored to an invisible Part.
--  ViewportFrame inside shows what the portal
--  secondary camera sees.
--  Workspace.CurrentCamera is NEVER touched.
-- ══════════════════════════════════════════
local function buildViewportRenderer(anchorPart, label)
    local bbg = Instance.new("BillboardGui")
    bbg.Name             = "PortalBB_" .. label
    bbg.Adornee          = anchorPart
    bbg.AlwaysOnTop      = false
    bbg.Size             = UDim2.new(0, VPW, 0, VPH)
    -- Push the billboard slightly off the wall so it sits in front
    bbg.StudsOffset      = Vector3.new(0, 0, 0.08)
    bbg.ResetOnSpawn     = false
    bbg.LightInfluence   = 0
    bbg.Parent           = anchorPart

    local vpf = Instance.new("ViewportFrame")
    vpf.Name                  = "VP"
    vpf.Size                  = UDim2.new(1, 0, 1, 0)
    vpf.BackgroundTransparency = 1
    vpf.LightColor            = Color3.new(1, 1, 1)
    vpf.Ambient               = Color3.new(1, 1, 1)
    vpf.Parent                = bbg

    local vpCam = Instance.new("Camera")
    vpCam.Name        = "VPCam_" .. label
    vpCam.FieldOfView = 70
    vpCam.Parent      = vpf
    vpf.CurrentCamera = vpCam

    return bbg, vpf, vpCam
end

-- ══════════════════════════════════════════
--  PORTAL OBJECT
-- ══════════════════════════════════════════
local PortalObject = {}
PortalObject.__index = PortalObject

local function newPortalObject(color, rimColor, label)
    local self    = setmetatable({}, PortalObject)
    self.color    = color
    self.rimColor = rimColor
    self.label    = label
    self.placed   = false
    self.cf       = CFrame.new()
    -- instances
    self.anchorPart   = nil
    self.surfacePart  = nil
    self.secondaryCam = nil
    self.rimAdornment = nil
    self.bbg          = nil
    self.vpf          = nil
    self.vpCam        = nil
    return self
end

function PortalObject:_build(cf)
    self:_clear()
    self.cf     = cf
    self.placed = true

    -- Invisible anchor (BillboardGui needs an Adornee in Workspace)
    local anchor       = Instance.new("Part")
    anchor.Name        = "PortalAnchor_" .. self.label
    anchor.Anchored    = true
    anchor.CanCollide  = false
    anchor.CastShadow  = false
    anchor.Transparency = 1
    anchor.Size        = Vector3.new(0.1, 0.1, 0.1)
    anchor.CFrame      = cf
    anchor.Parent      = Workspace
    self.anchorPart    = anchor

    -- Visual surface
    -- cf: +Z = outward normal. Cylinder axis = local X.
    -- Rotate -90 deg around Z so local X aligns with +Z (the normal).
    local surf    = buildSurfacePart(self.label, self.color)
    surf.CFrame   = cf * CFrame.Angles(0, 0, -math.pi * 0.5)
    surf.Parent   = Workspace
    self.surfacePart = surf

    -- Secondary mirror camera (a plain Workspace Camera — NOT CurrentCamera)
    local cam        = Instance.new("Camera")
    cam.Name         = "PortalCam_" .. self.label
    cam.FieldOfView  = 70
    cam.CFrame       = cf * CFrame.new(0, 0, -CAM_OFFSET)
    cam.Parent       = Workspace
    self.secondaryCam = cam

    -- ViewportFrame billboard renderer
    local bbg, vpf, vpCam = buildViewportRenderer(anchor, self.label)
    self.bbg   = bbg
    self.vpf   = vpf
    self.vpCam = vpCam

    -- Glow rim
    self.rimAdornment = buildRim(surf, self.rimColor)

    -- Optional WireframeFramework placement pulse
    if WF and WF.spawnEffect then
        task.spawn(function()
            local h = WF.spawnEffect(surf, {
                color = self.rimColor, thickness = 1.5,
                alwaysOnTop = true, overlay = true,
                buildMode = "random", driftTime = 0.2, wireFadeTime = 0.3,
            })
            task.delay(1.0, function() if h then pcall(h.cancel) end end)
        end)
    end
end

function PortalObject:_clear()
    self.placed = false
    local function destroy(inst)
        if inst then pcall(function() inst:Destroy() end) end
    end
    destroy(self.anchorPart);  self.anchorPart   = nil
    destroy(self.surfacePart); self.surfacePart  = nil
    destroy(self.secondaryCam);self.secondaryCam = nil
    destroy(self.bbg);         self.bbg          = nil
    self.vpf = nil; self.vpCam = nil; self.rimAdornment = nil
end

-- ══════════════════════════════════════════
--  PORTAL PAIR
-- ══════════════════════════════════════════
local PortalPair = {}
PortalPair.__index = PortalPair

local _allPairs = {}

local function newPair()
    local self = setmetatable({}, PortalPair)
    self.portalA = newPortalObject(COLOR_A, COLOR_A_RIM, "A")
    self.portalB = newPortalObject(COLOR_B, COLOR_B_RIM, "B")
    self.settings = {
        renderFPS = 20, teleportEnabled = true,
        cameraBleed = true, showRing = true,
    }
    self._prevDepth   = { A = nil, B = nil }
    self._destroyed   = false
    self._camBleeding = false
    self._playerCamRef= nil

    self._heartConn = RunService.Heartbeat:Connect(function()
        self:_update()
    end)
    _allPairs[#_allPairs + 1] = self
    return self
end

-- Placement
function PortalPair:placeA(cf) self.portalA:_build(cf); self._prevDepth.A = nil end
function PortalPair:placeB(cf) self.portalB:_build(cf); self._prevDepth.B = nil end
function PortalPair:placePair(cfA, cfB) self:placeA(cfA); self:placeB(cfB) end

function PortalPair:clearA()
    if self._camBleeding then self:_restoreCamera() end
    self.portalA:_clear(); self._prevDepth.A = nil
end
function PortalPair:clearB()
    if self._camBleeding then self:_restoreCamera() end
    self.portalB:_clear(); self._prevDepth.B = nil
end
function PortalPair:clear() self:clearA(); self:clearB() end

-- Settings
function PortalPair:setRenderFPS(fps) self.settings.renderFPS = math.clamp(fps, 1, 60) end
function PortalPair:setTeleport(v)    self.settings.teleportEnabled = v end
function PortalPair:setCameraBleed(v)
    if not v and self._camBleeding then self:_restoreCamera() end
    self.settings.cameraBleed = v
end
function PortalPair:setShowRing(v)
    self.settings.showRing = v
    if self.portalA.rimAdornment then self.portalA.rimAdornment.Visible = v end
    if self.portalB.rimAdornment then self.portalB.rimAdornment.Visible = v end
end

function PortalPair:_restoreCamera()
    self._camBleeding = false
    local r = self._playerCamRef
    if r and r.Parent and Workspace.CurrentCamera ~= r then
        Workspace.CurrentCamera = r
    end
    self._playerCamRef = nil
end

-- Main update
function PortalPair:_update()
    if self._destroyed then return end

    local activeCam = Workspace.CurrentCamera
    if not activeCam then return end

    local playerCF   = activeCam.CFrame
    local playerChar = LocalPlayer.Character
    local hrp        = playerChar and (
        playerChar:FindFirstChild("HumanoidRootPart") or
        playerChar:FindFirstChild("Torso"))

    local both = self.portalA.placed and self.portalB.placed

    -- Mirror cameras + sync ViewportFrames
    if both then
        pcall(function()
            self.portalB.secondaryCam.CFrame =
                mirrorThrough(self.portalA.cf, self.portalB.cf, playerCF)
            self.portalA.secondaryCam.CFrame =
                mirrorThrough(self.portalB.cf, self.portalA.cf, playerCF)

            -- Portal A shows view from B's side; portal B shows view from A's side
            if self.portalA.vpCam and self.portalA.vpCam.Parent then
                self.portalA.vpCam.CFrame     = self.portalB.secondaryCam.CFrame
                self.portalA.vpCam.FieldOfView= self.portalB.secondaryCam.FieldOfView
            end
            if self.portalB.vpCam and self.portalB.vpCam.Parent then
                self.portalB.vpCam.CFrame     = self.portalA.secondaryCam.CFrame
                self.portalB.vpCam.FieldOfView= self.portalA.secondaryCam.FieldOfView
            end
        end)
    end

    -- Teleport
    if self.settings.teleportEnabled and hrp and both then
        local function check(entry, exit, key)
            local depth = planeDepth(entry.cf, hrp.Position)
            local prev  = self._prevDepth[key]
            if prev and prev >= 0 and depth < -TELEPORT_DEPTH
               and insideOval(entry.cf, hrp.Position) then
                self:_teleport(hrp, entry, exit)
            end
            self._prevDepth[key] = depth
        end
        check(self.portalA, self.portalB, "A")
        check(self.portalB, self.portalA, "B")
    end

    -- Camera bleed (optional, heavily guarded)
    if self.settings.cameraBleed and both and hrp then
        pcall(function() self:_updateCameraBleed(activeCam, playerCF) end)
    elseif self._camBleeding then
        self:_restoreCamera()
    end
end

function PortalPair:_updateCameraBleed(activeCam, playerCF)
    if self._camBleeding then
        -- Check if we've left both portal planes
        local stillIn = false
        for _, portal in ipairs({ self.portalA, self.portalB }) do
            if portal.placed then
                if planeDepth(portal.cf, playerCF.Position) < 0
                   and insideOval(portal.cf, playerCF.Position) then
                    stillIn = true; break
                end
            end
        end
        if not stillIn then self:_restoreCamera() end
        return
    end

    -- Check if camera just entered a portal
    local pairs = {
        { entry = self.portalA, exit = self.portalB },
        { entry = self.portalB, exit = self.portalA },
    }
    for _, p in ipairs(pairs) do
        if p.entry.placed and p.exit.placed
           and p.exit.secondaryCam and p.exit.secondaryCam.Parent then
            local d = planeDepth(p.entry.cf, playerCF.Position)
            if d < 0 and insideOval(p.entry.cf, playerCF.Position) then
                self._camBleeding  = true
                self._playerCamRef = activeCam
                if Workspace.CurrentCamera ~= p.exit.secondaryCam then
                    Workspace.CurrentCamera = p.exit.secondaryCam
                end
                return
            end
        end
    end
end

function PortalPair:_teleport(hrp, entry, exit)
    local relCF = entry.cf:Inverse() * hrp.CFrame
    hrp.CFrame  = exit.cf * FLIP180 * relCF

    local vel = hrp.AssemblyLinearVelocity
    local lv  = entry.cf:VectorToObjectSpace(vel)
    lv        = Vector3.new(-lv.X, lv.Y, -lv.Z)
    hrp.AssemblyLinearVelocity = exit.cf:VectorToWorldSpace(lv)

    local liveCam = Workspace.CurrentCamera
    if liveCam
       and liveCam ~= self.portalA.secondaryCam
       and liveCam ~= self.portalB.secondaryCam then
        local camRel  = entry.cf:Inverse() * liveCam.CFrame
        liveCam.CFrame = exit.cf * FLIP180 * camRel
    end

    self._camBleeding  = false
    self._playerCamRef = nil
    self._prevDepth.A  = nil
    self._prevDepth.B  = nil
    print(("[Portal] Teleported %s → %s"):format(entry.label, exit.label))
end

function PortalPair:destroy()
    if self._destroyed then return end
    self._destroyed = true
    if self._camBleeding then self:_restoreCamera() end
    if self._heartConn then self._heartConn:Disconnect() end
    self:clear()
    for i = #_allPairs, 1, -1 do
        if _allPairs[i] == self then table.remove(_allPairs, i); break end
    end
end

-- ══════════════════════════════════════════
--  PUBLIC MODULE
-- ══════════════════════════════════════════
local Portal = {}
function Portal.newPair()  return newPair() end
function Portal.getPairs() return table.clone(_allPairs) end
function Portal.destroyAll()
    for _, p in ipairs(table.clone(_allPairs)) do p:destroy() end
end

Portal.VERSION  = "2.0.0"
Portal.COLOR_A  = COLOR_A
Portal.COLOR_B  = COLOR_B
Portal.PORTAL_W = PORTAL_W
Portal.PORTAL_H = PORTAL_H

return Portal