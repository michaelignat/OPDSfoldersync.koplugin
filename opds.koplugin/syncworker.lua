local OPDSBrowser = require("opdsbrowser")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")

local MAX_FEED_PAGES = 100
local DEFAULT_FILE_LIMIT = 50
local PART_SUFFIX = ".opds-autosync.part"

local SyncWorker = {}

function SyncWorker.run(owner)
    -- A fork inherits UI and logging state; never render or log private feed data from it.
    -- https://github.com/koreader/koreader/blob/896dd63e363adf0ac9ce6a81bff76638c42c1044/frontend/ui/trapper.lua
    UIManager.show = function() end
    for _, level in ipairs({ "dbg", "info", "warn", "err" }) do
        logger[level] = function() end
    end
    local successful = true
    for _, server in ipairs(owner.servers) do
        local directory = server.sync_dir or owner.opds_settings.sync_dir
        if server.sync and directory then
            local ok, result = pcall(SyncWorker.syncCatalog, owner, server)
            successful = ok and result and successful
        end
    end
    return successful
end

function SyncWorker.syncCatalog(owner, server)
    local directory = server.sync_dir or owner.opds_settings.sync_dir
    if lfs.attributes(directory, "mode") ~= "directory" then return false end
    local browser = setmetatable({
        settings = owner.opds_settings,
        servers = owner.servers,
        sync = true,
        sync_server = server,
        root_catalog_username = server.username,
        root_catalog_password = server.password,
        root_catalog_raw_names = server.raw_names,
        root_catalog_title = server.title,
        _manager = { updated = false }
    }, { __index = OPDSBrowser })
    browser.genItemTableFromURL = SyncWorker.getItems
    browser.parseFeed = SyncWorker.parseFeed
    local queue = { server.url }
    local visited = {}
    local filenames = {}
    local filetypes = SyncWorker.getFiletypes(owner.opds_settings.filetypes)
    local file_limit = math.max(0, tonumber(owner.opds_settings.sync_max_dl) or DEFAULT_FILE_LIMIT)
    if file_limit == 0 then return true end
    local matched = 0
    local pages = 0
    local successful = true
    while true do
        local feed_url = table.remove(queue, 1)
        if not feed_url then break end
        if visited[feed_url] then
            successful = false
        end
        if not visited[feed_url] then
            if pages >= MAX_FEED_PAGES then return false end
            visited[feed_url] = true
            pages = pages + 1
            local items = browser:genItemTableFromURL(feed_url)
            for _, item in ipairs(items) do
                if item.url and #(item.acquisitions or {}) == 0 and not visited[item.url] then
                    table.insert(queue, item.url)
                end
                local acquisition, filetype = SyncWorker.findAcquisition(browser, item, filetypes)
                if acquisition then
                    matched = matched + 1
                    local filename = browser:getFileName(item)
                    local path = browser:getLocalDownloadPath(filename, filetype, acquisition.href)
                    if not filenames[path] then
                        filenames[path] = true
                        local ok, downloaded = pcall(SyncWorker.download, browser, path, acquisition.href)
                        successful = ok and downloaded and successful
                    end
                end
                if matched >= file_limit then return successful end
            end
            if items.hrefs and items.hrefs.next then table.insert(queue, items.hrefs.next) end
        end
    end
    return successful
end

function SyncWorker.findAcquisition(browser, item, filetypes)
    for _, acquisition in ipairs(item.acquisitions or {}) do
        if acquisition.href then
            local filetype = browser.getFiletype(acquisition)
            if filetype and (not filetypes or filetypes[filetype:lower()]) then return acquisition, filetype end
        end
    end
end

function SyncWorker.parseFeed(browser, feed_url)
    local catalog = OPDSBrowser.parseFeed(browser, feed_url)
    if type(catalog) ~= "table" then error("Catalog unavailable", 0) end
    if catalog.is_opds2 and type(catalog.metadata) ~= "table" then error("Invalid catalog", 0) end
    if not catalog.is_opds2 and not catalog.feed then error("Invalid catalog", 0) end
    return catalog
end

function SyncWorker.getItems(browser, feed_url)
    local catalog = browser:parseFeed(feed_url)
    if catalog.is_opds2 then return browser:genItemTableFromCatalog2(catalog, feed_url) end
    return browser:genItemTableFromCatalog(catalog, feed_url)
end

function SyncWorker.getFiletypes(value)
    if not value or util.trim(value) == "" then return nil end
    local filetypes = {}
    for filetype in util.gsplit(value, ",") do
        filetypes[util.trim(filetype):lower()] = true
    end
    return filetypes
end

function SyncWorker.download(browser, path, remote_url)
    local attributes = lfs.attributes(path)
    if attributes and attributes.mode == "file" and attributes.size > 0 then return true end
    local temporary_path = path .. PART_SUFFIX
    os.remove(temporary_path)
    local ok, downloaded = pcall(browser.downloadFile, browser, temporary_path, remote_url,
        browser.root_catalog_username, browser.root_catalog_password)
    local size = lfs.attributes(temporary_path, "size") or 0
    if not ok or not downloaded or size == 0 then
        os.remove(temporary_path)
        return false
    end
    if not os.rename(temporary_path, path) then
        os.remove(temporary_path)
        return false
    end
    return true
end

return SyncWorker
