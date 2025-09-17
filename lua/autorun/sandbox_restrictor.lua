local RestrictorFile = "restrictor_settings.txt"
-- Branding Options
local PanelCategory = "Excelsus"
local PanelName = "Restrictor"

if SERVER then
    util.AddNetworkString("excelsus_cannotspawn")
    util.AddNetworkString("excelsus_cannotequip")
    util.AddNetworkString("excelsus_cannottool")
    util.AddNetworkString("excelsus_update_restrictor")

    -- Load a Restrictor table from file, ensuring necessary subtables exist
    local function LoadRestrictor()
        if file.Exists(RestrictorFile, "DATA") then
            local raw = file.Read(RestrictorFile, "DATA")
            local tbl = util.JSONToTable(raw)
            if type(tbl) == "table" then
                tbl.Entities = tbl.Entities or {}
                tbl.Weapons  = tbl.Weapons  or {}
                tbl.Tools    = tbl.Tools    or {}
                return tbl
            end
        end
        return { Entities = {}, Weapons = {}, Tools = {} }
    end

    -- Save the Restrictor table to disk (pretty JSON)
    local function SaveRestrictor(tbl)
        file.Write(RestrictorFile, util.TableToJSON(tbl, true))
    end

    local Restrictor = LoadRestrictor()

    -- Apply updates sent from clients (only admins allowed to update server-side table)
    net.Receive("excelsus_update_restrictor", function(_, ply)
        if not ply:IsAdmin() then return end
        local tbl = net.ReadTable()
        if type(tbl) == "table" then
            tbl.Entities = tbl.Entities or {}
            tbl.Weapons  = tbl.Weapons  or {}
            tbl.Tools    = tbl.Tools    or {}
            Restrictor = tbl
            SaveRestrictor(Restrictor)
        end
    end)

    -- Entity restriction: remove restricted entities and notify owner
    hook.Add("OnEntityCreated", "Restrictor_Entities", function(ent)
        if not IsValid(ent) then return end
        timer.Simple(0, function() -- wait a tick so owner/physics attacker is available
            if not IsValid(ent) then return end
            local class = ent:GetClass()
            if Restrictor.Entities[class] then
                local owner = ent:GetOwner()
                if not IsValid(owner) then
                    owner = ent:GetPhysicsAttacker(1) -- fallback
                end
                if IsValid(owner) then
                    net.Start("excelsus_cannotspawn")
                    net.WriteEntity(owner)
                    net.WriteString(class)
                    net.Send(owner)
                end
                if IsValid(ent) then ent:Remove() end
            end
        end)
    end)

    -- Weapon restriction: deny pickup and notify only the player attempting pickup
    hook.Add("PlayerCanPickupWeapon", "Restrictor_Weapons", function(ply, weapon)
        if not IsValid(weapon) or not IsValid(ply) then return end
        local class = weapon:GetClass()
        if Restrictor.Weapons[class] then
            net.Start("excelsus_cannotequip")
            net.WriteEntity(ply)
            net.WriteString(class)
            net.Send(ply)
            return false
        end
    end)

    -- Tool restriction: deny use of restricted tools using the CanTool hook
    -- CanTool signature: function(ply, tr, tool) -> boolean
    hook.Add("CanTool", "Restrictor_Tools", function(ply, tr, tool)
        if not IsValid(ply) then return end
        if type(tool) ~= "string" then return end
        if Restrictor.Tools[tool] then
            net.Start("excelsus_cannottool")
            net.WriteEntity(ply)
            net.WriteString(tool)
            net.Send(ply)
            return false
        end
    end)
end

