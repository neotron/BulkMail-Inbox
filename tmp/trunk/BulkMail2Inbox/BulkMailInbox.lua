BulkMailInbox = AceLibrary('AceAddon-2.0'):new('AceDB-2.0', 'AceEvent-2.0', 'AceHook-2.1', 'AceConsole-2.0')

local L = AceLibrary('AceLocale-2.2'):new('BulkMailInbox')
BulkMailInbox.L = L

local tablet = AceLibrary('Tablet-2.0')
local abacus = AceLibrary('Abacus-2.0')

local _G = getfenv(0)

local sortFields, inboxCache, markTable  -- tables
local ibIndex, ibChanged, inboxCash, cleanPass, cashOnly, markOnly, takeAllInProgress-- variables

--[[----------------------------------------------------------------------------
  Local Processing
------------------------------------------------------------------------------]]
-- Build a table with info about all items and money in the Inbox
local function inboxCacheBuild()
	inboxCache = {}
	inboxCash = 0
	for i = 1, GetInboxNumItems() do
		_, _, sender, subject, money, _, daysLeft, hasItem, _, wasReturned = GetInboxHeaderInfo(i)
		if hasItem or money > 0 then
			table.insert(inboxCache, {
				index = i, sender = sender, bmid = daysLeft..subject, returnable = not wasReturned,
				daysLeft = daysLeft, itemLink = GetInboxItemLink(i) or L["Cash Only"], money = money, qty = select(3, GetInboxItem(i)),
				texture = hasItem and select(2, GetInboxItem(i)) or money > 0 and "Interface\\Icons\\INV_Misc_Coin_01",
			})
			inboxCash = inboxCash + money
		end
	end
	table.sort(inboxCache, function(a,b)
		local sf = sortFields[BulkMailInbox.db.char.sortField]
		if a and b then
			a[sf] = type(a[sf]) == 'boolean' and tostring(a[sf]) or a[sf]
			b[sf] = type(b[sf]) == 'boolean' and tostring(b[sf]) or b[sf]
			if a[sf] > b[sf] then return true end
		end
	end)
end

local function takeAll(cash, mark)
	cashOnly = cash
	markOnly = mark
	ibIndex = GetInboxNumItems()
	takeAllInProgress = true
	BulkMailInbox:MAIL_INBOX_UPDATE()
end

--[[----------------------------------------------------------------------------
  Setup
------------------------------------------------------------------------------]]
function BulkMailInbox:OnInitialize()
	self:RegisterDB('BulkMail2InboxDB')
	self:RegisterDefaults('profile', {
		tablet_data = { detached = true, anchor = "TOPLEFT", offsetx = 340, offsety = -104 }
	})
	self:RegisterDefaults('char', {
		altDel = false,
		ctrlRet = true,
		shiftTake = true,
		takeAll = true,
		inboxUI = true,
		sortField = 1,
	})

	sortFields = { 'itemLink', 'qty', 'money', 'returnable', 'sender', 'daysLeft' }
	markTable = {}

	self.opts = {
		type = 'group',
		args = {
			altdel = {
				name = L["Alt-click Delete"], type = 'toggle', aliases = L["alt"],
				desc = L["Enable Alt-Click on inbox items to delete them."],
				get = function() return self.db.char.altDel end,
				set = function(v) self.db.char.altDel = v end,
			},
			ctrlret = {
				name = L["Ctrl-click Return"], type = 'toggle', aliases = L["ctrl"],
				desc = L["Enable Ctrl-click on inbox items to return them."],
				get = function() return self.db.char.ctrlRet end,
				set = function(v) self.db.char.ctrlRet = v end,
			},
			shifttake = {
				name = L["Shift-click Take"], type = 'toggle', aliases = L["shift"],
				desc = L["Enable Shift-click on inbox items to take them."],
				get = function() return self.db.char.shiftTake end,
				set = function(v) self.db.char.shiftTake = v end,
			},
			takeall = {
				name = L["Take All"], type = 'toggle', aliases = L["ta"],
				desc = L["Enable 'Take All' button in inbox."],
				get = function() return self.db.char.takeAll end,
				set = function(v) self.db.char.takeAll = v self:UpdateTakeAllButton() end,
			},
			gui = {
				name = L["Show Inbox GUI"], type = 'toggle',
				desc = L["Show the Inbox Items GUI"],
				get = function() return self.db.char.inboxUI end,
				set = function(v) self.db.char.inboxUI = v self:UpdateInboxGUI() end,
			},
		},
	}
	self:RegisterChatCommand({"/bulkmailinbox", "/bmi"}, self.opts) 
end

function BulkMailInbox:OnEnable()
	self:UpdateTakeAllButton()
	self:RegisterEvent('MAIL_SHOW')
	self:RegisterEvent('MAIL_CLOSED')
	self:RegisterEvent('PLAYER_ENTERING_WORLD')
	self:RegisterEvent('UI_ERROR_MESSAGE')
	self:RegisterEvent('MAIL_INBOX_UPDATE')

	-- Handle being LoD loaded while at the mailbox
	if MailFrame:IsVisible() then
		self:MAIL_SHOW()
	end
