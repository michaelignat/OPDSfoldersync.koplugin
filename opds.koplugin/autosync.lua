local UIManager = require("ui/uimanager")
local NetworkMgr = require("ui/network/manager")
local ffiutil = require("ffi/util")

local CONNECTIVITY_POLL_SECONDS = 15
local PROCESS_POLL_SECONDS = 0.25
local EVENT_DELAY_SECONDS = 3
local RETRY_DELAY_SECONDS = 30
local MAX_RETRIES = 3
local WORKER_TIMEOUT_SECONDS = 5 * 60
local SECONDS_PER_HOUR = 60 * 60
local DEFAULTS = {
    auto_sync = false,
    sync_on_resume = true,
    sync_on_network = true,
    sync_periodic = false,
    sync_interval_hours = 24,
    sync_min_interval_seconds = 60
}

local AutoSync = {}

function AutoSync:attach(owner)
    self:detach(self.owner)
    self.owner = owner
    self.suspended = false
    self.browser_open = false
    self.connected = NetworkMgr:isConnected()
    local settings = owner.opds_settings
    for name, value in pairs(DEFAULTS) do
        if settings[name] == nil then settings[name] = value end
    end
    settings.sync_interval_hours = self:boundedNumber(settings.sync_interval_hours, 24, 1, 168)
    settings.sync_min_interval_seconds = self:boundedNumber(settings.sync_min_interval_seconds, 60, 15, 86400)
    settings.last_auto_attempt_time = math.min(tonumber(settings.last_auto_attempt_time) or 0, os.time())
    owner.updated = true
    owner:onFlushSettings()
    self:configure(true)
end

function AutoSync:boundedNumber(value, default, minimum, maximum)
    value = tonumber(value)
    if not value or value ~= value then return default end
    return math.max(minimum, math.min(maximum, value))
end

function AutoSync:configure(request_initial)
    UIManager:unschedule(self.tick)
    self.due = nil
    self.retries = 0
    self:cancelWorker()
    if not self.owner then return end
    local settings = self.owner.opds_settings
    self.periodic_due = os.time() + settings.sync_interval_hours * SECONDS_PER_HOUR
    if not settings.auto_sync or self.suspended or self.browser_open then return end
    UIManager:scheduleIn(CONNECTIVITY_POLL_SECONDS, self.tick)
    if request_initial and (settings.sync_on_resume or settings.sync_on_network) then self:request() end
end

function AutoSync:request()
    if not self.owner or self.suspended or self.browser_open or (self.process and not self.process.cancelled) or self.due then return end
    local settings = self.owner.opds_settings
    if not settings.auto_sync then return end
    self.retries = 0
    self.due = math.max(os.time() + EVENT_DELAY_SECONDS,
        settings.last_auto_attempt_time + settings.sync_min_interval_seconds)
    UIManager:unschedule(self.tick)
    UIManager:scheduleIn(EVENT_DELAY_SECONDS, self.tick)
end

function AutoSync.tick()
    local self = AutoSync
    UIManager:unschedule(self.tick)
    if not self.owner or self.suspended or self.browser_open or not self.owner.opds_settings.auto_sync then return end
    local settings = self.owner.opds_settings
    local connected = NetworkMgr:isConnected()
    if connected and not self.connected and settings.sync_on_network then self:request() end
    self.connected = connected
    if settings.sync_periodic and os.time() >= self.periodic_due then
        self.periodic_due = os.time() + settings.sync_interval_hours * SECONDS_PER_HOUR
        self:request()
    end
    if self.due and os.time() >= self.due and not self.process then
        self.due = nil
        if not connected then
            self:retry()
        end
        if connected then self:startWorker() end
    end
    UIManager:unschedule(self.tick)
    UIManager:scheduleIn(CONNECTIVITY_POLL_SECONDS, self.tick)
end

function AutoSync:retry()
    if not self.owner or self.retries >= MAX_RETRIES then return end
    self.retries = self.retries + 1
    local delay_seconds = math.max(RETRY_DELAY_SECONDS * self.retries,
        self.owner.opds_settings.sync_min_interval_seconds)
    self.due = os.time() + delay_seconds
end

function AutoSync:startWorker()
    local owner = self.owner
    local eligible = false
    for _, server in ipairs(owner.servers) do
        if server.sync and (server.sync_dir or owner.opds_settings.sync_dir) then
            eligible = true
            break
        end
    end
    if not eligible then return end
    owner.opds_settings.last_auto_attempt_time = os.time()
    owner.updated = true
    owner:onFlushSettings()
    local pid, read_fd = ffiutil.runInSubProcess(function(_, write_fd)
        local ok, success = pcall(function()
            return require("syncworker").run(owner)
        end)
        ffiutil.writeToFD(write_fd, ok and success and "1" or "0", true)
    end, true)
    if not pid then
        self:retry()
        return
    end
    self.process = { pid = pid, read_fd = read_fd, started = os.time(), owner = owner }
    UIManager:scheduleIn(PROCESS_POLL_SECONDS, self.pollWorker)
end

function AutoSync.pollWorker()
    local self = AutoSync
    UIManager:unschedule(self.pollWorker)
    local process = self.process
    if not process then return end
    if process.cancelled then ffiutil.terminateSubProcess(process.pid) end
    if os.time() - process.started >= WORKER_TIMEOUT_SECONDS then
        process.timed_out = true
        ffiutil.terminateSubProcess(process.pid)
    end
    if not ffiutil.isSubProcessDone(process.pid) then
        UIManager:scheduleIn(PROCESS_POLL_SECONDS, self.pollWorker)
        return
    end
    local result = ffiutil.readAllFromFD(process.read_fd)
    self.process = nil
    if process.cancelled or process.owner ~= self.owner then return end
    if result ~= "1" or process.timed_out then
        self:retry()
        return
    end
    self.owner.opds_settings.last_auto_success_time = os.time()
    self.owner.updated = true
    self.owner:onFlushSettings()
    self.retries = 0
end

function AutoSync:cancelWorker()
    if not self.process then return end
    self.process.cancelled = true
    ffiutil.terminateSubProcess(self.process.pid)
    UIManager:unschedule(self.pollWorker)
    UIManager:scheduleIn(PROCESS_POLL_SECONDS, self.pollWorker)
end

function AutoSync:suspend(owner)
    if owner ~= self.owner then return end
    self.suspended = true
    self.due = nil
    UIManager:unschedule(self.tick)
    self:cancelWorker()
end

function AutoSync:resume(owner)
    if owner ~= self.owner then return end
    if self.suspended then
        self.suspended = false
        self:configure()
    end
    if owner.opds_settings.sync_on_resume then self:request() end
end

function AutoSync:networkConnected(owner)
    if owner ~= self.owner or not owner.opds_settings.sync_on_network then return end
    self:request()
end

function AutoSync:openBrowser(owner)
    if owner ~= self.owner then return true end
    self.browser_open = true
    self.due = nil
    UIManager:unschedule(self.tick)
    self:cancelWorker()
    return self.process == nil
end

function AutoSync:closeBrowser(owner)
    if owner ~= self.owner then return end
    self.browser_open = false
    self:configure(true)
end

function AutoSync:detach(owner)
    if owner ~= self.owner then return end
    UIManager:unschedule(self.tick)
    self:cancelWorker()
    self.due = nil
    self.owner = nil
end

return AutoSync
