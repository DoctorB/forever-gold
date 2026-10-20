-- Table: header plus rows of aligned cells, mouse-wheel scrolling, rows
-- created lazily to fit the height. Used by the History and Portfolio tabs.
--   columns = { { key, label, width (fraction), right? } }
--   rows    = { { cells = { text, ... }, colors = { [column] = rgb }, tip = { lines }? } }
local _, ns = ...

local W = ns.UI.Widgets
local Table = {}
ns.UI.Table = Table

Table.ROW_HEIGHT = 18
Table.PAD_LEFT = 10

local function pad(column)
  return column.right and 2 or Table.PAD_LEFT
end

function Table.New(parent, columns)
  local frame = CreateFrame("Frame", nil, parent)
  local self = setmetatable({ frame = frame, columns = columns, rows = {}, lines = {}, offset = 0, headers = {} },
    { __index = Table })
  for index, column in ipairs(columns) do
    local header = W.Text(frame, "GameFontNormalSmall", column.right and "RIGHT" or "LEFT")
    header:SetText(column.label)
    self.headers[index] = header
  end
  self.empty = W.Text(frame, "GameFontDisable", "CENTER")
  self.empty:SetPoint("CENTER", frame, "CENTER", 0, 0)
  frame:EnableMouseWheel(true)
  frame:SetScript("OnMouseWheel", function(_, delta)
    self.offset = math.max(0, math.min(self.offset - delta * 3, math.max(0, #self.rows - self.visible)))
    self:Render()
  end)
  frame:SetScript("OnSizeChanged", function() self:Layout() self:Render() end)
  return self
end

-- Positions headers and creates as many row lines as fit.
function Table:Layout()
  local width = self.frame:GetWidth() or 600
  local height = self.frame:GetHeight() or 200
  self.visible = math.max(1, math.floor(height / Table.ROW_HEIGHT) - 1)
  local x = 0
  for index, column in ipairs(self.columns) do
    local header = self.headers[index]
    header:ClearAllPoints()
    header:SetPoint("TOPLEFT", self.frame, "TOPLEFT", x + pad(column), 0)
    header:SetWidth(width * column.width - pad(column) - 4)
    x = x + width * column.width
  end
  for index = 1, math.max(self.visible, #self.lines) do
    local line = self.lines[index]
    if not line and index <= self.visible then
      line = CreateFrame("Frame", nil, self.frame)
      line:SetHeight(Table.ROW_HEIGHT)
      line.cells = {}
      for column = 1, #self.columns do
        line.cells[column] = W.Text(line, "GameFontHighlightSmall", self.columns[column].right and "RIGHT" or "LEFT")
      end
      local stripe = line:CreateTexture(nil, "BACKGROUND")
      stripe:SetAllPoints()
      stripe:SetColorTexture(1, 1, 1, index % 2 == 0 and 0.04 or 0)
      line:EnableMouse(true)
      line:SetScript("OnEnter", function()
        local row = line.row
        if not row or not row.tip or type(GameTooltip) ~= "table" then return end
        GameTooltip:SetOwner(line, "ANCHOR_CURSOR")
        for position, text in ipairs(row.tip) do
          if position == 1 then GameTooltip:SetText(text) else GameTooltip:AddLine(text, 0.9, 0.9, 0.9, true) end
        end
        GameTooltip:Show()
      end)
      line:SetScript("OnLeave", function() if type(GameTooltip) == "table" then GameTooltip:Hide() end end)
      self.lines[index] = line
    end
    if line then
      line:ClearAllPoints()
      line:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 0, -index * Table.ROW_HEIGHT)
      line:SetPoint("RIGHT", self.frame, "RIGHT", 0, 0)
      local cx = 0
      for column, spec in ipairs(self.columns) do
        local cell = line.cells[column]
        cell:ClearAllPoints()
        cell:SetPoint("LEFT", line, "LEFT", cx + pad(spec), 0)
        cell:SetWidth(width * spec.width - pad(spec) - 4)
        cx = cx + width * spec.width
      end
    end
  end
end

function Table:SetRows(rows, emptyText)
  self.rows = rows or {}
  self.emptyText = emptyText
  if not self.visible then self:Layout() end
  self.offset = math.min(self.offset, math.max(0, #self.rows - self.visible))
  self:Render()
end

function Table:Render()
  if not self.visible then self:Layout() end
  for index, line in ipairs(self.lines) do
    local row = index <= self.visible and self.rows[index + self.offset] or nil
    line.row = row
    if row then
      for column = 1, #self.columns do
        local cell = line.cells[column]
        cell:SetText(row.cells[column] or "")
        local color = row.colors and row.colors[column] or { 0.9, 0.9, 0.9 }
        cell:SetTextColor(color[1], color[2], color[3])
      end
      line:Show()
    else
      line:Hide()
    end
  end
  self.empty:SetText(#self.rows == 0 and (self.emptyText or "") or "")
end