end

function BulkMailInbox:OnDisable()
	self:UnregisterAllEvents()
	tablet:Unregister('BMI_InboxTablet')
end

--[[----------------------------------------------------------------------------
  Events
------------------------------------------------------------------------------]]
function BulkMailInbox:MAIL_SHOW()
	self:SecureHook('CheckInbox', 'RefreshInboxGUI')
	self:SecureHook(GameTooltip, 'SetInboxItem')
	self:Hook('InboxFrame_OnClick', nil, true)
	self:HookScript(MailFrameTab1, 'OnClick', 'MailFrameTab1_OnClick')
	self:HookScript(MailFrameTab2, 'OnClick', 'MailFrameTab2_OnClick')

	SendMailMailButton:Enable()
	ibIndex = GetInboxNumItems()
	ibChanged = GetTime()
	self:UpdateInboxGUI()
end

function BulkMailInbox:MAIL_CLOSED()
	self:UnhookAll()
	self:HideInboxGUI()
end
BulkMailInbox.PLAYER_ENTERING_WORLD = BulkMailInbox.MAIL_CLOSED  -- MAIL_CLOSED doesn't get called if, for example, the player accepts a port with the mail window open

function BulkMailInbox:UI_ERROR_MESSAGE(msg)  -- move Take All along if inventory is full to prevent infinite loop
	if msg == ERR_INV_FULL then
		cashOnly = true  -- keep parsing for cash, but no more room for items
	end
end

-- Take next inbox item or money; skip past COD items and letters.
function BulkMailInbox:MAIL_INBOX_UPDATE()
	self:RefreshInboxGUI()
	if not takeAllInProgress then return end

	local numItems = GetInboxNumItems()
	if ibIndex <= 0 then
		if cleanPass or numItems <= 0 then
			takeAllInProgress = false
			return
		else
			ibIndex = numItems
			cleanPass = true
			return takeAll(cashOnly, markOnly)
		end
	end
	
	local subject, money, COD, daysLeft, hasItem = select(4, GetInboxHeaderInfo(ibIndex))
	if markOnly and not markTable[daysLeft..subject] then
		ibIndex = ibIndex - 1
		return self:MAIL_INBOX_UPDATE()
	end

	if money > 0 then
		cleanPass = false
		ibChanged = GetTime()
		return TakeInboxMoney(ibIndex)
	end

	if not hasItem or cashOnly or COD > 0 then
		ibIndex = ibIndex - 1
		return self:MAIL_INBOX_UPDATE()
	else
		cleanPass = false
		ibChanged = GetTime()
		ibIndex = ibIndex - 1
		TakeInboxItem(ibIndex+1)
	end
	
end

--[[----------------------------------------------------------------------------
  Hooks
------------------------------------------------------------------------------]]
function BulkMailInbox:SetInboxItem(tooltip, index, ...)
	local money, COD, _, hasItem, _, wasReturned, _, canReply = select(5, GetInboxHeaderInfo(index))
	if self.db.char.shiftTake then tooltip:AddLine(L["Shift - Take Item"]) end
	if wasReturned then 
		if self.db.char.altDel then
			tooltip:AddLine(L["Alt - Delete Mail"])
		end
	elseif canReply and self.db.char.ctrlRet then
		tooltip:AddLine(L["Ctrl - Return Item"])
	end
end

function BulkMailInbox:InboxFrame_OnClick(index, ...)
	takeAllInProgress = false
	local _, _, _, _, money, COD, _, hasItem, _, wasReturned, _, canReply = GetInboxHeaderInfo(index)
 	if self.db.char.shiftTake and IsShiftKeyDown() then
		if money > 0 then TakeInboxMoney(index)
		elseif COD > 0 then return
		elseif hasItem then TakeInboxItem(index) end
	elseif self.db.char.ctrlRet and IsControlKeyDown() and not wasReturned and canReply then ReturnInboxItem(index)
	elseif self.db.char.altDel and IsAltKeyDown() then DeleteInboxItem(index)
	else return self.hooks.InboxFrame_OnClick(index, ...) end
	ibChanged = GetTime()
end

function BulkMailInbox:MailFrameTab1_OnClick(frame, a1)
	self:UpdateInboxGUI()
	return self.hooks[frame].OnClick(frame, a1)
end

function BulkMailInbox:MailFrameTab2_OnClick(frame, a1)
	self:HideInboxGUI()
	return self.hooks[frame].OnClick(frame, a1)
end

--[[----------------------------------------------------------------------------
  Inbox GUI
------------------------------------------------------------------------------]]
-- Update/Create the Take All button
function BulkMailInbox:UpdateTakeAllButton()
	if self.db.char.takeAll then
		if _G.BMI_TakeAllButton then return end
		local bmiTakeAllButton = CreateFrame("Button", "BMI_TakeAllButton", InboxFrame, "UIPanelButtonTemplate")
		bmiTakeAllButton:SetWidth(120)
		bmiTakeAllButton:SetHeight(25)
		bmiTakeAllButton:SetPoint("CENTER", InboxFrame, "TOP", -15, -410)
		bmiTakeAllButton:SetText("Take All")
		bmiTakeAllButton:SetScript("OnClick", function() takeAll() end)
	else
		if _G.BMI_TakeAllButton then _G.BMI_TakeAllButton:Hide() end
		_G.BMI_TakeAllButton = nil
	end
