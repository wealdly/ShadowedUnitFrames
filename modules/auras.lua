local Auras = {}
local SML = LibStub("LibSharedMedia-3.0")
local playerUnits = {player = true, vehicle = true, pet = true}
local mainHand, offHand, tempEnchantScan = {time = 0}, {time = 0}
local canCure = ShadowUF.Units.canCure
ShadowUF:RegisterModule(Auras, "auras", ShadowUF.L["Auras"])

local FILTER_STRINGS = {
	HELPFUL = {PLAYER = "HELPFUL|PLAYER", RAID = "HELPFUL|RAID", RAID_PLAYER_DISPELLABLE = "HELPFUL|RAID_PLAYER_DISPELLABLE"},
	HARMFUL = {PLAYER = "HARMFUL|PLAYER", RAID = "HARMFUL|RAID", RAID_PLAYER_DISPELLABLE = "HARMFUL|RAID_PLAYER_DISPELLABLE"},
}

local AURA_TYPES = {"buffs", "debuffs"}

local columnsHaveScale = {}
local _scanUnit, _scanFilter
local function _safeGetAuraSlots()
	return {C_UnitAuras.GetAuraSlots(_scanUnit, _scanFilter)}
end

-- Hooks that trigger a SUF aura re-scan after Blizzard finishes updating its frames.
-- Ensures SUF always reads fresh data regardless of event handler ordering.
local blizHooksInstalled = false

local function onBlizAurasUpdated(blizFrame)
	local unit = blizFrame.unit
	if not unit then return end
	local sufFrame = ShadowUF.Units.unitFrames[unit]
	if sufFrame and sufFrame:IsVisible() then
		Auras:Update(sufFrame)
	end
end

local function installBlizAuraHooks()
	if blizHooksInstalled then return end
	blizHooksInstalled = true
	if TargetFrame then
		hooksecurefunc(TargetFrame, "UpdateAuras", onBlizAurasUpdated)
	end
	if FocusFrame then
		hooksecurefunc(FocusFrame, "UpdateAuras", onBlizAurasUpdated)
	end
	if CompactUnitFrame_UpdateAuras then
		hooksecurefunc("CompactUnitFrame_UpdateAuras", onBlizAurasUpdated)
	end
end

function Auras:OnEnable(frame)
	frame.auras = frame.auras or {}

	frame:RegisterNormalEvent("PLAYER_ENTERING_WORLD", self, "Update")
	frame:RegisterNormalEvent("ZONE_CHANGED_NEW_AREA", self, "UpdateFilter")
	frame:RegisterNormalEvent("WEAPON_ENCHANT_CHANGED", self, "OnWeaponEnchantChanged")
	frame:RegisterUnitEvent("UNIT_AURA", self, "Update")
	frame:RegisterUpdateFunc(self, "Update")

	-- Install Blizzard frame hooks once if any aura frame uses the BLIZZARD filter
	if not blizHooksInstalled then
		local auraConfig = ShadowUF.db.profile.units[frame.unitType].auras
		for _, at in ipairs(AURA_TYPES) do
			local tc = auraConfig and auraConfig[at]
			if tc then
				for i = 1, 6 do
					if tc[i] and tc[i].filter == "BLIZZARD" then
						installBlizAuraHooks()
						break
					end
				end
			end
			if blizHooksInstalled then break end
		end
	end

	self:UpdateFilter(frame)
end

function Auras:GetDispelColorCurve(auraType)
	local isBuff = (auraType == "buffs")
	local cacheKey = isBuff and "_buffCurve" or "_debuffCurve"
	
	if( self[cacheKey] ) then return self[cacheKey] end
	if( not C_CurveUtil or not C_CurveUtil.CreateColorCurve ) then return nil end

	local curve = C_CurveUtil.CreateColorCurve()
	-- Use Enum values if available to ensure correct mapping
	local E = Enum and Enum.AuraDispelType
	local noneID = (E and E.None) or 0
	local magicID = (E and E.Magic) or 1
	local curseID = (E and E.Curse) or 2
	local diseaseID = (E and E.Disease) or 3
	local poisonID = (E and E.Poison) or 4
	local bleedID = (E and E.Bleed) or 11

	if( curve.SetType and Enum and Enum.LuaCurveType and Enum.LuaCurveType.Step ) then
		curve:SetType(Enum.LuaCurveType.Step)
	end

	-- Hardcode standard colors
	local baseR, baseG, baseB
	if( isBuff ) then
		baseR, baseG, baseB = 0.6, 0.6, 0.6
	else
		baseR, baseG, baseB = 0.8, 0, 0 -- Red
	end
	
	-- Add points using the resolved IDs
	curve:AddPoint(noneID, CreateColor(baseR, baseG, baseB))
	curve:AddPoint(magicID, CreateColor(0.2, 0.6, 1))   -- Magic (Blue)
	curve:AddPoint(curseID, CreateColor(0.6, 0, 1))     -- Curse (Purple)
	curve:AddPoint(diseaseID, CreateColor(0.6, 0.4, 0)) -- Disease (Brown)
	curve:AddPoint(poisonID, CreateColor(0, 0.6, 0))    -- Poison (Green)
	curve:AddPoint(bleedID, CreateColor(baseR, baseG, baseB)) -- Bleed (Red)
	
	self[cacheKey] = curve
	return curve
end

function Auras:OnDisable(frame)
	frame:UnregisterAll(self)
	self:ClearBossDebuffs(frame)
end

-- Aura positioning code
-- Definitely some of the more unusual code I've done, not sure I really like this method
-- but it does allow more flexibility with how things are anchored without me having to hardcode the 10 different growth methods
local function load(text)
	local result, err = loadstring(text)
	if( err ) then
		error(err, 3)
		return nil
	end

	return result()
end

local positionData = setmetatable({}, {
	__index = function(tbl, index)
		local data = {}
		local columnGrowth = ShadowUF.Layout:GetColumnGrowth(index)
		local auraGrowth = ShadowUF.Layout:GetAuraGrowth(index)
		data.xMod = (columnGrowth == "RIGHT" or auraGrowth == "RIGHT") and 1 or -1
		data.yMod = (columnGrowth ~= "TOP" and auraGrowth ~= "TOP") and -1 or 1

		local auraX, colX, auraY, colY, xOffset, yOffset, initialXOffset, initialYOffset = 0, 0, 0, 0, "", "", "", ""
		if( columnGrowth == "LEFT" or columnGrowth == "RIGHT" ) then
			colX = 1
			xOffset = " + offset"
			initialXOffset = string.format(" + (%d * offset)", data.xMod)
			auraY = 3
			data.isSideGrowth = true
		elseif( columnGrowth == "TOP" or columnGrowth == "BOTTOM" ) then
			colY = 2
			yOffset = " + offset"
			initialYOffset = string.format(" + (%d * offset)", data.yMod)
			auraX = 2
		end

		data.initialAnchor = load(string.format([[return function(button, offset)
			button:ClearAllPoints()
			button:SetPoint(button.point, button.anchorTo, button.relativePoint, button.xOffset%s, button.yOffset%s)
			button.anchorOffset = offset
		end]], initialXOffset, initialYOffset))
		data.column = load(string.format([[return function(button, positionTo, offset)
			button:ClearAllPoints()
			button:SetPoint("%s", positionTo, "%s", %d * (%d%s), %d * (%d%s)) end
		]], ShadowUF.Layout:ReverseDirection(columnGrowth), columnGrowth, data.xMod, colX, xOffset, data.yMod, colY, yOffset))
		data.aura = load(string.format([[return function(button, positionTo)
			button:ClearAllPoints()
			button:SetPoint("%s", positionTo, "%s", %d, %d) end
		]], ShadowUF.Layout:ReverseDirection(auraGrowth), auraGrowth, data.xMod * auraX, data.yMod * auraY))

		tbl[index] = data
		return tbl[index]
	end,
})

