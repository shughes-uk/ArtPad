local addon = ...

local frame = CreateFrame("Frame", addon .. "ConfigFrame", InterfaceOptionsFramePanelContainer)
frame.name = addon
frame:Hide()
frame:SetScript("OnShow", function(frame)
    local title = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("ArtPad Configuration")

    local subtitle = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    subtitle:SetHeight(35)
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    subtitle:SetPoint("RIGHT", frame, -32, 0)
    subtitle:SetNonSpaceWrap(true)
    subtitle:SetJustifyH("LEFT")
    subtitle:SetJustifyV("TOP")
    subtitle:SetText("This panel can be used to configure ArtPad.")

    local slider = CreateFrame("Slider", addon .. "ConfigFontSlider", frame, "OptionsSliderTemplate")
    slider:SetPoint("TOPLEFT", subtitle, "BOTTOMLEFT", 0, -15)
    slider:SetMinMaxValues(0.1, 4)
    slider:SetValueStep(0.1)
    slider.text = _G[slider:GetName() .. "Text"]
    slider.low = _G[slider:GetName() .. "Low"]
    slider.high = _G[slider:GetName() .. "High"]
   
    slider.text:SetText("Canvas Scale")
    slider.low:SetText("Small")
    slider.high:SetText("Large")
    slider.tooltipText = "Configure the scale factor of the ArtPad canvas"

    slider:SetScript("OnValueChanged", function(self, value)
        ArtPad_Settings["Scale"] = value;
        ArtPad.mainFrame:SetScale(value);
    end)

    local Refresh;
    function Refresh()
        if not frame:IsVisible() then return end       
        slider:SetValue(ArtPad_Settings["Scale"])
    end

    frame:SetScript("OnShow", Refresh) 
    Refresh()
end)

InterfaceOptions_AddCategory(frame)
