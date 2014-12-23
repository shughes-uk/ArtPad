--[[
--
--	ArtPad
--	by Dust of Turalyon
--
--	Naming Convention:
--	- Methods are first letter upper case, camel case
--	- Member variables are first letter lower case
--	- Static handlers start with "On".
--
--]]

--[[ Protocol ]]
-- d(<x>,<y>,<a>,<b>)	-- Draw a line from (x,y) to (a,b)
-- c(<x>,<y>)		-- Clear a point at (x,y)
-- c(<x>,<y>,<a>,<b>)	-- Clear a line from (x,y) to (a,b)
-- c()			-- Clear Canavas
-- f(<r>,<g>,<b>,<a>)	-- Change to given color
-- t(<x>,<y>,"<t>")	-- Draw text t with bottom left corner at (x,y)
ArtPad =
{
-- [[ Version data from the TOC file ]]
version = GetAddOnMetadata("ArtPad", "Version");
saveVersion = GetAddOnMetadata("ArtPad", "X-SaveVersion");
protocolVersion = GetAddOnMetadata("ArtPad", "X-ProtocolVersion");
eventListener = CreateFrame("FRAME");
canvasSize = {["X"] = 3840 ; ["Y"] = 2160 };
}

-- [[ Event Handlers]]
function ArtPad:Variables_Loaded()
	--print("VAR LOADED");
end

function ArtPad:Player_Login()
	RegisterAddonMessagePrefix("ArtPad");

	-- [[ Sort settings ]]
	local ArtPad_Settings_Default = {
				["SaveVersion"]	= self.saveVersion;
				["AdminOnly"]	= false; -- Ignore non-raid admins
				["WarnClear"]	= true; -- Warn before clearing screen
				["Mode"]		= "GUILD";
				["Scale"]		= 1;
				["MinimapIcon"] = {};
				["OneTimeMessage"] = false;
			};
	if not ArtPad_Settings then
		ArtPad_Settings = ArtPad_Settings_Default;
	elseif ArtPad_Settings["SaveVersion"] < self.saveVersion then
		ArtPad_Settings = ArtPad_Settings_Default;
	end;
	-- [[ Setup Canvas ]]
	self:SetupMainFrame();

	-- [[ Setup minimap Icon ]]
	local LDB = LibStub("LibDataBroker-1.1")
	local LDBIcon = LibStub("LibDBIcon-1.0")
	if LDB then
        artpadLauncher = LDB:NewDataObject("ArtPad", {
            type = "launcher",
            icon = "Interface\\AddOns\\Artpad\\icon",
            OnClick = self.MiniMapClick,
            OnTooltipShow = function(tt)                
                tt:AddLine("|cffffff00" .. "Left Click|r to toggle the Artpad window")
                tt:AddLine("|cffffff00" .. "Right Click|r to toggle between raid and guild mode")
            end,
        })
        if LDBIcon then
            LDBIcon:Register("ArtPad", artpadLauncher, ArtPad_Settings.MinimapIcon)
            LDBIcon:Show("ArtPad")
        end
    end
end

function ArtPad:Player_Regen_Disabled()
	-- Close window when entering combat
	if self.mainFrame:IsShown() then
		self.mainFrame:Hide();
	end;
end;

function ArtPad:Chat_Msg_Addon(prefix, message, disType, sender)
	if prefix == "ArtPad" and sender ~= UnitName("player") then
	-- Check security 
		if (ArtPad_Settings["Mode"] == "GUILD" and disType == "GUILD") or (ArtPad_Settings["Mode"] == "RAID" and disType == "RAID") then
			if ArtPad_Settings["Mode"] == "RAID" then
				if not self:ValidateSender(sender) then
					return;
				end;
			end;
		--draw a line				
			local x,y,a,b,brushR,brushG,brushB,brushA = string.match(message, "d%((%d+),(%d+),(%d+),(%d+),(%d+%.?%d*),(%d+%.?%d*),(%d+%.?%d*),(%d+%.?%d*)%)");
			if x then
				if not self.mainFrame:IsShown() and artpadLauncher then
					artpadLauncher.icon = 'Interface\\AddOns\\Artpad\\iconact';
				end					
				self:DrawLine(x,y,a,b,{r=brushR,g=brushG,b=brushB,a=brushA});
				return;
			end;
		--erase a point
			local x,y = string.match(message, "c%((%d+),(%d+)%)");
			if x then
				self:ClearLine(x,y);
				return;
			end;
		--erase a line
			local x,y,a,b = string.match(message, "c%((%d+),(%d+),(%d+),(%d+)%)");
			if x then
				self:ClearLine(x,y,a,b);
				return;
			end;
		--create text
			local x,y,t = string.match(message, "t%((%d+),(%d+),\"([^\"]+)\"%)");
			if x then
				if not self.mainFrame:IsShown() and artpadLauncher then
					artpadLauncher.icon = 'Interface\\AddOns\\Artpad\\iconact';
				end
				self:CreateText(x,y,t);
				return;
			end;
		--wipe the canvas
			local a, b = string.find(message, "c%(%)");
			if a then
				self:ClearCanavas();
				self:Message(sender .. " just cleared the canvas")
				return;
			end;
		end;
	end;
