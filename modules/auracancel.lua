-- Secure right-click/click cancel for the player's cancelable buffs.
--
-- Direct port of JustAC/UI/UIPrecombatOverlay.lua's approach. SUF's aura icons stay INSECURE, so
-- SUF keeps all its filtering / layout / multi-frame setup and can rebuild the icons every frame
-- (which a protected frame can't do in combat). A pool of invisible SecureActionButtonTemplate
-- layers is parked over the cancelable player-buff icons OUT OF COMBAT, each carrying a
-- /cancelaura macro. The pool lives in a container hidden in combat by a SECURE state driver
-- ([combat] hide) — taint-free — so we never show/hide secure frames in combat ourselves.

local POOL_SIZE = 40
local container, layers, eventFrame, scheduled

local function ensurePool()
	if( container ) then return true end
	if( InCombatLockdown() ) then return false end
	container = CreateFrame("Frame", "SUFAuraCancelOverlay", UIParent)
	-- Secure environment hides every layer in combat — taint-free; SUF's icons revert to normal.
	RegisterStateDriver(container, "visibility", "[combat] hide; show")
	layers = {}
	for i = 1, POOL_SIZE do
		local b = CreateFrame("Button", "SUFAuraCancelLayer" .. i, container, "SecureActionButtonTemplate")
		b:RegisterForClicks("AnyDown", "AnyUp") -- fire regardless of the key-down/up cast CVar
		b:SetFrameStrata("HIGH")
		-- Forward hover to the icon below so its tooltip still shows through the layer.
		b:SetScript("OnEnter", function(self)
			local f = self.icon and self.icon:GetScript("OnEnter")
			if( f ) then f(self.icon) end
		end)
		b:SetScript("OnLeave", function(self)
			local f = self.icon and self.icon:GetScript("OnLeave")
			if( f ) then f(self.icon) end
		end)
		b:Hide()
		layers[i] = b
	end
	return true
end

-- Point a layer at a SUF aura icon (out of combat only) with a /cancelaura macro for its buff.
-- Copies the icon's rect instead of anchoring to it: a protected frame anchored to the icon
-- makes the icon's geometry protected too, so SUF's own in-combat aura re-layout
-- (SetHeight/SetWidth/SetScale on the icons) would be blocked. Rect copies leave the icons free;
-- refresh() re-syncs positions out of combat.
local function configureLayer(layer, icon, name)
	local left, bottom = icon:GetLeft(), icon:GetBottom()
	if( not left ) then return false end -- no rect yet
	layer.icon = icon
	layer:SetAttribute("type", "macro")
	layer:SetAttribute("macrotext", "/cancelaura " .. name)
	local scale = icon:GetEffectiveScale() / layer:GetEffectiveScale()
	layer:ClearAllPoints()
	layer:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", left * scale, bottom * scale)
	layer:SetSize(icon:GetWidth() * scale, icon:GetHeight() * scale)
	layer:SetFrameLevel(icon:GetFrameLevel() + 10)
	layer:Show()
	return true
end

-- Cover every shown, cancelable player-buff icon with a secure layer (out of combat).
local function refresh()
	if( InCombatLockdown() or not ensurePool() ) then return end
	local units = ShadowUF.Units and ShadowUF.Units.unitFrames
	local pf = units and units.player
	local placed = 0
	if( pf and pf.auras ) then
		for i = 1, 6 do
			local cfg = ShadowUF.db.profile.units.player.auras.buffs[i]
			local group = pf.auras["buffs" .. i]
			if( group and group.buttons and cfg and not cfg.clickThrough ) then
				for _, icon in ipairs(group.buttons) do
					if( placed < POOL_SIZE and icon:IsShown() and icon.unit and icon.auraInstanceID
						and icon.filter and icon.filter:find("HELPFUL") and UnitIsUnit(icon.unit, "player") ) then
						local data = C_UnitAuras.GetAuraDataByAuraInstanceID("player", icon.auraInstanceID)
						-- 12.0 secrets aura names in encounters (C_Secrets.ShouldAurasBeSecret, and it is
						-- NOT combat-gated — a boss target alone flips it). Feeding a secret string to
						-- SetAttribute taints SUF, so those buffs get no layer. Per-spell exempt auras
						-- (GetSpellAuraSecrecy == 0) stay readable and still get one.
						if( data and data.name and not issecretvalue(data.name)
							and configureLayer(layers[placed + 1], icon, data.name) ) then
							placed = placed + 1
						end
					end
				end
			end
		end
	end
	for i = placed + 1, POOL_SIZE do layers[i]:Hide(); layers[i].icon = nil end
end

local function schedule()
	-- Nothing to do in combat (layers are hidden by the state driver, refresh() bails), so don't
	-- even spin a timer — UNIT_AURA fires constantly mid-fight. PLAYER_REGEN_ENABLED re-maps after.
	if( scheduled or InCombatLockdown() ) then return end
	scheduled = true
	C_Timer.After(0.05, function() scheduled = false; refresh() end)
end

eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")     -- re-map once combat ends
eventFrame:RegisterUnitEvent("UNIT_AURA", "player")
eventFrame:SetScript("OnEvent", schedule)

-- Re-map after SUF rebuilds/repositions its aura icons (config or layout changes).
if( ShadowUF and ShadowUF.Layout ) then
	hooksecurefunc(ShadowUF.Layout, "Reload", schedule)
end
