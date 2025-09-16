-- Branding / UI
local PanelTab = "Excelsus"
local PanelCategory = "Options"
local PanelName = "Limiter"

-- Persistence
local CONFIG_FILE = "ar2_altfire_settings.txt"
local DEFAULT_SETTINGS = {
    pickup_cooldown = 5,
    medkit_cooldown = 5,
    alt_ammo_entities = {
        {class = "item_ammo_ar2_altfire", ammo_type = "AR2AltFire", amount = 3},
        {class = "item_ammo_smg1_grenade", ammo_type = "SMG1AltFire", amount = 3}
    }
}

-- Load / Save
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
    local lastPickup = {} -- sid -> table of ammo types -> last pickup time
    local lastDamage = {} -- sid -> timestamp

    -- Helper: get a player's unique ID
    local function PlayerID(ply)
        return ply:SteamID64() or tostring(ply:EntIndex())
    end

    -- Clamp a player's alt-fire ammo counts to the configured limits
    local function ClampPlayerAmmo(ply)
        if not IsValid(ply) then return end

        for _, entry in ipairs(settings.alt_ammo_entities or {}) do
            local ammoType = entry.ammo_type
            local maxAmount = entry.amount or 1
            if ammoType then
                local current = ply:GetAmmoCount(ammoType)
                if current > maxAmount then
                    ply:SetAmmo(maxAmount, ammoType)

                    -- Notify player of clamped ammo
                    local msg = string.format("Your %s ammo has been clamped to the maximum of %d.", ammoType, maxAmount)
                    net.Start("Excelsus_Notify")
                    net.WriteString(msg)
                    net.Send(ply)
                end
            end
        end
    end

    hook.Add("EntityTakeDamage", "Excelsus_Medkit_LastDamage", function(target, dmg)
        if not IsValid(target) or not target:IsPlayer() then return end
        lastDamage[PlayerID(target)] = CurTime()
    end)

    local function NotifyPlayer(ply, msg)
        if not IsValid(ply) then return end
        local now = CurTime()
        if not ply._NextExcelsusMsg or ply._NextExcelsusMsg < now then
            net.Start("Excelsus_Notify")
            net.WriteString(msg)
            net.Send(ply)
            ply._NextExcelsusMsg = now + 1
        end
    end

    local function CanPickupItem(ply, ent)
        if not IsValid(ply) or not IsValid(ent) then return true end
        local sid = PlayerID(ply)
        local now = CurTime()
        local entClass = ent:GetClass()

        -- Check alt-ammo table
        for _, row in ipairs(settings.alt_ammo_entities) do
            if row.class == entClass then
                local ammoType = row.ammo_type or ""
                local limit = row.amount or 1

                -- Limit check first
                if ply:GetAmmoCount(ammoType) >= limit then
                    NotifyPlayer(ply, string.format("You already have the maximum %d of %s.", limit, entClass))
                    return false
                end

                lastPickup[sid] = lastPickup[sid] or {}
                local lastTime = lastPickup[sid][ammoType] or 0

                -- Cooldown check only if not at max
                if (now - lastTime) < settings.pickup_cooldown then
                    NotifyPlayer(ply, string.format("You must wait %ds before picking up more %s.", math.ceil(settings.pickup_cooldown - (now - lastTime)), entClass))
                    return false
                end

                -- Track pickup timestamp
                lastPickup[sid][ammoType] = now
                return true
            end
        end

        -- Medkit / Armor logic remains unchanged
        if entClass == "item_healthkit" or entClass == "item_battery" then
            local last = lastDamage[sid]
            if last and (now - last) < settings.medkit_cooldown then
                local remaining = settings.medkit_cooldown - (now - last)
                local text = entClass == "item_healthkit" and "Healthkit" or "Armor"
                NotifyPlayer(ply, string.format("You cannot pick up %s for %ds after taking damage.", text, math.ceil(remaining)))
                return false
            end
        end

        return true
    end

    hook.Add("PlayerCanPickupItem", "Excelsus_ItemPickup", CanPickupItem)

    -- Hook: always clamp on spawn after loadout
    hook.Add("PlayerSpawn", "Excelsus_ClampAltFireOnSpawn", function(ply)
        timer.Simple(0.1, function() -- slight delay ensures loadout has given ammo
            ClampPlayerAmmo(ply)
        end)
    end)

    -- Hook: whenever server gives ammo via GiveAmmo (or any other method)
    hook.Add("PlayerAmmoChanged", "Excelsus_ClampAltFireOnGiveAmmo", function(ply, ammoType, amount)
        timer.Simple(0, function()
            ClampPlayerAmmo(ply)
        end)
    end)

    -- Server settings exchange
    util.AddNetworkString("Excelsus_RequestSettings")
    util.AddNetworkString("Excelsus_SendSettings")
    util.AddNetworkString("Excelsus_UpdateSettings")
    util.AddNetworkString("Excelsus_Notify")

    net.Receive("Excelsus_RequestSettings", function(_, ply)
        if not ply:IsSuperAdmin() then return end
        net.Start("Excelsus_SendSettings")
            net.WriteInt(settings.pickup_cooldown, 16)
            net.WriteInt(settings.medkit_cooldown, 16)
            net.WriteTable(settings.alt_ammo_entities)
        net.Send(ply)
    end)

    net.Receive("Excelsus_UpdateSettings", function(_, ply)
        if not ply:IsSuperAdmin() then return end

        local newPickup = net.ReadInt(16)
        local newMed = net.ReadInt(16)
        local newTable = net.ReadTable()

        settings.pickup_cooldown = newPickup
        settings.medkit_cooldown = newMed
        settings.alt_ammo_entities = newTable
        SaveSettings(settings)

        -- Clamp all players to new limits immediately
        for _, p in ipairs(player.GetAll()) do
            ClampPlayerAmmo(p)
        end

        -- Broadcast updated table to all admins
        for _, p in ipairs(player.GetAll()) do
            if p:IsSuperAdmin() then
                net.Start("Excelsus_SendSettings")
                    net.WriteInt(settings.pickup_cooldown,16)
                    net.WriteInt(settings.medkit_cooldown,16)
                    net.WriteTable(settings.alt_ammo_entities)
                net.Send(p)
            end
        end
    end)