end;


ArtPad.events = {
	["VARIABLES_LOADED"] = ArtPad.Variables_Loaded;
	["PLAYER_LOGIN"] = ArtPad.Player_Login;
	["PLAYER_REGEN_DISABLED"] = ArtPad.Player_Regen_Disabled;
	["CHAT_MSG_ADDON"] = ArtPad.Chat_Msg_Addon;
};
-- [[ Event Management ]]

function ArtPad:SetUpEvents()	
	self.eventListener.pad = self;
	self.eventListener:SetScript("OnEvent", self.OnEvent);
	self:RegisterEvents(self.events);
end

function ArtPad:RegisterEvents(eventList)
	for event, handler in pairs(eventList) do
		self.eventListener:RegisterEvent(event);
	end
end;

function ArtPad:UnregisterEvents(eventList)
	for event, handler in pairs(eventList) do
		self.eventListener:UnregisterEvent(event);
	end
end;

-- [[ Button Handling ]]
ArtPad.buttons = {
	["Close"] =
		function (frame, button, down)
			local self = frame.pad; -- Static Method
			self.mainFrame:Hide();
		end;
	["Clear"] =
		function (frame, button, down)
			local self = frame.pad; -- Static Method
			self:ClearCanavas();
			self:SendClear();
		end;
	["Text"] =
		function (frame, button, down)
			local self = frame.pad; -- Static Method
			if self.state == "SLEEP" then
				self.textInput:SetText("");
				self.textInput:Show();
			end;
		end;
	["ColorPicker"] =
		function (frame, button, down)
			local self = frame.pad; -- Static Method
			ColorPickerFrame:SetColorRGB( self.brushColor.r, self.brushColor.g, self.brushColor.b);
			ColorPickerFrame.hasOpacity, ColorPickerFrame.opacity = (self.brushColor.a ~= nil), self.brushColor.a;
			ColorPickerFrame.previousValues = {self.brushColor.r, self.brushColor.g, self.brushColor.b, self.brushColor.a};
			ColorPickerFrame.func, ColorPickerFrame.opacityFunc, ColorPickerFrame.cancelFunc = 
			self.ColorPicker_Callback, self.ColorPicker_Callback, self.ColorPicker_Callback;
			ColorPickerFrame:Hide(); -- Need to run the OnShow handler.
			ColorPickerFrame:Show();
		end;
};

ArtPad.shortcuts = {
	["Close"] = "ESCAPE";
};


-- [[ Minimap Event]]
function ArtPad.MiniMapClick(clickedframe, button)
	if not InCombatLockdown() then
		if button ~= "RightButton" then 
			if ArtPad.mainFrame:IsShown() then
				ArtPad.mainFrame:Hide();
			else
				ArtPad.mainFrame:Show();
			end
		else
			if ArtPad_Settings["Mode"] == "GUILD" then
				ArtPad_Settings["Mode"] = "RAID";
				ArtPad:Message("ArtPad now raid/party wide only")
			else
				ArtPad_Settings["Mode"] = "GUILD";
				ArtPad:Message("ArtPad now guild wide");
			end
		end
	end
end;
-- [[ Frame Event Handling ]]
function ArtPad.OnEvent(frame, event, ...)
	local self = frame.pad; -- Static Method
	if self.events[event] then
		self.events[event](self, ...);
	else
		self:Message("ArtPad Error: Unknown Event");
	end;
end;

-- [[ Keyboard Event Handling ]]
function ArtPad.OnKeyDown(frame, key)
	local self = frame.pad; -- Static Method
end;

OnKeyUp = function (frame, key)
	local self = frame.pad; -- Static Method
	if (key == "ESCAPE") then
		frame:Hide();
	end;
end;

-- [[ Mouse Event Handling ]]
state = "SLEEP";

