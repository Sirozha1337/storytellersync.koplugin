local Api = require("StorytellerApi")
local ButtonDialog = require("ui/widget/buttondialog")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local StorytellerBookLink = {}

function StorytellerBookLink.resolveBookUuid(plugin, callback)
    -- 1. Check cache
    local cached_uuid = plugin.ui.doc_settings:readSetting("storyteller_book_uuid")
    if cached_uuid then
        callback(cached_uuid)
        return
    end

    -- 2. Fetch book list and try matching
    local ok, books = Api:getBooks(plugin.settings.server_url, plugin.settings.auth_token)
    if not ok or type(books) ~= "table" then
        logger.warn("StorytellerSync: Failed to fetch books:", books)
        callback(nil, books or "Network error")
        return
    end

    -- Try title match
    local props = plugin.ui.document:getProps()
    local local_title = props and props.title
    if local_title and local_title ~= "" then
        local lower_title = local_title:lower()
        for _, book in ipairs(books) do
            if book.title and book.title:lower() == lower_title then
                logger.dbg("StorytellerSync: Matched by title:", book.title)
                plugin.ui.doc_settings:saveSetting("storyteller_book_uuid", book.uuid)
                plugin.ui.doc_settings:saveSetting("storyteller_book_title", book.title)
                callback(book.uuid)
                return
            end
        end
    end

    -- Try filename match
    local file = plugin.ui.document.file
    if file then
        local util = require("util")
        local _, filename = util.splitFilePathName(file)
        if filename then
            local name_no_ext = filename:match("(.+)%..+$") or filename
            local lower_name = name_no_ext:lower()
            for _, book in ipairs(books) do
                if book.title and book.title:lower() == lower_name then
                    logger.dbg("StorytellerSync: Matched by filename:", book.title)
                    plugin.ui.doc_settings:saveSetting("storyteller_book_uuid", book.uuid)
                    plugin.ui.doc_settings:saveSetting("storyteller_book_title", book.title)
                    callback(book.uuid)
                    return
                end
            end
        end
    end

    -- No auto-match — no automatic prompt on book open
    logger.dbg("StorytellerSync: No automatic match found for this book")
    callback(nil)
end

function StorytellerBookLink.showBookLinkDialog(plugin)
    UIManager:show(InfoMessage:new{
        text = _("Fetching books from server…"),
        timeout = 1,
    })

    UIManager:scheduleIn(0.5, function()
        Device:setIgnoreInput(true)
        local ok, books = Api:getBooks(plugin.settings.server_url, plugin.settings.auth_token)
        Device:setIgnoreInput(false)

        if not ok or type(books) ~= "table" then
            UIManager:show(InfoMessage:new{
                text = T(_("Failed to fetch books: %1"), books or "unknown error"),
            })
            return
        end

        if #books == 0 then
            UIManager:show(InfoMessage:new{
                text = _("No books found on the server."),
            })
            return
        end

        -- Sort by title
        table.sort(books, function(a, b)
            return (a.title or "") < (b.title or "")
        end)

        local current_uuid = plugin.ui.doc_settings:readSetting("storyteller_book_uuid")
        local buttons = {}
        for _i, book in ipairs(books) do
            local display_text = book.title or book.uuid
            if book.uuid == current_uuid then
                display_text = "✓ " .. display_text
            end
            table.insert(buttons, {
                {
                    text = display_text,
                    callback = function()
                        plugin.ui.doc_settings:saveSetting("storyteller_book_uuid", book.uuid)
                        plugin.ui.doc_settings:saveSetting("storyteller_book_title", book.title or "")
                        UIManager:close(plugin._book_link_dialog)
                        UIManager:show(InfoMessage:new{
                            text = T(_("Linked to: %1"), book.title or book.uuid),
                            timeout = 3,
                        })
                    end,
                },
            })
        end

        plugin._book_link_dialog = ButtonDialog:new{
            title = _("Select the matching book"),
            buttons = buttons,
        }
        UIManager:show(plugin._book_link_dialog)
    end)
end

return StorytellerBookLink