end

-- Inbox Items GUI
function BulkMailInbox:UpdateInboxGUI()
	if not self.db.char.inboxUI then return self:HideInboxGUI() end
	if not tablet:IsRegistered('BMI_InboxTablet') then
		tablet:Register('BMI_InboxTablet', 'detachedData', self.db.profile.tablet_data, 'strata', "HIGH", 'maxHeight', 850,
			'cantAttach', true, 'dontHook', true, 'showTitleWhenDetached', true, 'children', function()
				inboxCacheBuild()
				tablet:SetTitle(string.format(L["BulkMailInbox -- Inbox Items (%d mails, %s)"], GetInboxNumItems(), abacus:FormatMoneyShort(inboxCash)))
				local hlcol = 'text'..self.db.char.sortField
				local cat = tablet:AddCategory('columns', 6,
					'func', function() self.db.char.sortField = sortFields[self.db.char.sortField+1] and self.db.char.sortField+1 or 1 end,
					'text', L["Items (Inbox click actions apply)"],
					'text2', L["Qty."],
					'text3', L["Money"],
					'text4', L["Returnable"],
					'text5', L["Sender"],
					'text6', L["TTL"],
					hlcol..'R', 1, hlcol..'G', 0.8, hlcol..'B', 0
				)
				if inboxCache and next(inboxCache) then
					for i, info in pairs(inboxCache) do
						cat:AddLine(
							'checked', true, 'hasCheck', true, 'checkIcon', not markTable[info.bmid] and info.texture,
							'func', function()
								if not IsModifierKeyDown() then
									markTable[info.bmid] = not markTable[info.bmid] and true or nil
									self:RefreshInboxGUI()
								else
									InboxFrame_OnClick(info.index)
								end
							end, 'indentation', markTable[info.bmid] and 0 or 10,
							'text', info.itemLink,
							'text2', info.qty,
							'text3', abacus:FormatMoneyFull(info.money),
							'text4', info.returnable and L["Yes"] or L["No"],
							'text5', info.sender,
							'text6', string.format("%0.1f", info.daysLeft),
							'textR', markTable[info.bmid] and 1, 'textG', markTable[info.bmid] and 1, 'textB', markTable[info.bmid] and 1,
							'text2R', markTable[info.bmid] and 1, 'text2G', markTable[info.bmid] and 1, 'text2B', markTable[info.bmid] and 1,
							'text3R', markTable[info.bmid] and 1, 'text3G', markTable[info.bmid] and 1, 'text3B', markTable[info.bmid] and 1,
							'text4R', markTable[info.bmid] and 1, 'text4G', markTable[info.bmid] and 1, 'text4B', markTable[info.bmid] and 1,
							'text5R', markTable[info.bmid] and 1, 'text5G', markTable[info.bmid] and 1, 'text5B', markTable[info.bmid] and 1,
							'text6R', markTable[info.bmid] and 1, 'text6G', markTable[info.bmid] and 1, 'text6B', markTable[info.bmid] and 1,
							hlcol..'R', 1, hlcol..'G', 1, hlcol..'B', markTable[info.bmid] and 1 or 0.5
						)
					end
				else
					cat:AddLine('text', L["No items"])
				end
				cat = tablet:AddCategory('columns', 1)
				cat:AddLine()
				cat:AddLine('text', L["Take All"], 'func', takeAll)
				cat:AddLine('text', L["Take Cash"], 'func', function() takeAll(true) end)
				cat:AddLine('text', L["Take Selected"], 'func', next(markTable) and function() takeAll(false, true) end,
					'textR', not next(markTable) and 0.5, 'textG', not next(markTable) and 0.5, 'textB', not next(markTable) and 0.5
				)
				cat:AddLine('text', L["Clear Selected"], 'func', next(markTable) and function() for i in pairs(markTable) do markTable[i] = nil end end,
					'textR', not next(markTable) and 0.5, 'textG', not next(markTable) and 0.5, 'textB', not next(markTable) and 0.5
				)
				cat:AddLine('text', L["Close"], 'func', function() BulkMailInbox:ScheduleEvent(function() tablet:Close('BMI_InboxTablet') end, 0.01) end)  -- WTF
			end
		)
	end
	tablet:Open('BMI_InboxTablet')
	self:ScheduleRepeatingEvent('BMI_UpdateGUIEvent', self.RefreshInboxGUI, 0.5, self)
end

function BulkMailInbox:HideInboxGUI()
	if tablet:IsRegistered('BMI_InboxTablet') then
		tablet:Close('BMI_InboxTablet')
	end
	self:CancelScheduledEvent('BMI_UpdateGUIEvent')
end

function BulkMailInbox:RefreshInboxGUI()
	if GetTime() - ibChanged > 2.5 then return end
	if tablet:IsRegistered('BMI_InboxTablet') then
		tablet:Refresh('BMI_InboxTablet')
	end
end