function ArtPad.OnMouseDown(frame, button)
	local self = frame.pad; -- Static Method
	if self.FrameMouseDown(frame) then
		self.state = "FRAME";
	elseif self.state == "SLEEP" then
		if button == "LeftButton" then
			self.state = "PAINT";
		else
			self.state = "CLEAR";
		end;
	elseif self.state == "TEXT" then
		self:CreateText(self.lastX, self.lastY,
			self.textInput:GetText());
		self:SendText(self.lastX, self.lastY,
			self.textInput:GetText());
		self.state = "SLEEP";
	end;
end;

function ArtPad.OnMouseUp(frame, button)
	local self = frame.pad; -- Static Method
	self.FrameMouseUp(frame);
	self.state = "SLEEP";
end;

ArtPad.Desired_X_Ofs = 1;
ArtPad.Desired_Y_Ofs = 1;
ArtPad.Actual_X_Ofs = 0;
ArtPad.Actual_Y_Ofs = 0;

function ArtPad.OnMouseWheel(frame, delta)
	local self = frame.pad; -- Static Method
	local frameScale = self.mainFrame:GetScale();
	local newScale = frameScale + (frameScale*0.10*delta) ;
	if 100 > newScale and newScale > 0.05 then
		local curmx, curmy = GetCursorPosition();
		--mouse coords are subject to scaling because reasons
		curmx = curmx/UIParent:GetScale();
		curmy = curmy/UIParent:GetScale();	
		if delta == 1 then			
			self.CalcNewZoomOffset(curmx,curmy);			
			newx = self.Actual_X_Ofs - (self.Actual_X_Ofs - self.Desired_X_Ofs)*0.10
			newy = self.Actual_Y_Ofs - (self.Actual_Y_Ofs - self.Desired_Y_Ofs)*0.10
		else 
			self.Desired_X_Ofs = 0;
			self.Desired_Y_Ofs = 0;			
			newx = self.Actual_X_Ofs - (self.Actual_X_Ofs - self.Desired_X_Ofs)*0.40
			newy = self.Actual_Y_Ofs - (self.Actual_Y_Ofs - self.Desired_Y_Ofs)*0.40
		end
		self.mainFrame:SetPoint("CENTER", newx/newScale, newy/newScale);
		self.Actual_Y_Ofs = newy;
		self.Actual_X_Ofs = newx;
		self.mainFrame:SetScale(newScale)
		ArtPad_Settings["Scale"] = newScale
	end
end
		
function ArtPad.CalcNewZoomOffset(mx,my)
	--magic math to work out how much we need to offset the center of the canvas by to make the zoom effect
	local screen_Y_Center = (GetScreenHeight() * 0.5) ;
	local screen_X_Center = (GetScreenWidth() * 0.5) ;
	ArtPad.Desired_X_Ofs = screen_X_Center - mx + ArtPad.Actual_X_Ofs;
	ArtPad.Desired_Y_Ofs = screen_Y_Center - my + ArtPad.Actual_Y_Ofs;	
	return ArtPad.Desired_X_Ofs , ArtPad.Desired_Y_Ofs;
end

-- [[ Override Handling ]]
function ArtPad.OnShow(frame)
	if  not InCombatLockdown() then
		
		local self = frame.pad; -- Static Method
		if not ArtPad_Settings["OneTimeMessage"] then
			self:Message("New in ArtPad 8.6 : Try using the mousewheel!")
			ArtPad_Settings["OneTimeMessage"] = true;
		end
		-- Set Override
		for b, k in pairs(self.shortcuts) do
			SetOverrideBindingClick(self.mainFrame, true, k, "ArtPad_MainFrame_"..b);
		end;

		artpadLauncher.icon = "Interface\\AddOns\\Artpad\\icon"

		self.text_button:Show()
		self.cpicker_button:Show()
		self.clear_button:Show()
		self.secretFrame:Show()
		self.versionText:Show()
	end
end;

function ArtPad.OnHide(frame)
	local self = frame.pad; -- Static Method
	-- Clear Override
	ClearOverrideBindings(self.mainFrame);
	self.text_button:Hide()
	self.cpicker_button:Hide()
	self.textInput:Hide()
	self.clear_button:Hide()
	self.secretFrame:Hide()
	self.versionText:Hide()
end;

-- [[ Tracking Functions ]]
function ArtPad.OnEnter(frame, motion)
	local self = frame.pad; -- Static Method
	self.mainFrame:SetScript("OnUpdate", self.OnUpdate);
end;

function ArtPad.OnLeave(frame, motion)
	local self = frame.pad; -- Static Method
	self.mainFrame:SetScript("OnUpdate", nil);
	self.state = "SLEEP";
	self.lastX = nil;
	self.lastY = nil;

end;

