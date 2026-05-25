--[[
* trove/plugins/vault.lua — Vault Browser
*
* Displays Mog Vault Deposit Boxes and Wardrobe contents.
* Uses the generic tab protocol (TAB_SOURCE = 1).
* Supports item withdrawal via action 15.
*
* Command: /trove vault
]]--

local imgui = require('imgui');

------------------------------------------------------------
-- Shared (injected via init)
------------------------------------------------------------
local renderIcon = nil;
local getItemRes = nil;
local ui = nil;
local renderTooltip = nil;

------------------------------------------------------------
-- State
------------------------------------------------------------
local isOpen          = { false };
local selectedCat     = nil;
local summary         = {};
local summaryLoaded   = false;
local items           = {};
local itemsLoaded     = false;
local searchBuf       = { '' };

-- Selection + withdraw state
local selectedItem     = nil;     -- index into items[]
local withdrawCooldown = 0;
local COOLDOWN_SEC     = 2.0;
local statusMsg        = '';
local statusTime       = 0;
local statusIsErr      = false;

------------------------------------------------------------
-- Protocol
------------------------------------------------------------
local PACKET_ID            = 0x1A4;
local C2S_TAB_SUMMARY     = 13;
local C2S_TAB_CATEGORY     = 14;
local C2S_VAULT_WITHDRAW   = 15;
local S2C_TAB_SUMMARY     = 12;
local S2C_TAB_ENTRY        = 8;
local S2C_END_LIST         = 2;
local S2C_ACK              = 3;
local TAB_SOURCE_VAULT     = 1;

local function makePacket()
    local p = {};
    for i = 1, 64 do p[i] = 0; end
    return p;
end

local function sendVaultSummary()
    local p = makePacket();
    p[5] = C2S_TAB_SUMMARY;
    p[7] = TAB_SOURCE_VAULT;
    AshitaCore:GetPacketManager():AddOutgoingPacket(PACKET_ID, p);
end

local function sendVaultCategory(categoryName)
    local p = makePacket();
    p[5] = C2S_TAB_CATEGORY;
    p[7] = TAB_SOURCE_VAULT;
    local bytes = { string.byte(categoryName, 1, 20) };
    for i = 1, math.min(#bytes, 20) do p[8 + i] = bytes[i]; end
    AshitaCore:GetPacketManager():AddOutgoingPacket(PACKET_ID, p);
end

local function sendVaultWithdraw(locId, slotId)
    local p = makePacket();
    p[5] = C2S_VAULT_WITHDRAW;
    p[7] = locId;
    p[8] = slotId;
    AshitaCore:GetPacketManager():AddOutgoingPacket(PACKET_ID, p);
    withdrawCooldown = os.clock() + COOLDOWN_SEC;
end

------------------------------------------------------------
-- Packet reading helpers
------------------------------------------------------------
local function readU16(data, offset)
    local lo = struct.unpack('B', data, offset + 1);
    local hi = struct.unpack('B', data, offset + 2);
    return lo + hi * 256;
end

local function readString(data, offset, maxLen)
    local s = '';
    for i = 0, maxLen - 1 do
        local b = struct.unpack('B', data, offset + i + 1);
        if b == 0 then break; end
        s = s .. string.char(b);
    end
    return s;
end

------------------------------------------------------------
-- Helpers
------------------------------------------------------------
local function isOnCooldown()
    return os.clock() < withdrawCooldown;
end

local function parseSubtype(subtype)
    local locId, slotId = subtype:match('(%d+):(%d+)');
    return tonumber(locId), tonumber(slotId);
end

-- Town zones where vault withdrawal is allowed (matches server VAULT_ZONES)
local TOWN_ZONES = {
    [232]=true, [231]=true, [230]=true, -- San d'Oria
    [236]=true, [234]=true, [235]=true, -- Bastok
    [238]=true, [240]=true, [239]=true, [241]=true, -- Windurst
    [80]=true, [87]=true, [94]=true,    -- [S] cities
    [248]=true, [247]=true, [252]=true, -- Selbina, Rabao, Norg
    [243]=true, [244]=true, [245]=true, [246]=true, -- Jeuno
    [237]=true,             -- Metalworks
    [249]=true, [250]=true, -- Mhaura, Kazham
    [48]=true, [50]=true, [53]=true,  -- Al Zahbi, Whitegate, Nashmau
    [26]=true,              -- Tavnazian Safehold
    [284]=true, [281]=true, [222]=true, -- Celennia, Leafallia, Provenance
};

-- Withdraw cost lookup (swap_cost / 5, indexed by numUpgrades = numContainers - 2)
local WITHDRAW_COSTS = {
    [0]=2000, 1700, 1400, 1100, 1000, 900, 800, 700,
    600, 500, 400, 300, 200, 150, 100, 50, 20, 10, 0,
};

local function isInTown()
    local zoneId = AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0);
    return TOWN_ZONES[zoneId] == true;
