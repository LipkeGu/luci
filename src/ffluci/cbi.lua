--[[
FFLuCI - Configuration Bind Interface

Description:
Offers an interface for binding confiugration values to certain
data types. Supports value and range validation and basic dependencies.

FileId:
$Id$

License:
Copyright 2008 Steven Barth <steven@midlink.org>

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at 

	http://www.apache.org/licenses/LICENSE-2.0 

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

]]--
module("ffluci.cbi", package.seeall)

require("ffluci.template")
require("ffluci.util")
require("ffluci.http")
require("ffluci.model.uci")

local class      = ffluci.util.class
local instanceof = ffluci.util.instanceof

-- Loads a CBI map from given file, creating an environment and returns it
function load(cbimap)
	require("ffluci.fs")
	require("ffluci.i18n")
	
	local cbidir = ffluci.fs.dirname(ffluci.util.__file__()) .. "model/cbi/"
	local func, err = loadfile(cbidir..cbimap..".lua")
	
	if not func then
		error(err)
		return nil
	end
	
	ffluci.util.resfenv(func)
	ffluci.util.updfenv(func, ffluci.cbi)
	ffluci.util.extfenv(func, "translate", ffluci.i18n.translate)
	
	local map = func()
	
	if not instanceof(map, Map) then
		error("CBI map returns no valid map object!")
		return nil
	end
	
	ffluci.i18n.loadc("cbi")
	
	return map
end

-- Node pseudo abstract class
Node = class()

function Node.__init__(self, title, description)
	self.children = {}
	self.title = title or ""
	self.description = description or ""
	self.template = "cbi/node"
end

-- Append child nodes
function Node.append(self, obj)
	table.insert(self.children, obj)
end

-- Parse this node and its children
function Node.parse(self, ...)
	for k, child in ipairs(self.children) do
		child:parse(...)
	end
end

-- Render this node
function Node.render(self)
	ffluci.template.render(self.template, {self=self})
end

-- Render the children
function Node.render_children(self, ...)
	for k, node in ipairs(self.children) do
		node:render(...)
	end
end


--[[
Map - A map describing a configuration file 
]]--
Map = class(Node)

function Map.__init__(self, config, ...)
	Node.__init__(self, ...)
	self.config = config
	self.template = "cbi/map"
	self.uci = ffluci.model.uci.Session()
	self.ucidata = self.uci:show(self.config)
	if not self.ucidata then
		error("Unable to read UCI data: " .. self.config)
	else
		self.ucidata = self.ucidata[self.config]
	end	
end

-- Creates a child section
function Map.section(self, class, ...)
	if instanceof(class, AbstractSection) then
		local obj  = class(self, ...)
		self:append(obj)
		return obj
	else
		error("class must be a descendent of AbstractSection")
	end
end

-- UCI add
function Map.add(self, sectiontype)
	local name = self.uci:add(self.config, sectiontype)
	if name then
		self.ucidata[name] = self.uci:show(self.config, name)
	end
	return name
end

-- UCI set
function Map.set(self, section, option, value)
	local stat = self.uci:set(self.config, section, option, value)
	if stat then
		local val = self.uci:get(self.config, section, option)
		if option then
			self.ucidata[section][option] = val
		else
			if not self.ucidata[section] then
				self.ucidata[section] = {}
			end
			self.ucidata[section][".type"] = val
		end
	end
	return stat
end

-- UCI del
function Map.del(self, section, option)
	local stat = self.uci:del(self.config, section, option)
	if stat then
		if option then
			self.ucidata[section][option] = nil
		else
			self.ucidata[section] = nil
		end
	end
	return stat
end

-- UCI get (cached)
function Map.get(self, section, option)
	if option and self.ucidata[section] then
		return self.ucidata[section][option]
	else
		return self.ucidata[section]
	end
end


--[[
AbstractSection
]]--
AbstractSection = class(Node)

function AbstractSection.__init__(self, map, sectiontype, ...)
	Node.__init__(self, ...)
	self.sectiontype = sectiontype
	self.map = map
	self.config = map.config
	self.optionals = {}
	
	self.addremove = true
	self.optional = true
	self.dynamic = false
end

-- Appends a new option
function AbstractSection.option(self, class, ...)
	if instanceof(class, AbstractValue) then
		local obj  = class(self.map, ...)
		self:append(obj)
		return obj
	else
		error("class must be a descendent of AbstractValue")
	end	
end

-- Parse optional options
function AbstractSection.parse_optionals(self, section)
	if not self.optional then
		return
	end
	
	local field = ffluci.http.formvalue("cbi.opt."..self.config.."."..section)
	for k,v in ipairs(self.children) do
		if v.optional and not v:ucivalue(section) then
			if field == v.option then
				self.map:set(section, field, v.default)
				field = nil
			else
				table.insert(self.optionals, v)
			end
		end
	end
	
	if field and field:len() > 0 and self.dynamic then
		self:add_dynamic(field)
	end
end

