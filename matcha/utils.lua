local utils = {}

local function find_with(node, names)
	for _, child in next, node:GetChildren() do
		local match = true
		for i = 1, #names do
			if not child:FindFirstChild(names[i]) then
				match = false
				break
			end
		end
		if match then
			return child
		end
	end
end

local function descend(node, path)
	for i = 1, #path do
		local step = path[i]
		if type(step) == "table" then
			node = find_with(node, step)
		else
			node = node:FindFirstChild(step)
		end
		if not node then
			return
		end
	end
	return node
end

utils.bind = function(parent, root_name, paths)
	local cache, cache_root

	return function()
		local base = parent
		if type(base) == "function" then
			base = base()
		end
		if not base then
			cache = nil
			return
		end

		local root = base
		if root_name then
			root = base:FindFirstChild(root_name)
			if not root then
				cache = nil
				return
			end
		end

		if cache and cache_root ~= root then
			cache = nil
		end

		if not cache then
			local found = {}
			for key, path in pairs(paths) do
				local node = descend(root, path)
				if not node then
					return
				end
				found[key] = node
			end
			cache, cache_root = found, root
		end

		return cache
	end
end

local env = _G or getfenv(0)
local existing = env.utils
if type(existing) == "table" then
	for k, v in pairs(utils) do existing[k] = v end
	utils = existing
else
	env.utils = utils
end

return utils