end

local function getWithdrawCost()
    local numContainers = #summary;
    local numUpgrades = math.max(0, math.min(numContainers - 2, 18));
    return WITHDRAW_COSTS[numUpgrades] or 2000;
end

------------------------------------------------------------
-- Render: Summary view
------------------------------------------------------------
local function renderSummary()
    if summaryLoaded ~= true then
        ui.dim('Loading...');
        return;
    end

    if #summary == 0 then
        ui.dim('No vault containers unlocked.');
        return;
    end

    if ui.button('Refresh', 60, 22) then
        summaryLoaded = false;
        sendVaultSummary();
    end
    imgui.Separator();
    imgui.Spacing();

    imgui.BeginChild('##vault_summary', { -1, -1 }, false);
    for i, entry in ipairs(summary) do
        local subtitle = string.format('%d item%s stored', entry.count, entry.count ~= 1 and 's' or '');
        local isWardrobe = entry.category:find('Wardrobe');
        local iconId = isWardrobe and 61 or 46; -- Armoire / Armor Box

        renderIcon(iconId, 28);
        imgui.SameLine(0, 6);

        -- Category button (inline, reduced width to account for icon)
        local btnWidth = imgui.GetContentRegionAvail();
        if ui.categoryButton(entry.category, subtitle, i) then
            selectedCat = entry.category;
            selectedItem = nil;
            items = {};
            itemsLoaded = false;
            searchBuf = { '' };
            sendVaultCategory(entry.category);
        end
        imgui.Spacing();
    end
    imgui.EndChild();
end

