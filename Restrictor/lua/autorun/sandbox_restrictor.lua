local RestrictorFile = "restrictor_settings.txt"

-- Branding Options
local PanelCategory = "Excelsus"
local PanelName = "Restrictor"

if SERVER then
    util.AddNetworkString("bb_cannotspawn")
    util.AddNetworkString("bb_cannotequip")
    util.AddNetworkString("bb_update_restrictor")

    -- Load Restrictor table from file
    local function LoadRestrictor()
        if file.Exists(RestrictorFile, "DATA") then
            local data = file.Read(RestrictorFile, "DATA")
            local tbl = util.JSONToTable(data)
            if tbl then return tbl end
        end
        return { Entities = {}, Weapons = {} }
    end

    -- Save Restrictor table to file
    local function SaveRestrictor(tbl)
        file.Write(RestrictorFile, util.TableToJSON(tbl, true))
    end

    local Restrictor = LoadRestrictor()

    -- Receive updates from admin clients to immediately apply restrictions
    net.Receive("bb_update_restrictor", function(len, ply)
        if not ply:IsAdmin() then return end
        local tbl = net.ReadTable()
        if tbl and type(tbl) == "table" then
            Restrictor = tbl
            SaveRestrictor(Restrictor)
        end
    end)

    -- Entity restriction: prevent spawning restricted entities
    hook.Add("OnEntityCreated", "Restrictor_Entities", function(ent)
        if not IsValid(ent) then return end
        timer.Simple(0, function()
            if not IsValid(ent) then return end
            local class = ent:GetClass()
            if Restrictor.Entities[class] then
                local owner = ent:GetOwner()
                if not IsValid(owner) then
                    owner = ent:GetPhysicsAttacker(1) -- fallback for owner
                end
                if IsValid(owner) then
                    net.Start("bb_cannotspawn")
                    net.WriteEntity(owner)
                    net.WriteString(class)
                    net.Broadcast()
                end
                ent:Remove()
            end
        end)
    end)

    -- Weapon restriction: prevent picking up restricted weapons
    hook.Add("PlayerCanPickupWeapon", "Restrictor_Weapons", function(ply, weapon)
        if not IsValid(weapon) then return end
        local class = weapon:GetClass()
        if Restrictor.Weapons[class] then
            net.Start("bb_cannotequip")
            net.WriteEntity(ply)
            net.WriteString(class)
            net.Broadcast()
            return false
        end
    end)
end

if CLIENT then
    local RestrictedSound = "buttons/button10.wav"

    -- Notification helper
    local function NotifyRestricted(msg)
        notification.AddLegacy(msg, NOTIFY_ERROR, 2)
        surface.PlaySound(RestrictedSound)
    end

    -- Entity restriction notification
    net.Receive("bb_cannotspawn", function()
        local ply = net.ReadEntity()
        local class = net.ReadString()
        if ply == LocalPlayer() then
            NotifyRestricted("Entity '"..class.."' is restricted from being spawned.")
        end
    end)

    -- Weapon restriction notification
    net.Receive("bb_cannotequip", function()
        local ply = net.ReadEntity()
        local class = net.ReadString()
        if ply == LocalPlayer() then
            NotifyRestricted("Weapon '"..class.."' is restricted from being spawned.")
        end
    end)

    -- Load Restrictor table locally for the GUI
    local function LoadRestrictor()
        if file.Exists(RestrictorFile, "DATA") then
            local data = file.Read(RestrictorFile, "DATA")
            local tbl = util.JSONToTable(data)
            if tbl then return tbl end
        end
        return { Entities = {}, Weapons = {} }
    end

    -- Save local changes and send update to server
    local function SaveRestrictor(tbl)
        file.Write(RestrictorFile, util.TableToJSON(tbl, true))
        net.Start("bb_update_restrictor")
        net.WriteTable(tbl)
        net.SendToServer()
    end

    local Restrictor = LoadRestrictor()

    -- Auto-refresh local Restrictor table if file is modified externally
    local lastModified = 0
    timer.Create("RestrictorFileWatcher", 2, 0, function()
        if file.Exists(RestrictorFile, "DATA") then
            local modTime = file.Time(RestrictorFile, "DATA") or 0
            if modTime > lastModified then
                lastModified = modTime
                Restrictor = LoadRestrictor()
            end
        end
    end)

    -- ==========================
    -- TOOLMENU PANEL
    -- ==========================
    hook.Add("PopulateToolMenu", "RestrictorOptions", function()
        spawnmenu.AddToolMenuOption("Options", PanelCategory, "RestrictorPanel", PanelName, "", "", function(panel)
            panel:ClearControls()

            local btn = vgui.Create("DButton", panel)
            btn:Dock(TOP)
            btn:SetText("Open Restrictor Panel")
            btn.DoClick = function()
				if not LocalPlayer():IsSuperAdmin() then
					notification.AddLegacy("You must be a superadmin to open this menu.", NOTIFY_ERROR, 3)
					surface.PlaySound("buttons/button10.wav")
					return
				end

                local Frame = vgui.Create("DFrame")
                Frame:SetTitle("Restrictor Settings")
                Frame:SetSize(400, 400)
                Frame:Center()
                Frame:MakePopup()

                local Table = vgui.Create("DListView", Frame)
                Table:Dock(FILL)
                Table:AddColumn("Class")
                Table:AddColumn("Type")

                -- Refreshes table GUI to match current Restrictor table
                local function RefreshTable()
                    Table:Clear()
                    for class, _ in pairs(Restrictor.Entities) do
                        local line = Table:AddLine(class, "Entities")
                        line.OnRightClick = function()
                            local menu = DermaMenu()
                            menu:AddOption("Remove", function()
                                Restrictor.Entities[class] = nil
                                SaveRestrictor(Restrictor)
                                RefreshTable()
                            end)
                            menu:Open()
                        end
                    end
                    for class, _ in pairs(Restrictor.Weapons) do
                        local line = Table:AddLine(class, "Weapons")
                        line.OnRightClick = function()
                            local menu = DermaMenu()
                            menu:AddOption("Remove", function()
                                Restrictor.Weapons[class] = nil
                                SaveRestrictor(Restrictor)
                                RefreshTable()
                            end)
                            menu:Open()
                        end
                    end
                end

                RefreshTable()

                -- Panel to add new restricted classes
                local EntryPanel = vgui.Create("DPanel", Frame)
                EntryPanel:Dock(BOTTOM)
                EntryPanel:SetTall(40)

                local TextEntry = vgui.Create("DTextEntry", EntryPanel)
                TextEntry:Dock(LEFT)
                TextEntry:SetWide(200)
                TextEntry:SetPlaceholderText("Class name...")

                local TypeSelector = vgui.Create("DComboBox", EntryPanel)
                TypeSelector:Dock(LEFT)
                TypeSelector:SetWide(100)
                TypeSelector:AddChoice("Entities")
                TypeSelector:AddChoice("Weapons")
                TypeSelector:ChooseOptionID(1)

                local AddButton = vgui.Create("DButton", EntryPanel)
                AddButton:Dock(FILL)
                AddButton:SetText("Add to Restrictor")
                AddButton.DoClick = function()
                    local class = TextEntry:GetValue():Trim()
                    local typ = TypeSelector:GetSelected()
                    if class == "" then return end

                    if typ == "Entities" then
                        Restrictor.Entities[class] = true
                    elseif typ == "Weapons" then
                        Restrictor.Weapons[class] = true
                    end

                    SaveRestrictor(Restrictor)
                    RefreshTable()
                    TextEntry:SetText("")
                end
            end
        end)
    end)
end