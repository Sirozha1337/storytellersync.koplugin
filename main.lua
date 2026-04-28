--[[--
Storyteller Sync plugin for KOReader.

Synchronizes reading progress between KOReader and a Storyteller server
using fragment-based (sentence span ID) positioning.

@module koplugin.StorytellerSync
]]--

local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Math = require("optmath")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local time = require("ui/time")
local _ = require("gettext")
local T = require("ffi/util").template
local LocatorHelper = require("LocatorHelper")
local Api = require("StorytellerApi")
local StorytellerBookLink = require("StorytellerBookLink")
local StorytellerAuth = require("StorytellerAuth")

local StorytellerSync = WidgetContainer:extend{
    name = "storytellersync",
    is_doc_only = true,

    -- Debounce state
    push_timestamp = nil,
    pull_timestamp = nil,
    page_update_counter = nil,
    last_page = nil,
    periodic_push_task = nil,
    periodic_push_scheduled = nil,

    -- Device auth polling state
    device_auth_polling = false,
    device_auth_poll_task = nil,

    -- EPUB spine: array of href strings, index = DocFragment index (1-based)
    _epub_spine = nil,
    _epub_spine_map = nil,

    settings = nil,
}

local SYNC_STRATEGY = {
    PROMPT  = 1,
    SILENT  = 2,
    DISABLE = 3,
}

local API_CALL_DEBOUNCE_DELAY = time.s(25)

StorytellerSync.default_settings = {
    server_url = nil,
    auth_token = nil,
    auto_sync = false,
    pages_before_update = 5,
    sync_forward = SYNC_STRATEGY.PROMPT,
    sync_backward = SYNC_STRATEGY.DISABLE,
}

function StorytellerSync:init()
    self.push_timestamp = 0
    self.pull_timestamp = 0
    self.page_update_counter = 0
    self.last_page = -1
    self.periodic_push_scheduled = false

    self.periodic_push_task = function()
        self.periodic_push_scheduled = false
        self.page_update_counter = 0
        self:updateProgress(false, false)
    end

    self.settings = G_reader_settings:readSetting("storyteller_sync", self.default_settings)
    self.ui.menu:registerToMainMenu(self)
end

function StorytellerSync:isLoggedIn()
    return self.settings.server_url and self.settings.auth_token
end

-- ────────────────────────────────────────────────────────────
-- Menu
-- ────────────────────────────────────────────────────────────

function StorytellerSync:_isEpub()
    if not self.ui or not self.ui.document then return true end
    local file = self.ui.document.file
    return file and file:lower():match("%.epub$") ~= nil
end

function StorytellerSync:addToMainMenu(menu_items)
    if not self:_isEpub() then return end

    menu_items.storyteller_sync = {
        text = _("Storyteller sync"),
        sorting_hint = "tools",
        sub_item_table = self:getSubMenuItems(),
    }
end

function StorytellerSync:getSubMenuItems()
    return {
        {
            text = _("Server URL"),
            keep_menu_open = true,
            callback = function()
                self:showServerUrlDialog()
            end,
        },
        {
            text_func = function()
                return self:isLoggedIn() and _("Logout") or _("Login")
            end,
            keep_menu_open = true,
            callback_func = function()
                if self:isLoggedIn() then
                    return function(menu)
                        StorytellerAuth.logout(self, menu)
                    end
                else
                    return function(menu)
                        StorytellerAuth.startLogin(self, menu)
                    end
                end
            end,
            separator = true,
        },
        {
            text = _("Automatically sync"),
            checked_func = function() return self.settings.auto_sync end,
            callback = function()
                self.settings.auto_sync = not self.settings.auto_sync
                self:registerEvents()
            end,
        },
        {
            text_func = function()
                local period = self.settings.pages_before_update
                if period and period > 0 then
                    return T(_("Sync every # pages (%1)"), period)
                else
                    return _("Sync every # pages (disabled)")
                end
            end,
            enabled_func = function() return self.settings.auto_sync end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local SpinWidget = require("ui/widget/spinwidget")
                UIManager:show(SpinWidget:new{
                    text = _("Number of page turns before syncing progress."),
                    value = self.settings.pages_before_update or 0,
                    value_min = 0,
                    value_max = 999,
                    value_step = 1,
                    value_hold_step = 10,
                    ok_text = _("Set"),
                    title_text = _("Pages before sync"),
                    default_value = 5,
                    callback = function(spin)
                        self.settings.pages_before_update = spin.value > 0 and spin.value or nil
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end,
                })
            end,
            separator = true,
        },
        {
            text = _("Push progress now"),
            enabled_func = function() return self:isLoggedIn() end,
            callback = function()
                self:updateProgress(true, true)
            end,
        },
        {
            text = _("Pull progress now"),
            enabled_func = function() return self:isLoggedIn() end,
            callback = function()
                self:getProgress(true, true)
            end,
            separator = true,
        },
        {
            text_func = function()
                local uuid = self.ui.doc_settings:readSetting("storyteller_book_uuid")
                local title = self.ui.doc_settings:readSetting("storyteller_book_title")
                if uuid and title then
                    return T(_("Book Linked (%1 %2)"), uuid:sub(1, 8), title)
                elseif uuid then
                    return T(_("Book Linked (%1)"), uuid:sub(1, 8))
                else
                    return _("Link this book")
                end
            end,
            enabled_func = function() return self:isLoggedIn() end,
            callback = function()
                StorytellerBookLink.showBookLinkDialog(self)
            end,
        },
    }
