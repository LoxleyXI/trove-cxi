--[[
* trove/plugins/vault.lua — Vault Browser
*
* Displays Mog Vault Deposit Boxes and Wardrobe contents.
* Reads directly from client memory (no server packets needed).
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

------------------------------------------------------------
-- Vault container definitions
------------------------------------------------------------
-- Deposit Boxes: location IDs 19-44 (A-Z)
-- Wardrobes:     location IDs 45-70 (A-Z)

local DEPOSIT_BASE  = 19;
local WARDROBE_BASE = 45;
local MAX_VAULTS    = 26;

local function buildContainers()
    local deposits  = {};
    local wardrobes = {};
    for i = 0, MAX_VAULTS - 1 do
        local letter = string.char(65 + i); -- A-Z
        table.insert(deposits,  { id = DEPOSIT_BASE + i,  name = 'Deposit Box ' .. letter });
        table.insert(wardrobes, { id = WARDROBE_BASE + i, name = 'Wardrobe ' .. letter });
    end
    return deposits, wardrobes;
end

local DEPOSITS, WARDROBES = buildContainers();

------------------------------------------------------------
-- State
------------------------------------------------------------
local isOpen       = { false };
local selectedCat  = nil;   -- nil = summary, else container table entry
local items        = {};
local lastScan     = 0;
local SCAN_INTERVAL = 1;

------------------------------------------------------------
-- Inventory reading (client-side memory)
------------------------------------------------------------
local function getContainerItems(containerId)
    local inventory = AshitaCore:GetMemoryManager():GetInventory();
    if inventory == nil then return {}; end

    local max = inventory:GetContainerCountMax(containerId);
    if max == nil or max == 0 then return {}; end

    local result = {};
    for j = 0, max do
        local ok, item = pcall(function() return inventory:GetContainerItem(containerId, j); end);
        if not ok or item == nil then break; end
        if item.Id ~= 0 and item.Id ~= 65535 then
            table.insert(result, {
                id       = item.Id,
                count    = item.Count or 1,
                slot     = j,
            });
        end
    end
    return result;
end

local function getContainerCount(containerId)
    local inventory = AshitaCore:GetMemoryManager():GetInventory();
    if inventory == nil then return 0; end

    local max = inventory:GetContainerCountMax(containerId);
    if max == nil or max == 0 then return 0; end

    local count = 0;
    for j = 0, max do
        local ok, item = pcall(function() return inventory:GetContainerItem(containerId, j); end);
        if not ok or item == nil then break; end
        if item.Id ~= 0 and item.Id ~= 65535 then
            count = count + 1;
        end
    end
    return count;
end

-- Check which vaults are accessible (non-zero max capacity)
local function isContainerAccessible(containerId)
    local inventory = AshitaCore:GetMemoryManager():GetInventory();
    if inventory == nil then return false; end
    local max = inventory:GetContainerCountMax(containerId);
    return max ~= nil and max > 0;
end

------------------------------------------------------------
-- Render: Summary view (category list)
------------------------------------------------------------
local function renderSummary()
    local hasAny = false;

    -- Deposit Boxes
    for _, box in ipairs(DEPOSITS) do
        if isContainerAccessible(box.id) then
            hasAny = true;
            local count = getContainerCount(box.id);
            local label = string.format('%s (%d)', box.name, count);
            if imgui.Selectable(label, false) then
                selectedCat = box;
                items = getContainerItems(box.id);
            end
        end
    end

    -- Separator between deposits and wardrobes
    local hasDeposits = hasAny;
    local hasWardrobes = false;

    for _, wr in ipairs(WARDROBES) do
        if isContainerAccessible(wr.id) then
            if not hasWardrobes and hasDeposits then
                imgui.Spacing();
                imgui.Separator();
                imgui.Spacing();
            end
            hasWardrobes = true;
            hasAny = true;
            local count = getContainerCount(wr.id);
            local label = string.format('%s (%d)', wr.name, count);
            if imgui.Selectable(label, false) then
                selectedCat = wr;
                items = getContainerItems(wr.id);
            end
        end
    end

    if not hasAny then
        ui.dim('No vault containers available.');
    end
end

------------------------------------------------------------
-- Render: Item list view
------------------------------------------------------------
local function renderItems()
    -- Back button
    if ui.button('Back', 50, 22) then
        selectedCat = nil;
        items = {};
        return;
    end
    imgui.SameLine();
    ui.dim(string.format('%s (%d items)', selectedCat.name, #items));
    imgui.Separator();
    imgui.Spacing();

    if #items == 0 then
        ui.dim('Empty.');
        return;
    end

    for _, item in ipairs(items) do
        local res = getItemRes(item.id);
        local name = res and res.Name[1] or string.format('Item %d', item.id);

        if res then
            renderIcon(item.id, 22);
            imgui.SameLine();
        end

        if item.count > 1 then
            imgui.Text(string.format('%s x%d', name, item.count));
        else
            imgui.Text(name);
        end
    end
end

------------------------------------------------------------
-- Main render
------------------------------------------------------------
local function renderWindow()
    if not isOpen[1] then return; end

    imgui.SetNextWindowSize({ 280, 400 }, ImGuiCond_FirstUseEver);
    if imgui.Begin('Vault', isOpen, ImGuiWindowFlags_NoCollapse) then
        if selectedCat then
            renderItems();
        else
            renderSummary();
        end
    end
    imgui.End();
end

------------------------------------------------------------
-- Plugin export
------------------------------------------------------------
return {
    name        = 'Vault',
    description = 'Browse Mog Vault deposit boxes and wardrobes',

    init = function(sharedRenderIcon, sharedGetItemRes, sharedUi)
        renderIcon = sharedRenderIcon;
        getItemRes = sharedGetItemRes;
        ui = sharedUi;
    end,

    commands = {
        vault = function(state, args)
            isOpen[1] = not isOpen[1];
        end,
    },

    window = {
        isOpen  = isOpen,
        render  = renderWindow,
        label   = 'Vault',
        icon    = 26352, -- Moogle Sacoche
    },
};
