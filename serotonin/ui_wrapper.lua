--[[
This is CQC's, not made by me.
--]]


local Library = {}

-- ============= Element Object =============
local Element = {}
Element.__index = Element

function Element:Get()
	return ui.getValue(self.TabRef, self.ContainerRef, self.Name)
end

function Element:Set(value)
	ui.setValue(self.TabRef, self.ContainerRef, self.Name, value)
end

function Element:Visible(state)
	ui.setVisibility(self.TabRef, self.ContainerRef, self.Name, state)
end

-- ============= Container Object =============
local Container = {}
Container.__index = Container

local function MakeElement(tabRef, containerRef, name)
	return setmetatable({
		TabRef = tabRef,
		ContainerRef = containerRef,
		Name = name,
	}, Element)
end

function Container:Checkbox(name, inLine)
	ui.newCheckbox(self.TabRef, self.Ref, name, inLine)
	return MakeElement(self.TabRef, self.Ref, name)
end

function Container:SliderInt(name, min, max, default)
	ui.newSliderInt(self.TabRef, self.Ref, name, min, max, default)
	return MakeElement(self.TabRef, self.Ref, name)
end

function Container:SliderFloat(name, min, max, default)
	ui.newSliderFloat(self.TabRef, self.Ref, name, min, max, default)
	return MakeElement(self.TabRef, self.Ref, name)
end

function Container:Dropdown(name, options, defaultIndex)
	ui.newDropdown(self.TabRef, self.Ref, name, options, defaultIndex)
	local element = MakeElement(self.TabRef, self.Ref, name)
	element.Get = function()
		local index = ui.getValue(self.TabRef, self.Ref, name)
		return options[index + 1]
	end
	return element
end

function Container:Multiselect(name, options)
	ui.newMultiselect(self.TabRef, self.Ref, name, options)
	local element = MakeElement(self.TabRef, self.Ref, name)

	element.Get = function()
		local states = ui.getValue(self.TabRef, self.Ref, name)
		local selected = {}
		for i, state in ipairs(states) do
			if state then
				selected[options[i]] = true
			end
		end
		return selected
	end

	return element
end

function Container:Colorpicker(name, defaultColor, inLine)
	ui.newColorpicker(self.TabRef, self.Ref, name, defaultColor, inLine)
	local Element = MakeElement(self.TabRef, self.Ref, name)
	Element.Get = function(_, Type)
		Type = (tostring(Type) or "table"):lower()
		if Type == "rgb" then
			local color = ui.getValue(self.TabRef, self.Ref, name)
			return Color3.fromRGB(color.r, color.g, color.b)
		end

		return ui.getValue(self.TabRef, self.Ref, name)
	end
	return Element
end

function Container:InputText(name, defaultText)
	ui.newInputText(self.TabRef, self.Ref, name, defaultText)
	return MakeElement(self.TabRef, self.Ref, name)
end

function Container:Button(name, callback)
	ui.newButton(self.TabRef, self.Ref, name, callback)
	local element = MakeElement(self.TabRef, self.Ref, name)
	element.Get = nil
	element.Set = nil
	return element
end

function Container:Listbox(name, options, callback)
	ui.newListbox(self.TabRef, self.Ref, name, options, function()
		if callback then
			local index = ui.getValue(self.TabRef, self.Ref, name)
			local selected = options[index + 1]
			callback(selected)
		end
	end)
	return MakeElement(self.TabRef, self.Ref, name)
end

-- ============= Tab Object =============
local Tab = {}
Tab.__index = Tab

function Tab:Container(containerRef, displayName, options)
	ui.newContainer(self.Ref, containerRef, displayName, options or {})
	return setmetatable({
		TabRef = self.Ref,
		Ref = containerRef,
	}, Container)
end

-- ============= Root =============
function Library.NewTab(tabRef, displayName)
	ui.newTab(tabRef, displayName)
	return setmetatable({ Ref = tabRef }, Tab)
end

return Library