local function positionButton(id,  group, config)
	local position = positionData[group.forcedAnchorPoint or config.anchorPoint]
	local button = group.buttons[id]
	button.isAuraAnchor = nil

	-- Alright, in order to find out where an aura group is going to be anchored to certain buttons need
	-- to be flagged as suitable anchors visually, this speeds it up because this data is cached and doesn't
	-- have to be recalculated unless auras are specifically changed
	if( id > 1 ) then
		if( position.isSideGrowth and id <= config.perRow ) then
			button.isAuraAnchor = true
		end

		if( id % config.perRow == 1 or config.perRow == 1 ) then
			position.column(button, group.buttons[id - config.perRow], 0)

			if( not position.isSideGrowth ) then
				button.isAuraAnchor = true
			end
		else
			position.aura(button, group.buttons[id - 1])
		end
	else
		button.isAuraAnchor = true
		button.point = ShadowUF.Layout:GetPoint(config.anchorPoint)
		button.relativePoint = ShadowUF.Layout:GetRelative(config.anchorPoint)
		button.xOffset = config.x + (position.xMod * ShadowUF.db.profile.backdrop.inset)
		button.yOffset = config.y + (position.yMod * ShadowUF.db.profile.backdrop.inset)
		button.anchorTo = group.anchorTo

		position.initialAnchor(button, 0)
	end
end


-- Fixed layout: grid-based wrapping (always perRow auras per row) with inter-row offset compensation
-- Adapted from v4.4.14 original behavior
local function positionAllButtonsFixed(group, config)
	local position = positionData[group.forcedAnchorPoint or config.anchorPoint]

	-- Pass 1: figure out which rows have scaled auras
	local columnID = 0
	for id = 1, group.totalAuras do
		local button = group.buttons[id]
		if( not button or not button:IsShown() ) then break end

		if( id % config.perRow == 1 or config.perRow == 1 ) then
			columnID = columnID + 1
			columnsHaveScale[columnID] = nil
		end

		if( not columnsHaveScale[columnID] and button.isSelfScaled ) then
			local size = math.ceil(button:GetSize() * button:GetScale())
			columnsHaveScale[columnID] = columnsHaveScale[columnID] and math.max(size, columnsHaveScale[columnID]) or size
		end
	end

	-- Pass 2: position with offset compensation between rows
	columnID = 1
	for id = 1, group.totalAuras do
		local button = group.buttons[id]
		if( not button or not button:IsShown() ) then break end

		button.isAuraAnchor = nil

		if( id > 1 ) then
			if( id % config.perRow == 1 or config.perRow == 1 ) then
				columnID = columnID + 1

				local anchorButton = group.buttons[id - config.perRow]
				local previousScale, currentScale = columnsHaveScale[columnID - 1], columnsHaveScale[columnID]
				local offset = 0
				-- Previous row has a scaled aura, and the button we are anchoring to is not scaled
				if( previousScale and not anchorButton.isSelfScaled ) then
					offset = (previousScale / 4)
				end

				-- Current row has a scaled aura, and the button isn't scaled
				if( currentScale and not button.isSelfScaled ) then
					offset = offset + (currentScale / 4)
				end

				-- Current button is scaled, previous anchor is not
				if( button.isSelfScaled and not anchorButton.isSelfScaled ) then
					offset = offset - (currentScale / 6)
				end

				-- At least one of them is not scaled
				if( ( not button.isSelfScaled or not anchorButton.isSelfScaled ) and offset > 0 ) then
					offset = offset + 1
				end

				position.column(button, anchorButton, math.ceil(offset))

				if( not position.isSideGrowth ) then
					button.isAuraAnchor = true
				end
			else
				position.aura(button, group.buttons[id - 1])

				if( position.isSideGrowth ) then
					button.isAuraAnchor = true
				end
			end
		else
			-- First button: adjust initial anchor if row has scaled auras
			local offset = 0
			if( columnsHaveScale[columnID] ) then
				offset = math.ceil(columnsHaveScale[columnID] / 8)
				if( button.isSelfScaled ) then
					offset = -(offset / 2)
				else
					offset = offset + 2
				end
			end

			button.isAuraAnchor = true
			button.point = ShadowUF.Layout:GetPoint(config.anchorPoint)
			button.relativePoint = ShadowUF.Layout:GetRelative(config.anchorPoint)
			button.xOffset = config.x + (position.xMod * ShadowUF.db.profile.backdrop.inset)
			button.yOffset = config.y + (position.yMod * ShadowUF.db.profile.backdrop.inset)
			button.anchorTo = group.anchorTo

			if( offset ~= button.anchorOffset ) then
				position.initialAnchor(button, offset)
			end
		end
	end
end

-- Dynamic layout: pixel-based flow wrapping when enlarged auras are present
-- Rows wrap based on accumulated effective width
local function positionAllButtonsDynamic(group, config)
	local position = positionData[group.forcedAnchorPoint or config.anchorPoint]
	local normalSize = config.size
	local maxRowWidth = config.perRow * normalSize

	local currentRowWidth = 0
	local rowFirst = nil
	local prevButton = nil

	for id = 1, group.totalAuras do
		local button = group.buttons[id]
		if( not button or not button:IsShown() ) then break end

		local effectiveWidth = normalSize * button:GetScale()
		local needsNewRow = (id > 1) and (currentRowWidth + effectiveWidth > maxRowWidth)

		button.isAuraAnchor = nil

		if( id == 1 ) then
			button.isAuraAnchor = true
			button.point = ShadowUF.Layout:GetPoint(config.anchorPoint)
			button.relativePoint = ShadowUF.Layout:GetRelative(config.anchorPoint)
			button.xOffset = config.x + (position.xMod * ShadowUF.db.profile.backdrop.inset)
			button.yOffset = config.y + (position.yMod * ShadowUF.db.profile.backdrop.inset)
			button.anchorTo = group.anchorTo
			position.initialAnchor(button, 0)
			rowFirst = button
			currentRowWidth = effectiveWidth
		elseif( needsNewRow ) then
			position.column(button, rowFirst, 0)
			if( not position.isSideGrowth ) then
				button.isAuraAnchor = true
			end
			rowFirst = button
			currentRowWidth = effectiveWidth
		else
			position.aura(button, prevButton)
			if( position.isSideGrowth and not rowFirst ) then
				button.isAuraAnchor = true
			end
			currentRowWidth = currentRowWidth + effectiveWidth
		end

		prevButton = button
	end
end

-- Dispatch to the appropriate layout function based on user setting
local function positionAllButtons(group, config)
	if( ShadowUF.db.profile.enlargeLayout ) then
		positionAllButtonsFixed(group, config)
	else
		positionAllButtonsDynamic(group, config)
	end
end

-- Aura button functions
-- Updates the X seconds left on aura tooltip while it's shown
local function updateTooltip(self)
	if( not GameTooltip:IsForbidden() and GameTooltip:IsOwned(self) ) then
		if( self.filter == "HELPFUL" ) then
			GameTooltip:SetUnitBuffByAuraInstanceID(self.unit, self.auraInstanceID, self.filter)
		elseif( self.filter == "HARMFUL" ) then
			GameTooltip:SetUnitDebuffByAuraInstanceID(self.unit, self.auraInstanceID, self.filter)
		else
			GameTooltip:SetUnitAuraByAuraInstanceID(self.unit, self.auraInstanceID, self.filter)
		end
	end
end

