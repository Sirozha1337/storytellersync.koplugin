--[[--
Storyteller Sync Engine - Sync Coordinator & State Machine

Manages synchronization lifecycle, debouncing, concurrency locking,
offline queue draining, conflict resolution, and position navigation.

@module StorytellerSyncEngine
]]--

local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local Math = require("optmath")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local time = require("ui/time")
local _ = require("gettext")
local T = require("ffi/util").template

local Api = require("StorytellerApi")
local LocatorHelper = require("LocatorHelper")
local StorytellerBookLink = require("StorytellerBookLink")
local StorytellerQueue = require("StorytellerQueue")

local SYNC_STRATEGY = {
    PROMPT  = 1,
    SILENT  = 2,
    DISABLE = 3,
}

local API_CALL_DEBOUNCE_DELAY = time.s(3)

local StorytellerSyncEngine = {}

function StorytellerSyncEngine:new(plugin)
    local o = {
        plugin = plugin,
        is_syncing = false,
        sync_again = false,

        -- State tracking
        last_synced_locator = nil,
        push_timestamp = 0,
        pull_timestamp = 0,
        page_update_counter = 0,
        last_page = -1,
        periodic_push_scheduled = false,
        periodic_push_task = nil,
    }
    setmetatable(o, self)
    self.__index = self
    return o
end

function StorytellerSyncEngine:init()
    self.push_timestamp = 0
    self.pull_timestamp = 0
    self.page_update_counter = 0
    self.last_page = -1
    self.periodic_push_scheduled = false
    self.is_syncing = false
    self.sync_again = false

    self.periodic_push_task = function()
        self.periodic_push_scheduled = false
        self.page_update_counter = 0
        self:pushProgress(false, false)
    end
end

function StorytellerSyncEngine:cleanup()
    self:cancelPeriodicPush()
    self.periodic_push_task = nil
    self.is_syncing = false
    self.sync_again = false
end

function StorytellerSyncEngine:cancelPeriodicPush()
    if self.periodic_push_task then
        UIManager:unschedule(self.periodic_push_task)
    end
    self.periodic_push_scheduled = false
    self.page_update_counter = 0
end

function StorytellerSyncEngine:schedulePeriodicPush()
    if not self.periodic_push_task then return end
    UIManager:unschedule(self.periodic_push_task)
    UIManager:scheduleIn(10, self.periodic_push_task)
    self.periodic_push_scheduled = true
end

-- ────────────────────────────────────────────────────────────
-- Lifecycle Event Handlers
-- ────────────────────────────────────────────────────────────

function StorytellerSyncEngine:handleReaderReady()
    local ui = self.plugin.ui
    if not ui then return end

    self.last_page = ui:getCurrentPage()
    self.last_synced_locator = LocatorHelper.buildCurrentLocator(ui, self.plugin._epub_spine, self.plugin._epub_spine_meta)

    if self.plugin.settings.auto_sync and self.plugin:isLoggedIn() then
        UIManager:nextTick(function()
            self:syncFull(false, true)
        end)
    end
end

function StorytellerSyncEngine:handlePageUpdate(page)
    if page == nil then return end

    if self.last_page ~= page then
        self.last_page = page
        self.page_update_counter = self.page_update_counter + 1

        local pages_threshold = self.plugin.settings.pages_before_update
        if self.periodic_push_scheduled or (pages_threshold and self.page_update_counter >= pages_threshold) then
            self:schedulePeriodicPush()
        end
    end
end

function StorytellerSyncEngine:handleSuspend()
    logger.dbg("StorytellerSyncEngine: handleSuspend")
    self:cancelPeriodicPush()
    self:pushProgress(false, true) -- force=true to bypass debounce
end

function StorytellerSyncEngine:handleResume()
    logger.dbg("StorytellerSyncEngine: handleResume")
    -- If auto_restore_wifi is enabled and wifi was on, wait for onNetworkConnected
    if Device:hasWifiRestore() and NetworkMgr.wifi_was_on and G_reader_settings:isTrue("auto_restore_wifi") then
        logger.dbg("StorytellerSyncEngine: Waiting for auto_restore_wifi...")
        return
    end

    if NetworkMgr:isOnline() then
        UIManager:scheduleIn(1, function()
            self:syncFull(false, false)
        end)
    end
end

function StorytellerSyncEngine:handleNetworkConnected()
    logger.dbg("StorytellerSyncEngine: handleNetworkConnected")
    UIManager:scheduleIn(0.5, function()
        self:syncFull(false, false)
    end)
end

function StorytellerSyncEngine:handleCloseDocument()
    logger.dbg("StorytellerSyncEngine: handleCloseDocument")
    self:cancelPeriodicPush()
    self:pushProgress(false, true) -- force=true to bypass debounce
