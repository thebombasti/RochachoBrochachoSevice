--[[
    ╔══════════════════════════════════════════════════════════════════════╗
    ║               WIREFRAME FRAMEWORK  v6.0  [XENO]                     ║
    ║                                                                      ║
    ║  GPU-only rendering via WireframeHandleAdornment + AddLine()        ║
    ║  Vertex-dot phase via SphereHandleAdornment (drift + settle)        ║
    ║  Real mesh geometry extracted via EditableMesh (cached).            ║
    ║                                                                      ║
    ║  USAGE:                                                              ║
    ║    local WF = loadstring(readfile("WireframeFramework.lua"))()      ║
    ║                                                                      ║
    ║    local wf = WF.new(part)                                          ║
    ║    local wf = WF.newModel(model)                                    ║
    ║    local wf = WF.newCharacter(characterModel)                       ║
    ║    local wf = WF.newBatch({part1, part2, ...})                      ║
    ║                                                                      ║
    ║  METHODS (all chainable):                                           ║
    ║    wf:Enable()  /  wf:Disable()  /  wf:Destroy()                   ║
    ║    wf:SetColor(Color3)                                               ║
    ║    wf:SetThickness(number)                                           ║
    ║    wf:SetTransparency(number)   -- 0 opaque, 1 invisible            ║
    ║    wf:SetAlwaysOnTop(bool)      -- show through walls               ║
    ║    wf:Pulse(duration, color)                                         ║
    ║                                                                      ║
    ║  SPAWN / DELETE ANIMATIONS:                                          ║
    ║    WF.spawnEffect(part, cfg)   -- node-graph wireframe → mesh       ║
    ║    WF.deleteEffect(part, cfg)  -- mesh → wireframe → dissolve       ║
    ║                                                                      ║
    ║  cfg fields:                                                         ║
    ║    color         Color3   wire/dot color                            ║
    ║    thickness     number   line thickness                             ║
    ║    alwaysOnTop   bool                                                ║
    ║    buildMode     string   "topdown"|"bottomup"|"random"|"inward"    ║
    ║    vertexDelay   number   seconds between each vertex trigger        ║
    ║    driftTime     number   seconds each vertex drifts (default 0.3)  ║
    ║    meshFadeTime  number   seconds mesh fades in/out (default 0.4)   ║
    ║    wireFadeTime  number   seconds wireframe fades (default 0.3)     ║
    ║    onComplete    fn                                                  ║
    ║                                                                      ║
    ║  LEGACY ANIMATIONS:                                                  ║
    ║    WF.buildAnimate(target, cfg)                                      ║
    ║    WF.faceReveal(target, cfg)                                        ║
    ╚══════════════════════════════════════════════════════════════════════╝
--]]

local Players      = game:GetService("Players")
local RunService   = game:GetService("RunService")
local AssetService = game:GetService("AssetService")
local TweenService = game:GetService("TweenService")
local Workspace    = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer
local Camera      = Workspace.CurrentCamera

-- ══════════════════════════════════════════
--  INSTANCE REGISTRY
-- ══════════════════════════════════════════
local _registry = {}

