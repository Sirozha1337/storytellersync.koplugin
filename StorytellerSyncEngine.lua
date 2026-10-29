--[[--
Storyteller Sync Engine - Sync Coordinator & State Machine (Progress API v3)

Manages synchronization lifecycle, debouncing, concurrency locking,
confirmed/unconfirmed state tracking, offline queue draining,
conflict resolution (200 / 201 / 409), and CREngine XPointer navigation.

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

        -- v3 State tracking
        last_synced_progress = nil,
        pending_progress_doc = nil,
        last_page_turn_iso = nil,
        book_format = nil,
        is_confirmed = true,

        push_timestamp = 0,
        pull_timestamp = 0,
        page_update_counter = 0,
        last_page = -1,
        last_xpointer = nil,
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
    self.last_xpointer = nil
    self.last_page_turn_iso = nil
    self.pending_progress_doc = nil
    self.book_format = nil
    self.is_confirmed = true
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

--- Record a local navigation event at the exact moment the user arrives at a page/position.
function StorytellerSyncEngine:_recordLocalNavigation()
    local ui = self.plugin.ui
    if not ui or not ui.document then return end

    self.last_page_turn_iso = LocatorHelper.formatIso8601()
    local doc, fmt = LocatorHelper.buildProgressDocument(ui, self.last_page_turn_iso)
    if doc then
        self.pending_progress_doc = doc
        self.book_format = fmt
        self.last_xpointer = LocatorHelper.extractCrengineXPointer(doc)
        if not LocatorHelper.positionsEqual(doc, self.last_synced_progress) then
            self.is_confirmed = false
        end
    end
end

-- ────────────────────────────────────────────────────────────
-- Lifecycle Event Handlers
-- ────────────────────────────────────────────────────────────

function StorytellerSyncEngine:handleReaderReady()
    local ui = self.plugin.ui
    if not ui then return end

    self.last_page = ui:getCurrentPage()
    self.last_page_turn_iso = LocatorHelper.formatIso8601()
    local initial_doc, fmt = LocatorHelper.buildProgressDocument(ui, self.last_page_turn_iso)
    self.last_synced_progress = initial_doc
    self.pending_progress_doc = initial_doc
    self.book_format = fmt
    self.last_xpointer = initial_doc and LocatorHelper.extractCrengineXPointer(initial_doc)

    -- Check if there is an unconfirmed offline queue entry for this book
    local book_uuid = ui.doc_settings and ui.doc_settings:readSetting("storyteller_book_uuid")
    local queued = book_uuid and StorytellerQueue:peek(book_uuid)
    if queued and queued.progress_doc then
        self.pending_progress_doc = queued.progress_doc
        self.book_format = queued.format or self.book_format
        self.is_confirmed = false
    else
        self.is_confirmed = true
    end

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
        self:_recordLocalNavigation()

        if self.plugin.settings.auto_sync then
            self.page_update_counter = self.page_update_counter + 1
            local pages_threshold = self.plugin.settings.pages_before_update
            if self.periodic_push_scheduled or (pages_threshold and self.page_update_counter >= pages_threshold) then
                self:schedulePeriodicPush()
            end
        end
    end
end

function StorytellerSyncEngine:handlePosUpdate(_pos, page)
    local ui = self.plugin.ui
    if not ui or not ui.document then return end

    local current_xp = LocatorHelper.getCurrentXPointer(ui)
    if current_xp and current_xp ~= self.last_xpointer then
        if page then
            self.last_page = page
        end
        self:_recordLocalNavigation()

        if self.plugin.settings.auto_sync then
            self.page_update_counter = self.page_update_counter + 1
            local pages_threshold = self.plugin.settings.pages_before_update
            if self.periodic_push_scheduled or (pages_threshold and self.page_update_counter >= pages_threshold) then
                self:schedulePeriodicPush()
            end
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
        local ok, _data, code = Api:updateProgressWithFallback(
            server_url,
            auth_token,
            item.book_uuid,
            item.progress_doc,
            item.format
        )
        return ok, code
    end)
end

--- Get the current local progress document and format, preserving arrival timestamp.
function StorytellerSyncEngine:_getActiveLocalProgress()
    local ui = self.plugin.ui
    if not ui or not ui.document then return nil, nil end

    local current_xp = LocatorHelper.getCurrentXPointer(ui)
    local pending_xp = self.pending_progress_doc and LocatorHelper.extractCrengineXPointer(self.pending_progress_doc)

    if self.pending_progress_doc and current_xp and pending_xp == current_xp then
        return self.pending_progress_doc, (self.book_format or LocatorHelper.detectBookFormat(ui))
    end

    local doc, fmt = LocatorHelper.buildProgressDocument(ui, self.last_page_turn_iso)
    if doc then
        self.pending_progress_doc = doc
        self.book_format = fmt
    end
    return doc, fmt
end

--- Unified full synchronization pipeline:
-- 1. Drains offline queued items (Push)
-- 2. If current document has unconfirmed local changes, pushes to server first
-- 3. Pulls latest remote progression (Pull)
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

        -- Step 2: If current document has unconfirmed local changes, push first
        local ui = self.plugin.ui
        if ui and ui.doc_settings then
            local current_doc, format = self:_getActiveLocalProgress()
            if current_doc and (not self.is_confirmed or not LocatorHelper.positionsEqual(current_doc, self.last_synced_progress)) then
                local book_uuid = ui.doc_settings:readSetting("storyteller_book_uuid")
                if book_uuid then
                    logger.dbg("StorytellerSyncEngine: Flushing unconfirmed local progress before pull")
                    local ok_push, _data, code, used_fmt = Api:updateProgressWithFallback(
                        self.plugin.settings.server_url,
                        self.plugin.settings.auth_token,
                        book_uuid,
                        current_doc,
                        format
                    )
                    if used_fmt and used_fmt ~= format then
                        format = used_fmt
                        self.book_format = used_fmt
                        if ui.document then
                            ui.document._storyteller_book_format = used_fmt
                        end
                    end
                    if ok_push then
                        -- 200 (matches latest) or 201 (saved new)
                        self.last_synced_progress = current_doc
                        self.is_confirmed = true
                        StorytellerQueue:remove(book_uuid)
                    elseif code == 409 then
                        logger.dbg("StorytellerSyncEngine: Server has newer position (409 Conflict)")
                        self.is_confirmed = true
                        StorytellerQueue:remove(book_uuid)
                    else
                        -- Network or 5xx error: save to queue so unconfirmed change isn't lost
                        self.is_confirmed = false
                        StorytellerQueue:push({
                            book_uuid = book_uuid,
                            progress_doc = current_doc,
                            format = format,
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

    local progress_doc, format = self:_getActiveLocalProgress()
    if not progress_doc then
        logger.warn("StorytellerSyncEngine: Could not build v3 progress document")
        return
    end

    if self.is_confirmed and LocatorHelper.positionsEqual(progress_doc, self.last_synced_progress) then
        logger.dbg("StorytellerSyncEngine: Position confirmed and unchanged. Skipping push.")
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
            -- Queue offline with original arrival timestamp preserved
            self.is_confirmed = false
            StorytellerQueue:push({
                book_uuid = book_uuid,
                progress_doc = progress_doc,
                format = format,
            })
            return
        end

        local ok, data, code, used_fmt = Api:updateProgressWithFallback(
            self.plugin.settings.server_url,
            self.plugin.settings.auth_token,
            book_uuid,
            progress_doc,
            format
        )
        if used_fmt and used_fmt ~= format then
            format = used_fmt
            self.book_format = used_fmt
            if ui.document then
                ui.document._storyteller_book_format = used_fmt
            end
        end

        logger.dbg("StorytellerSyncEngine: [Push v3]", format, ok, data, code)

        if ok then
            -- 200 (already latest) or 201 (saved new)
            self.last_synced_progress = progress_doc
            self.is_confirmed = true
            self.push_timestamp = now
            StorytellerQueue:remove(book_uuid)
        elseif code == 409 then
            -- Server position is newer, mark confirmed and trigger a pull
            logger.info("StorytellerSyncEngine: Server has newer position (409). Triggering pull.")
            self.is_confirmed = true
            StorytellerQueue:remove(book_uuid)
            self:pullProgress(interactive, false)
        else
            -- Offline or network/server 5xx error: keep unconfirmed and save to queue
            self.is_confirmed = false
            StorytellerQueue:push({
                book_uuid = book_uuid,
                progress_doc = progress_doc,
                format = format,
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

        local ui = self.plugin.ui
        local format = (ui and LocatorHelper.detectBookFormat(ui)) or self.book_format or "ebook"

        local ok, data, code = Api:getProgress(
            self.plugin.settings.server_url,
            self.plugin.settings.auth_token,
            book_uuid,
            format
        )

        -- If format=readaloud returned 404 (e.g. server only has ebook format), retry with ebook
        if not ok and code == 404 and format ~= "ebook" then
            ok, data, code = Api:getProgress(
                self.plugin.settings.server_url,
                self.plugin.settings.auth_token,
                book_uuid,
                "ebook"
            )
        end

        if not ok or type(data) ~= "table" then
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

        if not data.references and not data.progression then
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

        if not ui or not ui.document then
            finish()
            return
        end

        -- Resolve remote CREngine XPointer in the local document (handles both ebook and readaloud DOMs)
        local remote_xp = LocatorHelper.resolveXPointerInDocument(data, ui)
        if remote_xp and ui.document:isXPointerInCurrentPage(remote_xp) then
            logger.dbg("StorytellerSyncEngine: [Pull v3] Remote XPointer", remote_xp, "is on current page.")
            self.last_synced_progress = data
            self.is_confirmed = true
            if interactive then
                UIManager:show(InfoMessage:new{
                    text = _("Already in sync."),
                    timeout = 3,
                })
            end
            finish()
            return
        end

        -- Resolve remote target page via CREngine XPointer
        local current_page = ui.document:getCurrentPage()
        local remote_target_page = remote_xp and ui.document:getPageFromXPointer(remote_xp)

        local current_percent = LocatorHelper.getLastPercent(ui)
        local remote_percent = tonumber(data.progression)

        logger.dbg("StorytellerSyncEngine: [Pull v3] Current page:", current_page,
                   "Remote target page:", remote_target_page,
                   "Current percent:", current_percent,
                   "Remote percent:", remote_percent,
                   "Remote XPointer:", remote_xp)

        if remote_target_page and current_page then
            if remote_target_page == current_page then
                logger.dbg("StorytellerSyncEngine: [Pull v3] Remote target page", remote_target_page, "is current page. Already in sync.")
                self.last_synced_progress = data
                self.is_confirmed = true
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
                self.last_synced_progress = data
                self.is_confirmed = true
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
            self:syncToRemoteProgress(data, remote_xp)
            self.last_page = ui.document:getCurrentPage()
            self.last_page_turn_iso = data.modified or LocatorHelper.formatIso8601()
            local updated_doc, fmt = LocatorHelper.buildProgressDocument(ui, self.last_page_turn_iso)
            self.last_synced_progress = updated_doc or data
            self.pending_progress_doc = updated_doc or data
            self.book_format = fmt or self.book_format
            self.last_xpointer = updated_doc and LocatorHelper.extractCrengineXPointer(updated_doc) or remote_xp
            self.is_confirmed = true
            StorytellerQueue:remove(book_uuid)

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
            local prompt_text
            if data.title and data.title ~= "" then
                prompt_text = T(_("Sync to %1% (%2) from Storyteller?"), percent_display, data.title)
            else
                prompt_text = T(_("Sync to %1% from Storyteller?"), percent_display)
            end
            UIManager:show(ConfirmBox:new{
                text = prompt_text,
                ok_callback = doSync,
                cancel_callback = finish,
            })
        else
            finish()
        end
    end)
end

--- Navigate reader to remote v3 progression document.
-- @tparam table progress_doc v3 Progression Document
-- @tparam string|nil resolved_xp Resolved CREngine XPointer
function StorytellerSyncEngine:syncToRemoteProgress(progress_doc, resolved_xp)
    local ui = self.plugin.ui
    if not ui or not ui.document then return end

    logger.dbg("StorytellerSyncEngine: syncToRemoteProgress: resolved_xp:", resolved_xp,
               "progression:", progress_doc and progress_doc.progression)

    if resolved_xp and ui.document:isXPointerInDocument(resolved_xp) then
        logger.dbg("StorytellerSyncEngine: Navigating via GotoXPointer:", resolved_xp)
        if ui.link then
            ui.link:addCurrentLocationToStack()
        end
        ui:handleEvent(Event:new("GotoXPointer", resolved_xp, resolved_xp))
        return
    end

    local total_progression = progress_doc and tonumber(progress_doc.progression)
    if total_progression then
        logger.dbg("StorytellerSyncEngine: Fallback navigating via GotoPercent:", total_progression * 100)
        if ui.link then
            ui.link:addCurrentLocationToStack()
        end
        ui:handleEvent(Event:new("GotoPercent", total_progression * 100))
    end
end

return StorytellerSyncEngine