end

-- ────────────────────────────────────────────────────────────
-- Sync Execution Pipelines
-- ────────────────────────────────────────────────────────────

--- Drains any pending offline queue items to the server.
-- @treturn number Number of items sent
function StorytellerSyncEngine:drainQueue()
    if not self.plugin:isLoggedIn() then return 0 end
    if StorytellerQueue:count() == 0 then return 0 end

    local server_url = self.plugin.settings.server_url
    local auth_token = self.plugin.settings.auth_token

    return StorytellerQueue:drain(function(item)
        local ok, _data, code = Api:updatePosition(
            server_url,
            auth_token,
            item.book_uuid,
            item.locator,
            item.timestamp
        )
        return ok, code
    end)
end

--- Unified full synchronization pipeline:
-- 1. Drains offline queued items (Push)
-- 2. Pulls latest remote position (Pull)
function StorytellerSyncEngine:syncFull(interactive, ensure_networking)
    if self.is_syncing then
        logger.dbg("StorytellerSyncEngine: syncFull already in progress, setting sync_again")
        self.sync_again = true
        return
    end

    if not self.plugin:isLoggedIn() then
        if interactive then
            UIManager:show(InfoMessage:new{
                text = _("Please login first."),
                timeout = 3,
            })
        end
        return
    end

    if ensure_networking and NetworkMgr:willRerunWhenOnline(function()
        self:syncFull(interactive, ensure_networking)
    end) then
        return
    end

    if not NetworkMgr:isOnline() and not interactive then
        logger.dbg("StorytellerSyncEngine: Device is offline, skipping syncFull")
        return
    end

    self.is_syncing = true

    local ok, err = pcall(function()
        -- Step 1: Drain offline queue
        self:drainQueue()

        -- Step 2: If current document has pending un-synced local changes, push first
        local ui = self.plugin.ui
        if ui and ui.doc_settings then
            local current_locator = LocatorHelper.buildCurrentLocator(ui, self.plugin._epub_spine, self.plugin._epub_spine_meta)
            if current_locator and not LocatorHelper.locatorsEqual(current_locator, self.last_synced_locator) then
                local book_uuid = ui.doc_settings:readSetting("storyteller_book_uuid")
                if book_uuid then
                    logger.dbg("StorytellerSyncEngine: Flushing uncommitted local progress before pull")
                    local timestamp = os.time() * 1000
                    local ok_push, _data, code = Api:updatePosition(
                        self.plugin.settings.server_url,
                        self.plugin.settings.auth_token,
                        book_uuid,
                        current_locator,
                        timestamp
                    )
                    if ok_push then
                        self.last_synced_locator = current_locator
                    elseif code == 409 then
                        logger.dbg("StorytellerSyncEngine: Server has newer position (409 Conflict)")
                    else
                        -- Save to queue so uncommitted change isn't lost if pull fails
                        StorytellerQueue:push({
                            book_uuid = book_uuid,
                            locator = current_locator,
                            timestamp = timestamp,
                        })
                    end
                end
            end
        end

        -- Step 3: Pull remote progress
        self:pullProgress(interactive, false, function()
            self.is_syncing = false
            if self.sync_again then
                self.sync_again = false
                UIManager:nextTick(function()
                    self:syncFull(false, false)
                end)
            end
        end)
    end)

    if not ok then
        logger.err("StorytellerSyncEngine: syncFull encountered error:", err)
        self.is_syncing = false
    end
end

