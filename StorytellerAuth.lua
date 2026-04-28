local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template
local NetworkMgr = require("ui/network/manager")
local QRWidget = require("ui/widget/qrwidget")
local CenterContainer = require("ui/widget/container/centercontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local TextBoxWidget = require("ui/widget/textboxwidget")
local Font = require("ui/font")
local Size = require("ui/size")
local Dialog = require("ui/widget/buttondialog")
local Api = require("StorytellerApi")

local StorytellerAuth = {}

function StorytellerAuth.fixUri(uri, base_url)
    if not uri then return nil end
    local path = uri:match("^https?://[^/]+(/.*)$") or uri:match("^(/.*)$")
    if path then
        return base_url .. path
    end
    return uri
end

function StorytellerAuth.createLoginDialog(verification_uri, verification_uri_complete, user_code, close_callback)
    local Screen = require("device").screen
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    local qr_widget = QRWidget:new{
        text = verification_uri_complete or verification_uri,
        width = screen_w / 2, -- Reasonable size for QR
    }

    local content = VerticalGroup:new{
        align = "center",
        TextBoxWidget:new{
            text = T(_("Go to:\n%1\n\nEnter code: %2\n\nWaiting for approval…"), verification_uri, user_code),
            face = Font:getFace("infofont"),
            width = screen_w - Size.padding.fullscreen * 2,
            alignment = "center",
        },
        CenterContainer:new{
            dimen = { w = screen_w, h = qr_widget:getSize().h + Size.padding.large * 2 },
            qr_widget
        }
    }

    local dialog = Dialog:new{
        title = _("Storyteller Login"),
        _added_widgets = { content },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = close_callback,
                }
            }
        }
    }

    return dialog
end

function StorytellerAuth.closeLoginDialog(plugin, dialog, message)
    plugin.device_auth_polling = false
    UIManager:close(dialog)
    if not message then
        return
    end

    UIManager:show(InfoMessage:new{
        text = _(message),
        timeout = 3,
    })
end

function StorytellerAuth.startLogin(plugin, menu)
    if not plugin.settings.server_url then
        UIManager:show(InfoMessage:new{
            text = _("Please set the server URL first."),
            timeout = 3,
        })
        return
    end

    if NetworkMgr:willRerunWhenOnline(function() StorytellerAuth.startLogin(plugin, menu) end) then
        return
    end

    Device:setIgnoreInput(true)
    local ok, data = Api:startDeviceAuth(plugin.settings.server_url)
    Device:setIgnoreInput(false)

    if not ok then
        UIManager:show(InfoMessage:new{
            text = T(_("Login failed: %1"), data or "unknown error"),
        })
        return
    end

    local user_code = data.user_code or "????"
    local device_code = data.device_code
    local interval = (data.interval or 5)
    local expires_in = data.expires_in or 600

    -- The server might return verification URLs with an incorrect host/port (e.g., 0.0.0.0:80).
    -- Extract the path and append it to the configured server URL.
    local base_url = plugin.settings.server_url:gsub("/$", "")
    local verification_uri = StorytellerAuth.fixUri(data.verification_uri, base_url)
    local verification_uri_complete = StorytellerAuth.fixUri(data.verification_uri_complete, base_url)

    local dialog
    dialog = StorytellerAuth.createLoginDialog(verification_uri, verification_uri_complete, user_code, function()
        StorytellerAuth.closeLoginDialog(plugin, dialog, nil)
    end)
    UIManager:show(dialog)

    -- Start polling
    plugin.device_auth_polling = true
    local elapsed = 0
    plugin.device_auth_poll_task = function()
        if not plugin.device_auth_polling then return end
        elapsed = elapsed + interval

        if elapsed > expires_in then
            StorytellerAuth.closeLoginDialog(plugin, dialog, "Login timed out. Please try again.")
            return
        end

        local poll_ok, poll_data, poll_code = Api:pollDeviceToken(plugin.settings.server_url, device_code)

        if poll_ok and poll_data and poll_data.access_token then
            -- Success!
            plugin.settings.auth_token = poll_data.access_token
            if menu then menu:updateItems() end
            StorytellerAuth.closeLoginDialog(plugin, dialog, "Successfully logged in to Storyteller.")
            return
        end

        -- Check if still pending or slow_down
        if not poll_ok then
            local err_str = tostring(poll_data or "")
            if err_str:find("authorization_pending") or err_str:find("slow_down") then
                -- Keep polling
                UIManager:scheduleIn(interval, plugin.device_auth_poll_task)
                return
            end
            -- Actual error (denied, expired, etc.)
            StorytellerAuth.closeLoginDialog(plugin, dialog, "Login failed: " .. tostring(poll_data or "unknown error"))
            return
        end

        -- Unexpected state, keep polling
        UIManager:scheduleIn(interval, plugin.device_auth_poll_task)
    end

    UIManager:scheduleIn(interval, plugin.device_auth_poll_task)
end

function StorytellerAuth.logout(plugin, menu)
    plugin.settings.auth_token = nil
    plugin.settings.auto_sync = false
    plugin:registerEvents()
    if menu then menu:updateItems() end
    UIManager:show(InfoMessage:new{
        text = _("Logged out of Storyteller."),
        timeout = 2,
    })
end

return StorytellerAuth
