-- Branding Options
local ServerPrefix = "[Excelsus]"
local PanelCategory = "Excelsus"
local PanelName = "AR2 Balls"

local CONFIG_FILE = "ar2_altfire_settings.txt"
local DEFAULT_SETTINGS = {
    altfire_limit = 3,
    pickup_cooldown = 5
}

-- =========================
-- Settings Persistence
-- =========================
local function LoadSettings()
    if not file.Exists(CONFIG_FILE, "DATA") then return table.Copy(DEFAULT_SETTINGS) end
    local content = file.Read(CONFIG_FILE, "DATA")
    if not content then return table.Copy(DEFAULT_SETTINGS) end
    local ok, tbl = pcall(util.JSONToTable, content)
    if ok and type(tbl) == "table" then return tbl end
    return table.Copy(DEFAULT_SETTINGS)
end

local function SaveSettings(tbl)
    if type(tbl) ~= "table" then return end
    file.Write(CONFIG_FILE, util.TableToJSON(tbl, true))
end

local settings = LoadSettings()

if SERVER then
    util.AddNetworkString("AR2AltFire_UpdateSettings")

    local ALT_AMMO_TYPE = "AR2AltFire"
    local ALT_AMMO_ENTITY_CLASS = "item_ammo_ar2_altfire"
    local lastPickup = {}

    local function PlayerID(ply) return ply:SteamID64() or tostring(ply:EntIndex()) end

    local function EnforceAmmoLimit(ply)
        if not IsValid(ply) or not ply:IsPlayer() then return end
        local limit = settings.altfire_limit
        if limit >= 0 then
            local current = ply:GetAmmoCount(ALT_AMMO_TYPE)
            if current > limit then ply:SetAmmo(limit, ALT_AMMO_TYPE) end
        end
    end

    local function NotifyPlayer(ply, msg)
        if not IsValid(ply) then return end
        local now = CurTime()
        if not ply._NextAR2AmmoMsg or ply._NextAR2AmmoMsg < now then
            ply:ChatPrint(msg)
            ply._NextAR2AmmoMsg = now + 1
        end
    end

    local function CanPickupAmmo(ply, ent)
        if not IsValid(ply) or not IsValid(ent) then return true end
        if ent:GetClass() ~= ALT_AMMO_ENTITY_CLASS then return true end

        local limit = settings.altfire_limit
        if limit >= 0 and ply:GetAmmoCount(ALT_AMMO_TYPE) >= limit then
            NotifyPlayer(ply, string.format("%s You already have the maximum AR2 alt-fire ammo.", ServerPrefix))
            return false
        end

        local sid = PlayerID(ply)
        local cooldown = settings.pickup_cooldown
        local now = CurTime()
        if lastPickup[sid] and (now - lastPickup[sid]) < cooldown then
            local remaining = cooldown - (now - lastPickup[sid])
            NotifyPlayer(ply, string.format("%s You must wait %ds before picking up more AR2 alt-fire ammo.", ServerPrefix, math.ceil(remaining)))
            return false
        end

        lastPickup[sid] = now
        timer.Simple(0, function() if IsValid(ply) then EnforceAmmoLimit(ply) end end)
        return true
    end

    -- Hooks
    hook.Add("PlayerCanPickupItem", "AR2AltFire_ItemPickup", CanPickupAmmo)
    hook.Add("PlayerAmmoChanged", "AR2AltFire_AmmoChanged", function(ply, ammoType)
        if game.GetAmmoName(ammoType) == ALT_AMMO_TYPE then EnforceAmmoLimit(ply) end
    end)
    hook.Add("PlayerSpawn", "AR2AltFire_OnSpawn", function(ply) timer.Simple(0, function() EnforceAmmoLimit(ply) end) end)

    -- Network receiver for live updates
    net.Receive("AR2AltFire_UpdateSettings", function(len, ply)
        if not ply:IsSuperAdmin() then return end
        local limit = net.ReadInt(16)
        local cooldown = net.ReadInt(16)
        settings.altfire_limit = limit
        settings.pickup_cooldown = cooldown
        SaveSettings(settings)

        -- Enforce on all players immediately
        for _, v in ipairs(player.GetAll()) do 
            EnforceAmmoLimit(v)
        end
    end)
end

if CLIENT then
    hook.Add("PopulateToolMenu", "Excelsus_AR2Options", function()
        spawnmenu.AddToolMenuOption("Options", PanelCategory, "AR2Panel", PanelName, "", "", function(panel)
            panel:ClearControls()

            if not LocalPlayer():IsSuperAdmin() then
                panel:Help("You must be a superadmin to edit this panel.")
                return
            end

            panel:Help("Settings to modify the behavior of how Combine Balls are regulated.")

            local sliderLimit = panel:NumSlider("Alt-Fire Ammo Limit", "ar2_altfire_limit", 0, 10, 0)
            sliderLimit:SetValue(settings.altfire_limit)

            local sliderCooldown = panel:NumSlider("Pickup Cooldown (seconds)", "ar2_altfire_pickup_cooldown", 0, 30, 0)
            sliderCooldown:SetValue(settings.pickup_cooldown)

            local function SendSettings()
                net.Start("AR2AltFire_UpdateSettings")
                net.WriteInt(math.floor(sliderLimit:GetValue()), 16)
                net.WriteInt(math.floor(sliderCooldown:GetValue()), 16)
                net.SendToServer()
            end

            sliderLimit.OnValueChanged = SendSettings
            sliderCooldown.OnValueChanged = SendSettings

            panel:Button("Reset to Defaults", function()
                sliderLimit:SetValue(DEFAULT_SETTINGS.altfire_limit)
                sliderCooldown:SetValue(DEFAULT_SETTINGS.pickup_cooldown)

                -- Send live update to server
                net.Start("AR2AltFire_UpdateSettings")
                net.WriteInt(DEFAULT_SETTINGS.altfire_limit, 16)
                net.WriteInt(DEFAULT_SETTINGS.pickup_cooldown, 16)
                net.SendToServer()
            end)
        end)
    end)
end