--- Push current reading position to the server.
-- @tparam boolean interactive True if initiated by direct user tap in menu
-- @tparam boolean force True to bypass time-based debounce (e.g. on suspend)
function StorytellerSyncEngine:pushProgress(interactive, force)
    if not self.plugin:isLoggedIn() then
        if interactive then
            UIManager:show(InfoMessage:new{
                text = _("Please login first."),
                timeout = 3,
            })
        end
        return
    end

    local now = UIManager:getElapsedTimeSinceBoot()
    if not interactive and not force and (now - self.push_timestamp <= API_CALL_DEBOUNCE_DELAY) then
        logger.dbg("StorytellerSyncEngine: Push debounced")
        return
    end

    local ui = self.plugin.ui
    if not ui then return end

    local locator = LocatorHelper.buildCurrentLocator(ui, self.plugin._epub_spine, self.plugin._epub_spine_meta)
    if not locator then
        logger.warn("StorytellerSyncEngine: Could not build locator")
        return
    end

    if LocatorHelper.locatorsEqual(locator, self.last_synced_locator) then
        logger.dbg("StorytellerSyncEngine: Position unchanged. Skipping push.")
        if interactive then
            UIManager:show(InfoMessage:new{
                text = _("Position hasn't changed. Skipping sync."),
                timeout = 3,
            })
        end
        return
    end

    if interactive and NetworkMgr:willRerunWhenOnline(function()
        self:pushProgress(interactive, force)
    end) then
        return
    end

    StorytellerBookLink.resolveBookUuid(self.plugin, function(book_uuid, err)
        if not book_uuid then
            if interactive then
                UIManager:show(InfoMessage:new{
                    text = err and T(_("Sync error: %1"), err)
                        or _("This book is not linked to a Storyteller book. Use 'Link this book' from the menu."),
                    timeout = 5,
                })
            end
            return
        end

        if not NetworkMgr:isOnline() and not interactive then
            -- Queue offline
            StorytellerQueue:push({
                book_uuid = book_uuid,
                locator = locator,
                timestamp = os.time() * 1000,
            })
            return
        end

        local timestamp = os.time() * 1000
        local ok, data, code = Api:updatePosition(
            self.plugin.settings.server_url,
            self.plugin.settings.auth_token,
            book_uuid,
            locator,
            timestamp
        )

        logger.dbg("StorytellerSyncEngine: [Push]", ok, data, code)

        if ok then
            self.last_synced_locator = locator
            self.push_timestamp = now
        elseif code == 409 then
            -- Server position is newer, trigger a pull
            logger.info("StorytellerSyncEngine: Server has newer position (409). Triggering pull.")
            self:pullProgress(interactive, false)
        else
            -- Offline or network error: save to queue
            StorytellerQueue:push({
                book_uuid = book_uuid,
                locator = locator,
                timestamp = timestamp,
            })
        end

        if interactive then
            if ok then
                UIManager:show(InfoMessage:new{
                    text = _("Progress pushed."),
                    timeout = 3,
                })
            elseif code == 409 then
                UIManager:show(InfoMessage:new{
                    text = _("Server has a newer position. Pulling newest..."),
                    timeout = 3,
                })
            else
                UIManager:show(InfoMessage:new{
                    text = T(_("Sync error: %1"), data or "unknown"),
                    timeout = 3,
                })
            end
        end
    end)
end