local function showTooltip(self)
	if( not ShadowUF.db.profile.locked ) then return end
	if( GameTooltip:IsForbidden() ) then return end
	if( ShadowUF.db.profile.tooltipCombat and InCombatLockdown() ) then return end

	GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
	if( self.filter == "TEMP" ) then
		GameTooltip:SetInventoryItem("player", self.auraID)
		self:SetScript("OnUpdate", nil)
	else
		if( self.filter == "HELPFUL" ) then
			GameTooltip:SetUnitBuffByAuraInstanceID(self.unit, self.auraInstanceID, self.filter)
		elseif( self.filter == "HARMFUL" ) then
			GameTooltip:SetUnitDebuffByAuraInstanceID(self.unit, self.auraInstanceID, self.filter)
		else
			GameTooltip:SetUnitAuraByAuraInstanceID(self.unit, self.auraInstanceID, self.filter)
		end
		
		self:SetScript("OnUpdate", updateTooltip)
	end
end

local function hideTooltip(self)
	self:SetScript("OnUpdate", nil)
	if not GameTooltip:IsForbidden() then
		GameTooltip:Hide()
	end
end

local function cancelAura(self, mouseButton)
	if( mouseButton ~= "RightButton" ) then return end
	if( InCombatLockdown() ) then return end
	if( not self.filter or not self.filter:find("HELPFUL") ) then return end
	if( not self.unit or not UnitIsUnit(self.unit, "player") ) then return end
	
	if( self.auraInstanceID ) then
		local auraData = C_UnitAuras.GetAuraDataByAuraInstanceID("player", self.auraInstanceID)
		if( auraData and auraData.name ) then
			CancelSpellByName(auraData.name)
		end
	end
end

local function updateButton(id, group, config)
	local button = group.buttons[id]
	if( not button ) then
		group.buttons[id] = CreateFrame("Button", nil, group)

		button = group.buttons[id]
		button:SetScript("OnEnter", showTooltip)
		button:SetScript("OnLeave", hideTooltip)
		button:RegisterForClicks("RightButtonUp")

		button.cooldown = CreateFrame("Cooldown", group.parent:GetName() .. "Aura" .. group.type .. id .. "Cooldown", button, "CooldownFrameTemplate")
		button.cooldown:SetAllPoints(button)
		button.cooldown:SetReverse(true)
		button.cooldown:SetDrawEdge(false)
		button.cooldown:SetDrawSwipe(true)
		button.cooldown:SetSwipeColor(0, 0, 0, 0.8)
		button.cooldown:Hide()

		button.stack = button:CreateFontString(nil, "OVERLAY")
		button.stack:SetFont("Interface\\AddOns\\ShadowedUnitFrames\\media\\fonts\\Myriad Condensed Web.ttf", 10, "OUTLINE")
		button.stack:SetShadowColor(0, 0, 0, 1.0)
		button.stack:SetShadowOffset(0.50, -0.50)
		button.stack:SetHeight(1)
		button.stack:SetWidth(1)
		button.stack:SetAllPoints(button)
		button.stack:SetJustifyV("BOTTOM")
		button.stack:SetJustifyH("RIGHT")

		button.border = button:CreateTexture(nil, "OVERLAY")
		button.border:SetPoint("CENTER", button)

		button.icon = button:CreateTexture(nil, "BACKGROUND")
		button.icon:SetAllPoints(button)
		button.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	end

	if( ShadowUF.db.profile.auras.borderType == "" ) then
		button.border:Hide()
	elseif( ShadowUF.db.profile.auras.borderType == "blizzard" ) then
		button.border:SetTexture("Interface\\Buttons\\UI-Debuff-Overlays")
		button.border:SetTexCoord(0.296875, 0.5703125, 0, 0.515625)
		button.border:Show()
	else
		button.border:SetTexture("Interface\\AddOns\\ShadowedUnitFrames\\media\\textures\\border-" .. ShadowUF.db.profile.auras.borderType)
		button.border:SetTexCoord(0, 1, 0, 1)
		button.border:Show()
	end

	-- Set the button sizing
	-- Per-frame override for Blizzard Cooldown Count, fallback to global
	local hideCC = config.disableBlizzardCC
	if hideCC == nil then hideCC = ShadowUF.db.profile.blizzardcc end
	button.cooldown:SetHideCountdownNumbers(hideCC)
	button:SetHeight(config.size)
	button:SetWidth(config.size)
	button.border:SetHeight(config.size + 1)
	button.border:SetWidth(config.size + 1)
	button.stack:SetFont("Interface\\AddOns\\ShadowedUnitFrames\\media\\fonts\\Myriad Condensed Web.ttf", math.floor((config.size * 0.60) + 0.5), "OUTLINE")

	-- Click-through: disable mouse clicks but keep mouse motion (tooltips)
	if not InCombatLockdown() then
		button:SetMouseClickEnabled(not config.clickThrough)
	end

	if not config.clickThrough then
		button:SetScript("OnClick", cancelAura)
	else
		button:SetScript("OnClick", nil)
	end
	button.parent = group.parent
	button:ClearAllPoints()
	button:Hide()

	-- Position the button quickly
	positionButton(id, group, config)
	
	-- Update Cooldown Text Styling
	Auras:UpdateCooldownText(button, config)
end

function Auras:UpdateCooldownText(button, config)
	if( not button or not button.cooldown ) then return end

	-- Try to get the cooldown text region if we haven't already
	if( not button.cooldown.timerText ) then
		for _, region in pairs({button.cooldown:GetRegions()}) do
			if( region:GetObjectType() == "FontString" ) then
				button.cooldown.timerText = region
				break
			end
		end
	end

	local text = button.cooldown.timerText
	if( text ) then
		-- Apply Font Settings: per-frame override → global aura font → general font
		local fontDetails = ShadowUF.db.profile.font
		local font = SML:Fetch("font", (config and config.cooldownFont) or fontDetails.cooldownName or fontDetails.name)
		local size = (config and config.cooldownFontSize) or fontDetails.cooldownSize or fontDetails.size
		local outline = (config and config.cooldownFontOutline) or fontDetails.cooldownOutline
		if( outline == nil ) then outline = fontDetails.extra end

		text:SetFont(font, size, outline)

		-- Apply Color: per-frame override → global aura font color
		local color = (config and config.cooldownFontColor) or fontDetails.cooldownColor
		if( color ) then
			text:SetTextColor(color.r, color.g, color.b, color.a or 1)
		else
			text:SetTextColor(1, 1, 1, 1)
		end
	end
end

-- Let the mover access this for creating aura things
Auras.updateButton = updateButton

-- Create an aura anchor as well as the buttons to contain it
local function updateGroup(self, groupKey, config, reverseConfig)
	self.auras[groupKey] = self.auras[groupKey] or CreateFrame("Frame", nil, self.highFrame)

	local group = self.auras[groupKey]
	group.buttons = group.buttons or {}

	group.maxAuras = config.perRow * config.maxRows
	group.totalAuras = 0
	group.temporaryEnchants = 0
	group.lastTemporary = 0
	group.groupKey = groupKey
	group.parent = self
	group.anchorTo = self
	group:SetFrameLevel(self.highFrame:GetFrameLevel() + 1)
	group:Show()

	-- Temp enchants for any player buffs frame with temporary enabled
	if( self.unit == "player" and config.temporary ) then
		mainHand.time = 0
		mainHand.has = false
		offHand.time = 0
		offHand.has = false
		timeElapsed = ShadowUF.Performance:GetRate("tempEnchantScan") -- Force immediate scan on next OnUpdate
		group:SetScript("OnUpdate", tempEnchantScan)
	else
		group:SetScript("OnUpdate", nil)
	end

	-- Extract base type from groupKey
	local baseType = groupKey:match("^(%a+)%d*$") or groupKey
	group.type = baseType
	group.filter = baseType == "buffs" and "HELPFUL" or baseType == "debuffs" and "HARMFUL" or ""

	for id, button in pairs(group.buttons) do
		updateButton(id, group, config)
	end