ArtPad.mouseX = -1;
ArtPad.mouseY = -1;
function ArtPad.OnUpdate(frame, elapsed)
	local self = frame.pad; -- Static Method
	local mx, my = GetCursorPosition();
	if mx == self.mouseX and my == self.mouseY then
		return;
	else
		self.mouseX = mx;
		self.mouseY = my;
	end;
	local x, y;		-- Local coordinates
	local scale = self.mainFrame:GetScale();--*UIParent:GetScale();

	mx = mx/scale;
	my = my/scale;
	x = math.floor(mx - self.mainFrame:GetLeft());
	y = math.floor(my - self.mainFrame:GetBottom());

	if self.state ~= "SLEEP" then
		self:HandleMove(x, y, self.lastX, self.lastY);
	end;

	self.lastX = x;
	self.lastY = y;
end;

function ArtPad:HandleMove(x,y,oldX,oldY)
	if self.state == "PAINT" then
		self:DrawLine(x,y,oldX,oldY,self.brushColor);
		self:SendLine(x,y,oldX,oldY,self.brushColor);
	elseif self.state == "CLEAR" then
		self:ClearLine(x,y,oldX,oldY);
		self:SendClear(x,y,oldX,oldY);
	end;
end;

function ArtPad.OnTextEnter(frame)
	local self = frame.pad; -- Static Method
	self.state = "TEXT";
	frame:Hide();
end;

function ArtPad.OnTextEscape(frame)
	local self = frame.pad; -- Static Method
	frame:Hide();
end;

-- [[ Authorisation ]]
function ArtPad:ValidateSender(sender)
	if ArtPad_Settings["AdminOnly"] then
		-- Check if sender is a raid admin
		local num = GetNumGroupMembers()
		local authorized = false
		-- require assist if it's a raid, and leader if it's a party (everyone in a party has assist)
		local minRank = IsInRaid() and 1 or 2
		if (num > 0) then
			for i = 1, num do
				local name, rank = GetRaidRosterInfo(i)
				if name == sender then
					authorized = rank >= minRank
				end;
			end;
		end;
		return authorized;
	else
		-- No check needed, all are allowed
		return true;
	end;
end;

ArtPad.slashCommands = {
	["guild"] = 
		function (self)
			ArtPad_Settings["Mode"] = "GUILD";
			self:Message("AP now in Guild mode");
		end;
	["raid"] =
		function (self)
			ArtPad_Settings["Mode"] = "RAID";
			self:Message("AP now in Raid Mode");
		end;
	["show"] =
		function (self)
			self.mainFrame:Show();
		end;
	["hide"] =
		function (self)
			self.mainFrame:Hide();
		end;
	["toggle"] =
		function (self)
			if self.mainFrame:IsShown() then
				self.mainFrame:Hide();
			else
				self.mainFrame:Show();
			end;
		end;
	["clear"] =
		function (self)
			self:ClearCanavas();
		end;
	["adminonly"] =
		function (self, state)
			-- TODO: Generalize
			-- Set
			if state == "off" or state == "false" then
				ArtPad_Settings["AdminOnly"] = false;
			elseif state == "on" or state == "true" then
				ArtPad_Settings["AdminOnly"] = true;
			else -- Toggle
				if ArtPad_Settings["AdminOnly"] then
					ArtPad_Settings["AdminOnly"] = false;
				else
					ArtPad_Settings["AdminOnly"] = true;
				end;
			end;
			if ArtPad_Settings["AdminOnly"] then
				self:Message("ArtPad: AdminOnly enabled");
			else
				self:Message("ArtPad: AdminOnly disabled");
			end;
		end;
};

function ArtPad.OnSlashCommand(msg)
	local self = ArtPad; -- Static Method
	local cmd, arg = string.match(msg, "^(%a*)%s*(.*)$");
	if cmd then
		cmd = string.lower(cmd);
		if self.slashCommands[cmd] then
			self.slashCommands[cmd](self, arg);
		else
			self:Message("ArtPad:");
			self:Message("/ap [show | hide | toggle | clear]");
			self:Message("/ap [adminonly]");
			self:Message("/ap guild");
			self:Message("/ap raid");
		end;
	end;
end;

-- [[ Misc ]]
function ArtPad:Message(msg)
	DEFAULT_CHAT_FRAME:AddMessage(msg);
end;

-- [[ Frame Setup and handling ]]

ArtPad.mainFrame = nil;	-- For input/output
ArtPad.textInput = nil;

ArtPad.brushColorSample = nil;

