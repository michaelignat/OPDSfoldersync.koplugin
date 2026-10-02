local AutoSync = require("autosync")
local ButtonDialog = require("ui/widget/buttondialog")
local SpinWidget = require("ui/widget/spinwidget")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local TOGGLES = {
    { key = "auto_sync", text = _("Enable automatic OPDS sync") },
    { key = "sync_on_resume", text = _("Sync on resume") },
    { key = "sync_on_network", text = _("Sync on network reconnect") },
    { key = "sync_periodic", text = _("Periodic sync") }
}
local INTERVALS = {
    {
        key = "sync_interval_hours",
        text = _("Sync interval (hours)"),
        minimum = 1,
        maximum = 168,
        default = 24
    },
    {
        key = "sync_min_interval_seconds",
        text = _("Minimum time between attempts (seconds)"),
        minimum = 15,
        maximum = 86400,
        default = 60
    }
}

local AutoSyncSettings = {}

function AutoSyncSettings.show(owner)
    local dialog
    local buttons = {}
    local settings = owner.opds_settings
    for __, option in ipairs(TOGGLES) do
        table.insert(buttons, {{
            text = T(_("%1: %2"), option.text, settings[option.key] and _("On") or _("Off")),
            callback = function()
                settings[option.key] = not settings[option.key]
                AutoSyncSettings.save(owner)
                UIManager:close(dialog)
                AutoSyncSettings.show(owner)
            end
        }})
    end
    for __, option in ipairs(INTERVALS) do
        table.insert(buttons, {{
            text = T(_("%1: %2"), option.text, tonumber(settings[option.key]) or option.default),
            callback = function()
                UIManager:close(dialog)
                UIManager:show(SpinWidget:new{
                    title_text = option.text,
                    value = tonumber(settings[option.key]) or option.default,
                    value_min = option.minimum,
                    value_max = option.maximum,
                    value_step = 1,
                    default_value = option.default,
                    ok_text = _("Save"),
                    callback = function(spin)
                        settings[option.key] = spin.value
                        AutoSyncSettings.save(owner)
                    end
                })
            end
        }})
    end
    table.insert(buttons, {{
        text = _("Close"),
        callback = function() UIManager:close(dialog) end
    }})
    dialog = ButtonDialog:new{ title = _("Automatic sync"), buttons = buttons }
    UIManager:show(dialog)
end

function AutoSyncSettings.save(owner)
    owner.updated = true
    owner:onFlushSettings()
    AutoSync:configure()
end

return AutoSyncSettings
