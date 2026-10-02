local DataStorage = require("datastorage")
local PluginLoader = require("pluginloader")
local lfs = require("libs/libkoreader-lfs")

local replacement_path = (DataStorage:getDataDir() .. "/plugins/opds.koplugin"):gsub("/+", "/")
local original_discover = PluginLoader._discover

-- Android's bundled plugins are private; both copies would otherwise be loaded.
-- https://github.com/koreader/koreader/blob/896dd63e363adf0ac9ce6a81bff76638c42c1044/frontend/pluginloader.lua
function PluginLoader:_discover()
    local discovered = original_discover(self)
    if lfs.attributes(replacement_path .. "/main.lua", "mode") ~= "file" then return discovered end
    local replacement
    for _, plugin in ipairs(discovered) do
        if plugin.name == "opds" and plugin.path:gsub("/+", "/") == replacement_path then
            replacement = plugin
            break
        end
    end
    if not replacement then return discovered end
    local selected = {}
    for _, plugin in ipairs(discovered) do
        if plugin.name ~= "opds" or plugin == replacement then
            table.insert(selected, plugin)
        end
    end
    return selected
end