function ArtPad:SetupMainFrame()
	local frameM = CreateFrame("Frame", nil, nil);

	self.mainFrame = frameM;
	self.mainFrame.pad = self;

	frameM:SetFrameStrata("BACKGROUND");
	frameM:SetWidth(self.canvasSize.X);
	frameM:SetHeight(self.canvasSize.Y);
	frameM:SetScale(ArtPad_Settings["Scale"]);
	frameM:SetPoint("CENTER");
	frameM:SetMovable(true);
	frameM:SetClampedToScreen(false);
	frameM:Hide();

	local frameT = CreateFrame("EditBox", nil, UIParent);
	self.textInput = frameT;
	self.textInput.pad = self;

	frameT:SetPoint("BOTTOMLEFT", frameM, "TOP", -110, -100);
	frameT:SetPoint("TOPRIGHT", frameM, "TOP", 110, -80);
	frameT:SetFont("Fonts\\FRIZQT__.TTF",18);
	frameT:Hide();

	local t = frameM:CreateTexture(nil, "BACKGROUND");
	t:SetTexture(0,0,0,0.5);
	t:SetAllPoints(frameM);

	

	self.versionText = UIParent:CreateFontString(nil, "ARTWORK");
	self.versionText:SetPoint("TOP", UIParent, "TOP", 10, -10);
	--self.versionText:SetTextColor(0, 0, 0, 1);
	self.versionText:SetFont("Fonts\\FRIZQT__.TTF",16);
	self.versionText:SetJustifyH("LEFT")
	self.versionText:SetText("ArtPad v."..self.version);
	self.versionText:Hide()


	--colorpicker_button	
	--buttonframe
	self.cpicker_button = CreateFrame("Button", "cpicker_button", UIParent);
	self.cpicker_button:SetPoint("TOP", UIParent, "TOP", 10, -40);
	self.cpicker_button:SetWidth(100);
	self.cpicker_button:SetHeight(40);
	self.cpicker_button:SetText("Color Picker");
	self.cpicker_button:SetScript("OnClick", self.buttons["ColorPicker"]);
	self.cpicker_button.pad = self;
	self.cpicker_button:SetNormalFontObject("GameFontNormalLarge");
	self.cpicker_button:Hide()
	--texture
	local cpicker_button_tex = cpicker_button:CreateTexture(nil, "ARTWORK");
	cpicker_button_tex:SetTexture(1,1,1,1);
	cpicker_button_tex:SetAllPoints()
	cpicker_button:SetNormalTexture(cpicker_button_tex);	
	cpicker_button:SetHighlightTexture("Interface/Buttons/UI-Panel-Button-Highlight")
	self.brushColorSample = cpicker_button_tex;

	--text_button
	--buttonframe
	self.text_button = CreateFrame("Button", "text_button", UIParent)
	self.text_button:SetPoint("TOP", UIParent, "TOP", -110, -40)
	self.text_button:SetWidth(100)
	self.text_button:SetHeight(40)
	self.text_button:SetScript("OnClick", self.buttons["Text"]);
	self.text_button.pad = self;
	self.text_button:SetText("Text")
	self.text_button:SetNormalFontObject("GameFontNormalLarge")
	self.text_button:Hide()

	--textures
	local tb_ntex = self.text_button:CreateTexture()
	tb_ntex:SetTexture("Interface/Buttons/UI-Panel-Button-Up")
	tb_ntex:SetTexCoord(0, 0.625, 0, 0.6875)
	tb_ntex:SetAllPoints()	
	self.text_button:SetNormalTexture(tb_ntex)
	
	local tb_htex = self.text_button:CreateTexture()
	tb_htex:SetTexture("Interface/Buttons/UI-Panel-Button-Highlight")
	tb_htex:SetTexCoord(0, 0.625, 0, 0.6875)
	tb_htex:SetAllPoints()
	self.text_button:SetHighlightTexture(tb_htex)
	
	local tb_ptex = self.text_button:CreateTexture()
	tb_ptex:SetTexture("Interface/Buttons/UI-Panel-Button-Down")
	tb_ptex:SetTexCoord(0, 0.625, 0, 0.6875)
	tb_ptex:SetAllPoints()
	self.text_button:SetPushedTexture(tb_ptex)

	--clear_button
	--buttonframe
	self.clear_button = CreateFrame("Button", "clear_button", UIParent)
	self.clear_button:SetPoint("TOP", UIParent, "TOP", 130, -40)
	self.clear_button:SetWidth(110)
	self.clear_button:SetHeight(40)	
	self.clear_button:SetText("Clear Canvas")
	self.clear_button:SetNormalFontObject("GameFontNormalLarge")
	self.clear_button:SetScript("OnClick", self.buttons["Clear"]);
	self.clear_button.pad = self;
	self.clear_button:Hide()
	
	--textures
	local c_ntex = self.clear_button:CreateTexture()
	c_ntex:SetTexture("Interface/Buttons/UI-Panel-Button-Up")
	c_ntex:SetTexCoord(0, 0.625, 0, 0.6875)
	c_ntex:SetAllPoints()	
	self.clear_button:SetNormalTexture(c_ntex)

	
	local c_htex = self.clear_button:CreateTexture()
	c_htex:SetTexture("Interface/Buttons/UI-Panel-Button-Highlight")
	c_htex:SetTexCoord(0, 0.625, 0, 0.6875)
	c_htex:SetAllPoints()
	self.clear_button:SetHighlightTexture(c_htex)
	
	local c_ptex = self.clear_button:CreateTexture()
	c_ptex:SetTexture("Interface/Buttons/UI-Panel-Button-Down")
	c_ptex:SetTexCoord(0, 0.625, 0, 0.6875)
	c_ptex:SetAllPoints()
	self.clear_button:SetPushedTexture(c_ptex)

	--escape_button_thing
	self.escape_button = CreateFrame("Button", "ArtPad_MainFrame_Close", UIParent);
	self.escape_button:SetScript("OnClick", self.buttons["Close"]);
	self.escape_button.pad = self;
	self.escape_button:Hide()
	
	self.mainFrame:SetScript("OnEnter", self.OnEnter);
	self.mainFrame:SetScript("OnLeave", self.OnLeave);

	self.secretFrame = CreateFrame("Frame", nil, nil);
	self.secretFrame:SetScript("OnMouseWheel", self.OnMouseWheel);
	self.secretFrame:EnableMouseWheel(true);
	self.secretFrame.pad = self;

	self.secretFrame:SetWidth(4096);
	self.secretFrame:SetHeight(2160);
	self.secretFrame:SetScale(1);
	self.secretFrame:SetPoint("CENTER");
	self.secretFrame:SetClampedToScreen(false);
	self.secretFrame:Hide()

	self.mainFrame:EnableMouse(true);	

	self.mainFrame:SetScript("OnMouseDown", self.OnMouseDown);
	self.mainFrame:SetScript("OnMouseUp", self.OnMouseUp);

	self.mainFrame:SetScript("OnShow", self.OnShow);
	self.mainFrame:SetScript("OnHide", self.OnHide);

	self.textInput:SetScript("OnEnterPressed", self.OnTextEnter);
	self.textInput:SetScript("OnEscapePressed", self.OnTextEscape);