-- Add a dynamic option
function AbstractSection.add_dynamic(self, field, optional)
	local o = self:option(Value, field, field)
	o.optional = optional
end

-- Parse all dynamic options
function AbstractSection.parse_dynamic(self, section)
	if not self.dynamic then
		return
	end
	
	local arr  = ffluci.util.clone(self:ucivalue(section))
	local form = ffluci.http.formvalue("cbid."..self.config.."."..section)
	if type(form) == "table" then
		for k,v in pairs(form) do
			arr[k] = v
		end
	end	
	
	for key,val in pairs(arr) do
		local create = true
		
		for i,c in ipairs(self.children) do
			if c.option == key then
				create = false
			end
		end
		
		if create and key:sub(1, 1) ~= "." then
			self:add_dynamic(key, true)
		end
	end
end	

-- Returns the section's UCI table
function AbstractSection.ucivalue(self, section)
	return self.map:get(section)
end



--[[
NamedSection - A fixed configuration section defined by its name
]]--
NamedSection = class(AbstractSection)

function NamedSection.__init__(self, map, section, ...)
	AbstractSection.__init__(self, map, ...)
	self.template = "cbi/nsection"
	
	self.section = section
	self.addremove = false
end

function NamedSection.parse(self)	
	local active = self:ucivalue(self.section)
	
	if self.addremove then
		local path = self.config.."."..self.section
		if active then -- Remove the section
			if ffluci.http.formvalue("cbi.rns."..path) and self:remove() then
				return
			end
		else           -- Create and apply default values
			if ffluci.http.formvalue("cbi.cns."..path) and self:create() then
				for k,v in pairs(self.children) do
					v:write(self.section, v.default)
				end
			end
		end
	end
	
	if active then
		AbstractSection.parse_dynamic(self, self.section)
		Node.parse(self, self.section)
		AbstractSection.parse_optionals(self, self.section)
	end	
end

-- Removes the section
function NamedSection.remove(self)
	return self.map:del(self.section)
end

-- Creates the section
function NamedSection.create(self)
	return self.map:set(self.section, nil, self.sectiontype)
end



--[[
TypedSection - A (set of) configuration section(s) defined by the type
	addremove: 	Defines whether the user can add/remove sections of this type
	anonymous:  Allow creating anonymous sections
	valid: 		a list of names or a validation function for creating sections 
	scope:		a list of names or a validation function for editing sections
]]--
TypedSection = class(AbstractSection)

function TypedSection.__init__(self, ...)
	AbstractSection.__init__(self, ...)
	self.template  = "cbi/tsection"
	
	self.anonymous   = false
	self.valid       = nil
	self.scope		 = nil
end

-- Creates a new section of this type with the given name (or anonymous)
function TypedSection.create(self, name)
	if name then	
		self.map:set(name, nil, self.sectiontype)
	else
		name = self.map:add(self.sectiontype)
	end
	
	for k,v in pairs(self.children) do
		if v.default then
			self.map:set(name, v.option, v.default)
		end
	end
end

function TypedSection.parse(self)
	if self.addremove then
		-- Create
		local crval = "cbi.cts." .. self.config .. "." .. self.sectiontype
		local name  = ffluci.http.formvalue(crval)
		if self.anonymous then
			if name then
				self:create()
			end
		else		
			if name then
				name = ffluci.util.validate(name, self.valid)
				if not name then
					self.err_invalid = true
				end		
				if name and name:len() > 0 then
					self:create(name)
				end
			end
		end
		
		-- Remove
		crval = "cbi.rts." .. self.config
		name = ffluci.http.formvalue(crval)
		if type(name) == "table" then
			for k,v in pairs(name) do
				if ffluci.util.validate(k, self.valid) then
					self:remove(k)
				end
			end
		end		
	end
	
	for k, v in pairs(self:ucisections()) do
		AbstractSection.parse_dynamic(self, k)
		Node.parse(self, k)
		AbstractSection.parse_optionals(self, k)
	end
end

-- Remove a section
function TypedSection.remove(self, name)
	return self.map:del(name)
end

-- Render the children
function TypedSection.render_children(self, section)
	for k, node in ipairs(self.children) do
		node:render(section)
	end
end

-- Return all matching UCI sections for this TypedSection
function TypedSection.ucisections(self)
	local sections = {}
	for k, v in pairs(self.map.ucidata) do
		if v[".type"] == self.sectiontype then
			if ffluci.util.validate(k, self.scope) then
				sections[k] = v
			end
		end
	end
	return sections	
end



--[[
AbstractValue - An abstract Value Type
	null:		Value can be empty
	valid:		A function returning the value if it is valid otherwise nil 
	depends:	A table of option => value pairs of which one must be true
	default:	The default value
	size:		The size of the input fields
	rmempty:	Unset value if empty
	optional:	This value is optional (see AbstractSection.optionals)
]]--
AbstractValue = class(Node)

function AbstractValue.__init__(self, map, option, ...)
	Node.__init__(self, ...)
	self.option = option
	self.map    = map
	self.config = map.config
	self.tag_invalid = {}
	
	self.valid    = nil
	self.depends  = nil
	self.default  = nil
	self.size     = nil
	self.optional = false