--- Pull reading position from the server and apply navigation if needed.
-- @tparam boolean interactive True if initiated by direct user tap
-- @tparam boolean ensure_networking True to prompt network connection if offline
-- @tparam[opt] function on_finish Completion callback
function StorytellerSyncEngine:pullProgress(interactive, ensure_networking, on_finish)
    local function finish()
        if on_finish then on_finish() end
    end

    if not self.plugin:isLoggedIn() then
        if interactive then
            UIManager:show(InfoMessage:new{
                text = _("Please login first."),
                timeout = 3,
            })
        end
        finish()
        return
    end

    local now = UIManager:getElapsedTimeSinceBoot()
    if not interactive and (now - self.pull_timestamp <= API_CALL_DEBOUNCE_DELAY) then
        logger.dbg("StorytellerSyncEngine: Pull debounced")
        finish()
        return
    end

    if ensure_networking and NetworkMgr:willRerunWhenOnline(function()
        self:pullProgress(interactive, ensure_networking, on_finish)
    end) then
        return
    end

    if not NetworkMgr:isOnline() and not interactive then
        logger.dbg("StorytellerSyncEngine: Device is offline, skipping pullProgress")
        finish()
        return
    end

    StorytellerBookLink.resolveBookUuid(self.plugin, function(book_uuid, err)
        if not book_uuid then
            if interactive then
                UIManager:show(InfoMessage:new{
                    text = err and T(_("Sync error: %1"), err)
                        or _("This book is not linked to a Storyteller book. Use 'Link this book' from the menu."),
                    timeout = 5,
                })
            end
            finish()
            return
        end

        local ok, data, code = Api:getPosition(
            self.plugin.settings.server_url,
            self.plugin.settings.auth_token,
            book_uuid
        )

        if not ok or not data then
            if interactive then
                UIManager:show(InfoMessage:new{
                    text = (not ok and code ~= 404)
                        and T(_("Sync error: %1"), data or "unknown")
                        or _("No progress found on server."),
                    timeout = 3,
                })
            end
            finish()
            return
        end

        local remote_locator = data.locator
        if not remote_locator then
            if interactive then
                UIManager:show(InfoMessage:new{
                    text = _("No position data on server."),
                    timeout = 3,
                })
            end
            finish()
            return
        end

        self.pull_timestamp = now

        local ui = self.plugin.ui
        if not ui or not ui.document then
            finish()
            return
        end

        -- Check if the remote fragment is already visible on the current page
        local remote_xpath = LocatorHelper.createXPathFromLocator(remote_locator, self.plugin._epub_spine_map)
        if remote_xpath and ui.document:isXPointerInCurrentPage(remote_xpath) then
            logger.dbg("StorytellerSyncEngine: [Pull] Remote fragment", remote_xpath, "is on current page.")
            self.last_synced_locator = remote_locator
            if interactive then
                UIManager:show(InfoMessage:new{
                    text = _("Already in sync."),
                    timeout = 3,
                })
            end
            finish()
            return
        end

        -- Resolve remote target page
        local current_page = ui.document:getCurrentPage()
        local remote_target_page = LocatorHelper.getPageFromLocator(
            remote_locator,
            ui,
            self.plugin._epub_spine,
            self.plugin._epub_spine_map
        )

        -- Compare with current position percentage (Readium-aligned)
        local current_locator = LocatorHelper.buildCurrentLocator(ui, self.plugin._epub_spine, self.plugin._epub_spine_meta)
        local current_percent = (current_locator and current_locator.locations and current_locator.locations.totalProgression)
            or LocatorHelper.getLastPercent(ui)
        local remote_percent = remote_locator.locations and remote_locator.locations.totalProgression

        logger.dbg("StorytellerSyncEngine: [Pull] Current page:", current_page, "Remote target page:", remote_target_page,
                   "Current percent:", current_percent, "Remote percent:", remote_percent)

        if remote_target_page and current_page then
            if remote_target_page == current_page then
                logger.dbg("StorytellerSyncEngine: [Pull] Remote target page", remote_target_page, "is current page. Already in sync.")
                self.last_synced_locator = remote_locator
                if interactive then
                    UIManager:show(InfoMessage:new{
                        text = _("Already in sync."),
                        timeout = 3,
                    })
                end
                finish()
                return
            end
        elseif remote_percent and current_percent then
            -- Fallback when target page cannot be resolved directly
            local total_pages = LocatorHelper.getPageCount(ui) or (ui.document.info and ui.document.info.number_of_pages) or 1
            local threshold = 0.5 / total_pages

            if math.abs(remote_percent - current_percent) < threshold then
                self.last_synced_locator = remote_locator
                if interactive then
                    UIManager:show(InfoMessage:new{
                        text = _("Already in sync."),
                        timeout = 3,
                    })
                end
                finish()
                return
            end
        end

        -- Determine forward vs backward sync direction
        local is_forward = true
        if remote_target_page and current_page then
            is_forward = (remote_target_page > current_page)
        elseif remote_percent and current_percent then
            is_forward = (remote_percent > current_percent)
        end

        local strategy = is_forward and self.plugin.settings.sync_forward or self.plugin.settings.sync_backward
        if strategy == SYNC_STRATEGY.DISABLE then
            finish()
            return
        end

        local function doSync()
            self:syncToRemoteLocator(remote_locator, remote_xpath)
            self.last_synced_locator = LocatorHelper.buildCurrentLocator(ui, self.plugin._epub_spine, self.plugin._epub_spine_meta)
            UIManager:show(InfoMessage:new{
                text = _("Progress synchronized."),
                timeout = 3,
            })
            finish()
        end

        if interactive or strategy == SYNC_STRATEGY.SILENT then
            doSync()
        elseif strategy == SYNC_STRATEGY.PROMPT then
            local percent_display = remote_percent and Math.round(remote_percent * 100) or "?"
            UIManager:show(ConfirmBox:new{
                text = T(_("Sync to %1% from Storyteller?"), percent_display),
                ok_callback = doSync,
                cancel_callback = finish,
            })
        else
            finish()
        end
    end)
end

--- Navigate reader to remote Readium locator.
function StorytellerSyncEngine:syncToRemoteLocator(locator, xpath)
    local ui = self.plugin.ui
    if not ui then return end

    logger.dbg("StorytellerSyncEngine: syncToRemoteLocator: locator:", locator, ", xpath:", xpath)

    local navigated = false
    if xpath and ui.link and ui.document:isXPointerInDocument(xpath) then
        logger.dbg("StorytellerSyncEngine: Navigating via xpath:", xpath)
        ui.link:onGotoLink({ xpointer = xpath }, true)
        navigated = true
    end

    if not navigated then
        local target_page = LocatorHelper.getPageFromLocator(
            locator,
            ui,
            self.plugin._epub_spine,
            self.plugin._epub_spine_map
        )
        if target_page then
            logger.dbg("StorytellerSyncEngine: Navigating to resolved chapter page:", target_page)
            ui:handleEvent(Event:new("GotoPage", target_page))
            navigated = true
        end
    end

    if not navigated then
        local total_progression = locator.locations and locator.locations.totalProgression
        if total_progression then
            logger.dbg("StorytellerSyncEngine: Fallback navigating via percentage:", total_progression * 100)
            ui:handleEvent(Event:new("GotoPercent", total_progression * 100))
        end
    end
end

return StorytellerSyncEngine