end;

function ArtPad.FrameMouseDown(frame)
	if (IsShiftKeyDown()) then
		frame:StartMoving();
		return true;
--	elseif (IsAltKeyDown()) then
--		local w = frame:GetWidth();
--		local h = frame:GetHeight();
--		local x, y = frame:GetCenter();
--		local mx, my = GetCursorPosition();
--		local scaleL, scaleW;
--		scaleL = frame:GetScale();
--		scaleW = UIParent:GetScale();
--		mx = mx/scaleW;
--		my = my/scaleW;
--		x = x*scaleL;
--		y = y*scaleL
--		x = mx - x;
--		y = my - y;
--		x = x/w*h;
--		if (abs(x) > abs(y)) then
--			if (x > 0) then
--				frame:StartSizing("RIGHT");
--			else
--				frame:StartSizing("LEFT");
--			end;
--		else
--			if (y > 0) then
--				frame:StartSizing("TOP");
--			else
--				frame:StartSizing("BOTTOM");
--			end;
--		end;
--		return true;
	end;
	return false;
end;

function ArtPad.FrameMouseUp(frame)
	frame:StopMovingOrSizing();
end;

--[[ ColorPicker Handling ]]
function ArtPad.ColorPicker_Callback(restore)
	local self = ArtPad;
	local newR, newG, newB, newA;
	if restore then
	-- The user bailed, we extract the old color from the table created by ShowColorPicker.
	newR, newG, newB, newA = unpack(restore);
	else
	-- Something changed
	newA, newR, newG, newB = OpacitySliderFrame:GetValue(), ColorPickerFrame:GetColorRGB();
	end;
	-- update the brush
	self:SetColor(newR,newG,newB,newA);
end;
-- [[ Drawing ]]

ArtPad.brushColor = { r = 1.0; g = 1.0; b = 1.0; a = 0.75; };

ArtPad.mainLines = {};
ArtPad.junkLines = {};
ArtPad.mainTexts = {};
ArtPad.junkTexts = {};