end

-- Returns the formvalue for this object
function AbstractValue.formvalue(self, section)
	local key = "cbid."..self.map.config.."."..section.."."..self.option
	return ffluci.http.formvalue(key)
end

function AbstractValue.parse(self, section)
	local fvalue = self:formvalue(section)
	if fvalue == "" then
		fvalue = nil
	end
	
	
	if fvalue then -- If we have a form value, validate it and write it to UCI
		fvalue = self:validate(fvalue)
		if not fvalue then
			self.tag_invalid[section] = true
		end
		if fvalue and not (fvalue == self:ucivalue(section)) then
			self:write(section, fvalue)
		end 
	elseif ffluci.http.formvalue("cbi.submit") then -- Unset the UCI or error
		if self.rmempty or self.optional then
			self:remove(section)
		else
			self.tag_invalid[section] = true
		end
	end
end

-- Render if this value exists or if it is mandatory
function AbstractValue.render(self, section)
	if not self.optional or self:ucivalue(section) then 
		ffluci.template.render(self.template, {self=self, section=section})
	end
end

-- Return the UCI value of this object
function AbstractValue.ucivalue(self, section)
	return self.map:get(section, self.option)
end

-- Validate the form value
function AbstractValue.validate(self, val)
	return ffluci.util.validate(val, self.valid)
end

-- Write to UCI
function AbstractValue.write(self, section, value)
	return self.map:set(section, self.option, value)
end

-- Remove from UCI
function AbstractValue.remove(self, section)
	return self.map:del(section, self.option)
end




--[[
Value - A one-line value
	maxlength:	The maximum length
	isnumber:	The value must be a valid (floating point) number
	isinteger:  The value must be a valid integer
	ispositive: The value must be positive (and a number)
]]--
Value = class(AbstractValue)

function Value.__init__(self, ...)
	AbstractValue.__init__(self, ...)
	self.template  = "cbi/value"
	
	self.maxlength  = nil
	self.isnumber   = false
	self.isinteger  = false
end

-- This validation is a bit more complex
function Value.validate(self, val)
	if self.maxlength and tostring(val):len() > self.maxlength then
		val = nil
	end
	
	return ffluci.util.validate(val, self.valid, self.isnumber, self.isinteger)
end



--[[
Flag - A flag being enabled or disabled
]]--
Flag = class(AbstractValue)

function Flag.__init__(self, ...)
	AbstractValue.__init__(self, ...)
	self.template  = "cbi/fvalue"
	
	self.enabled = "1"
	self.disabled = "0"
end

-- A flag can only have two states: set or unset
function Flag.parse(self, section)
	self.default = self.enabled
	local fvalue = self:formvalue(section)
	
	if fvalue then
		fvalue = self.enabled
	else
		fvalue = self.disabled
	end	
	
	if fvalue == self.enabled or (not self.optional and not self.rmempty) then 		
		if not(fvalue == self:ucivalue(section)) then
			self:write(section, fvalue)
		end 
	else
		self:remove(section)
	end
end



--[[
ListValue - A one-line value predefined in a list
	widget: The widget that will be used (select, radio)
]]--
ListValue = class(AbstractValue)

function ListValue.__init__(self, ...)
	AbstractValue.__init__(self, ...)
	self.template  = "cbi/lvalue"
	self.keylist = {}
	self.vallist = {}
	
	self.size   = 1
	self.widget = "select"
end

function ListValue.add_value(self, key, val)
	val = val or key
	table.insert(self.keylist, tostring(key))
	table.insert(self.vallist, tostring(val)) 
end

function ListValue.validate(self, val)
	if ffluci.util.contains(self.keylist, val) then
		return val
	else
		return nil
	end
end



--[[
MultiValue - Multiple delimited values
	widget: The widget that will be used (select, checkbox)
	delimiter: The delimiter that will separate the values (default: " ")
]]--
MultiValue = class(AbstractValue)

function MultiValue.__init__(self, ...)
	AbstractValue.__init__(self, ...)
	self.template = "cbi/mvalue"
	self.keylist = {}
	self.vallist = {}	
	
	self.widget = "checkbox"
	self.delimiter = " "
end

function MultiValue.add_value(self, key, val)
	val = val or key
	table.insert(self.keylist, tostring(key))
	table.insert(self.vallist, tostring(val)) 
end

function MultiValue.valuelist(self, section)
	local val = self:ucivalue(section)
	
	if not(type(val) == "string") then
		return {}
	end
	
	return ffluci.util.split(val, self.delimiter)
end

function MultiValue.validate(self, val)
	if not(type(val) == "string") then
		return nil
	end
	
	local result = ""
	
	for value in val:gmatch("[^\n]+") do
		if ffluci.util.contains(self.keylist, value) then
			result = result .. self.delimiter .. value
		end 
	end
	
	if result:len() > 0 then
		return result:sub(self.delimiter:len() + 1)
	else
		return nil
	end
end