if CLIENT then
    local RestrictedSound = "buttons/button10.wav"

    -- Simple helper for showing notification + sound
    local function NotifyRestricted(msg)
        notification.AddLegacy(msg, NOTIFY_ERROR, 2)
        surface.PlaySound(RestrictedSound)
    end

    -- Notification handlers for entity/weapon/tool denials
    net.Receive("excelsus_cannotspawn", function()
        local ply = net.ReadEntity()
        local class = net.ReadString()
        if ply == LocalPlayer() then
            NotifyRestricted("Entity '" .. class .. "' is restricted from being spawned.")
        end
    end)

    net.Receive("excelsus_cannotequip", function()
        local ply = net.ReadEntity()
        local class = net.ReadString()
        if ply == LocalPlayer() then
            NotifyRestricted("Weapon '" .. class .. "' is restricted from being picked up.")
        end
    end)

    net.Receive("excelsus_cannottool", function()
        local ply = net.ReadEntity()
        local tool = net.ReadString()
        if ply == LocalPlayer() then
            NotifyRestricted("Tool '" .. tool .. "' is restricted.")
        end
    end)

    -- Local load/save helpers used by the GUI
    local function LoadRestrictor()
        if file.Exists(RestrictorFile, "DATA") then
            local raw = file.Read(RestrictorFile, "DATA")
            local tbl = util.JSONToTable(raw)
            if type(tbl) == "table" then
                tbl.Entities = tbl.Entities or {}
                tbl.Weapons  = tbl.Weapons  or {}
                tbl.Tools    = tbl.Tools    or {}
                return tbl
            end
        end
        return { Entities = {}, Weapons = {}, Tools = {} }
    end

    -- Save locally and notify the server so changes apply immediately
    local function SaveRestrictor(tbl)
        tbl.Entities = tbl.Entities or {}
        tbl.Weapons  = tbl.Weapons  or {}
        tbl.Tools    = tbl.Tools    or {}
        file.Write(RestrictorFile, util.TableToJSON(tbl, true))
        net.Start("excelsus_update_restrictor")
        net.WriteTable(tbl)
        net.SendToServer()
    end

    local Restrictor = LoadRestrictor()

    -- Watch file modification time and reload local table when changed externally
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
    
    -- OpenRestrictorFrame() - context menu opens edit/add subpanel; proper spacing and reliable remove option
    local function OpenRestrictorFrame()
        if not LocalPlayer():IsSuperAdmin() then
            notification.AddLegacy("You must be a superadmin to open this menu.", NOTIFY_ERROR, 3)
            surface.PlaySound("buttons/button10.wav")
            return
        end

        local Frame = vgui.Create("DFrame")
        Frame:SetTitle("Restrictor Settings")
        Frame:SetSize(520, 420)
        Frame:Center()
        Frame:MakePopup()

        local List = vgui.Create("DListView", Frame)
        List:SetMultiSelect(false)
        List:Dock(FILL)
        List:AddColumn("Class")
        List:AddColumn("Type")

        -- Refresh the list and populate entries
        local function RefreshList()
            List:Clear()

            for class, _ in pairs(Restrictor.Entities or {}) do
                List:AddLine(class, "Entity")
            end
            for class, _ in pairs(Restrictor.Weapons or {}) do
                List:AddLine(class, "Weapon")
            end
            for class, _ in pairs(Restrictor.Tools or {}) do
                List:AddLine(class, "Tool")
            end
        end

        RefreshList()

        local function OpenEditPanel(existingLine)
            local isEdit = IsValid(existingLine)
            local preClass, preType
            if isEdit then
                preClass = existingLine:GetColumnText(1)
                preType  = existingLine:GetColumnText(2)
            end

            local Sub = vgui.Create("DFrame")
            Sub:SetTitle(isEdit and ("Edit: " .. preClass) or "Add Restrictor Entry")
            Sub:SetSize(400, 180)
            Sub:Center()
            Sub:MakePopup()
            Sub:SetSizable(false)
            Sub:DockPadding(8, 32, 8, 8)

            local nameLabel = vgui.Create("DLabel", Sub)
            nameLabel:Dock(TOP)
            nameLabel:DockMargin(0, 0, 0, 4)
            nameLabel:SetText("Class / Tool name:")
            nameLabel:SetAutoStretchVertical(true)

            local nameEntry = vgui.Create("DTextEntry", Sub)
            nameEntry:Dock(TOP)
            nameEntry:DockMargin(0, 0, 0, 8)
            nameEntry:SetTall(24)
            nameEntry:SetPlaceholderText("e.g. sent_ball, m9k_minigun, remover")
            if preClass then nameEntry:SetText(preClass) end

            local typeLabel = vgui.Create("DLabel", Sub)
            typeLabel:Dock(TOP)
            typeLabel:DockMargin(0, 0, 0, 4)
            typeLabel:SetText("Type:")
            typeLabel:SetAutoStretchVertical(true)

            local typeCombo = vgui.Create("DComboBox", Sub)
            typeCombo:Dock(TOP)
            typeCombo:DockMargin(0, 0, 0, 8)
            typeCombo:SetTall(24)
            typeCombo:AddChoice("Entity")
            typeCombo:AddChoice("Weapon")
            typeCombo:AddChoice("Tool")
            if preType then
                typeCombo:ChooseOption(preType)
            else
                typeCombo:ChooseOptionID(1)
            end

            local btnPanel = vgui.Create("DPanel", Sub)
            btnPanel:Dock(BOTTOM)
            btnPanel:SetTall(28)
            btnPanel:SetPaintBackground(false)

            local cancelBtn = vgui.Create("DButton", btnPanel)
            cancelBtn:Dock(RIGHT)
            cancelBtn:SetWide(80)
            cancelBtn:SetText("Cancel")
            cancelBtn.DoClick = function() Sub:Close() end

            local saveBtn = vgui.Create("DButton", btnPanel)
            saveBtn:Dock(RIGHT)
            saveBtn:SetWide(80)
            saveBtn:SetText("Save")
            saveBtn.DoClick = function()
                local class = (nameEntry:GetValue() or ""):Trim()
                if class == "" then
                    notification.AddLegacy("Name cannot be empty.", NOTIFY_ERROR, 2)
                    return
                end

                local typ = typeCombo:GetSelected() or "Entity"

                if isEdit then
                    if preType == "Entity" then Restrictor.Entities[preClass] = nil end
                    if preType == "Weapon" then Restrictor.Weapons[preClass] = nil end
                    if preType == "Tool" then Restrictor.Tools[preClass] = nil end
                end

                if typ == "Entity" then Restrictor.Entities[class] = true
                elseif typ == "Weapon" then Restrictor.Weapons[class] = true
                elseif typ == "Tool" then Restrictor.Tools[class] = true end

                SaveRestrictor(Restrictor)
                RefreshList()
                Sub:Close()
            end

            if isEdit then
                local removeBtn = vgui.Create("DButton", btnPanel)
                removeBtn:Dock(LEFT)
                removeBtn:SetWide(100)
                removeBtn:SetText("Remove")
                removeBtn:DockMargin(0, 0, 8, 0)
                removeBtn.DoClick = function()
                    if preType == "Entity" then Restrictor.Entities[preClass] = nil end
                    if preType == "Weapon" then Restrictor.Weapons[preClass] = nil end
                    if preType == "Tool" then Restrictor.Tools[preClass] = nil end
                    SaveRestrictor(Restrictor)
                    RefreshList()
                    Sub:Close()
                end
            end
        end

        -- Right-click context menu for rows
        List.OnRowRightClick = function(self, lineID, line)
            local menu = DermaMenu()
            menu:AddOption("Edit", function() OpenEditPanel(line) end)
            menu:AddOption("Remove", function()
                local class = line:GetColumnText(1)
                local typ = line:GetColumnText(2)
                if typ == "Entity" then Restrictor.Entities[class] = nil end
                if typ == "Weapon" then Restrictor.Weapons[class] = nil end
                if typ == "Tool" then Restrictor.Tools[class] = nil end
                SaveRestrictor(Restrictor)
                RefreshList()
            end)
            menu:Open()
        end

        -- Right-click on empty space
        List.OnMousePressed = function(self, code)
            if code ~= MOUSE_RIGHT then return end

            local menu = DermaMenu()
            menu:AddOption("Add...", function() OpenEditPanel(nil) end)
            menu:Open()
        end
    end

    -- Add button to Options -> Restrictor -> Settings (superadmin only check happens in frame)
    hook.Add("PopulateToolMenu", "RestrictorOptions", function()
        spawnmenu.AddToolMenuOption("Options", PanelCategory, "RestrictorPanel", PanelName, "", "", function(panel)
            panel:ClearControls()

            local btn = vgui.Create("DButton", panel)
            btn:Dock(TOP)
            btn:SetText("Open Restrictor Panel")
            btn.DoClick = OpenRestrictorFrame
        end)
    end)
end