local function _register(obj)   _registry[#_registry+1] = obj end
local function _unregister(obj)
    for i = #_registry, 1, -1 do
        if _registry[i] == obj then table.remove(_registry, i); break end
    end
end

-- ══════════════════════════════════════════
--  MESH DATA EXTRACTION
-- ══════════════════════════════════════════
local function getMeshId(part)
    if part:IsA("MeshPart") and part.MeshId ~= "" then return part.MeshId end
    local sm = part:FindFirstChildWhichIsA("SpecialMesh")
    if sm and sm.MeshId ~= "" then return sm.MeshId end
    return nil
end

local _meshCache = {}

local function extractMeshData(part)
    local meshId = getMeshId(part)
    if not meshId then return nil end
    if _meshCache[meshId] ~= nil then
        return _meshCache[meshId] ~= false and _meshCache[meshId] or nil
    end

    local em
    if not pcall(function()
        em = AssetService:CreateEditableMeshAsync(Content.fromUri(meshId))
    end) or not em then
        warn("[WF] CreateEditableMeshAsync failed for " .. part.Name)
        _meshCache[meshId] = false
        return nil
    end

    local vidToIdx = {}
    local unitVerts = {}
    for _, vid in ipairs(em:GetVertices()) do
        local i = #unitVerts + 1
        unitVerts[i]  = em:GetPosition(vid)
        vidToIdx[vid] = i
    end

    local edgeSet = {}
    local edgeA   = {}
    local edgeB   = {}
    for _, fid in ipairs(em:GetFaces()) do
        local fv = em:GetFaceVertices(fid)
        local i1 = vidToIdx[fv[1]]
        local i2 = vidToIdx[fv[2]]
        local i3 = vidToIdx[fv[3]]
        local k
        k = i1<i2 and i1.."_"..i2 or i2.."_"..i1
        if not edgeSet[k] then edgeSet[k]=true; edgeA[#edgeA+1]=i1; edgeB[#edgeB+1]=i2 end
        k = i2<i3 and i2.."_"..i3 or i3.."_"..i2
        if not edgeSet[k] then edgeSet[k]=true; edgeA[#edgeA+1]=i2; edgeB[#edgeB+1]=i3 end
        k = i3<i1 and i3.."_"..i1 or i1.."_"..i3
        if not edgeSet[k] then edgeSet[k]=true; edgeA[#edgeA+1]=i3; edgeB[#edgeB+1]=i1 end
    end

    local nv = #unitVerts
    local ne = #edgeA
    em:Destroy()

    local vertEdges = table.create(nv)
    for i = 1, nv do vertEdges[i] = {} end
    for i = 1, ne do
        local a, b = edgeA[i], edgeB[i]
        vertEdges[a][#vertEdges[a]+1] = i
        vertEdges[b][#vertEdges[b]+1] = i
    end

    -- Neighbour vertices (vertices sharing an edge) — used for inward mode
    local vertNeighbors = table.create(nv)
    for i = 1, nv do vertNeighbors[i] = {} end
    for i = 1, ne do
        local a, b = edgeA[i], edgeB[i]
        vertNeighbors[a][#vertNeighbors[a]+1] = b
        vertNeighbors[b][#vertNeighbors[b]+1] = a
    end

    print(string.format("[WF] '%s' — %d verts | %d edges (cached)", part.Name, nv, ne))

    local data = {
        unitVerts    = unitVerts,
        edgeA        = edgeA,
        edgeB        = edgeB,
        vertEdges    = vertEdges,
        vertNeighbors = vertNeighbors,
    }
    _meshCache[meshId] = data
    return data
end

-- ══════════════════════════════════════════
--  BOX FALLBACK
-- ══════════════════════════════════════════
local BOX_UNIT_VERTS = {
    Vector3.new(-0.5,-0.5,-0.5), Vector3.new(-0.5,-0.5, 0.5),
    Vector3.new(-0.5, 0.5,-0.5), Vector3.new(-0.5, 0.5, 0.5),
    Vector3.new( 0.5,-0.5,-0.5), Vector3.new( 0.5,-0.5, 0.5),
    Vector3.new( 0.5, 0.5,-0.5), Vector3.new( 0.5, 0.5, 0.5),
}
local BOX_EA = {1,3,5,7,1,2,5,6,1,2,3,4}
local BOX_EB = {2,4,6,8,3,4,7,8,5,6,7,8}

local function _makeBoxData()
    local unitVerts = {}
    for i, v in ipairs(BOX_UNIT_VERTS) do unitVerts[i] = v end
    local edgeA = {table.unpack(BOX_EA)}
    local edgeB = {table.unpack(BOX_EB)}
    local nv = 8; local ne = 12
    local vertEdges    = {}; for i=1,nv do vertEdges[i]={} end
    local vertNeighbors= {}; for i=1,nv do vertNeighbors[i]={} end
    for i=1,ne do
        local a,b = edgeA[i], edgeB[i]
        vertEdges[a][#vertEdges[a]+1]=i; vertEdges[b][#vertEdges[b]+1]=i
        vertNeighbors[a][#vertNeighbors[a]+1]=b
        vertNeighbors[b][#vertNeighbors[b]+1]=a
    end
    return { unitVerts=unitVerts, edgeA=edgeA, edgeB=edgeB,
             vertEdges=vertEdges, vertNeighbors=vertNeighbors }
end

-- ══════════════════════════════════════════
--  VERT SCALING
--
--  EditableMesh positions are in an arbitrary mesh-local space.
--  The range is NOT guaranteed to be -0.5..0.5 — it varies per asset.
--  To fit the wireframe to the part's visible size we:
--    1. Find the actual min/max bounds of the vert cloud
--    2. Compute the cloud's center and span per axis
--    3. Remap each vert so the cloud fills part.Size exactly,
--       centered at the part's local origin (0,0,0)
--
--  Returns a new scaledVerts array (Vector3, part-local space).
--  Safe to call with BOX_UNIT_VERTS too (they're already -0.5..0.5
--  so the remap is a no-op equivalent to * sz).
-- ══════════════════════════════════════════
-- ──────────────────────────────────────────────────────────────────────────
--  _scaleVertsToPartSize
--
--  WireframeHandleAdornment.AddLine coords are in the adornee's OBJECT SPACE:
--    • Relative to the part's CFrame (position + rotation)
--    • NOT pre-multiplied by part.Size
--    • So a vertex at the top-right-front corner of a 4×6×2 part
--      should be passed as Vector3(2, 3, 1) — half-size on each axis.
--
--  EditableMesh vertex positions come out in an arbitrary scale that
--  depends on how the mesh was exported. They might be:
--    • Already normalized  (-0.5 to 0.5)
--    • In stud-scale       (-2 to 2 for a 4-stud-wide mesh)
--    • In any other range
--
--  Strategy:
--    1. Compute the bounding box of the raw verts.
--    2. Find the largest span across any axis.
--    3. Normalize all verts so the largest span maps to [-0.5, 0.5].
--       (Preserves aspect ratio — a tall thin mesh stays tall and thin.)
--    4. Multiply by part.Size to get final object-space coords.
--
--  This means the wireframe exactly fits the part's visual bounds
--  regardless of what scale the mesh artist exported at.
-- ──────────────────────────────────────────────────────────────────────────
local function _scaleVertsToPartSize(unitVerts, partSize)
    local nv = #unitVerts
    if nv == 0 then return {} end

    -- Step 1: bounding box
    local minX, minY, minZ =  math.huge,  math.huge,  math.huge
    local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
    for i = 1, nv do
        local v = unitVerts[i]
        if v.X < minX then minX=v.X end; if v.X > maxX then maxX=v.X end
        if v.Y < minY then minY=v.Y end; if v.Y > maxY then maxY=v.Y end
        if v.Z < minZ then minZ=v.Z end; if v.Z > maxZ then maxZ=v.Z end
    end

    local spanX = maxX - minX
    local spanY = maxY - minY
    local spanZ = maxZ - minZ
    local cx = (minX + maxX) * 0.5
    local cy = (minY + maxY) * 0.5
    local cz = (minZ + maxZ) * 0.5

    -- Step 2: largest span → normalize to [-0.5, 0.5]
    -- Use per-axis normalization so the wireframe fits each axis of the part.
    -- Avoid divide-by-zero for degenerate (flat/line) meshes.
    local nsx = spanX > 0.0001 and (1.0 / spanX) or 0
    local nsy = spanY > 0.0001 and (1.0 / spanY) or 0
    local nsz = spanZ > 0.0001 and (1.0 / spanZ) or 0

    -- Step 3+4: normalize then scale by partSize
    -- normalized coord = (v - center) / span  → range [-0.5, 0.5]
    -- final coord      = normalized * partSize → range [-size/2, size/2]
    local sx = nsx * partSize.X
    local sy = nsy * partSize.Y
    local sz = nsy * partSize.Z  -- intentional: use Y normalizer for Z too?
    -- Actually use per-axis: each axis normalized independently then scaled.
    sz = nsz * partSize.Z

    local scaled = table.create(nv)
    for i = 1, nv do
        local v = unitVerts[i]
        scaled[i] = Vector3.new(
            (v.X - cx) * sx,
            (v.Y - cy) * sy,
            (v.Z - cz) * sz)
    end
    return scaled
end

-- ══════════════════════════════════════════
--  VERTEX ORDER BUILDERS
--  Returns an array of vertex indices sorted
--  by the chosen buildMode.
--
--  "topdown"  — highest Y first (world-up)
--  "bottomup" — lowest Y first
--  "random"   — shuffled
--  "inward"   — BFS from centroid-nearest vert
-- ══════════════════════════════════════════
local function _buildOrder(unitVerts, vertNeighbors, mode, partSize)
    local nv = #unitVerts
    local order = table.create(nv)
    for i = 1, nv do order[i] = i end

    -- Scale verts by part size for world-space Y comparison
    local sz = partSize or Vector3.new(1,1,1)

    if mode == "topdown" then
        table.sort(order, function(a, b)
            return unitVerts[a].Y * sz.Y > unitVerts[b].Y * sz.Y
        end)
    elseif mode == "bottomup" then
        table.sort(order, function(a, b)
            return unitVerts[a].Y * sz.Y < unitVerts[b].Y * sz.Y
        end)
    elseif mode == "inward" then
        -- BFS from vertex closest to mesh centroid (0,0,0 in unit space)
        local bestDist = math.huge
        local seed = 1
        for i = 1, nv do
            local v = unitVerts[i]
            local d = v.X*v.X + v.Y*v.Y + v.Z*v.Z
            if d < bestDist then bestDist=d; seed=i end
        end
        local visited = table.create(nv, false)
        local queue   = { seed }
        visited[seed] = true
        local head = 1
        order = {}
        while head <= #queue do
            local cur = queue[head]; head=head+1
            order[#order+1] = cur
            for _, nb in ipairs(vertNeighbors[cur]) do
                if not visited[nb] then
                    visited[nb]=true
                    queue[#queue+1]=nb
                end
            end
        end
        -- Disconnected verts fallback
        for i=1,nv do
            if not visited[i] then order[#order+1]=i end
        end
    else
        -- random (default)
        for i = nv, 2, -1 do
            local j = math.random(1, i)
            order[i], order[j] = order[j], order[i]
        end
    end
    return order
end

-- ══════════════════════════════════════════
--  EASING HELPERS
-- ══════════════════════════════════════════
local function easeOutCubic(t)
    local u = 1 - t
    return 1 - u*u*u
end

local function easeInCubic(t)
    return t*t*t
end

local function lerpV3(a, b, t)
    return Vector3.new(
        a.X + (b.X - a.X)*t,
        a.Y + (b.Y - a.Y)*t,
        a.Z + (b.Z - a.Z)*t)
end

-- ══════════════════════════════════════════
--  SPAWN EFFECT
--
--  overlay = false (default):
--    1. Hides mesh (Transparency = 1)
--    2. Vertices drift in as dots, edges appear as both ends settle
--    3. Wireframe fades out, mesh fades in
--
--  overlay = true:
--    Part is NEVER touched. Wireframe builds up as a pure
--    visual overlay on top of the fully-visible part.
--    The built WireframeHandleAdornment is passed to onDone
--    so the caller can keep it as a selection indicator.
--
--  Returns { cancel = fn, adornment = wha }
-- ══════════════════════════════════════════

local function _spawnEffectPart(part, cfg, onDone)
    local color       = cfg.color       or Color3.fromRGB(80, 160, 255)
    local thickness   = cfg.thickness   or 1.0
    local alwaysOnTop = cfg.alwaysOnTop or false
    local buildMode   = cfg.buildMode   or "random"
    local vertexDelay = cfg.vertexDelay or nil
    local driftTime   = cfg.driftTime   or 0.3
    local meshFadeTime= cfg.meshFadeTime or 0.4
    local wireFadeTime= cfg.wireFadeTime or 0.3
    local overlay     = cfg.overlay     or false  -- true = never touch part transparency
    local cancelled   = false

    -- Get mesh data
    local data = extractMeshData(part)
    local isMesh = data ~= nil
    if not isMesh then data = _makeBoxData() end

    local unitVerts    = data.unitVerts
    local edgeA        = data.edgeA
    local edgeB        = data.edgeB
    local vertEdges    = data.vertEdges
    local vertNeighbors= data.vertNeighbors
    local nv           = #unitVerts
    local ne           = #edgeA
    local sz           = part.Size

    -- Scale unit verts to part-local space using bounds remap
    local scaledVerts = _scaleVertsToPartSize(unitVerts, sz)

    -- Build trigger order
    local order = _buildOrder(unitVerts, vertNeighbors, buildMode, sz)

    -- Auto vertex delay: spread triggers so last vert triggers ~60% through
    -- total animation, leaving room for drift+fade phases.
    local totalEstimate = driftTime + meshFadeTime + wireFadeTime + 0.2
    if not vertexDelay then
        vertexDelay = math.max(0.008, (totalEstimate * 0.6) / nv)
    end

    -- Clamp to performance budget: never trigger >4 verts per frame
    -- If vertexDelay < frame budget, burst-batch them.
    local vertsPerTick = 1
    if vertexDelay < 0.016 then
        vertsPerTick = math.ceil(0.016 / vertexDelay)
        vertexDelay  = 0.016
    end
    -- Hard cap: never more than 6 per tick (perf safety)
    vertsPerTick = math.min(vertsPerTick, 6)

    -- Hide the real part (only in non-overlay mode)
    local origTransparency = part.Transparency
    if not overlay then
        part.Transparency = 1
    end

    -- Create empty wireframe adornment (lines added as verts settle)
    local wha = Instance.new("WireframeHandleAdornment")
    wha.Adornee     = part
    wha.Color3      = color
    wha.Thickness   = thickness
    wha.AlwaysOnTop = alwaysOnTop
    wha.Transparency= 0
    wha.ZIndex      = 2
    wha.Visible     = true
    wha.Parent      = part

    -- Per-vertex state
    -- settled[i] = true once vertex i has reached its final position
    local settled     = table.create(nv, false)
    -- edgeAdded[i] = true once edge i line has been added to wha
    local edgeAdded   = table.create(ne, false)

    -- Active drifting vertex list
    -- Each entry: { vi, dotAdorn, startPos, targetPos, elapsed, totalTime }
    local active      = {}
    local activeCount = 0

    -- Pre-generate random drift offsets for each vertex
    -- Direction is a random unit vector, magnitude 0.2–1.0 studs
    local driftOffsets = table.create(nv)
    for i = 1, nv do
        local dx = (math.random()-0.5)*2
        local dy = (math.random()-0.5)*2
        local dz = (math.random()-0.5)*2
        local len = math.sqrt(dx*dx+dy*dy+dz*dz)
        if len < 0.001 then len = 1 end
        local mag = 0.2 + math.random() * 0.8  -- 0.2 to 1.0 studs
        driftOffsets[i] = Vector3.new(
            dx/len * mag,
            dy/len * mag,
            dz/len * mag)
    end

    local triggerIdx = 1   -- pointer into order[]
    local elapsed    = 0
    local settledCount = 0

    local heartConn
    heartConn = RunService.Heartbeat:Connect(function(dt)
        if cancelled then heartConn:Disconnect(); return end
        elapsed = elapsed + dt

        -- Trigger new vertices this tick
        local triggered = 0
        while triggerIdx <= nv and triggered < vertsPerTick do
            local trigTime = (triggerIdx - 1) * vertexDelay
            if elapsed < trigTime then break end

            local vi = order[triggerIdx]
            triggerIdx = triggerIdx + 1
            triggered  = triggered + 1

            local target = scaledVerts[vi]
            local start  = target + driftOffsets[vi]

            -- Create dot adornment
            local dot = Instance.new("SphereHandleAdornment")
            dot.Adornee    = part
            dot.Color3     = color
            dot.Radius     = 0.06
            dot.AlwaysOnTop= alwaysOnTop
            dot.Transparency = 0.1
            dot.ZIndex     = 3
            dot.CFrame     = CFrame.new(start)
            dot.Visible    = true
            dot.Parent     = part

            activeCount = activeCount + 1
            active[activeCount] = {
                vi      = vi,
                dot     = dot,
                start   = start,
                target  = target,
                elapsed = 0,
            }
        end

        -- Update drifting vertices
        local writeIdx = 0
        for i = 1, activeCount do
            local s = active[i]
            s.elapsed = s.elapsed + dt
            local t   = math.min(s.elapsed / driftTime, 1)
            local et  = easeOutCubic(t)

            local pos = lerpV3(s.start, s.target, et)
            s.dot.CFrame = CFrame.new(pos)

            -- Fade dot out as it approaches (~last 30% of drift)
            local alpha = t > 0.7 and (1 - (t-0.7)/0.3) or 1
            s.dot.Transparency = 1 - alpha

            if t >= 1 then
                -- Settled
                settled[s.vi] = true
                settledCount  = settledCount + 1
                s.dot.Visible = false
                pcall(function() s.dot:Destroy() end)

                -- Check all edges touching this vertex
                for _, ei in ipairs(vertEdges[s.vi]) do
                    if not edgeAdded[ei] then
                        local oa = edgeA[ei]
                        local ob = edgeB[ei]
                        if settled[oa] and settled[ob] then
                            edgeAdded[ei] = true
                            wha:AddLine(scaledVerts[oa], scaledVerts[ob])
                        end
                    end
                end
            else
                writeIdx = writeIdx + 1
                active[writeIdx] = s
            end
        end
        activeCount = writeIdx

        -- All vertices settled — completion
        if settledCount >= nv and triggerIdx > nv and activeCount == 0 then
            heartConn:Disconnect()

            if overlay then
                -- Overlay mode: wireframe stays up as selection indicator.
                -- Pass the adornment to onDone so caller can own/destroy it.
                if not cancelled and onDone then pcall(onDone, wha) end
            else
                -- Full mode: wireframe fades out, mesh fades in
                local wfSteps   = math.max(1, math.ceil(wireFadeTime / 0.016))
                local meshSteps = math.max(1, math.ceil(meshFadeTime / 0.016))

                task.spawn(function()
                    for i = 1, wfSteps do
                        if cancelled then return end
                        wha.Transparency = i / wfSteps
                        task.wait(wireFadeTime / wfSteps)
                    end
                    wha.Visible = false
                    pcall(function() wha:Destroy() end)
                end)

                task.spawn(function()
                    task.wait(wireFadeTime * 0.4)
                    for i = 1, meshSteps do
                        if cancelled then return end
                        part.Transparency = 1 - (i / meshSteps)
                        task.wait(meshFadeTime / meshSteps)
                    end
                    part.Transparency = origTransparency
                    if not cancelled and onDone then pcall(onDone, wha) end
                end)
            end
        end
    end)

    return {
        adornment = wha,
        cancel = function()
            cancelled = true
            pcall(function() heartConn:Disconnect() end)
            for i = 1, activeCount do
                pcall(function() active[i].dot:Destroy() end)
            end
            pcall(function() wha:Destroy() end)
            if not overlay then
                part.Transparency = origTransparency
            end
        end,
    }
end

-- ══════════════════════════════════════════
--  DELETE EFFECT
--
--  Reverse of spawn:
--  1. Wireframe re-appears (fades in)
--  2. Mesh fades out
--  3. Vertex dots appear at settled positions,
--     then drift away and dissolve
--  4. Edges disappear as their endpoint dots leave
--  5. onDone called (caller should Destroy/hide part)
-- ══════════════════════════════════════════
local function _deleteEffectPart(part, cfg, onDone)
    local color       = cfg.color       or Color3.fromRGB(80, 160, 255)
    local thickness   = cfg.thickness   or 1.0
    local alwaysOnTop = cfg.alwaysOnTop or false
    local buildMode   = cfg.buildMode   or "random"
    local vertexDelay = cfg.vertexDelay or nil
    local driftTime   = cfg.driftTime   or 0.3
    local meshFadeTime= cfg.meshFadeTime or 0.4
    local wireFadeTime= cfg.wireFadeTime or 0.3
    local overlay     = cfg.overlay     or false  -- true = never touch part transparency
    local cancelled   = false

    local data = extractMeshData(part)
    local isMesh = data ~= nil
    if not isMesh then data = _makeBoxData() end

    local unitVerts    = data.unitVerts
    local edgeA        = data.edgeA
    local edgeB        = data.edgeB
    local vertEdges    = data.vertEdges
    local vertNeighbors= data.vertNeighbors
    local nv           = #unitVerts
    local ne           = #edgeA
    local sz           = part.Size

    local scaledVerts = _scaleVertsToPartSize(unitVerts, sz)

    -- Reverse order: last to settle is first to leave
    local spawnOrder = _buildOrder(unitVerts, vertNeighbors, buildMode, sz)
    -- Reverse it for dissolve
    local order = table.create(nv)
    for i = 1, nv do order[i] = spawnOrder[nv - i + 1] end

    local totalEstimate = driftTime + meshFadeTime + wireFadeTime + 0.2
    if not vertexDelay then
        vertexDelay = math.max(0.008, (totalEstimate * 0.6) / nv)
    end
    local vertsPerTick = 1
    if vertexDelay < 0.016 then
        vertsPerTick = math.ceil(0.016 / vertexDelay)
        vertexDelay  = 0.016
    end
    vertsPerTick = math.min(vertsPerTick, 6)

    local origTransparency = part.Transparency

    -- Build full wireframe immediately (all edges)
    local wha = Instance.new("WireframeHandleAdornment")
    wha.Adornee     = part
    wha.Color3      = color
    wha.Thickness   = thickness
    wha.AlwaysOnTop = alwaysOnTop
    wha.Transparency= 1  -- starts invisible
    wha.ZIndex      = 2
    wha.Visible     = true
    wha.Parent      = part

    for i = 1, ne do
        wha:AddLine(scaledVerts[edgeA[i]], scaledVerts[edgeB[i]])
    end

    -- Track which edges are still "visible" (not yet broken by a departing vert)
    -- We'll hide the whole WHA and re-build a partial one as verts depart.
    -- For simplicity: we keep a second adornment for "remaining" edges and
    -- swap to it after the full one fades. This avoids per-line remove (not in API).
    -- Instead: use a "remaining" table + rebuild-on-change approach.
    -- Since AddLine can't be removed, we'll manage this by destroying/rebuilding
    -- the WHA each time an edge should disappear — but only when a vert departs.
    -- On dense meshes this would be expensive, so we batch: rebuild every N departures.

    -- Actually simpler: use one WHA for the pre-built full wireframe (fades to invisible),
    -- then a second WHA built on-the-fly for remaining edges as verts are "active" (departing).
    -- Edges are removed (not added) when both endpoints have departed.

    local edgeGone   = table.create(ne, false)  -- edge has been cleared
    local vertGone   = table.create(nv, false)  -- vert has departed (started drifting)
    local vertSettled= table.create(nv, true)   -- all start settled

    -- Second WHA: remaining-edge adornment, rebuilt when edges are removed
    -- We use a "dirty" flag and rebuild at most once every 3 departures.
    local remainWHA = nil
    local dirtyEdge = false
    local departCount = 0
    local REBUILD_EVERY = 3

    local function rebuildRemainWHA()
        if remainWHA then pcall(function() remainWHA:Destroy() end) end
        local rw = Instance.new("WireframeHandleAdornment")
        rw.Adornee     = part
        rw.Color3      = color
        rw.Thickness   = thickness
        rw.AlwaysOnTop = alwaysOnTop
        rw.Transparency= 0
        rw.ZIndex      = 2
        rw.Visible     = true
        rw.Parent      = part
        for i = 1, ne do
            if not edgeGone[i] then
                rw:AddLine(scaledVerts[edgeA[i]], scaledVerts[edgeB[i]])
            end
        end
        remainWHA = rw
    end

    -- Pre-generate drift offsets (same logic as spawn but reversed direction)
    local driftOffsets = table.create(nv)
    for i = 1, nv do
        local dx = (math.random()-0.5)*2
        local dy = (math.random()-0.5)*2
        local dz = (math.random()-0.5)*2
        local len = math.sqrt(dx*dx+dy*dy+dz*dz)
        if len < 0.001 then len = 1 end
        local mag = 0.2 + math.random() * 0.8
        driftOffsets[i] = Vector3.new(dx/len*mag, dy/len*mag, dz/len*mag)
    end

    local active      = {}
    local activeCount = 0
    local triggerIdx  = 1
    local elapsed     = 0
    local goneCount   = 0

    -- Phase 1: fade in wireframe. In non-overlay mode also fade out mesh.
    task.spawn(function()
        -- Wireframe fade in
        local steps = math.max(1, math.ceil(wireFadeTime / 0.016))
        for i = 1, steps do
            if cancelled then return end
            wha.Transparency = 1 - (i / steps)
            task.wait(wireFadeTime / steps)
        end
        wha.Transparency = 0
    end)

    if not overlay then
        task.spawn(function()
            -- Mesh fade out (slight overlap)
            task.wait(wireFadeTime * 0.3)
            local steps = math.max(1, math.ceil(meshFadeTime / 0.016))
            for i = 1, steps do
                if cancelled then return end
                part.Transparency = origTransparency + (1 - origTransparency) * (i / steps)
                task.wait(meshFadeTime / steps)
            end
            part.Transparency = 1

            -- Now build the remain WHA and hide the full one
            if not cancelled then
                rebuildRemainWHA()
                wha.Visible = false
            end
        end)
    else
        -- Overlay: no mesh fade. Just swap to remainWHA after wire fades in.
        task.spawn(function()
            task.wait(wireFadeTime + 0.02)
            if not cancelled then
                rebuildRemainWHA()
                wha.Visible = false
            end
        end)
    end

    -- Phase 2: vertices depart.
    -- In overlay mode we can start immediately after wire fades in.
    -- In full mode we wait for mesh to finish fading too.
    local departDelay = overlay
        and (wireFadeTime + 0.05)
        or  (wireFadeTime * 0.3 + meshFadeTime + 0.05)

    task.delay(departDelay, function()
        if cancelled then return end

        local heartConn
        heartConn = RunService.Heartbeat:Connect(function(dt)
            if cancelled then heartConn:Disconnect(); return end
            elapsed = elapsed + dt

            -- Trigger vertices to depart
            local triggered = 0
            while triggerIdx <= nv and triggered < vertsPerTick do
                local trigTime = (triggerIdx - 1) * vertexDelay
                if elapsed < trigTime then break end

                local vi = order[triggerIdx]
                triggerIdx = triggerIdx + 1
                triggered  = triggered + 1
                vertGone[vi] = true

                local startPos = scaledVerts[vi]
                local endPos   = startPos + driftOffsets[vi]

                -- Create dot that drifts away
                local dot = Instance.new("SphereHandleAdornment")
                dot.Adornee     = part
                dot.Color3      = color
                dot.Radius      = 0.06
                dot.AlwaysOnTop = alwaysOnTop
                dot.Transparency= 0.1
                dot.ZIndex      = 3
                dot.CFrame      = CFrame.new(startPos)
                dot.Visible     = true
                dot.Parent      = part

                activeCount = activeCount + 1
                active[activeCount] = {
                    vi      = vi,
                    dot     = dot,
                    start   = startPos,
                    target  = endPos,
                    elapsed = 0,
                }

                -- Mark edges touching this vert as gone if both endpoints departed
                for _, ei in ipairs(vertEdges[vi]) do
                    if not edgeGone[ei] then
                        local oa = edgeA[ei]; local ob = edgeB[ei]
                        if vertGone[oa] and vertGone[ob] then
                            edgeGone[ei] = true
                            departCount  = departCount + 1
                            if departCount % REBUILD_EVERY == 0 then
                                rebuildRemainWHA()
                            end
                        end
                    end
                end
            end

            -- Update drifting dots
            local writeIdx = 0
            for i = 1, activeCount do
                local s = active[i]
                s.elapsed = s.elapsed + dt
                local t   = math.min(s.elapsed / driftTime, 1)
                local et  = easeInCubic(t)  -- accelerate away

                local pos = lerpV3(s.start, s.target, et)
                s.dot.CFrame = CFrame.new(pos)

                -- Fade in during first 30%, then fade out
                local alpha
                if t < 0.3 then
                    alpha = t / 0.3
                else
                    alpha = 1 - (t - 0.3) / 0.7
                end
                s.dot.Transparency = 1 - math.max(0, alpha)

                if t >= 1 then
                    goneCount = goneCount + 1
                    s.dot.Visible = false
                    pcall(function() s.dot:Destroy() end)
                else
                    writeIdx = writeIdx + 1
                    active[writeIdx] = s
                end
            end
            activeCount = writeIdx

            -- All done
            if triggerIdx > nv and activeCount == 0 then
                heartConn:Disconnect()
                pcall(function() wha:Destroy() end)
                if remainWHA then pcall(function() remainWHA:Destroy() end) end
                if not cancelled and onDone then pcall(onDone) end
            end
        end)
    end)

    return {
        cancel = function()
            cancelled = true
            for i = 1, activeCount do
                pcall(function() active[i].dot:Destroy() end)
            end
            pcall(function() wha:Destroy() end)
            if remainWHA then pcall(function() remainWHA:Destroy() end) end
            if not overlay then
                part.Transparency = origTransparency
            end
        end,
    }
end

-- ══════════════════════════════════════════
--  PUBLIC SPAWN / DELETE WRAPPERS
--  Works on BasePart or Model
-- ══════════════════════════════════════════
local WF = {}

function WF.spawnEffect(target, cfg)
    cfg = cfg or {}
    local handles   = {}
    local cancelled = false
    local stagger   = cfg.stagger or 0.04
    local completed = 0

    local parts = {}
    if target:IsA("BasePart") then
        parts[1] = target
    elseif target:IsA("Model") then
        local excl = { HumanoidRootPart = true }
        for _, d in ipairs(target:GetDescendants()) do
            if d:IsA("BasePart") and not excl[d.Name] then
                parts[#parts+1] = d
            end
        end
    end

    if #parts == 0 then
        warn("[WF] spawnEffect: no parts found")
        return { cancel = function() end }
    end

    local masterThread = task.spawn(function()
        for i, part in ipairs(parts) do
            if cancelled then break end
            local h = _spawnEffectPart(part, cfg, function(wha)
                completed = completed + 1
                if completed >= #parts and cfg.onComplete then
                    -- Pass the built adornment to the caller in overlay mode
                    -- so they can swap it for a WFObj or destroy it.
                    pcall(cfg.onComplete, wha)
                end
            end)
            handles[#handles+1] = h
            if i < #parts then task.wait(stagger) end
        end
    end)

    return {
        cancel = function()
            cancelled = true
            pcall(task.cancel, masterThread)
            for _, h in ipairs(handles) do h.cancel() end
        end,
    }
end

function WF.deleteEffect(target, cfg)
    cfg = cfg or {}
    local handles   = {}
    local cancelled = false
    local stagger   = cfg.stagger or 0.04
    local completed = 0

    local parts = {}
    if target:IsA("BasePart") then
        parts[1] = target
    elseif target:IsA("Model") then
        local excl = { HumanoidRootPart = true }
        for _, d in ipairs(target:GetDescendants()) do
            if d:IsA("BasePart") and not excl[d.Name] then
                parts[#parts+1] = d
            end
        end
    end

    if #parts == 0 then
        warn("[WF] deleteEffect: no parts found")
        return { cancel = function() end }
    end

    local masterThread = task.spawn(function()
        for i, part in ipairs(parts) do
            if cancelled then break end
            local h = _deleteEffectPart(part, cfg, function()
                completed = completed + 1
                if completed >= #parts and cfg.onComplete then
                    pcall(cfg.onComplete)
                end
            end)
            handles[#handles+1] = h
            if i < #parts then task.wait(stagger) end
        end
    end)

    return {
        cancel = function()
            cancelled = true
            pcall(task.cancel, masterThread)
            for _, h in ipairs(handles) do h.cancel() end
        end,
    }
end

-- ══════════════════════════════════════════
--  PART DESCRIPTOR (static wireframe)
-- ══════════════════════════════════════════
local Desc = {}
Desc.__index = Desc

function Desc.new(part, color, thickness, alwaysOnTop, transparency)
    local self        = setmetatable({}, Desc)
    self.part         = part
    self.color        = color
    self.thickness    = thickness
    self.alwaysOnTop  = alwaysOnTop  or false
    self.transparency = transparency or 0
    self.isMesh       = false
    self.unitVerts    = nil
    self.edgeA        = nil
    self.edgeB        = nil
    self.adornment    = nil

    local data = extractMeshData(part)
    if data then
        self.isMesh    = true
        self.unitVerts = data.unitVerts
        self.edgeA     = data.edgeA
        self.edgeB     = data.edgeB
    end
    self:_buildRenderer()
    return self
end

function Desc:_buildRenderer()
    local nEdges = self.isMesh and #self.edgeA or 12
    local verts  = self.isMesh and self.unitVerts or BOX_UNIT_VERTS
    local ea     = self.isMesh and self.edgeA     or BOX_EA
    local eb     = self.isMesh and self.edgeB     or BOX_EB

    local wha = Instance.new("WireframeHandleAdornment")
    wha.Adornee     = self.part
    wha.Color3      = self.color
    wha.Thickness   = self.thickness
    wha.AlwaysOnTop = self.alwaysOnTop
    wha.Transparency= self.transparency
    wha.ZIndex      = 1
    wha.Visible     = true
    wha.Parent      = self.part

    if self.isMesh then
        local scaled = _scaleVertsToPartSize(verts, self.part.Size)
        for i = 1, nEdges do wha:AddLine(scaled[ea[i]], scaled[eb[i]]) end
    else
        local sz = self.part.Size
        for i = 1, nEdges do
            local v0 = verts[ea[i]]; local v1 = verts[eb[i]]
            wha:AddLine(
                Vector3.new(v0.X*sz.X, v0.Y*sz.Y, v0.Z*sz.Z),
                Vector3.new(v1.X*sz.X, v1.Y*sz.Y, v1.Z*sz.Z))
        end
    end
    self.adornment = wha
end

function Desc:setVisible(v)    if self.adornment then self.adornment.Visible = v end end
function Desc:setColor(c)      self.color=c; if self.adornment then self.adornment.Color3=c end end
function Desc:setThickness(t)  self.thickness=t; if self.adornment then self.adornment.Thickness=t end end
function Desc:setAlwaysOnTop(v) self.alwaysOnTop=v; if self.adornment then self.adornment.AlwaysOnTop=v end end
function Desc:setTransparency(t) self.transparency=t; if self.adornment then self.adornment.Transparency=t end end
function Desc:destroy()
    if self.adornment then
        pcall(function() self.adornment:Destroy() end)
        self.adornment = nil
    end
end

-- ══════════════════════════════════════════
--  WIREFRAME OBJECT (static)
-- ══════════════════════════════════════════
local WFObj = {}
WFObj.__index = WFObj

local function _makeWFObj(parts, color, thickness, alwaysOnTop, transparency)
    local self         = setmetatable({}, WFObj)
    self._enabled      = false
    self._destroyed    = false
    self._color        = color        or Color3.fromRGB(80, 160, 255)
    self._thickness    = thickness    or 1.0
    self._alwaysOnTop  = alwaysOnTop  or false
    self._transparency = transparency or 0
    self._descs        = {}
    self._pulseThread  = nil

    for _, part in ipairs(parts) do
        if part:IsA("BasePart") then
            self._descs[#self._descs+1] =
                Desc.new(part, self._color, self._thickness, self._alwaysOnTop, self._transparency)
        end
    end
    return self
end

function WFObj:Enable()
    if self._destroyed then return self end
    self._enabled = true
    for i=1,#self._descs do self._descs[i]:setVisible(true) end
    return self
end

function WFObj:Disable()
    self._enabled = false
    for i=1,#self._descs do self._descs[i]:setVisible(false) end
    return self
end

function WFObj:SetColor(c)
    self._color = c
    for i=1,#self._descs do self._descs[i]:setColor(c) end
    return self
end

function WFObj:SetThickness(t)
    self._thickness = t
    for i=1,#self._descs do self._descs[i]:setThickness(t) end
    return self
end

function WFObj:SetAlwaysOnTop(v)
    self._alwaysOnTop = v
    for i=1,#self._descs do self._descs[i]:setAlwaysOnTop(v) end
    return self
end

function WFObj:SetTransparency(t)
    self._transparency = t
    for i=1,#self._descs do self._descs[i]:setTransparency(t) end
    return self
end

function WFObj:Pulse(duration, pulseColor)
    if self._pulseThread then pcall(task.cancel, self._pulseThread) end
    local orig = self._color
    pulseColor = pulseColor or Color3.fromRGB(255,255,255)
    duration   = duration   or 0.4
    self._pulseThread = task.spawn(function()
        self:SetColor(pulseColor)
        task.wait(duration * 0.5)
        local steps = 12
        for i = 1, steps do
            local t = i/steps
            self:SetColor(Color3.new(
                pulseColor.R + (orig.R-pulseColor.R)*t,
                pulseColor.G + (orig.G-pulseColor.G)*t,
                pulseColor.B + (orig.B-pulseColor.B)*t))
            task.wait(duration * 0.5 / steps)
        end
        self:SetColor(orig)
        self._pulseThread = nil
    end)
    return self
end

function WFObj:GetInfo()
    local t = {}
    for i = 1, #self._descs do
        local d = self._descs[i]
        t[i] = {
            part    = d.part.Name,
            type    = d.isMesh and "mesh" or "box",
            edges   = d.isMesh and #d.edgeA or 12,
            backend = "gpu",
        }
    end
    return t
end

function WFObj:Destroy()
    if self._destroyed then return end
    self._destroyed = true
    self._enabled   = false
    if self._pulseThread then pcall(task.cancel, self._pulseThread) end
    for i = 1, #self._descs do self._descs[i]:destroy() end
    self._descs = {}
    _unregister(self)
end

-- ══════════════════════════════════════════
--  PUBLIC FACTORY (static wireframes)
-- ══════════════════════════════════════════
function WF.new(part, color, thickness, alwaysOnTop, transparency)
    assert(part and part:IsA("BasePart"), "[WF] .new() requires a BasePart")
    local obj = _makeWFObj({part}, color, thickness, alwaysOnTop, transparency)
    _register(obj)
    return obj
end

function WF.newModel(model, color, thickness, excludeNames, alwaysOnTop, transparency)
    assert(model, "[WF] .newModel() requires a Model")
    local excl = {}
    for _, n in ipairs(excludeNames or {}) do excl[n]=true end
    local parts = {}
    for _, d in ipairs(model:GetDescendants()) do
        if d:IsA("BasePart") and not excl[d.Name] then parts[#parts+1]=d end
    end
    if #parts == 0 then warn("[WF] newModel: no parts found in "..model.Name) end
    local obj = _makeWFObj(parts, color, thickness, alwaysOnTop, transparency)
    _register(obj)
    return obj
end

function WF.newCharacter(model, color, thickness, alwaysOnTop, transparency)
    return WF.newModel(model, color, thickness, {"HumanoidRootPart"}, alwaysOnTop, transparency)
end

function WF.newBatch(parts, color, thickness, alwaysOnTop, transparency)
    local obj = _makeWFObj(parts, color, thickness, alwaysOnTop, transparency)
    _register(obj)
    return obj
end

function WF.destroyAll()
    for _, obj in ipairs(table.clone(_registry)) do obj:Destroy() end
end

function WF.getInstanceCount() return #_registry end
function WF.clearMeshCache()   _meshCache = {} end

-- ══════════════════════════════════════════
--  LEGACY: buildAnimate
-- ══════════════════════════════════════════
local function _buildAnimatePart(part, cfg, onDone)
    local color        = cfg.color        or Color3.fromRGB(80, 160, 255)
    local thickness    = cfg.thickness    or 1.0
    local alwaysOnTop  = cfg.alwaysOnTop  or false
    local transparency = cfg.transparency or 0
    local duration     = cfg.duration     or 1.5

    local data = extractMeshData(part)
    local isMesh = data ~= nil and data ~= false
    local unitVerts, edgeA, edgeB, vertEdges

    if isMesh then
        unitVerts = data.unitVerts; edgeA=data.edgeA; edgeB=data.edgeB; vertEdges=data.vertEdges
    else
        unitVerts = BOX_UNIT_VERTS
        edgeA=BOX_EA; edgeB=BOX_EB
        vertEdges = {}
        for i=1,8 do vertEdges[i]={} end
        for i=1,12 do
            vertEdges[BOX_EA[i]][#vertEdges[BOX_EA[i]]+1]=i
            vertEdges[BOX_EB[i]][#vertEdges[BOX_EB[i]]+1]=i
        end
    end

    -- Bounds-aware scaling (fixes accessories / non-standard mesh scales)
    local scaledVerts = _scaleVertsToPartSize(unitVerts, part.Size)
    local nVerts = #scaledVerts

    local wha = Instance.new("WireframeHandleAdornment")
    wha.Adornee=part; wha.Color3=color; wha.Thickness=thickness
    wha.AlwaysOnTop=alwaysOnTop; wha.Transparency=transparency
    wha.ZIndex=2; wha.Visible=true; wha.Parent=part

    local order = table.create(nVerts)
    for i=1,nVerts do order[i]=i end
    for i=nVerts,2,-1 do local j=math.random(1,i); order[i],order[j]=order[j],order[i] end

    local placed = table.create(nVerts, false)
    local cancelled = false
    local interval = duration/nVerts
    local vertsPerTick = 1
    if interval < 0.016 then vertsPerTick=math.ceil(0.016/interval); interval=0.016 end

    local thread = task.spawn(function()
        local i = 1
        while i <= nVerts and not cancelled do
            for b=1,vertsPerTick do
                if i>nVerts then break end
                local vi = order[i]; placed[vi]=true
                for _, ei in ipairs(vertEdges[vi]) do
                    local other = edgeA[ei]==vi and edgeB[ei] or edgeA[ei]
                    if placed[other] then
                        wha:AddLine(scaledVerts[edgeA[ei]], scaledVerts[edgeB[ei]])
                    end
                end
                i=i+1
            end
            if not part or not part.Parent then break end
            task.wait(interval)
        end
        if not cancelled and onDone then pcall(onDone, wha) end
    end)

    return {
        adornment=wha,
        cancel=function()
            cancelled=true; pcall(task.cancel,thread); pcall(function() wha:Destroy() end)
        end,
        destroyAdornment=function() pcall(function() wha:Destroy() end) end,
    }
end

function WF.buildAnimate(target, cfg)
    cfg = cfg or {}
    local handles={};local cancelled=false;local stagger=cfg.stagger or 0.05
    local parts={}
    if target:IsA("BasePart") then parts[1]=target
    elseif target:IsA("Model") then
        local excl={HumanoidRootPart=true}
        for _,d in ipairs(target:GetDescendants()) do
            if d:IsA("BasePart") and not excl[d.Name] then parts[#parts+1]=d end
        end
    end
    if #parts==0 then warn("[WF] buildAnimate: no parts found"); return {cancel=function()end} end
    local partDuration=(cfg.duration or 1.5); local completed=0
    local masterThread=task.spawn(function()
        for i,part in ipairs(parts) do
            if cancelled then break end
            local partCfg={}; for k,v in pairs(cfg) do partCfg[k]=v end
            partCfg.duration=partDuration-((i-1)*stagger)
            if partCfg.duration<0.2 then partCfg.duration=0.2 end
            local h=_buildAnimatePart(part,partCfg,function(wha)
                completed=completed+1
                if completed>=#parts then
                    if cfg.onComplete then pcall(cfg.onComplete) end
                    task.delay(0.5,function()
                        for _,bh in ipairs(handles) do if bh.destroyAdornment then bh.destroyAdornment() end end
                    end)
                end
            end)
            handles[#handles+1]=h
            if i<#parts then task.wait(stagger) end
        end
    end)
    return {cancel=function()
        cancelled=true; pcall(task.cancel,masterThread)
        for _,h in ipairs(handles) do h.cancel() end
    end}
end

-- ══════════════════════════════════════════
--  LEGACY: faceReveal
-- ══════════════════════════════════════════
local function _faceRevealPart(part, cfg, onDone)
    if not part:IsA("MeshPart") then if onDone then onDone() end; return {cancel=function()end} end
    local duration=cfg.duration or 2.0; local flickerTime=cfg.flickerTime or 0.25
    local fadeTime=cfg.fadeTime or 0.4; local useWave=cfg.wave or false
    local tintColor=cfg.color or nil; local cancelled=false
    local em
    if not pcall(function() em=AssetService:CreateEditableMeshAsync(Content.fromUri(part.MeshId)) end) or not em then
        if onDone then onDone() end; return {cancel=function()end}
    end
    local faceIds=em:GetFaces(); local nFaces=#faceIds
    if nFaces==0 then em:Destroy(); if onDone then onDone() end; return {cancel=function()end} end
    local faceColorIds={}
    for _,fid in ipairs(faceIds) do faceColorIds[fid]=em:GetFaceColors(fid) end
    local allColors=em:GetColors()
    for _,cid in ipairs(allColors) do em:SetColorAlpha(cid,1) end
    if tintColor then for _,cid in ipairs(allColors) do em:SetColor(cid,tintColor) end end
    pcall(function()
        local linked=AssetService:CreateMeshPartAsync(Content.fromObject(em))
        part:ApplyMesh(linked)
    end)
    local revealOrder=table.create(nFaces)
    if useWave then
        local seedFace=cfg.seedFace or faceIds[math.random(1,nFaces)]
        local visited={}; local queue={seedFace}; visited[seedFace]=true; local head=1
        while head<=#queue and #revealOrder<nFaces do
            local current=queue[head]; head=head+1; revealOrder[#revealOrder+1]=current
            local adj=em:GetAdjacentFaces(current)
            if adj then for _,adjFid in ipairs(adj) do if not visited[adjFid] then visited[adjFid]=true; queue[#queue+1]=adjFid end end end
        end
        for _,fid in ipairs(faceIds) do if not visited[fid] then revealOrder[#revealOrder+1]=fid end end
    else
        for _,fid in ipairs(faceIds) do revealOrder[#revealOrder+1]=fid end
        for i=nFaces,2,-1 do local j=math.random(1,i); revealOrder[i],revealOrder[j]=revealOrder[j],revealOrder[i] end
    end
    local activeSet={}; local activeCount=0
    local triggerAt=table.create(nFaces); local triggerStep=duration/nFaces
    for i=1,nFaces do triggerAt[i]=(i-1)*triggerStep end
    local nextTriggerIdx=1; local elapsed=0; local idleCount=0
    local heartConn
    heartConn=RunService.Heartbeat:Connect(function(dt)
        if cancelled then heartConn:Disconnect(); return end
        elapsed=elapsed+dt
        while nextTriggerIdx<=nFaces and elapsed>=triggerAt[nextTriggerIdx] do
            local fid=revealOrder[nextTriggerIdx]; nextTriggerIdx=nextTriggerIdx+1
            activeCount=activeCount+1
            activeSet[activeCount]={fid=fid,mode="flicker",alpha=1,flickerTimer=flickerTime}
        end
        local writeIdx=0
        for i=1,activeCount do
            local s=activeSet[i]; local fid=s.fid; local cols=faceColorIds[fid]
            if s.mode=="flicker" then
                s.flickerTimer=s.flickerTimer-dt
                local a=math.random()>0.5 and 1 or 0
                if cols then for _,cid in ipairs(cols) do em:SetColorAlpha(cid,a) end end
                if s.flickerTimer<=0 then s.mode="fade"; s.alpha=1 end
                writeIdx=writeIdx+1; activeSet[writeIdx]=s
            elseif s.mode=="fade" then
                s.alpha=s.alpha-dt/fadeTime
                if s.alpha<=0 then
                    s.alpha=0
                    if cols then for _,cid in ipairs(cols) do em:SetColorAlpha(cid,0) end end
                    idleCount=idleCount+1
                else
                    if cols then for _,cid in ipairs(cols) do em:SetColorAlpha(cid,s.alpha) end end
                    writeIdx=writeIdx+1; activeSet[writeIdx]=s
                end
            end
        end
        activeCount=writeIdx
        if nextTriggerIdx>nFaces and activeCount==0 then
            heartConn:Disconnect()
            pcall(function()
                local origPart=AssetService:CreateMeshPartAsync(Content.fromUri(part.MeshId))
                part:ApplyMesh(origPart)
            end)
            em:Destroy()
            if onDone then pcall(onDone) end
        end
    end)
    return {cancel=function()
        cancelled=true; pcall(function() heartConn:Disconnect() end)
        pcall(function() local op=AssetService:CreateMeshPartAsync(Content.fromUri(part.MeshId)); part:ApplyMesh(op) end)
        pcall(function() em:Destroy() end)
    end}
end

function WF.faceReveal(target, cfg)
    cfg=cfg or {}; local handles={}; local cancelled=false
    local stagger=cfg.stagger or 0.06; local completed=0
    local parts={}
    if target:IsA("MeshPart") then parts[1]=target
    elseif target:IsA("Model") then
        local excl={HumanoidRootPart=true}
        for _,d in ipairs(target:GetDescendants()) do
            if d:IsA("MeshPart") and not excl[d.Name] then parts[#parts+1]=d end
        end
    end
    if #parts==0 then warn("[WF] faceReveal: no MeshParts found"); return {cancel=function()end} end
    local masterThread=task.spawn(function()
        for i,part in ipairs(parts) do
            if cancelled then break end
            local partCfg={}; for k,v in pairs(cfg) do partCfg[k]=v end
            local h=_faceRevealPart(part,partCfg,function()
                completed=completed+1
                if completed>=#parts and cfg.onComplete then pcall(cfg.onComplete) end
            end)
            handles[#handles+1]=h
            if i<#parts then task.wait(stagger) end
        end
    end)
    return {cancel=function()
        cancelled=true; pcall(task.cancel,masterThread)
        for _,h in ipairs(handles) do h.cancel() end
    end}
end

WF.VERSION = "6.1.0"
WF.AUTHOR  = "first known runtime mesh wireframe for Roblox"

return WF