end

-- Update aura positions based off of configuration
-- Support multiple frames per type
function Auras:OnLayoutApplied(frame, config)
	-- Hide all existing aura buttons first
	if( frame.auras ) then
		for auraType, _ in pairs({buffs = true, debuffs = true}) do
			for i = 1, 6 do
				local groupKey = auraType .. i
				if( frame.auras[groupKey] and frame.auras[groupKey].buttons ) then
					for _, button in pairs(frame.auras[groupKey].buttons) do
						button:Hide()
					end
				end
			end
		end
	end

	if( not frame.visibility.auras ) then return end

	-- Setup enabled aura frames
	for _, auraType in pairs({"buffs", "debuffs"}) do
		local typeConfig = config.auras[auraType]
		if( typeConfig ) then
			for i = 1, 6 do
				local frameConfig = typeConfig[i]
				if( frameConfig and frameConfig.enabled ) then
					local groupKey = auraType .. i
					-- Create the unique frame for this slot
					updateGroup(frame, groupKey, frameConfig, nil)
					-- Store the aura type for scan()
					frame.auras[groupKey].auraType = auraType
					frame.auras[groupKey].frameIndex = i
					frame.auras[groupKey].filterType = frameConfig.filter
				end
			end
		end
	end

	-- Setup anchor-to-anchor logic
	frame.auras.anchorPairs = {}

	for i = 1, 6 do
		local buffsConfig = config.auras.buffs and config.auras.buffs[i]
		local debuffsConfig = config.auras.debuffs and config.auras.debuffs[i]
		local buffsGroup = frame.auras["buffs" .. i]
		local debuffsGroup = frame.auras["debuffs" .. i]

		-- Clear skipScan on both groups (may have been set by a previous layout)
		if( buffsGroup ) then buffsGroup.skipScan = nil end
		if( debuffsGroup ) then debuffsGroup.skipScan = nil end

		if( buffsConfig and buffsConfig.enabled and debuffsConfig and debuffsConfig.enabled and buffsGroup and debuffsGroup ) then
			local anchorOnConfig, parentGroup, childGroup, parentConfig, childConfig
			if( buffsConfig.anchorOn ) then
				anchorOnConfig = buffsConfig
				parentGroup, childGroup = debuffsGroup, buffsGroup
				parentConfig, childConfig = debuffsConfig, buffsConfig
			elseif( debuffsConfig.anchorOn ) then
				anchorOnConfig = debuffsConfig
				parentGroup, childGroup = buffsGroup, debuffsGroup
				parentConfig, childConfig = buffsConfig, debuffsConfig
			end

			if( anchorOnConfig ) then
				local isSequential = (anchorOnConfig.anchorMode == "SEQUENTIAL")
				frame.auras.anchorPairs[i] = {
					parent = parentGroup,
					child = childGroup,
					parentConfig = parentConfig,
					childConfig = childConfig,
					sequential = isSequential,
				}
				childGroup.forcedAnchorPoint = parentConfig.anchorPoint

				if( isSequential ) then
					-- Sequential mode: child scans into parent group, expand parent capacity
					parentGroup.maxAuras = parentGroup.maxAuras + childGroup.maxAuras
					childGroup.skipScan = true
				end
			end
		end
	end

	self:UpdateFilter(frame)
	
	-- Setup Boss Debuffs if enabled
	if config.auras.bossDebuffs and config.auras.bossDebuffs.enabled then
		self:SetupBossDebuffs(frame, config.auras.bossDebuffs)
	else
		self:ClearBossDebuffs(frame)
	end
end

-- Private Auras (Boss Debuffs) support
-- Only works with stable unit tokens (player, party, raid, maintank, mainassist)
local AddPrivateAuraAnchor = C_UnitAuras and C_UnitAuras.AddPrivateAuraAnchor
local RemovePrivateAuraAnchor = C_UnitAuras and C_UnitAuras.RemovePrivateAuraAnchor
local privateAuraUnits = {
	player = true,
	party = true,
	raid = true,
	maintank = true,
	mainassist = true,
}

function Auras:ClearBossDebuffs(frame)
	if not frame.bossDebuffs then return end

	local anchors = frame.bossDebuffs.anchorIDs
	if anchors and RemovePrivateAuraAnchor then
		for i = 1, #anchors do
			if anchors[i] then
				RemovePrivateAuraAnchor(anchors[i])
				anchors[i] = nil
			end
		end
	end

	-- Hide config mode placeholders
	if frame.bossDebuffs.testButtons then
		for i = 1, #frame.bossDebuffs.testButtons do
			frame.bossDebuffs.testButtons[i]:Hide()
		end
	end

	if frame.bossDebuffs.container then
		frame.bossDebuffs.container:Hide()
	end
	frame.bossDebuffs.unit = nil
end

function Auras:SetupBossDebuffs(frame, config)
	if not privateAuraUnits[frame.unitType] then
		self:ClearBossDebuffs(frame)
		return
	end

	-- Create container even without AddPrivateAuraAnchor so config mode placeholders work
	if not frame.bossDebuffs then
		frame.bossDebuffs = {}
		frame.bossDebuffs.anchorIDs = {}
		frame.bossDebuffs.testButtons = {}
		frame.bossDebuffs.container = CreateFrame("Frame", nil, frame.highFrame)
	end

	local container = frame.bossDebuffs.container
	local perRow = config.perRow or 3
	local maxRows = config.maxRows or 1
	local maxAuras = perRow * maxRows
	local iconSize = config.size or 32
	local spacing = 2

	-- Calculate total size
	local totalWidth = (iconSize * perRow) + (spacing * (perRow - 1))
	local totalHeight = (iconSize * maxRows) + (spacing * (maxRows - 1))

	container:SetSize(totalWidth, totalHeight)
	container:ClearAllPoints()

	-- Position based on anchorPoint
	local point = ShadowUF.Layout:GetPoint(config.anchorPoint)
	local relativePoint = ShadowUF.Layout:GetRelative(config.anchorPoint)
	container:SetPoint(point, frame, relativePoint, config.x or 0, config.y or 0)
	container:SetFrameLevel(frame.highFrame:GetFrameLevel() + 2)
	container:Show()

	-- Store config for update
	frame.bossDebuffs.config = config
	frame.bossDebuffs.maxAuras = maxAuras
	frame.bossDebuffs.perRow = perRow
	frame.bossDebuffs.iconSize = iconSize
	frame.bossDebuffs.spacing = spacing

	-- Force update
	frame.bossDebuffs.unit = nil
	Auras:UpdateBossDebuffs(frame)
end

