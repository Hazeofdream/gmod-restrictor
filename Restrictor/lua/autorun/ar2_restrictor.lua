-- Branding / UI
local ServerPrefix = "[Excelsus]"
local PanelCategory = "Excelsus"
local PanelName = "AR2 & Medkit"

-- Persistence
local CONFIG_FILE = "ar2_altfire_settings.txt"
local DEFAULT_SETTINGS = {
    pickup_cooldown = 5,
    medkit_cooldown = 5, -- seconds after damage to block medkit pickups
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

        -- Update settings immediately
        settings.pickup_cooldown = newPickup
        settings.medkit_cooldown = newMed
        settings.alt_ammo_entities = newTable

        -- Persist to file
        SaveSettings(settings)

        -- Optionally, broadcast to all admins so they have updated client-side table
        for _, p in ipairs(player.GetAll()) do
            if p:IsSuperAdmin() then
                net.Start("Excelsus_SendSettings")
                    net.WriteInt(settings.pickup_cooldown, 16)
                    net.WriteInt(settings.medkit_cooldown, 16)
                    net.WriteTable(settings.alt_ammo_entities)
                net.Send(p)
            end
        end
    end)
end

if CLIENT then
    -- Table to store active HUD messages
    local HUDMessages = {}

    -- Receive server notifications
    net.Receive("Excelsus_Notify", function()
        local msg = net.ReadString()
        table.insert(HUDMessages, {
            text = msg,
            expire = CurTime() + 3 -- Message duration in seconds
        })
    end)

    -- Draw HUD messages at bottom-center
    hook.Add("HUDPaint", "Excelsus_HUDMessages", function()
        if #HUDMessages == 0 then return end

        local scrW, scrH = ScrW(), ScrH()
        local x = scrW / 2
        local y = scrH - 100 -- Approximate center-bottom

        for i = #HUDMessages, 1, -1 do
            local msg = HUDMessages[i]
            local remaining = msg.expire - CurTime()
            if remaining <= 0 then
                table.remove(HUDMessages, i)
            else
                local alpha = math.min(255, math.max(0, remaining / 3 * 255))
                draw.SimpleTextOutlined(
                    msg.text,
                    "DermaDefaultBold",
                    x, y,
                    Color(255,255,255,alpha),
                    TEXT_ALIGN_CENTER,
                    TEXT_ALIGN_CENTER,
                    2,
                    Color(0,0,0,alpha)
                )
                y = y - 24 -- Stack messages upwards
            end
        end
    end)

    -- Client-side settings mirror (initially copy defaults)
    local clientSettings = table.Copy(DEFAULT_SETTINGS)

    -- Receive server settings
    net.Receive("Excelsus_SendSettings", function()
        clientSettings.pickup_cooldown = net.ReadInt(16)
        clientSettings.medkit_cooldown = net.ReadInt(16)
        clientSettings.alt_ammo_entities = net.ReadTable()
    end)

    -- Request server settings helper
    local function RequestServerSettings()
        net.Start("Excelsus_RequestSettings")
        net.SendToServer()
    end

    -- PopulateToolMenu for AR2 & Medkit
    hook.Add("PopulateToolMenu", "Excelsus_AR2MedkitPanel", function()
        spawnmenu.AddToolMenuOption("Options", PanelCategory, "ExcelsusPanel", PanelName, "", "", function(panel)
            panel:ClearControls()

            -- Only superadmins can edit ammo table
            if not LocalPlayer():IsSuperAdmin() then
                panel:Help("You must be a superadmin to edit the Ammo Table. Other settings are visible.")
            end

            -- Panel help
            panel:Help("Edit alt-ammo mappings and timing rules. Changes are saved to the server live.")

            panel:ControlHelp("") -- spacer

            -- Edit Ammo Table button
            local editBtn = vgui.Create("DButton", panel)
            editBtn:Dock(TOP)
            editBtn:DockMargin(0, 4, 0, 4)
            editBtn:SetText("Edit Ammo Table")
            editBtn:SetTall(26)
            editBtn:SetDisabled(not LocalPlayer():IsSuperAdmin())

            -- Reset Defaults button
            local resetBtn = vgui.Create("DButton", panel)
            resetBtn:Dock(TOP)
            resetBtn:DockMargin(0, 2, 0, 0)
            resetBtn:SetText("Reset to Defaults")
            resetBtn:SetTall(26)
            resetBtn:SetDisabled(not LocalPlayer():IsSuperAdmin())

            -- Request latest settings from server
            RequestServerSettings()

            -- Reset Defaults behavior
            resetBtn.DoClick = function()
                clientSettings = table.Copy(DEFAULT_SETTINGS)
                net.Start("Excelsus_UpdateSettings")
                    net.WriteInt(clientSettings.pickup_cooldown, 16)
                    net.WriteInt(clientSettings.medkit_cooldown, 16)
                    net.WriteTable(clientSettings.alt_ammo_entities)
                net.SendToServer()
            end

            -- Edit Ammo Table GUI
            editBtn.DoClick = function()
                RequestServerSettings()

                -- Main editor frame
                local frame = vgui.Create("DFrame")
                frame:SetTitle("Alt-Ammo Table & Settings Editor")
                frame:SetSize(760, 420)
                frame:Center()
                frame:MakePopup()

                -- Top numeric settings panel
                local topPanel = vgui.Create("DPanel", frame)
                topPanel:Dock(TOP)
                topPanel:SetTall(64)
                topPanel:DockPadding(8,8,8,8)

                -- Pickup cooldown
                local lblPickup = vgui.Create("DLabel", topPanel)
                lblPickup:SetPos(6, 8)
                lblPickup:SetText("Pickup Cooldown (s):")
                lblPickup:SizeToContents()
                local numPickup = vgui.Create("DTextEntry", topPanel)
                numPickup:SetPos(150, 4)
                numPickup:SetWide(100)
                numPickup:SetText(tostring(clientSettings.pickup_cooldown or DEFAULT_SETTINGS.pickup_cooldown))

                -- Medkit/Armor cooldown
                local lblMed = vgui.Create("DLabel", topPanel)
                lblMed:SetPos(270, 8)
                lblMed:SetText("Medkit/Armor Block After Damage (s):")
                lblMed:SizeToContents()
                local numMed = vgui.Create("DTextEntry", topPanel)
                numMed:SetPos(500, 4)
                numMed:SetWide(60)
                numMed:SetText(tostring(clientSettings.medkit_cooldown or DEFAULT_SETTINGS.medkit_cooldown))

                -- Ammo table list view
                local list = vgui.Create("DListView", frame)
                list:Dock(FILL)
                list:SetMultiSelect(false)
                list:AddColumn("Ammo Class"):SetFixedWidth(320)
                list:AddColumn("Ammo Type"):SetFixedWidth(240)
                list:AddColumn("Amount")

                -- Populate list from settings
                local function PopulateList()
                    list:Clear()
                    local entries = clientSettings.alt_ammo_entities or DEFAULT_SETTINGS.alt_ammo_entities
                    for _, row in ipairs(entries) do
                        list:AddLine(row.class or "", row.ammo_type or "", tostring(row.amount or 1))
                    end
                end

                timer.Simple(0.05, PopulateList)
                net.Receive("Excelsus_SendSettings", PopulateList)

                -- Right-click row: Edit / Remove
                list.OnRowRightClick = function(lst, idx, row)
                    local menu = DermaMenu()
                    menu:AddOption("Edit", function()
                        local w,h = 420,160
                        local sub = vgui.Create("DFrame")
                        sub:SetTitle("Edit Entry")
                        sub:SetSize(w,h)
                        sub:Center()
                        sub:MakePopup()

                        local lblA = vgui.Create("DLabel", sub)
                        lblA:SetPos(8,30)
                        lblA:SetText("Ammo Class:")
                        lblA:SizeToContents()
                        local teA = vgui.Create("DTextEntry", sub)
                        teA:SetPos(120,26)
                        teA:SetWide(w-140)
                        teA:SetText(row:GetValue(1))

                        local lblB = vgui.Create("DLabel", sub)
                        lblB:SetPos(8,60)
                        lblB:SetText("Ammo Type:")
                        lblB:SizeToContents()
                        local teB = vgui.Create("DTextEntry", sub)
                        teB:SetPos(120,56)
                        teB:SetWide(w-140)
                        teB:SetText(row:GetValue(2))

                        local lblC = vgui.Create("DLabel", sub)
                        lblC:SetPos(8,90)
                        lblC:SetText("Amount:")
                        lblC:SizeToContents()
                        local teC = vgui.Create("DTextEntry", sub)
                        teC:SetPos(120,86)
                        teC:SetWide(80)
                        teC:SetText(row:GetValue(3))

                        local ok = vgui.Create("DButton", sub)
                        ok:SetText("Save")
                        ok:SetPos(w-100,h-40)
                        ok:SetWide(80)
                        ok.DoClick = function()
                            local nc = teA:GetValue():Trim()
                            local na = teB:GetValue():Trim()
                            local nm = tonumber(teC:GetValue()) or 1
                            if nc=="" or na=="" then
                                notification.AddLegacy("Class and Ammo Type required.", NOTIFY_ERROR, 3)
                                return
                            end
                            row:SetValue(1, nc)
                            row:SetValue(2, na)
                            row:SetValue(3, tostring(math.max(0, math.floor(nm))))

                            -- Immediately update server with new table
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

                            sub:Close()
                        end
                    end)

                    menu:AddOption("Remove", function()
                        if idx then
                            list:RemoveLine(idx)

                            -- Immediately update server
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
                        end
                    end)

                    menu:Open()
                end

                -- Right-click empty space: Add new entry
                list.OnRowRightClickOutside = function()
                    local menu = DermaMenu()
                    menu:AddOption("Add Entry", function()
                        local w,h = 420,160
                        local sub = vgui.Create("DFrame")
                        sub:SetTitle("Add Entry")
                        sub:SetSize(w,h)
                        sub:Center()
                        sub:MakePopup()

                        local lblA = vgui.Create("DLabel", sub)
                        lblA:SetPos(8,30)
                        lblA:SetText("Ammo Class:")
                        lblA:SizeToContents()
                        local teA = vgui.Create("DTextEntry", sub)
                        teA:SetPos(120,26)
                        teA:SetWide(w-140)
                        teA:SetText("item_ammo_class")

                        local lblB = vgui.Create("DLabel", sub)
                        lblB:SetPos(8,60)
                        lblB:SetText("Ammo Type:")
                        lblB:SizeToContents()
                        local teB = vgui.Create("DTextEntry", sub)
                        teB:SetPos(120,56)
                        teB:SetWide(w-140)
                        teB:SetText("AMMO_NAME")

                        local lblC = vgui.Create("DLabel", sub)
                        lblC:SetPos(8,90)
                        lblC:SetText("Amount:")
                        lblC:SizeToContents()
                        local teC = vgui.Create("DTextEntry", sub)
                        teC:SetPos(120,86)
                        teC:SetWide(80)
                        teC:SetText("1")

                        local ok = vgui.Create("DButton", sub)
                        ok:SetText("Add")
                        ok:SetPos(w-100,h-40)
                        ok:SetWide(80)
                        ok.DoClick = function()
                            local nc = teA:GetValue():Trim()
                            local na = teB:GetValue():Trim()
                            local nm = tonumber(teC:GetValue()) or 1
                            if nc=="" or na=="" then
                                notification.AddLegacy("Class and Ammo Type required.", NOTIFY_ERROR, 3)
                                return
                            end
                            list:AddLine(nc, na, tostring(math.max(0, math.floor(nm))))

                            -- Immediately update server
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

                            sub:Close()
                        end
                    end)
                    menu:Open()
                end

                -- Bottom panel: Save & Apply numeric cooldowns
                local bottom = vgui.Create("DPanel", frame)
                bottom:Dock(BOTTOM)
                bottom:SetTall(36)
                bottom:DockPadding(8,6,8,6)

                local saveBtn = vgui.Create("DButton", bottom)
                saveBtn:Dock(RIGHT)
                saveBtn:SetWide(140)
                saveBtn:SetText("Save & Apply")
                saveBtn.DoClick = function()
                    clientSettings.pickup_cooldown = tonumber(numPickup:GetValue()) or DEFAULT_SETTINGS.pickup_cooldown
                    clientSettings.medkit_cooldown = tonumber(numMed:GetValue()) or DEFAULT_SETTINGS.medkit_cooldown

                    -- Build table from list
                    local newTable = {}
                    for _, vline in ipairs(list:GetLines()) do
                        table.insert(newTable, {
                            class = vline:GetValue(1),
                            ammo_type = vline:GetValue(2),
                            amount = tonumber(vline:GetValue(3)) or 1
                        })
                    end
                    clientSettings.alt_ammo_entities = newTable

                    -- Send updated settings to server
                    net.Start("Excelsus_UpdateSettings")
                        net.WriteInt(clientSettings.pickup_cooldown,16)
                        net.WriteInt(clientSettings.medkit_cooldown,16)
                        net.WriteTable(clientSettings.alt_ammo_entities)
                    net.SendToServer()

                    frame:Close()
                end
            end
        end)
    end)
end