function ArtPad:SendLine(x, y, oldX, oldY, brush)
	if oldY and oldY then
		SendAddonMessage("ArtPad", "d("..x..","..y..","..oldX..","..oldY..","..brush.r..","..brush.g..","..brush.b..","..brush.a..")", ArtPad_Settings["Mode"]);
	end;
end;

function ArtPad:SendClear(x, y, oldX, oldY)
	if oldY and oldY then
		SendAddonMessage("ArtPad", "c("..x..","..y..","..oldX..","..oldY..")", ArtPad_Settings["Mode"]);
	elseif x and y then
		SendAddonMessage("ArtPad", "c("..x..","..y..")", ArtPad_Settings["Mode"]);
	else
		SendAddonMessage("ArtPad", "c()", ArtPad_Settings["Mode"]);
	end;
end;

function ArtPad:SendColor(r, g, b, a)
	SendAddonMessage("ArtPad", "f("..r..","..g..","..b..","..a..")", ArtPad_Settings["Mode"]);
end;

function ArtPad:SendText(x, y, text)
	SendAddonMessage("ArtPad", "t("..x..","..y..",\""..text.."\")", ArtPad_Settings["Mode"]);
end;

function ArtPad:DrawLine(x, y, oldX, oldY, brush)
	if oldX and oldY then
		self:CreateLine(x,y, oldX, oldY, brush);
	end;
end;

function ArtPad:ClearLine(x, y, oldX, oldY)
	for i = #self.mainLines, 1, -1 do
		local px = self.mainLines[i]["lax"];
		local py = self.mainLines[i]["lay"];
		local qx = self.mainLines[i]["lbx"];
		local qy = self.mainLines[i]["lby"];
		-- TODO: Don't only check for intersections, but also min distance
		-- http://www.softsurfer.com/Archive/algorithm_0106/algorithm_0106.htm
		if self:LineLineIntersect(x,y,oldX,oldY,px,py,qx,qy) then
			self:JunkLine(i);
		end;
	end;
	for i = #self.mainTexts, 1, -1 do
		local px = self.mainTexts[i]["lax"];
		local py = self.mainTexts[i]["lay"];
		local qx = self.mainTexts[i]["lbx"];
		local qy = self.mainTexts[i]["lby"];
		if self:LineLineIntersect(x,y,oldX,oldY,px,py,qx,qy) then
			self:JunkText(i);
		end;
	end;
end;

function ArtPad:PointPointDist(px, py, qx, qy)
	return math.sqrt(math.pow(px-qx,2) + math.pow(py-qy,2));
end;

function ArtPad:LinePointDist(lax, lay, lbx, lby, px, py)
	-- http://www.softsurfer.com/Archive/algorithm_0102/algorithm_0102.htm
	-- Note: Not working
	return math.abs((lay-lby)*px+(lbx-lax)*py+(lax*lby-lbx*lay)/
		math.sqrt(math.pow(lbx-lax,2)+math.pow(lby-lay,2)));
end;

function ArtPad:LineLineIntersect(ax0, ay0, ax1, ay1, bx0, by0, bx1, by1)
	--http://www.softsurfer.com/Archive/algorithm_0104/algorithm_0104B.htm#intersect2D_SegSeg()
	local ux, uy = ax1-ax0, ay1-ay0;
	local vx, vy = bx1-bx0, by1-by0;
	local wx, wy = ax0-bx0, ay0-by0;
	local D = ux*vy - uy*vx;

	if (D == 0) then
		-- Parallel
		return false;
	else
		local sI = (vx*wy-vy*wx) / D;
		if (sI < 0 or sI > 1) then -- no intersect with S1
			return false;
		end;

		local tI = (ux*wy-uy*wx) / D;
		if (tI < 0 or tI > 1) then -- no intersect with S2
			return false;
		end;

		return true;
	end;
end;

-- A square brush
function ArtPad:ClearCanavas()
	if ArtPad_Settings["WarnClear"] then
		-- TODO: Ask for permission to clear
	end;
	for i = #self.mainLines, 1, -1 do
		self:JunkLine(i);
	end;
	for i = #self.mainTexts, 1, -1 do
		self:JunkText(i);
	end;
end;

function ArtPad:SetColor(r, g, b, a)
	self.brushColor.r = r;
	self.brushColor.g = g;
	self.brushColor.b = b;
	self.brushColor.a = a;
	self.brushColorSample:SetTexture(r,g,b,a);
end;

function ArtPad:SetTexColor(tex, brush)
	tex:SetVertexColor(brush.r,
		brush.g,
		brush.b,
		brush.a);
end;

