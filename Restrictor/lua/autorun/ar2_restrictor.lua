
if not SERVER then return end

local ServerPrefix = "Excelsus"

-- Config
CreateConVar("ar2_altfire_limit", "2", FCVAR_ARCHIVE + FCVAR_REPLICATED, "Max AR2 alt-fire ammo allowed. -1 = unlimited. 0 = disable alt-fire.")
CreateConVar("ar2_altfire_pickup_cooldown", "5", FCVAR_ARCHIVE + FCVAR_REPLICATED, "Cooldown (seconds) between picking up item_ammo_ar2_altfire.")

local ALT_AMMO_TYPE = "AR2AltFire"
local ALT_AMMO_ENTITY_CLASS = "item_ammo_ar2_altfire"
local lastPickup = {}

local function PlayerID(ply) return ply:SteamID64() or tostring(ply:EntIndex()) end

local function EnforceAR2AltAmmo(ply)
    if not IsValid(ply) or not ply:IsPlayer() then return end
    local limit = GetConVar("ar2_altfire_limit"):GetInt()
    if limit < 0 then return end
    local current = ply:GetAmmoCount(ALT_AMMO_TYPE)
    if current > limit then
        ply:SetAmmo(limit, ALT_AMMO_TYPE)
    end
end

local function NotifyPickupCooldown(ply, remaining)
    if not IsValid(ply) then return end
    local now = CurTime()
    if not ply._NextAR2AmmoMsg or ply._NextAR2AmmoMsg < now then
        ply:ChatPrint(string.format("[%s] You must wait %is before picking up more AR2 alt-fire ammo.", ServerPrefix, math.ceil(remaining)))
        ply._NextAR2AmmoMsg = now + 1
    end
end

local function NotifyAtMaxAmmo(ply)
    if not IsValid(ply) then return end
    local now = CurTime()
    if not ply._NextAR2AmmoMsg or ply._NextAR2AmmoMsg < now then
        ply:ChatPrint(string.format("[%s] You already have the maximum AR2 alt-fire ammo.", ServerPrefix))
        ply._NextAR2AmmoMsg = now + 1
    end
end

-- Central check for whether the player may pick up AR2 alt ammo.
local function CanPickupAR2Ammo(ply, ent)
    if not IsValid(ply) or not IsValid(ent) then return true end
    if ent:GetClass() ~= ALT_AMMO_ENTITY_CLASS then return true end

    local limit = GetConVar("ar2_altfire_limit"):GetInt()
    if limit >= 0 and ply:GetAmmoCount(ALT_AMMO_TYPE) >= limit then
        NotifyAtMaxAmmo(ply)
        return false
    end

    local sid = PlayerID(ply)
    local cooldown = GetConVar("ar2_altfire_pickup_cooldown"):GetFloat()
    local now = CurTime()

    if lastPickup[sid] and (now - lastPickup[sid]) < cooldown then
        local remaining = cooldown - (now - lastPickup[sid])
        NotifyPickupCooldown(ply, remaining)
        return false
    end

    lastPickup[sid] = now

    timer.Simple(0, function()
        if IsValid(ply) then EnforceAR2AltAmmo(ply) end
    end)

    return true
end

-- item-based pickups (ammo/health/armor)
hook.Add("PlayerCanPickupItem", "AR2AltFire_PickupCooldown_ItemHook", function(ply, item)
    return CanPickupAR2Ammo(ply, item)
end)

-- clamp when ammo is changed programmatically (GiveAmmo, SetAmmo, etc.)
hook.Add("PlayerAmmoChanged", "AR2AltFire_ClampOnAmmoChanged", function(ply, ammoType, oldCount, newCount)
    if not IsValid(ply) then return end
    if game.GetAmmoName(ammoType) == ALT_AMMO_TYPE then
        EnforceAR2AltAmmo(ply)
    end
end)

-- clamp on spawn
hook.Add("PlayerSpawn", "AR2AltFire_EnforceOnSpawn", function(ply)
    timer.Simple(0, function()
        if IsValid(ply) then EnforceAR2AltAmmo(ply) end
    end)
end)