------------------------------------------------------------
-- Render: Item list view
------------------------------------------------------------
local function renderItems()
    if ui.button('< Back', 55, 22) then
        selectedCat = nil;
        selectedItem = nil;
        items = {};
        itemsLoaded = false;
        searchBuf = { '' };
        return;
    end
    imgui.SameLine();
    ui.colored(selectedCat, 'header');
    imgui.SameLine();
    ui.dim(string.format('(%d)', #items));

    -- Refresh
    imgui.SameLine(imgui.GetWindowWidth() - 80);
    if ui.button('Refresh', 60, 22) then
        items = {};
        itemsLoaded = false;
        selectedItem = nil;
        sendVaultCategory(selectedCat);
    end

    imgui.Separator();
    imgui.Spacing();

    if not itemsLoaded then
        ui.dim('Loading...');
        return;
    end

    if #items == 0 then
        ui.dim('Empty.');
        return;
    end

    -- Search filter
    imgui.PushItemWidth(-1);
    imgui.InputText('##vault_search', searchBuf, 256);
    imgui.PopItemWidth();
    imgui.Spacing();

    local filter = searchBuf[1]:lower();

    -- Bottom panel height for selection
    local bottomH = selectedItem and 50 or 0;

    imgui.BeginChild('##vault_items', { -1, -1 - bottomH }, false);
    local idx = 0;
    for i, item in ipairs(items) do
        local res = getItemRes(item.iconId);
        local name = (res and res.Name and res.Name[1]) or item.name or '???';
        if filter == '' or name:lower():find(filter, 1, true) then
            idx = idx + 1;
            local isSelected = (selectedItem == i);

            local base = ui.color('childBg');
            local bgColor;
            if isSelected then
                bgColor = { base[1] + 0.08, base[2] + 0.06, base[3] + 0.12, 0.90 };
            elseif idx % 2 == 0 then
                bgColor = { base[1], base[2], base[3], 0.35 };
            else
                bgColor = { base[1], base[2], base[3], 0.20 };
            end

            local rowId = string.format('##vr_%d', i);
            imgui.PushStyleColor(ImGuiCol_ChildBg, bgColor);
            imgui.BeginChild(rowId, { -1, 28 }, false);

            imgui.SetCursorPos({ 4, 1 });
            renderIcon(item.iconId, 24);
            imgui.SameLine(32);

            imgui.SetCursorPosY(0);
            if imgui.Selectable(string.format('##vsel_%d', i), isSelected,
                ImGuiSelectableFlags_SpanAllColumns, { 0, 28 }) then
                selectedItem = isSelected and nil or i;
            end

            local dl = imgui.GetWindowDrawList();
            local wx, wy = imgui.GetWindowPos();
            dl:AddText({ wx + 32, wy + 7 }, imgui.GetColorU32(ui.color('white')), name);

            if item.tier and item.tier ~= '' and item.tier ~= '1' then
                local qtyStr = 'x' .. item.tier;
                local nameW = imgui.CalcTextSize(name);
                dl:AddText({ wx + 34 + nameW, wy + 7 }, imgui.GetColorU32(ui.color('dimmed')), ' ' .. qtyStr);
            end

            imgui.EndChild();
            imgui.PopStyleColor(1);

            if imgui.IsItemHovered() and renderTooltip then
                renderTooltip({ id = item.iconId, name = name, qty = tonumber(item.tier) or 1 });
            end
        end
    end
    imgui.EndChild();

    -- Bottom panel: selected item + withdraw button
    if selectedItem and items[selectedItem] then
        local item = items[selectedItem];
        local res = getItemRes(item.iconId);
        local name = (res and res.Name and res.Name[1]) or item.name or '???';
        local cooldown = isOnCooldown();
        local inTown = isInTown();
        local hasSlot = item.locId and item.slotId;
        local cost = getWithdrawCost();

        -- Determine withdraw state
        local canWithdraw = hasSlot and inTown and not cooldown;
        local reason = nil;
        if not hasSlot then
            reason = 'Item data unavailable.';
        elseif not inTown then
            reason = 'You must be in a town to withdraw.';
        elseif cooldown then
            reason = 'Please wait...';
        end

        imgui.Separator();
        imgui.Spacing();

        renderIcon(item.iconId, 24);
        imgui.SameLine(0, 6);
        imgui.SetCursorPosY(imgui.GetCursorPosY() + 4);
        ui.colored(name, 'white');

        imgui.SameLine(imgui.GetWindowWidth() - 90);
        imgui.SetCursorPosY(imgui.GetCursorPosY() - 4);

        if not canWithdraw then
            imgui.PushStyleVar(ImGuiStyleVar_Alpha, 0.35);
        end

        if ui.button('Withdraw', 72, 26) and canWithdraw then
            sendVaultWithdraw(item.locId, item.slotId);
        end

        if not canWithdraw then
            imgui.PopStyleVar();
        end

        -- Tooltip on withdraw button (always shows cost, shows reason if greyed)
        if imgui.IsItemHovered() then
            ui.tooltip(function()
                if reason then
                    imgui.TextColored({ 1, 0.5, 0.5, 1 }, reason);
                    imgui.Separator();
                end
                renderIcon(65535, 16);
                imgui.SameLine(0, 4);
                if cost > 0 then
                    imgui.TextColored({ 1.0, 0.85, 0.35, 1.0 }, string.format('Cost: %s gil', tostring(cost)));
                else
                    imgui.TextColored({ 0.4, 1.0, 0.4, 1.0 }, 'Free');
                end
            end);
        end

        -- Status message
        if statusMsg ~= '' and os.clock() < statusTime + 3 then
            imgui.SetCursorPosX(8);
            if statusIsErr then
                imgui.TextColored({ 1, 0.4, 0.4, 1 }, statusMsg);
            else
                imgui.TextColored({ 0.4, 1, 0.4, 1 }, statusMsg);
            end
        end
    end
end

------------------------------------------------------------
-- Main render
------------------------------------------------------------
local function renderWindow()
    if not isOpen[1] then return; end

    if not summaryLoaded then
        sendVaultSummary();
        summaryLoaded = 'pending';
    end

    imgui.SetNextWindowSize({ 420, 450 }, ImGuiCond_FirstUseEver);
    imgui.SetNextWindowSizeConstraints({ 350, 300 }, { 600, 800 });

    local winColors = ui.pushWindowStyle();

    if imgui.Begin('Vault###trove_vault', isOpen, ImGuiWindowFlags_None) then
        if selectedCat then
            renderItems();
        else
            renderSummary();
        end
    end
    imgui.End();
    ui.popWindowStyle(winColors);
end

------------------------------------------------------------
-- Plugin export
------------------------------------------------------------
return {
    name        = 'Vault',
    description = 'Browse Mog Vault deposit boxes and wardrobes',

    init = function(sharedRenderIcon, sharedGetItemRes, sharedUi, sharedRenderTooltip)
        renderIcon = sharedRenderIcon;
        getItemRes = sharedGetItemRes;
        ui = sharedUi;
        renderTooltip = sharedRenderTooltip;
    end,

    commands = {
        vault = function(state, args)
            isOpen[1] = not isOpen[1];
            if isOpen[1] and not summaryLoaded then
                sendVaultSummary();
            end
        end,
    },

    window = {
        isOpen  = isOpen,
        render  = renderWindow,
        label   = 'Vault',
        icon    = 26352,
    },

    onPacketIn = function(e, state)
        if e.id ~= PACKET_ID then return; end

        local action = struct.unpack('B', e.data_modified, 0x04 + 1);

        if action == S2C_TAB_SUMMARY then
            local source = struct.unpack('B', e.data_modified, 0x06 + 1);
            if source ~= TAB_SOURCE_VAULT then return; end

            local entryCount = struct.unpack('B', e.data_modified, 0x05 + 1);
            summary = {};
            local offset = 0x08;
            for i = 1, entryCount do
                local category = readString(e.data_modified, offset, 20);
                local count    = readU16(e.data_modified, offset + 20);
                table.insert(summary, { category = category, count = count });
                offset = offset + 22;
            end
            summaryLoaded = true;
            return;
        end

        if action == S2C_TAB_ENTRY then
            local source = struct.unpack('B', e.data_modified, 0x05 + 1);
            if source ~= TAB_SOURCE_VAULT then return; end

            local iconId   = readU16(e.data_modified, 0x06);
            local subtype  = readString(e.data_modified, 0x1C, 23);
            local name     = readString(e.data_modified, 0x34, 23);
            local tier     = readString(e.data_modified, 0x4C, 7);

            local locId, slotId = parseSubtype(subtype);

            table.insert(items, {
                iconId = iconId,
                name   = name,
                tier   = tier,
                locId  = locId,
                slotId = slotId,
            });
            return;
        end

        if action == S2C_END_LIST then
            local source = struct.unpack('B', e.data_modified, 0x05 + 1);
            if source ~= TAB_SOURCE_VAULT then return; end
            itemsLoaded = true;
            return;
        end

        if action == S2C_ACK and isOnCooldown() then
            local resultCode = struct.unpack('B', e.data_modified, 0x05 + 1);
            local msg = readString(e.data_modified, 0x10, 31);

            if resultCode == 0 then
                -- Print "Obtained: <item name>" to chat log
                if selectedItem and items[selectedItem] then
                    local item = items[selectedItem];
                    local res = getItemRes(item.iconId);
                    local name = (res and res.Name and res.Name[1]) or item.name or '???';
                    print(string.format('\30\01Obtained: \30\02%s\30\01', name));
                end

                statusMsg = 'Withdrawn!';
                statusIsErr = false;
                statusTime = os.clock();
                selectedItem = nil;
                if selectedCat then
                    items = {};
                    itemsLoaded = false;
                    summaryLoaded = false;
                    sendVaultSummary();
                    sendVaultCategory(selectedCat);
                end
            else
                statusMsg = msg ~= '' and msg or 'Withdraw failed.';
                statusIsErr = true;
                statusTime = os.clock();
                withdrawCooldown = 0;
            end
            return;
        end
    end,
};