function Auras:UpdateBossDebuffs(frame)
	if not frame.bossDebuffs or not frame.bossDebuffs.container then return end

	if not privateAuraUnits[frame.unitType] then return end

	-- Config mode: show placeholders (same pattern as scanConfigMode for regular auras)
	if frame.configMode then
		self:ShowBossDebuffsPlaceholders(frame)
		return
	end

	-- Hide placeholders when leaving config mode
	if frame.bossDebuffs.testButtons then
		for i = 1, #frame.bossDebuffs.testButtons do
			frame.bossDebuffs.testButtons[i]:Hide()
		end
	end

	if not AddPrivateAuraAnchor then return end

	local unit = frame.unit
	if not unit then
		self:ClearBossDebuffs(frame)
		return
	end

	if frame.bossDebuffs.unit == unit then return end

	-- Clear old anchors
	local anchors = frame.bossDebuffs.anchorIDs
	if RemovePrivateAuraAnchor then
		for i = 1, #anchors do
			if anchors[i] then
				RemovePrivateAuraAnchor(anchors[i])
				anchors[i] = nil
			end
		end
	end

	local config = frame.bossDebuffs.config
	local container = frame.bossDebuffs.container
	local maxAuras = frame.bossDebuffs.maxAuras
	local perRow = frame.bossDebuffs.perRow
	local iconSize = frame.bossDebuffs.iconSize
	local spacing = frame.bossDebuffs.spacing

	-- Create anchor points for Private Auras
	for i = 1, maxAuras do
		local row = math.floor((i - 1) / perRow)
		local col = (i - 1) % perRow
		local xOffset = col * (iconSize + spacing)
		local yOffset = -row * (iconSize + spacing)

		local auraAnchor = {
			unitToken = unit,
			auraIndex = i,
			parent = container,
			showCountdownFrame = config.showCooldown ~= false,
			showCountdownNumbers = config.showCooldownNumbers ~= false,
			isContainer = false,
			iconInfo = {
				iconWidth = iconSize,
				iconHeight = iconSize,
				borderScale = iconSize / 18,
				iconAnchor = {
					point = "TOPLEFT",
					relativeTo = container,
					relativePoint = "TOPLEFT",
					offsetX = xOffset,
					offsetY = yOffset,
				},
			},
		}

		local anchorID = AddPrivateAuraAnchor(auraAnchor)
		if anchorID then
			anchors[i] = anchorID
		end
	end

	frame.bossDebuffs.unit = unit
end

-- Config mode placeholders for Private Auras
-- Same visual structure as scanConfigMode buttons (icon, border, cooldown, stack)
-- Grid positioning matches the real AddPrivateAuraAnchor layout
local bossTestTextures = {
	"Interface\\Icons\\Spell_Shadow_AuraOfDarkness",
	"Interface\\Icons\\Spell_Shadow_CurseOfTongues",
	"Interface\\Icons\\Spell_Fire_Incinerate",
	"Interface\\Icons\\Spell_Shadow_UnholyFrenzy",
	"Interface\\Icons\\Spell_Nature_Earthquake",
	"Interface\\Icons\\Spell_Fire_FelFlameRing",
}

