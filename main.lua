--[[--
Storyteller Sync plugin for KOReader.

Synchronizes reading progress between KOReader and a Storyteller server
using Progress API v3 (OPDS Progression v1.0) with native CREngine XPointers.

@module koplugin.StorytellerSync
]]--

local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local StorytellerAuth = require("StorytellerAuth")
local StorytellerBookLink = require("StorytellerBookLink")
local StorytellerSyncEngine = require("StorytellerSyncEngine")

local StorytellerSync = WidgetContainer:extend{
    name = "storytellersync",
    is_doc_only = true,

    -- Sync engine instance
    engine = nil,

    -- Device auth polling state
    device_auth_polling = false,
    device_auth_poll_task = nil,

    settings = nil,
}

local SYNC_STRATEGY = {
    PROMPT  = 1,
    SILENT  = 2,
    DISABLE = 3,
}

StorytellerSync.default_settings = {
    server_url = nil,
    auth_token = nil,
    auto_sync = false,
    pages_before_update = 5,
    sync_forward = SYNC_STRATEGY.PROMPT,
    sync_backward = SYNC_STRATEGY.DISABLE,
}

function StorytellerSync:init()
    self.settings = G_reader_settings:readSetting("storyteller_sync", self.default_settings)
    self.engine = StorytellerSyncEngine:new(self)
    self.engine:init()
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
            text = _("Sync now"),
            enabled_func = function() return self:isLoggedIn() end,
            callback = function()
                self:sync()
            end,
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
-- Sync delegate methods
-- ────────────────────────────────────────────────────────────

function StorytellerSync:sync()
    if self.engine then
        self.engine:syncFull(true, true)
    end
end

function StorytellerSync:updateProgress(ensure_networking, interactive)
    if self.engine then
        self.engine:pushProgress(interactive, false)
    end
end

function StorytellerSync:getProgress(ensure_networking, interactive)
    if self.engine then
        self.engine:pullProgress(interactive, ensure_networking)
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

    self:registerEvents()

    if self:isLoggedIn() then
        StorytellerBookLink.resolveBookUuid(self, function(uuid)
            if uuid then
                logger.info("StorytellerSync: Book auto-linked:", uuid)
            end
        end)
    end

    if self.engine then
        self.engine:handleReaderReady()
    end
end

function StorytellerSync:_onPageUpdate(page)
    if self.engine then
        self.engine:handlePageUpdate(page)
    end
end

function StorytellerSync:_onPosUpdate(pos, page)
    if self.engine then
        self.engine:handlePosUpdate(pos, page)
    end
end

function StorytellerSync:_onCloseDocument()
    logger.dbg("StorytellerSync: onCloseDocument")
    self.onResume = nil
    self.onSuspend = nil

    if self.engine then
        self.engine:handleCloseDocument()
    end
end

function StorytellerSync:_onResume()
    logger.dbg("StorytellerSync: onResume")
    if self.engine then
        self.engine:handleResume()
    end
end

function StorytellerSync:_onSuspend()
    logger.dbg("StorytellerSync: onSuspend")
    if self.engine then
        self.engine:handleSuspend()
    end
end

function StorytellerSync:_onNetworkConnected()
    logger.dbg("StorytellerSync: onNetworkConnected")
    if self.engine then
        self.engine:handleNetworkConnected()
    end
end

function StorytellerSync:registerEvents()
    -- Always track page/pos updates so `modified` reflects the exact time the user arrived at the page,
    -- even if they later trigger a manual "Push progress now" or "Sync now".
    self.onPageUpdate = self._onPageUpdate
    self.onPosUpdate = self._onPosUpdate

    if self.settings.auto_sync then
        self.onCloseDocument = self._onCloseDocument
        self.onResume = self._onResume
        self.onSuspend = self._onSuspend
        self.onNetworkConnected = self._onNetworkConnected
    else
        self.onCloseDocument = nil
        self.onResume = nil
        self.onSuspend = nil
        self.onNetworkConnected = nil
    end
end

function StorytellerSync:onCloseWidget()
    if self.engine then
        self.engine:cleanup()
    end
    if self.device_auth_poll_task then
        UIManager:unschedule(self.device_auth_poll_task)
        self.device_auth_polling = false
        self.device_auth_poll_task = nil
    end
end

return StorytellerSync