-- [[ Line Handling ]]
-- Allocator
function ArtPad:CreateLine(x, y, a, b, brush)
	local ix = math.floor(x);
	local iy = math.floor(y);
	local ia = math.floor(a);
	local ib = math.floor(b);

	local cx, cy = (ix + ia)/2, (iy + ib)/2;
	local dx, dy = ix-ia, iy-ib;
	local dmax = math.max(math.abs(dx),math.abs(dy));
	local dr = math.sqrt(dx*dx + dy*dy);
	local scale = 1/dmax*32;
	local sinA, cosA = dy/dr*scale, dx/dr*scale;
	if dr == 0 then
		return nil;
	end

	local pix;
	--if #(self.junkLines) > 0 then
	--	pix = table.remove(self.junkLines); -- Recycling ftw!
	--else
	pix = self.mainFrame:CreateTexture(nil, "OVERLAY");
	pix:SetTexture("Interface\\AddOns\\ArtPad\\line.tga");
	--end;
	self:SetTexColor(pix, brush);
	pix:ClearAllPoints();

	pix:SetPoint("CENTER", self.mainFrame, "BOTTOMLEFT", cx, cy);
	pix:SetWidth(dmax); pix:SetHeight(dmax);
	pix:SetTexCoord(self.GetCoordsForTransform(
		cosA, sinA, -(cosA+sinA)/2+0.5,
		-sinA, cosA, -(-sinA+cosA)/2+0.5));
	pix:Show();
	pix["lax"] = ix;
	pix["lay"] = iy;
	pix["lbx"] = ia;
	pix["lby"] = ib;

	table.insert(self.mainLines, pix);

	return pix, #self.mainLines;
end;

-- Deallocator
function ArtPad:JunkLine(id)
	if self.mainLines[id] then
		local pix = table.remove(self.mainLines, id);
		if pix then
			table.insert(self.junkLines, pix);
			pix:Hide();
		end;
	end;
end;

-- [[ Text Handling ]]
function ArtPad:CreateText (x, y, text)
	local ix = math.floor(x);
	local iy = math.floor(y);

	if #(self.junkTexts) > 0 then
		tex = table.remove(self.junkTexts); -- Recycling ftw!
	else
		tex = self.mainFrame:CreateFontString(nil, "OVERLAY");
	end;
	tex:SetFont("Fonts\\FRIZQT__.TTF",12);
	tex:SetJustifyH("LEFT");
	tex:SetPoint("BOTTOMLEFT", self.mainFrame, "BOTTOMLEFT", ix, iy);
	tex:SetTextColor(self.brushColor.r, self.brushColor.g,
		self.brushColor.b, self.brushColor.a);

	tex:SetText(text);
	tex:Show();
	tex["lax"] = ix;
	tex["lay"] = iy;
	tex["lbx"] = ix + tex:GetWidth();
	tex["lby"] = iy + tex:GetHeight();

	table.insert(self.mainTexts, tex);

	return tex, #self.mainTexts;
end;

function ArtPad:JunkText(id)
	if self.mainTexts[id] then
		local tex = table.remove(self.mainTexts, id);
		if tex then
			table.insert(self.junkTexts, tex);
			tex:Hide();
		end;
	end;
end;

-- [[ Projection ]]
function ArtPad.GetCoordsForTransform(A, B, C, D, E, F)
	-- http://www.wowwiki.com/SetTexCoord_Transformations
	local det = A*E - B*D;
	local ULx, ULy, LLx, LLy, URx, URy, LRx, LRy;

	ULx, ULy = ( B*F - C*E ) / det, ( -(A*F) + C*D ) / det;
	LLx, LLy = ( -B + B*F - C*E ) / det, ( A - A*F + C*D ) / det;
	URx, URy = ( E + B*F - C*E ) / det, ( -D - A*F + C*D ) / det;
	LRx, LRy = ( E - B + B*F - C*E ) / det, ( -D + A -(A*F) + C*D ) / det;

	return ULx, ULy, LLx, LLy, URx, URy, LRx, LRy;
end;

    
--[[ Slash Commands ]]
SlashCmdList["ARTPAD"] = ArtPad.OnSlashCommand;
SLASH_ARTPAD1 = "/artpad";
SLASH_ARTPAD2 = "/ap";


-- [[ Binding Constants ]]

BINDING_HEADER_ARTPAD = "ArtPad";
BINDING_NAME_ARTPAD_SHOW = "Show Art Window";
BINDING_NAME_ARTPAD_HIDE = "Hide Art Window";
BINDING_NAME_ARTPAD_TOGGLE = "Toggle Art Window";

-- [[ Listen for events ]]

ArtPad:SetUpEvents();

