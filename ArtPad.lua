--[[
--
--	ArtPad
--	by Dust-Turalyon-EU , Snaxxramas-DefiasBrotherhood-EU ?
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
-- c()			-- Clear Canvas
-- f(<r>,<g>,<b>,<a>)	-- Change to given color
-- t(<x>,<y>,"<t>")	-- Draw text t with bottom left corner at (x,y)
local DEBUG = false;
function printd(msg)
	if DEBUG then 
		print(msg)
	end;
end;
ArtPad = LibStub("AceAddon-3.0"):NewAddon("MyAddon", "AceComm-3.0", "AceSerializer-3.0")
-- [[ Version data from the TOC file ]]
ArtPad.version = GetAddOnMetadata("ArtPad", "Version");
ArtPad.saveVersion = GetAddOnMetadata("ArtPad", "X-SaveVersion");
ArtPad.protocolVersion = GetAddOnMetadata("ArtPad", "X-ProtocolVersion");
ArtPad.main_prefix = "ArtPad"..ArtPad.protocolVersion;
ArtPad.persist_prefix = "ArtPad_P"..ArtPad.protocolVersion;
-- [[ Event grabbin ]]
ArtPad.eventListener = CreateFrame("FRAME");
-- [[ Canvas junk ]]
ArtPad.canvasSize = {["X"] = 3840 ; ["Y"] = 2160 };
ArtPad.sendingCanvas = false;
ArtPad.receivingCanvas = false;
ArtPad.missingLineCount = 0;
ArtPad.gotLineCount = false;

-- [[ Event Handlers]]
function ArtPad:Variables_Loaded()
	--printd("VAR LOADED");
end

function ArtPad:Player_Login()
	-- [[ Get Libs ]]
	ArtPad.LibSerialize = LibStub:GetLibrary("AceSerializer-3.0")
	ArtPad.LibCompress = LibStub:GetLibrary("LibCompress")
	ArtPad.LibCompressEncode = ArtPad.LibCompress:GetAddonEncodeTable()
	-- [[ Sort settings ]]
	local ArtPad_Settings_Default = {
				["SaveVersion"]	= self.saveVersion;
				["AdminOnly"]	= false; -- Ignore non-raid admins
				["WarnClear"]	= true; -- Warn before clearing screen
				["Mode"]		= "GUILD";
				["Scale"]		= 1;
				["MinimapIcon"] = {};
				["OneTimeMessage"] = false;
				["Debug"] = false;
			};
	if not ArtPad_Settings then
		ArtPad_Settings = ArtPad_Settings_Default;
	elseif ArtPad_Settings["SaveVersion"] < self.saveVersion then
		ArtPad_Settings = ArtPad_Settings_Default;
	end;
	DEBUG = ArtPad_Settings["Debug"]
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
    -- [[ Version checking ]]
    self:RegisterComm("ArtPad_Version", ArtPad.Version_Msg)
    self:SendCommMessage("ArtPad_Version",tostring(ArtPad.version),ArtPad_Settings["Mode"])

    -- [[ Start watching the persistence channel, with a backup timer incase nobody is around ]]
    self:RegisterComm(ArtPad.persist_prefix, ArtPad.Persist_Channel_Msg)
    C_Timer.After(5, ArtPad.PersistTimer_Expired)

    -- [[ Request line count/avalability ]]
    self:SendCommMessage(ArtPad.persist_prefix,"l()",ArtPad_Settings["Mode"]);
end

function ArtPad.Version_Msg(prefix, message, disType, sender)
	local self = ArtPad;
	if prefix == "ArtPad_Version" then
		local their_version = tonumber(message)
		if their_version then
			if their_version > tonumber(ArtPad.version) then
				-- new version out!
				self.versionText:SetText("ArtPad v."..self.version.." - UPDATE AVAILABLE (v"..their_version..")");
			end
		end
	end
end

function ArtPad:Player_Regen_Disabled()
	-- Close window when entering combat
	if self.mainFrame:IsShown() then
		self.mainFrame:Hide();
	end;
end;

function ArtPad.PersistTimer_Expired()
	if not ArtPad.gotLineCount then
		printd("Nobody replied to canvas info request. Fresh canvas")
		ArtPad.missingLineCount = 0;
		ArtPad.gotLineCount = true;
		ArtPad:RegisterComm(ArtPad.main_prefix, ArtPad.Chat_Msg_Addon)
	end
end

function ArtPad:GenerateAvailablityTable()
	local available_table = {}
	local startindex = 1;
	for i = 1 , #self.mainLines, 1 do 
	   if not self.mainLines[i] then
	      if startindex ~= i then
	         table.insert(available_table, {startindex, i-1})
	         startindex = i + 1
	      else
	         startindex = i + 1
	      end
	   end
	end
	if startindex ~= #self.mainLines +1 then
	   table.insert(available_table, {startindex, #ArtPad.mainLines})
	end
	return available_table
end

local REQUEST_MAX = 50;

function ArtPad:GenerateRequestTable(aval_table)
	local request_table = {};
	local r_count = 0;
	for k,range in pairs(aval_table) do
		start_rindex = 1;
		for i=range[1] , range[2] , 1  do
			if self.mainLines[i] then
				if start_rindex ~= i then					
					if r_count + ((i-1) - start_rindex) > REQUEST_MAX then
						table.insert(request_table, {start_rindex, start_rindex + (REQUEST_MAX - r_count)})
						--we can return early as we have hit the max request size
						return request_table;
					else
						table.insert(request_table, {start_rindex, i-1});
						r_count = r_count + (i-1) - start_rindex
						start_rindex = i + 1;
					end;
				else
					start_rindex = i + 1;
				end;
			end;
		end;
		if start_rindex ~= range[2] + 1 then
			if r_count + ((range[2]) - start_rindex) > REQUEST_MAX then
				table.insert(request_table, {start_rindex, start_rindex + (REQUEST_MAX - r_count)})
			else
				table.insert(request_table, {start_rindex, range[2]});
			end;
		end;
	end;
	return request_table;
end;

local TRANSFER_TIMEOUT = 0;
--[[
**Protocol spec for persist channel**

*Broadcasts*
l() - Request to be sent the ranges of lines available

*Whispers* 
Note - These are always serialized with aceserialize then compressed/encoded with libcompress)

data.availablity = { {1,100} , {150 , 200} } -- table of ranges of available lines
data.lines = { {index_of_line, line} } -- table of lines, lines are paired with their index and are in string format identical to the normal channel
data.request = { {1,100} , {150,200} } -- table of ranges to request, identical structure to the availablity table

]]
function ArtPad.Persist_Channel_Msg(prefix, message, disType, sender)
	local self = ArtPad;
	printd(prefix,message,disType,sender)

	--broadcasts	
	if prefix == self.persist_prefix and sender ~= UnitName("player") and disType == ArtPad_Settings["Mode"] then
		--request line table
		local linecount_request = string.match(message, "l%(%)")
		if linecount_request then
			local table;
			if self.gotLineCount then
				table = {availability = self:GenerateAvailablityTable(), linecount = #self.mainLines}
			end
			printd("Sending availability table")
			self:SendCommMessage(self.persist_prefix,self:EncodeData(table),"WHISPER",sender,"ALERT");
			return;
		end		
	end
	--whispers
	if prefix == self.persist_prefix and sender ~= UnitName("player") and disType == "WHISPER" then
		--whispers are sent compressed/encoded unlike broadcasts as they can be an huge
		data = self:DecodeData(message);
		if data then
			--line availability table
			if data.availability and not self.receivingCanvas and (self.missingLineCount > 0 or not self.gotLineCount)  then
				if not self.gotLineCount then
					for i= 1, data.linecount, 1 do
						table.insert(self.mainLines,false)
					end
					self.gotLineCount = true;
					self.missingLineCount = data.linecount;
					--it's safe to subscribe to canvas drawing now as our indexing is set up correctly
		    		self:RegisterComm(ArtPad.main_prefix, ArtPad.Chat_Msg_Addon)
		    		--start the timer to get new lines regularly
		    		C_Timer.After(2, ArtPad.GetMissingLines)
		    		printd("Got linecount")	
				end
				--check if they have any lines we need and request them
				local request_table = self:GenerateRequestTable(data.availability)
				if #request_table ~= 0 then
					printd("Requesting lines:")
					for k , v in pairs(request_table) do
						printd('istart '..tostring(v[1])..' iend '..tostring(v[2]))
					end
					GetMissingTimeout = 0;
					self:SendCommMessage(self.persist_prefix,self:EncodeData({request=request_table}),"WHISPER",sender,"ALERT");
					TRANSFER_TIMEOUT = 0;
					self.receivingCanvas = true;
					C_Timer.After(2,ArtPad.TransferTimeoutCheck)
				end;
			--sending info
			elseif data.sending then
			--someone is sending us some lines
				local progress = data.sending
				printd("someone is sending us lines, progress %"..tostring(progress))
				self.receivingCanvas = true;				
				if progress ~= 100 then
					--reset the timeout clock
					TRANSFER_TIMEOUT = 0;
				else
					--transfer complete
					self.receivingCanvas = false;
				end				
			--request for lines			
			elseif data.request then
				--grab the lines we need
				local lines = {}
				for k, range in pairs(data.request) do
					for i = range[1] , range[2], 1 do
						lines[i] = "d("..self.mainLines[i]["lax"]..","..self.mainLines[i]["lay"]..","..self.mainLines[i]["lbx"]..","..self.mainLines[i]["lby"]..","..self.mainLines[i]["r"]..","..self.mainLines[i]["g"]..","..self.mainLines[i]["b"]..","..self.mainLines[i]["a"]..")"
					end
				end
				--compress it up
				local to_send = self:EncodeData({lines=lines})
				--whisper it back, can take a long time.. is async though
				printd("Sending lines")
				self:SendCommMessage(self.persist_prefix,to_send,"WHISPER",sender,"BULK",self.SendMsg_Callback,sender)
				self.sendingCanvas = true;

			--they gave us some lines, draw them.
			elseif data.lines then
				printd("got lines")
				for i,line in pairs(data.lines) do
					local x,y,a,b,brushR,brushG,brushB,brushA = string.match(line, "d%((%d+),(%d+),(%d+),(%d+),(%d+%.?%d*),(%d+%.?%d*),(%d+%.?%d*),(%d+%.?%d*)%)");
					if x then
						if not self.mainFrame:IsShown() and artpadLauncher then
							artpadLauncher.icon = 'Interface\\AddOns\\Artpad\\iconact';
						end					
						self:DrawLine(x,y,a,b,{r=brushR,g=brushG,b=brushB,a=brushA},i);
						self.missingLineCount = self.missingLineCount - 1;
					end;
				end;
				self.receivingCanvas = false;
			end;
		end;
	end;
end;

function ArtPad.TransferTimeoutCheck()
	if TRANSFER_TIMEOUT < 25 and ArtPad.receivingCanvas then
		C_Timer.After(1,ArtPad.TransferTimeoutCheck)
		TRANSFER_TIMEOUT = TRANSFER_TIMEOUT + 1;
	elseif ArtPad.receivingCanvas then
		printd("Transfer timed out")
		ArtPad.receivingCanvas = false;
	end;
end;

local GetMissingTimeout = 0;
function ArtPad.GetMissingLines()
	local self = ArtPad;
	if self.missingLineCount == 0 then
		printd("got entire canvas")
		return;
	end;
	if not self.receivingCanvas then
		if GetMissingTimeout < 10 then
			printd("Broadcasting for line availability")
			self:SendCommMessage(ArtPad.persist_prefix,"l()",ArtPad_Settings["Mode"]);
			GetMissingTimeout  = GetMissingTimeout + 1;
			C_Timer.After(5, ArtPad.GetMissingLines)
		else
			printd("Couldn't get lines, giving up")
			self.missingLineCount = 0;
		end;
	end;
end

function ArtPad.Chat_Msg_Addon(prefix, message, disType, sender)
	local self = ArtPad;	
	--broadcasts
	if prefix == self.main_prefix and sender ~= UnitName("player") and disType == ArtPad_Settings["Mode"] then
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
			self:ClearCanvas();
			self:Message(sender .. " just cleared the canvas")
			return;
		end;		
	end;
end;

function ArtPad.SendMsg_Callback(arg,sent,total)
	local progress = sent/total * 100
	if sent == total then
		ArtPad.sendingCanvas = false;
	end
	ArtPad:SendCommMessage(ArtPad.persist_prefix,ArtPad:EncodeData({sending=progress}),"WHISPER",arg,"ALERT")
end

function ArtPad:DecodeData(data)
	local decoded = self.LibCompressEncode:Decode(data)		
	--Decompress the decoded data
	local decompressed, message = self.LibCompress:DecompressHuffman(decoded)
	if(not decompressed) then
		printd("ArtPad: error decompressing: " .. message)
		return nil
	end		
	-- Deserialize the decompressed data
	local success, final = self:Deserialize(decompressed)
	if (not success) then
		printd("ArtPad: error deserializing " .. final)
		self._debug_decompressed = decompressed
		return nil
	end
	return final
end

function ArtPad:EncodeData(data)
	local serialized = self:Serialize(data)
	local compressed = self.LibCompress:CompressHuffman(serialized)
	local encoded = self.LibCompressEncode:Encode(compressed)
	return encoded
end

ArtPad.events = {
	["VARIABLES_LOADED"] = ArtPad.Variables_Loaded;
	["PLAYER_LOGIN"] = ArtPad.Player_Login;
	["PLAYER_REGEN_DISABLED"] = ArtPad.Player_Regen_Disabled;
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
			self:ClearCanvas();
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
	["ArtMode"] =
		function (frame, button, down)
			local self = frame.pad;
			if self.mainFrame:GetFrameStrata() == "BACKGROUND" then
				self.mainFrame:SetFrameStrata("FULLSCREEN");
				self.canvasBackground:SetTexture(0,0,0,0.8);
			else
				self.mainFrame:SetFrameStrata("BACKGROUND");
				self.canvasBackground:SetTexture(0,0,0,0.5);
			end
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
		self.artmode_button:Show()
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
	self.artmode_button:Hide()
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
	["debug"] = function(self)
			ArtPad_Settings["Debug"] = not ArtPad_Settings["Debug"];
			DEBUG =  not ArtPad_Settings["Debug"];
			self:Message("Debug mode now: "..tostring(DEBUG))
		end;
	["testencoding"] =
		function(self)
			local lines = {}
			for i = #self.mainLines, 1, -1 do
				lines[i] = "d("..self.mainLines[i]["lax"]..","..self.mainLines[i]["lay"]..","..self.mainLines[i]["lbx"]..","..self.mainLines[i]["lby"]..","..self.mainLines[i]["r"]..","..self.mainLines[i]["g"]..","..self.mainLines[i]["b"]..","..self.mainLines[i]["a"]..")"
			end
			--compress it up
			local encoded = self:EncodeData({canvas=lines})
			local decoded = self:DecodeData(encoded)
		end;
	["dumpvar"] = 
		function(self)
			print("Receiving canvas : " ..tostring(self.receivingCanvas))
			print("Sending : "..tostring(self.sendingCanvas))
		end;
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
			self:ClearCanvas();
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
	frameT:SetFrameStrata("TOOLTIP");
	frameT:Hide();

	self.canvasBackground = frameM:CreateTexture(nil, "BACKGROUND");
	self.canvasBackground:SetTexture(0,0,0,0.5);
	self.canvasBackground:SetAllPoints(frameM);

	

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
	self.cpicker_button:SetFrameStrata("FULLSCREEN")
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
	self.text_button:SetPoint("TOP", UIParent, "TOP", -100, -40)
	self.text_button:SetWidth(100)
	self.text_button:SetHeight(40)
	self.text_button:SetScript("OnClick", self.buttons["Text"]);
	self.text_button.pad = self;
	self.text_button:SetText("Text")
	self.text_button:SetNormalFontObject("GameFontNormalLarge")
	self.text_button:SetFrameStrata("FULLSCREEN")
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
	self.clear_button:SetPoint("TOP", UIParent, "TOP", 120, -40)
	self.clear_button:SetWidth(110)
	self.clear_button:SetHeight(40)	
	self.clear_button:SetText("Clear Canvas")
	self.clear_button:SetNormalFontObject("GameFontNormalLarge")
	self.clear_button:SetScript("OnClick", self.buttons["Clear"]);
	self.clear_button.pad = self;
	self.clear_button:SetFrameStrata("FULLSCREEN")
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

	--artmode_button
	--buttonframe
	self.artmode_button = CreateFrame("Button", "artmode_button", UIParent)
	self.artmode_button:SetPoint("TOP", UIParent, "TOP", 240, -40)
	self.artmode_button:SetWidth(120)
	self.artmode_button:SetHeight(40)	
	self.artmode_button:SetText("Toggle ArtMode")
	self.artmode_button:SetNormalFontObject("GameFontNormalLarge")
	self.artmode_button:SetScript("OnClick", self.buttons["ArtMode"]);
	self.artmode_button.pad = self;
	self.artmode_button:SetFrameStrata("FULLSCREEN")
	self.artmode_button:Hide()
	
	--textures
	local am_ntex = self.artmode_button:CreateTexture()
	am_ntex:SetTexture("Interface/Buttons/UI-Panel-Button-Up")
	am_ntex:SetTexCoord(0, 0.625, 0, 0.6875)
	am_ntex:SetAllPoints()	
	self.artmode_button:SetNormalTexture(am_ntex)

	
	local am_htex = self.artmode_button:CreateTexture()
	am_htex:SetTexture("Interface/Buttons/UI-Panel-Button-Highlight")
	am_htex:SetTexCoord(0, 0.625, 0, 0.6875)
	am_htex:SetAllPoints()
	self.artmode_button:SetHighlightTexture(am_htex)
	
	local am_ptex = self.artmode_button:CreateTexture()
	am_ptex:SetTexture("Interface/Buttons/UI-Panel-Button-Down")
	am_ptex:SetTexCoord(0, 0.625, 0, 0.6875)
	am_ptex:SetAllPoints()
	self.artmode_button:SetPushedTexture(am_ptex)

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
		local msg = "d("..x..","..y..","..oldX..","..oldY..","..brush.r..","..brush.g..","..brush.b..","..brush.a..")"
		ArtPad:SendCommMessage(ArtPad.main_prefix, msg, ArtPad_Settings["Mode"], nil, "BULK")			
	end;
end;

function ArtPad:SendClear(x, y, oldX, oldY)
	local msg;
	if oldY and oldY then
		msg = "c("..x..","..y..","..oldX..","..oldY..")";
	elseif x and y then
		msg= "c("..x..","..y..")";
	else
		msg = "c()";
	end;
	ArtPad:SendCommMessage(ArtPad.main_prefix, msg, ArtPad_Settings["Mode"], nil, "BULK")	
end;

function ArtPad:SendColor(r, g, b, a)
	local msg = "f("..r..","..g..","..b..","..a..")";
	ArtPad:SendCommMessage(ArtPad.main_prefix, msg, ArtPad_Settings["Mode"], nil, "BULK")
end;

function ArtPad:SendText(x, y, text)
	local msg = "t("..x..","..y..",\""..text.."\")"
	ArtPad:SendCommMessage(ArtPad.main_prefix, msg, ArtPad_Settings["Mode"], nil, "BULK")
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
function ArtPad:ClearCanvas()
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
function ArtPad:CreateLine(x, y, a, b, brush, index)
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
	pix["r"] = brush.r
	pix["g"] = brush.g
	pix["b"] = brush.b
	pix["a"] = brush.a
	if index then
		table.insert(self.mainLines, index, pix)
	else
		table.insert(self.mainLines, pix);
	end

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

