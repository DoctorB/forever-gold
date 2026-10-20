-- Widgets: small builders over templates verified on Forever by the
-- project's other addons (UIPanelButtonTemplate, UICheckButtonTemplate,
-- InputBoxTemplate, BasicFrameTemplateWithInset, BackdropTemplate).
-- Frames are created lazily, only when a window is first opened.
local _, ns = ...

local W = {}
ns.UI.Widgets = W

W.GOLD = { 0.90, 0.71, 0.13 }
W.EMERALD = { 0.18, 0.80, 0.53 }
W.MUTED = { 0.65, 0.65, 0.65 }
W.WARN = { 1.0, 0.45, 0.30 }

function W.Text(parent, font, justify)
  local text = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
  text:SetJustifyH(justify or "LEFT")
  if text.SetWordWrap then text:SetWordWrap(false) end
  return text
end

function W.Button(parent, label, width, onClick)
  local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  button:SetSize(width or 100, 22)
  button:SetText(label)
  button:SetScript("OnClick", function() onClick(button) end)
  return button
end

function W.Check(parent, label, onClick)
  local check = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
  check:SetSize(24, 24)
  local text = W.Text(check, "GameFontHighlightSmall")
  text:SetPoint("LEFT", check, "RIGHT", 2, 0)
  text:SetText(label)
  check.label = text
  check:SetScript("OnClick", function() onClick(check:GetChecked() and true or false) end)
  return check
end

function W.Input(parent, width)
  local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
  box:SetSize(width or 80, 20)
  box:SetAutoFocus(false)
  box:SetScript("OnEscapePressed", function() box:ClearFocus() end)
  box:SetScript("OnEnterPressed", function() box:ClearFocus() end)
  return box
end

-- Read-only (or editable) multi-line text inside a mouse-wheel scroll frame.
function W.ScrollText(parent, editable)
  local scroll = CreateFrame("ScrollFrame", nil, parent)
  local edit = CreateFrame("EditBox", nil, scroll)
  edit:SetMultiLine(true)
  edit:SetAutoFocus(false)
  edit:SetFontObject("GameFontHighlightSmall")
  edit:SetWidth(300)
  edit:SetScript("OnEscapePressed", function() edit:ClearFocus() end)
  if not editable then
    edit:SetScript("OnTextChanged", function(_, userInput)
      if userInput and scroll.text then edit:SetText(scroll.text) end
    end)
  end
  scroll:SetScrollChild(edit)
  scroll:EnableMouseWheel(true)
  scroll:SetScript("OnMouseWheel", function(_, delta)
    local range = scroll:GetVerticalScrollRange() or 0
    local value = (scroll:GetVerticalScroll() or 0) - delta * 40
    if value < 0 then value = 0 end
    if value > range then value = range end
    scroll:SetVerticalScroll(value)
  end)
  scroll:SetScript("OnSizeChanged", function(_, width) edit:SetWidth(math.max(50, (width or 300) - 8)) end)
  function scroll.SetText(_, text)
    scroll.text = text
    edit:SetText(text or "")
    scroll:SetVerticalScroll(0)
  end
  function scroll.GetText() return edit:GetText() end
  scroll.edit = edit
  return scroll
end

function W.Color(text, rgb)
  return string.format("|cff%02x%02x%02x%s|r", rgb[1] * 255, rgb[2] * 255, rgb[3] * 255, text)
end