end


-- ────────────────────────────────────────────────────────────
-- Settings dialogs
-- ────────────────────────────────────────────────────────────

function StorytellerSync:showServerUrlDialog()
    local dialog
    dialog = InputDialog:new{
        title = _("Storyteller server URL"),
        input = self.settings.server_url or "https://",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("OK"),
                    is_enter_default = true,
                    callback = function()
                        local url = dialog:getInputText()
                        if url and url ~= "" and url ~= "https://" then
                            self.settings.server_url = url:gsub("/$", "")
                        else
                            self.settings.server_url = nil
                        end
                        UIManager:close(dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- ────────────────────────────────────────────────────────────
-- Sync logic helpers
-- ────────────────────────────────────────────────────────────

function StorytellerSync:_checkSyncPrerequisites(interactive, type)
    if not self:isLoggedIn() then
        if interactive then
            UIManager:show(InfoMessage:new{
                text = _("Please login first."),
                timeout = 3,
            })
        end
        return false
    end

    local now = UIManager:getElapsedTimeSinceBoot()
    local last_timestamp = (type == "push") and self.push_timestamp or self.pull_timestamp
    if not interactive and now - last_timestamp <= API_CALL_DEBOUNCE_DELAY then
        logger.dbg("StorytellerSync: " .. type .. " debounced")
        return false
    end

    return true, now
end

-- ────────────────────────────────────────────────────────────
-- Sync: Push (KOReader → Storyteller)
-- ────────────────────────────────────────────────────────────

function StorytellerSync:updateProgress(ensure_networking, interactive)
    local ok_pre, now = self:_checkSyncPrerequisites(interactive, "push")
    if not ok_pre then return end

    if ensure_networking and NetworkMgr:willRerunWhenOnline(function() self:updateProgress(ensure_networking, interactive) end) then
        return
    end

    StorytellerBookLink.resolveBookUuid(self, function(book_uuid)
        if not book_uuid then
            if interactive then
                UIManager:show(InfoMessage:new{
                    text = _("This book is not linked to a Storyteller book. Use 'Link this book' from the menu."),
                    timeout = 5,
                })
            end
            return
        end

        local locator = LocatorHelper.buildCurrentLocator(self.ui, self._epub_spine)
        if not locator then
            logger.warn("StorytellerSync: Could not build locator")
            return
        end

        if LocatorHelper.locatorsEqual(locator, self.last_synced_locator) then
            logger.dbg("StorytellerSync: Position unchanged. Skipping push.")
            if interactive then
                UIManager:show(InfoMessage:new{
                    text = _("Position hasn't changed. Skipping sync."),
                    timeout = 3,
                })
            end
            return
        end

        local timestamp = os.time() * 1000 -- milliseconds

        local ok, data, code = Api:updatePosition(
            self.settings.server_url,
            self.settings.auth_token,
            book_uuid,
            locator,
            timestamp
        )

        logger.dbg("StorytellerSync: [Push]", ok, data, code)

        if ok then
            self.last_synced_locator = locator
        end

        if interactive then
            if ok then
                UIManager:show(InfoMessage:new{
                    text = _("Progress pushed."),
                    timeout = 3,
                })
            elseif code == 409 then
                UIManager:show(InfoMessage:new{
                    text = _("Server has a newer position. Pull first."),
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

    self.push_timestamp = now
end

-- ────────────────────────────────────────────────────────────
-- Sync: Pull (Storyteller → KOReader)
-- ────────────────────────────────────────────────────────────

function StorytellerSync:getProgress(ensure_networking, interactive)
    local ok_pre, now = self:_checkSyncPrerequisites(interactive, "pull")
    if not ok_pre then return end

    if ensure_networking and NetworkMgr:willRerunWhenOnline(function() self:getProgress(ensure_networking, interactive) end) then
        return
    end

    StorytellerBookLink.resolveBookUuid(self, function(book_uuid)
        if not book_uuid then
            if interactive then
                UIManager:show(InfoMessage:new{
                    text = _("This book is not linked to a Storyteller book. Use 'Link this book' from the menu."),
                    timeout = 5,
                })
            end
            return
        end

        local ok, data = Api:getPosition(
            self.settings.server_url,
            self.settings.auth_token,
            book_uuid
        )

        if not ok or not data then
            if interactive then
                UIManager:show(InfoMessage:new{
                    text = _("No progress found on server."),
                    timeout = 3,
                })
            end
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
            return
        end

        -- Check if the remote fragment is already visible on the current page
        local remote_xpath = LocatorHelper.createXPathFromLocator(remote_locator, self._epub_spine_map)
        if remote_xpath and self.ui.document:isXPointerInCurrentPage(remote_xpath) then
            logger.dbg("StorytellerSync: [Pull] Remote fragment", remote_xpath, "is on current page.")
            if interactive then
                UIManager:show(InfoMessage:new{
                    text = _("Already in sync."),
                    timeout = 3,
                })
            end
            return
        end

        -- Compare with current position
        local current_percent = LocatorHelper.getLastPercent(self.ui)
        local remote_percent = remote_locator.locations and remote_locator.locations.totalProgression

        logger.dbg("StorytellerSync: [Pull] Current percent:", current_percent, "Remote percent:", remote_percent)

        if remote_percent and current_percent then
            -- Calculate sensitivity based on page count (threshold = 2 pages)
            local total_pages = LocatorHelper.getPageCount(self.ui)
            local threshold = 0.005
            if total_pages and total_pages > 0 then
                threshold = 2 / total_pages
            end
            logger.dbg("StorytellerSync: [Pull] Sync threshold:", threshold, "(total pages:", total_pages, ")")

            -- Consider "same" if within the threshold
            if math.abs(remote_percent - current_percent) < threshold then
                if interactive then
                    UIManager:show(InfoMessage:new{
                        text = _("Already in sync."),
                        timeout = 3,
                    })
                end
                return
            end
        end

        -- Determine forward/backward
        local is_forward = true
        if remote_percent and current_percent then
            is_forward = (remote_percent > current_percent)
        end

        local strategy = is_forward and self.settings.sync_forward or self.settings.sync_backward
        if strategy == SYNC_STRATEGY.DISABLE then
            return
        end

        local function doSync()
            self:syncToRemoteLocator(remote_locator, remote_xpath)
            self.last_synced_locator = LocatorHelper.buildCurrentLocator(self.ui, self._epub_spine)
            UIManager:show(InfoMessage:new{
                text = _("Progress synchronized."),
                timeout = 3,
            })
        end

        if interactive or strategy == SYNC_STRATEGY.SILENT then
            doSync()
        elseif strategy == SYNC_STRATEGY.PROMPT then
            local percent_display = remote_percent and Math.round(remote_percent * 100) or "?"
            UIManager:show(ConfirmBox:new{
                text = T(_("Sync to %1% from Storyteller?"), percent_display),
                ok_callback = doSync,
            })
        end
    end)

    self.pull_timestamp = now
end

--- Navigate to a remote Readium locator position.
function StorytellerSync:syncToRemoteLocator(locator, xpath)
    logger.dbg("StorytellerSync: syncToRemoteLocator: locator:", locator, ", xpath: ", xpath)
    if not xpath then return end

    -- Try fragment-based navigation via ReaderLink.
    -- CREngine's internal anchor format is "#elementId". We pass it through
    -- self.ui.link:onGotoLink() so it goes through isXPointerInDocument
    -- validation and fires GotoXPointer correctly.
    local navigated = false

    if xpath then
        logger.dbg("StorytellerSync: Navigating via xpath:", xpath)

        if self.ui.link and self.ui.document:isXPointerInDocument(xpath) then
            self.ui.link:onGotoLink({ xpointer = xpath }, true) -- neglect_current_location=true
            navigated = true
        else
            logger.warn("StorytellerSync: XPath not found in document:", xpath)
        end
    end

    if not navigated then
        -- Fallback: percentage-based navigation
        local total_progression = locator.locations and locator.locations.totalProgression
        if total_progression then
            logger.dbg("StorytellerSync: Navigating via percentage:", total_progression * 100)
            self.ui:handleEvent(Event:new("GotoPercent", total_progression * 100))
        end
    end
end

-- ────────────────────────────────────────────────────────────
-- Event handlers
-- ────────────────────────────────────────────────────────────

function StorytellerSync:onReaderReady()
    if not self:_isEpub() then
        logger.dbg("StorytellerSync: Document is not an EPUB. Disabling plugin.")
        return
    end

    self.last_page = self.ui:getCurrentPage()
    self:registerEvents()

    if self:isLoggedIn() then
        -- Auto-link book on open if not already linked
        StorytellerBookLink.resolveBookUuid(self, function(uuid)
            if uuid then
                logger.info("StorytellerSync: Book auto-linked:", uuid)
            end
        end)
    end

    -- Build the EPUB spine index→href map for getCurrentChapterHref().
    -- Only meaningful for reflowable (non-page) EPUB documents.
    self._epub_spine = nil
    self._epub_spine_map = nil
    if self.ui.document and not self.ui.document.info.has_pages then
        local file = self.ui.document.file
        if file and file:lower():match("%.epub$") then
            self._epub_spine, self._epub_spine_map = LocatorHelper.buildEpubSpine(file)
            if self._epub_spine then
                logger.dbg("StorytellerSync: Spine ready, items:", #self._epub_spine)
            else
                logger.warn("StorytellerSync: Could not build EPUB spine for:", file)
            end
        end
    end

    self.last_synced_locator = LocatorHelper.buildCurrentLocator(self.ui, self._epub_spine)

    if self.settings.auto_sync and self:isLoggedIn() then
        UIManager:nextTick(function()
            self:getProgress(true, false)
        end)
    end
end

function StorytellerSync:schedulePeriodicPush()
    UIManager:unschedule(self.periodic_push_task)
    UIManager:scheduleIn(10, self.periodic_push_task)
    self.periodic_push_scheduled = true
end

function StorytellerSync:_onPageUpdate(page)
    if page == nil then return end

    if self.last_page ~= page then
        self.last_page = page
        self.page_update_counter = self.page_update_counter + 1
        if self.periodic_push_scheduled or
           (self.settings.pages_before_update and self.page_update_counter >= self.settings.pages_before_update) then
            self:schedulePeriodicPush()
        end
    end
end

function StorytellerSync:_onCloseDocument()
    logger.dbg("StorytellerSync: onCloseDocument")
    self.onResume = nil
    self.onSuspend = nil

    if not self:isLoggedIn() then return end

    local book_uuid = self.ui.doc_settings:readSetting("storyteller_book_uuid")
    if not book_uuid then return end

    local locator = LocatorHelper.buildCurrentLocator(self.ui, self._epub_spine)
    if not locator then return end

    if LocatorHelper.locatorsEqual(locator, self.last_synced_locator) then
        logger.dbg("StorytellerSync: Position unchanged since open/sync. Skipping push on close.")
        return
    end

    local server_url = self.settings.server_url
    local auth_token = self.settings.auth_token
    local timestamp = os.time() * 1000

    NetworkMgr:goOnlineToRun(function()
        Api:updatePosition(server_url, auth_token, book_uuid, locator, timestamp)
    end)
end

function StorytellerSync:_onResume()
    logger.dbg("StorytellerSync: onResume")
    UIManager:scheduleIn(1, function()
        self:getProgress(true, false)
    end)
end

function StorytellerSync:_onSuspend()
    logger.dbg("StorytellerSync: onSuspend")
    self:updateProgress(true, false)
end

function StorytellerSync:_onNetworkConnected()
    logger.dbg("StorytellerSync: onNetworkConnected")
    UIManager:scheduleIn(0.5, function()
        self:getProgress(false, false)
    end)
end

function StorytellerSync:registerEvents()
    if self.settings.auto_sync then
        self.onCloseDocument = self._onCloseDocument
        self.onPageUpdate = self._onPageUpdate
        self.onResume = self._onResume
        self.onSuspend = self._onSuspend
        self.onNetworkConnected = self._onNetworkConnected
    else
        self.onCloseDocument = nil
        self.onPageUpdate = nil
        self.onResume = nil
        self.onSuspend = nil
        self.onNetworkConnected = nil
    end
end

function StorytellerSync:onCloseWidget()
    UIManager:unschedule(self.periodic_push_task)
    self.periodic_push_task = nil
    if self.device_auth_poll_task then
        UIManager:unschedule(self.device_auth_poll_task)
        self.device_auth_polling = false
        self.device_auth_poll_task = nil
    end
end

return StorytellerSync