end

if CLIENT then
    local HUDMessages = {}

    -- HUD Notifications
    net.Receive("Excelsus_Notify", function()
        local msg = net.ReadString()
        table.insert(HUDMessages, {text = msg, expire = CurTime() + 3})
    end)

    hook.Add("HUDPaint", "Excelsus_HUDMessages", function()
        if #HUDMessages == 0 then return end
        local scrW, scrH = ScrW(), ScrH()
        local x, y = scrW/2, scrH-100

        for i=#HUDMessages,1,-1 do
            local msg = HUDMessages[i]
            local remaining = msg.expire - CurTime()
            if remaining <= 0 then
                table.remove(HUDMessages, i)
            else
                local alpha = math.min(255, math.max(0, remaining/3*255))
                draw.SimpleTextOutlined(msg.text, "DermaDefaultBold", x, y, Color(255,255,255,alpha),
                    TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 2, Color(0,0,0,alpha))
                y = y - 24
            end
        end
    end)

    local clientSettings = table.Copy(DEFAULT_SETTINGS)

    net.Receive("Excelsus_SendSettings", function()
        clientSettings.pickup_cooldown = net.ReadInt(16)
        clientSettings.medkit_cooldown = net.ReadInt(16)
        clientSettings.alt_ammo_entities = net.ReadTable()
    end)

    local function RequestServerSettings()
        net.Start("Excelsus_RequestSettings")
        net.SendToServer()
    end

    -- Open Add/Edit sub-panel
    local function OpenAmmoEntryPopup(list, line)
        local isNew = not line
        local frame = vgui.Create("DFrame")
        frame:SetTitle(isNew and "Add Ammo Entry" or "Edit Ammo Entry")
        frame:SetSize(420, 160)
        frame:Center()
        frame:MakePopup()

        local lblClass = vgui.Create("DLabel", frame)
        lblClass:SetPos(8,30)
        lblClass:SetText("Ammo Class:")
        lblClass:SizeToContents()
        local teClass = vgui.Create("DTextEntry", frame)
        teClass:SetPos(120,26)
        teClass:SetWide(280)
        teClass:SetText(line and line:GetValue(1) or "")

        local lblType = vgui.Create("DLabel", frame)
        lblType:SetPos(8,60)
        lblType:SetText("Ammo Type:")
        lblType:SizeToContents()
        local teType = vgui.Create("DTextEntry", frame)
        teType:SetPos(120,56)
        teType:SetWide(280)
        teType:SetText(line and line:GetValue(2) or "")

        local lblAmount = vgui.Create("DLabel", frame)
        lblAmount:SetPos(8,90)
        lblAmount:SetText("Amount:")
        lblAmount:SizeToContents()
        local teAmount = vgui.Create("DTextEntry", frame)
        teAmount:SetPos(120,86)
        teAmount:SetWide(80)
        teAmount:SetText(line and line:GetValue(3) or "1")

        local btnSave = vgui.Create("DButton", frame)
        btnSave:SetText(isNew and "Add" or "Save")
        btnSave:SetPos(320, 120)
        btnSave:SetWide(80)
        btnSave.DoClick = function()
            local class = teClass:GetValue():Trim()
            local amtype = teType:GetValue():Trim()
            local amount = tonumber(teAmount:GetValue()) or 1
            if class == "" or amtype == "" then
                notification.AddLegacy("Class and Ammo Type required.", NOTIFY_ERROR, 3)
                return
            end

            if isNew then
                list:AddLine(class, amtype, tostring(math.max(0, math.floor(amount))))
            else
                line:SetValue(1, class)
                line:SetValue(2, amtype)
                line:SetValue(3, tostring(math.max(0, math.floor(amount))))
            end

            -- Update client table & send to server
            local updatedTable = {}
            for _, vline in ipairs(list:GetLines()) do
                table.insert(updatedTable, {
                    class = vline:GetValue(1),
                    ammo_type = vline:GetValue(2),
                    amount = tonumber(vline:GetValue(3)) or 1
                })
            end
            clientSettings.alt_ammo_entities = updatedTable
            net.Start("Excelsus_UpdateSettings")
                net.WriteInt(clientSettings.pickup_cooldown,16)
                net.WriteInt(clientSettings.medkit_cooldown,16)
                net.WriteTable(clientSettings.alt_ammo_entities)
            net.SendToServer()

            frame:Close()
        end
    end

    -- Open main table panel
    local function OpenAmmoTablePanel()
        local frame = vgui.Create("DFrame")
        frame:SetTitle("Alt-Ammo Table")
        frame:SetSize(620, 400)
        frame:Center()
        frame:MakePopup()

        local list = vgui.Create("DListView", frame)
        list:Dock(FILL)
        list:SetMultiSelect(false)
        list:AddColumn("Ammo Class"):SetFixedWidth(250)
        list:AddColumn("Ammo Type"):SetFixedWidth(250)
        list:AddColumn("Amount")

        local function PopulateList()
            list:Clear()
            local entries = clientSettings.alt_ammo_entities or DEFAULT_SETTINGS.alt_ammo_entities
            for _, row in ipairs(entries) do
                list:AddLine(row.class or "", row.ammo_type or "", tostring(row.amount or 1))
            end
        end

        timer.Simple(0.05, PopulateList)
        net.Receive("Excelsus_SendSettings", PopulateList)

        -- Right-click row menu: Edit / Remove
        list.OnRowRightClick = function(lst, idx, row)
            local menu = DermaMenu()
            menu:AddOption("Edit", function() OpenAmmoEntryPopup(lst, row) end)
            menu:AddOption("Remove", function()
                lst:RemoveLine(idx)
                local updatedTable = {}
                for _, vline in ipairs(lst:GetLines()) do
                    table.insert(updatedTable, {
                        class = vline:GetValue(1),
                        ammo_type = vline:GetValue(2),
                        amount = tonumber(vline:GetValue(3)) or 1
                    })
                end
                clientSettings.alt_ammo_entities = updatedTable
                net.Start("Excelsus_UpdateSettings")
                    net.WriteInt(clientSettings.pickup_cooldown,16)
                    net.WriteInt(clientSettings.medkit_cooldown,16)
                    net.WriteTable(clientSettings.alt_ammo_entities)
                net.SendToServer()
            end)
            menu:Open()
        end

        -- Right-click empty space: Add Entry
        list.OnMousePressed = function(lst, code)
            if code ~= MOUSE_RIGHT then return end

            -- Check if any row is hovered
            local hoveringRow = false
            for _, row in ipairs(lst:GetLines()) do
                if row:IsHovered() then
                    hoveringRow = true
                    break
                end
            end

            -- Only show Add menu if no row is hovered
            if not hoveringRow then
                local menu = DermaMenu()
                menu:AddOption("Add Entry", function() OpenAmmoEntryPopup(lst) end)
                menu:Open()
            end
        end
    end

    -- Main tool menu button
    hook.Add("PopulateToolMenu", "Excelsus_AR2MedkitPanel", function()
        spawnmenu.AddToolMenuOption(PanelTab, PanelCategory, "ExcelsusPanel", PanelName, "", "", function(panel)
            panel:ClearControls()
            if not LocalPlayer():IsSuperAdmin() then
                panel:Help("You must be a superadmin to edit the Ammo Table. Other settings are visible.")
            end
            panel:Help("Click the button below to edit alt-ammo mappings.")

            local btnOpen = vgui.Create("DButton", panel)
            btnOpen:Dock(TOP)
            btnOpen:DockPadding(4, 0, 0, 0)
            btnOpen:SetText("Edit Ammo Table")
            btnOpen:SetTall(26)
            btnOpen.DoClick = function()
                RequestServerSettings()
                OpenAmmoTablePanel()
            end
        end)
    end)
end