function Auras:ShowBossDebuffsPlaceholders(frame)
	local bd = frame.bossDebuffs
	local container = bd.container
	local maxAuras = bd.maxAuras
	local perRow = bd.perRow
	local iconSize = bd.iconSize
	local spacing = bd.spacing
	local config = bd.config

	for i = 1, maxAuras do
		local button = bd.testButtons[i]
		if not button then
			-- Same structure as updateButton: icon, border, cooldown, stack
			button = CreateFrame("Button", nil, container)

			button.cooldown = CreateFrame("Cooldown", (frame:GetName() or "SUFBossAura") .. "BossAura" .. i .. "Cooldown", button, "CooldownFrameTemplate")
			button.cooldown:SetAllPoints(button)
			button.cooldown:SetReverse(true)
			button.cooldown:SetDrawEdge(false)
			button.cooldown:SetDrawSwipe(true)
			button.cooldown:SetSwipeColor(0, 0, 0, 0.8)
			button.cooldown:Hide()

			button.stack = button:CreateFontString(nil, "OVERLAY")
			button.stack:SetFont("Interface\\AddOns\\ShadowedUnitFrames\\media\\fonts\\Myriad Condensed Web.ttf", 10, "OUTLINE")
			button.stack:SetShadowColor(0, 0, 0, 1.0)
			button.stack:SetShadowOffset(0.50, -0.50)
			button.stack:SetHeight(1)
			button.stack:SetWidth(1)
			button.stack:SetAllPoints(button)
			button.stack:SetJustifyV("BOTTOM")
			button.stack:SetJustifyH("RIGHT")

			button.border = button:CreateTexture(nil, "OVERLAY")
			button.border:SetPoint("CENTER", button)

			button.icon = button:CreateTexture(nil, "BACKGROUND")
			button.icon:SetAllPoints(button)
			button.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

			bd.testButtons[i] = button
		end

		-- Sizing (same as updateButton)
		button:SetSize(iconSize, iconSize)
		button.border:SetSize(iconSize + 1, iconSize + 1)
		button.stack:SetFont("Interface\\AddOns\\ShadowedUnitFrames\\media\\fonts\\Myriad Condensed Web.ttf", math.floor((iconSize * 0.60) + 0.5), "OUTLINE")
		button.cooldown:SetHideCountdownNumbers(ShadowUF.db.profile.blizzardcc)

		-- Grid position (matches AddPrivateAuraAnchor layout)
		local row = math.floor((i - 1) / perRow)
		local col = (i - 1) % perRow
		button:ClearAllPoints()
		button:SetPoint("TOPLEFT", container, "TOPLEFT", col * (iconSize + spacing), -row * (iconSize + spacing))

		-- Test texture
		local texIndex = ((i - 1) % #bossTestTextures) + 1
		button.icon:SetTexture(bossTestTextures[texIndex])

		-- Border (same logic as updateButton)
		if ShadowUF.db.profile.auras.borderType == "" then
			button.border:Hide()
		elseif ShadowUF.db.profile.auras.borderType == "blizzard" then
			button.border:SetTexture("Interface\\Buttons\\UI-Debuff-Overlays")
			button.border:SetTexCoord(0.296875, 0.5703125, 0, 0.515625)
			button.border:Show()
		else
			button.border:SetTexture("Interface\\AddOns\\ShadowedUnitFrames\\media\\textures\\border-" .. ShadowUF.db.profile.auras.borderType)
			button.border:SetTexCoord(0, 1, 0, 1)
			button.border:Show()
		end
		button.border:SetVertexColor(0.80, 0.20, 0.80)

		-- Test cooldown
		if config.showCooldown ~= false then
			button.cooldown:SetCooldown(GetTime() - (i * 15), 300)
			button.cooldown:Show()
		else
			button.cooldown:Hide()
		end

		-- Test stack (some with stacks like scanConfigMode)
		local testStacks = (i % 3 == 0) and math.random(2, 5) or 0
		button.stack:SetText(testStacks > 0 and testStacks or "")

		Auras:UpdateCooldownText(button)
		button:Show()
	end

	-- Hide extra buttons from previous config
	for i = maxAuras + 1, #bd.testButtons do
		bd.testButtons[i]:Hide()
	end
end

-- Temporary enchant support
local timeElapsed = 0
local function updateTemporaryEnchant(frame, slot, tempData, hasEnchant, enchantId, timeLeft, charges)
	charges = charges or 0

	-- Detect new or changed enchant (different id, reapply with higher time, or first appearance)
	local isNewEnchant = not tempData.has or tempData.enchantId ~= enchantId or timeLeft > tempData.time

	-- For the same ongoing enchant, skip if less than 750ms elapsed (only charges/icon could differ)
	if( not isNewEnchant and ( tempData.time - timeLeft ) < 750 ) then return false end

	-- Record start time only on new enchant detection
	if( isNewEnchant ) then
		tempData.startTime = GetTime()
	end

	tempData.has = hasEnchant
	tempData.time = timeLeft
	tempData.charges = charges
	tempData.enchantId = enchantId

	local config = ShadowUF.db.profile.units[frame.parent.unitType].auras[frame.type][frame.frameIndex]

	-- Create any buttons we need
	if( #(frame.buttons) < frame.temporaryEnchants ) then
		updateButton(frame.temporaryEnchants, frame, config)
	end

	local button = frame.buttons[frame.temporaryEnchants]

	-- Temp enchants are always player auras — respect enlarge setting
	if( config.enlarge and config.enlarge.PLAYER ) then
		button.isSelfScaled = true
		button:SetScale(config.selfScale or 1.30)
	else
		button.isSelfScaled = nil
		button:SetScale(1)
	end

	-- Ensure correct positioning for this slot
	positionButton(frame.temporaryEnchants, frame, config)

	-- Purple border
	button.border:SetVertexColor(0.50, 0, 0.50)

	-- Set cooldown only once per enchant — the CooldownFrameTemplate handles the countdown natively.
	if( isNewEnchant ) then
		if( not ShadowUF.db.profile.auras.disableCooldown ) then
			button.cooldown:SetCooldown(tempData.startTime, timeLeft / 1000)
			button.cooldown:Show()
		else
			button.cooldown:Hide()
		end
	end

	-- Size it
	button:SetHeight(config.size)
	button:SetWidth(config.size)
	button.border:SetHeight(config.size + 1)
	button.border:SetWidth(config.size + 1)

	-- Stack + icon + show!
	button.auraID = slot
	button.filter = "TEMP"
	button.unit = nil
	button.icon:SetTexture(GetInventoryItemTexture("player", slot))
	button.stack:SetText(charges > 1 and charges or "")
	button:Show()
end

-- Unfortunately, temporary enchants have basically no support beyond hacks. So we will hack!
tempEnchantScan = function(self, elapsed)
	if( self.parent.unit == self.parent.vehicleUnit and self.lastTemporary > 0 ) then
		mainHand.has = false
		offHand.has = false

		self.temporaryEnchants = 0
		self.lastTemporary = 0

		Auras:Update(self.parent)
		return
	end

	timeElapsed = timeElapsed + elapsed
	local tempEnchantRate = ShadowUF.Performance:GetRate("tempEnchantScan")
	if( timeElapsed < tempEnchantRate ) then return end
	timeElapsed = timeElapsed - tempEnchantRate


	local hasMain, mainTimeLeft, mainCharges, mainEnchantId, hasOff, offTimeLeft, offCharges, offEnchantId = GetWeaponEnchantInfo()
	self.temporaryEnchants = 0

	if( hasMain ) then
		self.temporaryEnchants = self.temporaryEnchants + 1
		updateTemporaryEnchant(self, 16, mainHand, hasMain, mainEnchantId, mainTimeLeft or 0, mainCharges)
	end

	mainHand.has = hasMain

	if( hasOff and self.temporaryEnchants < self.maxAuras ) then
		self.temporaryEnchants = self.temporaryEnchants + 1
		updateTemporaryEnchant(self, 17, offHand, hasOff, offEnchantId, offTimeLeft or 0, offCharges)
	end

	offHand.has = hasOff

	-- Update if totals changed
	if( self.lastTemporary ~= self.temporaryEnchants ) then
		self.lastTemporary = self.temporaryEnchants
		Auras:Update(self.parent)
	end
end

-- Force a fresh rescan when a weapon enchant changes (applied, removed, or replaced)
function Auras:OnWeaponEnchantChanged(frame)
	mainHand.has = false
	mainHand.time = 0
	mainHand.enchantId = nil
	offHand.has = false
	offHand.time = 0
	offHand.enchantId = nil
	timeElapsed = ShadowUF.Performance:GetRate("tempEnchantScan")
	self:Update(frame)
end

-- Zone-based aura filtering (blacklist/whitelist per zone + unit type)
local filterDefault = {}
function Auras:UpdateFilter(frame)
	if not frame.auras then return end
	local zone = select(2, IsInInstance()) or "none"
	if( zone == "scenario" ) then zone = "party" end
	if( zone == "interior" ) then zone = "neighborhood" end

	local white = ShadowUF.db.profile.filters.zonewhite[zone .. frame.unitType]
	local black = ShadowUF.db.profile.filters.zoneblack[zone .. frame.unitType]
	frame.auras.whitelist = white and ShadowUF.db.profile.filters.whitelists[white] or filterDefault
	frame.auras.blacklist = black and ShadowUF.db.profile.filters.blacklists[black] or filterDefault
end



-- 12.0: categorizeAura function removed - filtering is now done via API filters directly

local function renderAura(parent, frame, type, config, displayConfig, index, filter, isFriendly, curable, name, texture, count, auraType, durationObject, caster, isRemovable, nameplateShowPersonal, spellID, canApplyAura, isPlayerAura, auraInstanceID)

	-- Create any buttons we need
	frame.totalAuras = frame.totalAuras + 1
	if( #(frame.buttons) < frame.totalAuras ) then
		-- Get the correct config for this frame
		local unitConfig = ShadowUF.db.profile.units[frame.parent.unitType]
		local auraConfig = unitConfig.auras[frame.type]
		local frameIndex = frame.frameIndex or 1
		local frameConfig = auraConfig and auraConfig[frameIndex] or config
		updateButton(frame.totalAuras, frame, frameConfig)
	end

	-- Show debuff border, or a special colored border if it's stealable
	local button = frame.buttons[frame.totalAuras]
	if( isRemovable and not config.disableRemovableColor ) then
		button.border:SetVertexColor(ShadowUF.db.profile.auraColors.removable.r, ShadowUF.db.profile.auraColors.removable.g, ShadowUF.db.profile.auraColors.removable.b)
	else
		local curve = C_UnitAuras.GetAuraDispelTypeColor and C_CurveUtil and Auras:GetDispelColorCurve(type)
		if( curve ) then
			local color = C_UnitAuras.GetAuraDispelTypeColor(frame.parent.unit, auraInstanceID, curve)
			button.border:SetVertexColorFromBoolean(true, color, color)
		else
			if( type == "buffs" ) then
				button.border:SetVertexColor(0.6, 0.6, 0.6)
			else
				button.border:SetVertexColor(0.8, 0, 0)
			end
		end
	end

	-- Show the cooldown ring
	-- 12.0: Simplified - always show timers if enabled (ALL) or for player auras (PLAYER)
	if( not ShadowUF.db.profile.auras.disableCooldown and durationObject and ( config.timers.ALL or ( isPlayerAura and config.timers.PLAYER ) ) ) then
		local durationInfo = C_UnitAuras.GetAuraDuration(frame.parent.unit, auraInstanceID)
		if( durationInfo ) then
			button.cooldown:SetCooldownFromDurationObject(durationInfo)
			button.cooldown:Show()
		else
			button.cooldown:Hide()
		end
	else
		button.cooldown:Hide()
	end

	-- Size it
	button:SetHeight(config.size)
	button:SetWidth(config.size)
	button.border:SetHeight(config.size + 1)
	button.border:SetWidth(config.size + 1)

	-- Scale player auras if enlarge.PLAYER is enabled
	if isPlayerAura and config.enlarge and config.enlarge.PLAYER then
		button.isSelfScaled = true
		button:SetScale(config.selfScale or 1.30)
	else
		button.isSelfScaled = nil
		button:SetScale(1)
	end

	-- Stack + icon + show!
	button.auraID = index
	button.auraInstanceID = auraInstanceID
	button.filter = filter
	button.unit = frame.parent.unit
	button.icon:SetTexture(texture)
	
	-- Stack count
	if( button.stack ) then
		button.stack:SetText(C_UnitAuras.GetAuraApplicationDisplayCount(frame.parent.unit, auraInstanceID, 2))
		button.stack:Show()
	end
	
	button:Show()
end


-- Generate test auras for config mode preview
local function scanConfigMode(parent, frame, type, config, displayConfig, filter)
	local testCount = config.perRow * config.maxRows
	local isBuff = (type == "buffs")
	
	for i = 1, testCount do
		local mod = i % 5
		local auraType = mod == 0 and "Magic" or mod == 1 and "Curse" or mod == 2 and "Poison" or mod == 3 and "Disease" or ""
		
		-- Create test data
		local name = ShadowUF.L["Test Aura"]
		local texture = isBuff and "Interface\\Icons\\Spell_Nature_Rejuvenation" or "Interface\\Icons\\Ability_DualWield"
		local count = i % 3 == 0 and math.random(1, 5) or 0
		local isPlayerAura = i % 2 == 0
		local isRemovable = (type == "debuffs" and i % 3 == 0) or (type == "buffs" and i % 4 == 0)
		local spellID = 1000 + i
		local auraInstanceID = i
		
		-- Create any buttons we need
		frame.totalAuras = frame.totalAuras + 1
		if( #(frame.buttons) < frame.totalAuras ) then
			updateButton(frame.totalAuras, frame, config)
		end
		
		local button = frame.buttons[frame.totalAuras]
		
		-- Set border color based on aura type
		if( isRemovable and not isBuff and not config.disableRemovableColor ) then
			button.border:SetVertexColor(ShadowUF.db.profile.auraColors.removable.r, ShadowUF.db.profile.auraColors.removable.g, ShadowUF.db.profile.auraColors.removable.b)
		elseif( auraType == "Magic" ) then
			button.border:SetVertexColor(0.2, 0.6, 1)
		elseif( auraType == "Curse" ) then
			button.border:SetVertexColor(0.6, 0, 1)
		elseif( auraType == "Disease" ) then
			button.border:SetVertexColor(0.6, 0.4, 0)
		elseif( auraType == "Poison" ) then
			button.border:SetVertexColor(0, 0.6, 0)
		elseif( isBuff ) then
			button.border:SetVertexColor(0.6, 0.6, 0.6)
		else
			button.border:SetVertexColor(0.8, 0, 0)
		end
		
		-- Show cooldown for test
		if( not ShadowUF.db.profile.auras.disableCooldown and ( config.timers.ALL or ( isPlayerAura and config.timers.PLAYER ) ) ) then
			local duration = 300
			local startTime = GetTime() - (i * 20)
			button.cooldown:SetCooldown(startTime, duration)
			button.cooldown:Show()
		else
			button.cooldown:Hide()
		end
		
		-- Size it
		button:SetHeight(config.size)
		button:SetWidth(config.size)
		button.border:SetHeight(config.size + 1)
		button.border:SetWidth(config.size + 1)

		-- Scale player auras in config mode
		if isPlayerAura and config.enlarge and config.enlarge.PLAYER then
			button.isSelfScaled = true
			button:SetScale(config.selfScale or 1.30)
		else
			button.isSelfScaled = nil
			button:SetScale(1)
		end

		-- Set button properties
		button.auraID = i
		button.auraInstanceID = auraInstanceID
		button.filter = filter
		button.unit = frame.parent.unit
		button.icon:SetTexture(texture)
		
		-- Stack count
		if( button.stack ) then
			button.stack:SetText(count > 0 and count or "")
			button.stack:Show()
		end
		
		button:Show()
		
		if( frame.totalAuras >= frame.maxAuras ) then break end
	end
	
	for i=frame.totalAuras + 1, #(frame.buttons) do frame.buttons[i]:Hide() end
end

-- Scan for auras
-- Helper: process a single auraData and call renderAura
local function processAura(parent, frame, type, config, displayConfig, filter, unit, isFriendly, curable, index, auraData)
	local name = auraData.name
	local texture = auraData.icon
	local count = auraData.applications
	local durationObject = auraData
	local filterStrings = (type == "debuffs") and FILTER_STRINGS.HARMFUL or FILTER_STRINGS.HELPFUL

	local isPlayerAura = (config.filter == "PLAYER") or
		not C_UnitAuras.IsAuraFilteredOutByInstanceID(unit, auraData.auraInstanceID, filterStrings.PLAYER)

	local isRaid = (config.filter == "RAID") or
		not C_UnitAuras.IsAuraFilteredOutByInstanceID(unit, auraData.auraInstanceID, filterStrings.RAID)

	-- Removable = dispellable debuffs on friendlies OR stealable/purgeable buffs on enemies
	local canRemove = (type == "debuffs" and isFriendly) or (type == "buffs" and not isFriendly)
	local isRemovable = canRemove and not C_UnitAuras.IsAuraFilteredOutByInstanceID(unit, auraData.auraInstanceID, filterStrings.RAID_PLAYER_DISPELLABLE)

	local canApplyAura = (type == "buffs") and isRaid
	local caster = isPlayerAura and "player" or nil
	local rawSpellId = auraData.spellId
	local isSecret = issecretvalue and issecretvalue(rawSpellId)
	local spellID = isSecret and 0 or (rawSpellId or 0)
	local auraType = auraData.dispelName

	-- Blacklist/whitelist check (zone-based, non-secret spells only)
	local whitelist = parent.whitelist
	local blacklist = parent.blacklist
	if config.useFilter and not isSecret and (whitelist or blacklist) then
		local spellStr = tostring(spellID)
		if whitelist[type] and not whitelist[spellID] and not whitelist[spellStr] then
			return
		end
		if blacklist[type] and (blacklist[spellID] or blacklist[spellStr]) then
			return
		end
	end

	renderAura(parent, frame, type, config, displayConfig, index, filter, isFriendly, curable, name, texture, count, auraType, durationObject, caster, isRemovable, auraData.nameplateShowPersonal, spellID, canApplyAura, isPlayerAura, auraData.auraInstanceID)
end

local function scan(parent, frame, type, config, displayConfig, filter)
	if( frame.totalAuras >= frame.maxAuras or not config.enabled ) then return end

	-- Config mode: show test auras
	if( frame.parent.configMode ) then
		return scanConfigMode(parent, frame, type, config, displayConfig, filter)
	end

	if not frame.parent.unit then return end
	local unit = frame.parent.unit

	-- UnitIsFriend=true during duels, UnitIsEnemy=false for neutrals
	-- Combine both: true only for actual friendlies (not neutrals, not duel targets)
	local isEnemy = UnitIsEnemy(unit, "player")
	local isFriendly = UnitIsFriend(unit, "player") and not isEnemy
	local curable = (isFriendly and type == "debuffs")

	-- 12.0: All aura APIs use UnitTokenRestrictedForAddOns which blocks compound unit tokens
	-- (boss1target, etc.) except "targettarget" & focustarget which are explicitly exempted.
	-- pcall to silently skip unsupported units instead of throwing errors.
	_scanUnit, _scanFilter = unit, filter
	local ok, slots = pcall(_safeGetAuraSlots)
	if( not ok ) then
		for i = frame.totalAuras + 1, #(frame.buttons) do frame.buttons[i]:Hide() end
		return
	end

	-- Index 1 is continuation token, slots start at 2
	for i = 2, #slots do
		local index = slots[i]
		local auraData = C_UnitAuras.GetAuraDataBySlot(unit, index)
		if( auraData ) then
			processAura(parent, frame, type, config, displayConfig, filter, unit, isFriendly, curable, i - 1, auraData)
		end
		if( frame.totalAuras >= frame.maxAuras ) then break end
	end

	for i=frame.totalAuras + 1, #(frame.buttons) do frame.buttons[i]:Hide() end
end

Auras.scan = scan

-- Read Blizzard-filtered auraInstanceIDs directly from Blizzard frame objects.
-- Returns a list of IDs, empty table if Blizzard has data but nothing to show, or nil if unavailable.
local function getBlizzardAuraIDs(unit, auraType)
	local ids = {}
	local typeKey = (auraType == "buffs")

	-- Target and Focus, read from PriorityTable
	local directFrames = { target = TargetFrame, focus = FocusFrame }
	local blizFrame = directFrames[unit]
	if blizFrame then
		local tbl = typeKey and blizFrame.activeBuffs or blizFrame.activeDebuffs
		if tbl then
			tbl:Iterate(function(id)
				ids[#ids + 1] = id
				return false
			end)
		end
		return tbl and ids or nil
	end

	-- Party, Raid, Arena, find matching CompactUnitFrame
	local compactFrame
	for i = 1, 40 do
		local f = _G["CompactRaidFrame" .. i]
		if f and f.unit == unit then compactFrame = f; break end
	end
	if not compactFrame then
		for i = 1, 4 do
			local f = _G["CompactPartyFrameMember" .. i]
			if f and f.unit == unit then compactFrame = f; break end
		end
	end
	if compactFrame then
		local children = typeKey and compactFrame.buffFrames or compactFrame.debuffFrames
		if children then
			for i = 1, #children do
				local child = children[i]
				if not child:IsShown() then break end
				if child.auraInstanceID then
					ids[#ids + 1] = child.auraInstanceID
				end
			end
		end
		return children and ids or nil
	end

	return nil
end

-- Scan using Blizzard frames' own filtered aura list.
-- Reads auraInstanceIDs directly from Blizzard frame objects at scan time,
-- then fetches each aura's data. Falls back to unfiltered scan if unavailable.
local function scanBlizzard(parent, frame, type, config, displayConfig)
	if frame.totalAuras >= frame.maxAuras or not config.enabled then return end

	if frame.parent.configMode then
		local baseFilter = (type == "buffs") and "HELPFUL" or "HARMFUL"
		return scanConfigMode(parent, frame, type, config, displayConfig, baseFilter)
	end

	local unit = frame.parent.unit
	if not unit then return end

	local auraIDs = getBlizzardAuraIDs(unit, type)
	if not auraIDs then
		-- No Blizzard frame data, fall back to player auras only
		local baseFilter = (type == "buffs") and "HELPFUL|PLAYER" or "HARMFUL|PLAYER"
		return scan(parent, frame, type, config, displayConfig, baseFilter)
	end

	local isEnemy = UnitIsEnemy(unit, "player")
	local isFriendly = UnitIsFriend(unit, "player") and not isEnemy
	local curable = isFriendly and (type == "debuffs")
	local baseFilter = (type == "buffs") and "HELPFUL" or "HARMFUL"

	for idx = 1, #auraIDs do
		local ok, auraData = pcall(C_UnitAuras.GetAuraDataByAuraInstanceID, unit, auraIDs[idx])
		if ok and auraData then
			processAura(parent, frame, type, config, displayConfig, baseFilter, unit, isFriendly, curable, idx, auraData)
		end
		if frame.totalAuras >= frame.maxAuras then break end
	end

	for i = frame.totalAuras + 1, #(frame.buttons) do frame.buttons[i]:Hide() end
end

local function anchorGroupToGroup(frame, config, group, childConfig, childGroup)
	-- Child group has nothing in it yet, so don't care
	if( not childGroup.buttons[1] ) then return end

	-- Group we want to anchor to has nothing in it, takeover the postion
	if( group.totalAuras == 0 ) then
		local position = positionData[config.anchorPoint]
		childGroup.buttons[1]:ClearAllPoints()
		childGroup.buttons[1]:SetPoint(ShadowUF.Layout:GetPoint(config.anchorPoint), group.anchorTo, ShadowUF.Layout:GetRelative(config.anchorPoint), config.x + (position.xMod * ShadowUF.db.profile.backdrop.inset), config.y + (position.yMod * ShadowUF.db.profile.backdrop.inset))
		return
	end

	local anchorTo
	for i=#(group.buttons), 1, -1 do
		local button = group.buttons[i]
		if( button.isAuraAnchor and button:IsVisible() ) then
			anchorTo = button
			break
		end
	end

	local position = positionData[childGroup.forcedAnchorPoint or childConfig.anchorPoint]
	if( position.isSideGrowth ) then
		position.aura(childGroup.buttons[1], anchorTo)
	else
		position.column(childGroup.buttons[1], anchorTo, 2)
	end
end

Auras.anchorGroupToGroup = anchorGroupToGroup

-- Do an update and figure out what we need to scan
-- Support multiple frames per type
function Auras:Update(frame)
	local config = ShadowUF.db.profile.units[frame.unitType].auras
	
	-- Iterate over all possible aura frames
	for _, auraType in ipairs(AURA_TYPES) do
		local typeConfig = config[auraType]
		if( typeConfig ) then
			for i = 1, 6 do
				local frameConfig = typeConfig[i]
				local groupKey = auraType .. i
				local group = frame.auras[groupKey]

				if( group and frameConfig and frameConfig.enabled and not group.skipScan ) then
					group.totalAuras = (frameConfig.temporary and frame.unit == "player") and group.temporaryEnchants or 0

					local filterValue = frameConfig.filter or "ALL"
					local ok, err

					if filterValue == "BLIZZARD" then
						ok, err = pcall(scanBlizzard, frame.auras, group, auraType, frameConfig, frameConfig)
					else
						local baseFilter = auraType == "buffs" and "HELPFUL" or "HARMFUL"
						local effectiveFilter = baseFilter
						if filterValue ~= "ALL" then
							effectiveFilter = baseFilter .. "|" .. filterValue
						end
						ok, err = pcall(scan, frame.auras, group, auraType, frameConfig, frameConfig, effectiveFilter)
					end
					if not ok and not group.hasErrored then
						ShadowUF:Print("Error scanning " .. groupKey .. " (logged once): " .. tostring(err))
						group.hasErrored = true
					end

					-- Flow layout: reposition when enlarged auras take extra horizontal space
					if( frameConfig.enlarge and frameConfig.enlarge.PLAYER and group.totalAuras > 0 ) then
						positionAllButtons(group, frameConfig)
					end
				end
			end
		end
	end

	-- Apply anchor-to-anchor positioning for each configured pair
	if( frame.auras.anchorPairs ) then
		for i = 1, 6 do
			local pair = frame.auras.anchorPairs[i]
			if( pair ) then
				if( pair.sequential ) then
					-- Sequential mode: scan child auras into parent group (continuing after parent's auras)
					local childAuraType = pair.child.auraType
					local filterValue = pair.childConfig.filter or "ALL"
					local ok, err

					if filterValue == "BLIZZARD" then
						ok, err = pcall(scanBlizzard, frame.auras, pair.parent, childAuraType, pair.childConfig, pair.parentConfig)
					else
						local baseFilter = childAuraType == "buffs" and "HELPFUL" or "HARMFUL"
						local effectiveFilter = filterValue ~= "ALL" and (baseFilter .. "|" .. filterValue) or baseFilter
						ok, err = pcall(scan, frame.auras, pair.parent, childAuraType, pair.childConfig, pair.parentConfig, effectiveFilter)
					end
					if not ok and not pair.parent.hasErrored then
						ShadowUF:Print("Error scanning sequential auras (logged once): " .. tostring(err))
						pair.parent.hasErrored = true
					end

					-- Flow layout: reposition if enlarged auras present after sequential scan
					if( pair.parentConfig.enlarge and pair.parentConfig.enlarge.PLAYER and pair.parent.totalAuras > 0 ) then
						positionAllButtons(pair.parent, pair.parentConfig)
					end

					-- Hide unused child group buttons
					for j = 1, #(pair.child.buttons) do pair.child.buttons[j]:Hide() end
				elseif( pair.parent and pair.child ) then
					-- Column mode: anchor child group below/after parent group
					anchorGroupToGroup(frame, pair.parentConfig, pair.parent, pair.childConfig, pair.child)
				end
			end
		end
	end
	
	-- Update Boss Debuffs
	self:UpdateBossDebuffs(frame)
end
