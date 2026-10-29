--[[--
HTTP client for the Storyteller REST API.

Uses LuaSocket's http.request with KOReader's socketutil for timeouts.
All methods are stateless functions.

@module StorytellerApi
]]--

local JSON = require("json")
local http = require("socket.http")
local ltn12 = require("ltn12")
local socket = require("socket")
local logger = require("logger")
local socketutil = require("socketutil")

local StorytellerApi = {}

-- Timeouts (block_timeout, total_timeout)
local AUTH_TIMEOUTS     = { 5, 15 }
local API_TIMEOUTS      = { 3, 10 }

--- Helper to build full URLs correctly.
local function buildUrl(base, path)
    return base:gsub("/+$", "") .. "/" .. path:gsub("^/+", "")
end

--- Perform an HTTP request and return parsed JSON.
-- @string url Full URL to request
-- @string method HTTP method (GET, POST, etc.)
-- @table headers Table of HTTP headers
-- @string body Optional request body (for POST/PUT)
-- @table timeouts {block_timeout, total_timeout}
-- @treturn bool success
-- @treturn table|string Parsed JSON body on success, error message on failure
-- @treturn int HTTP status code
local function httpRequest(url, method, headers, body, timeouts)
    local sink = {}
    local request = {
        url     = url,
        method  = method,
        headers = headers or {},
        sink    = ltn12.sink.table(sink),
    }

    if body then
        request.source = ltn12.source.string(body)
        request.headers["content-length"] = tostring(#body)
    end

    socketutil:set_timeout(timeouts[1], timeouts[2])
    local code, resp_headers, status = socket.skip(1, http.request(request))
    socketutil:reset_timeout()

    if code == socketutil.TIMEOUT_CODE or
       code == socketutil.SSL_HANDSHAKE_CODE or
       code == socketutil.SINK_TIMEOUT_CODE then
        logger.warn("StorytellerApi: request interrupted:", code)
        return false, "Network timeout", nil
    end

    if resp_headers == nil then
        logger.warn("StorytellerApi: no HTTP headers:", status or code)
        return false, "Network or server unavailable", nil
    end

    local content = table.concat(sink)

    -- Parse JSON response if we got any content
    local parsed = nil
    if content ~= "" then
        local ok, result = pcall(JSON.decode, content)
        if ok then
            parsed = result
        else
            logger.warn("StorytellerApi: JSON decode error:", result)
            parsed = content
        end
    end

    code = tonumber(code)
    if not code or code < 200 or code > 299 then
        local err_msg = "HTTP error " .. tostring(code)
        if type(parsed) == "table" and parsed.error then
            err_msg = parsed.error
            if parsed.error_description then
                err_msg = err_msg .. ": " .. parsed.error_description
            end
        end
        return false, err_msg, code
    end

    return true, parsed, code
end

--- Build the default headers for API requests.
local function commonHeaders(token)
    local headers = {
        ["accept"] = "application/json",
    }
    if token then
        headers["authorization"] = "Bearer " .. token
    end
    return headers
end

--- Start the device authorization flow.
-- POST /api/v2/device/start
-- @string server_url Base URL of the Storyteller server
-- @treturn bool success
-- @treturn table|string On success: {device_code, user_code, verification_uri,
--   verification_uri_complete, expires_in, interval, qr_svg_url}
--   On failure: error message
function StorytellerApi:startDeviceAuth(server_url)
    local url = buildUrl(server_url, "/api/v2/device/start")
    local headers = commonHeaders()
    headers["content-type"] = "application/json"
    return httpRequest(url, "POST", headers, "{}", AUTH_TIMEOUTS)
end

--- Poll for device token after user has approved.
-- POST /api/v2/device/token
-- @string server_url Base URL of the Storyteller server
-- @string device_code The device_code from startDeviceAuth
-- @treturn bool success
-- @treturn table|string On success: session token data. On failure: error message
-- @treturn int HTTP status code
function StorytellerApi:pollDeviceToken(server_url, device_code)
    local url = buildUrl(server_url, "/api/v2/device/token")
    local body = JSON.encode({ device_code = device_code })
    local headers = commonHeaders()
    headers["content-type"] = "application/json"
    return httpRequest(url, "POST", headers, body, AUTH_TIMEOUTS)
end

--- Fetch the list of books from the Storyteller server.
-- GET /api/v2/books
-- @string server_url Base URL
-- @string token Bearer token
-- @treturn bool success
-- @treturn table|string Array of book objects on success, error on failure
function StorytellerApi:getBooks(server_url, token)
    local url = buildUrl(server_url, "/api/v2/books")
    local headers = commonHeaders(token)
    return httpRequest(url, "GET", headers, nil, API_TIMEOUTS)
end

local DEFAULT_FORMAT = "ebook"

--- Fetch the current reading progression for a book.
-- GET /api/v3/books/{bookUuid}/progress?format={format}
-- @string server_url Base URL
-- @string token Bearer token
-- @string book_uuid UUID of the book
-- @string[opt="ebook"] format Publication format ("ebook", "readaloud", "audiobook")
-- @treturn bool success
-- @treturn table|string Progression document or error message
-- @treturn int HTTP status code
function StorytellerApi:getProgress(server_url, token, book_uuid, format)
    local fmt = format or DEFAULT_FORMAT
    local url = buildUrl(server_url, "/api/v3/books/" .. book_uuid .. "/progress?format=" .. fmt)
    local headers = commonHeaders(token)
    return httpRequest(url, "GET", headers, nil, API_TIMEOUTS)
end

--- Update the reading progression for a book.
-- POST /api/v3/books/{bookUuid}/progress?format={format}
-- @string server_url Base URL
-- @string token Bearer token
-- @string book_uuid UUID of the book
-- @table progress_doc Progression document {modified, device, progression, references, title?}
-- @string[opt="ebook"] format Publication format ("ebook", "readaloud", "audiobook")
-- @treturn bool success (true for 200 and 201)
-- @treturn table|string Response data or error message
-- @treturn int HTTP status code (200 = matches latest, 201 = saved, 409 = server has newer)
function StorytellerApi:updateProgress(server_url, token, book_uuid, progress_doc, format)
    local fmt = format or DEFAULT_FORMAT
    local url = buildUrl(server_url, "/api/v3/books/" .. book_uuid .. "/progress?format=" .. fmt)
    local body = JSON.encode(progress_doc)
    local headers = commonHeaders(token)
    headers["content-type"] = "application/json"
    return httpRequest(url, "POST", headers, body, API_TIMEOUTS)
end

--- Update progression, retrying as "ebook" when the server could not interpret
-- the position for the requested format. The server answers 404 for unknown
-- formats, but for an unresolvable position it stores the raw reference and
-- answers 201 with no "#char=" reference, so that case is treated as a miss too.
-- @treturn bool success
-- @treturn table|string Response data or error message
-- @treturn int HTTP status code
-- @treturn string Format that was finally used
function StorytellerApi:updateProgressWithFallback(server_url, token, book_uuid, progress_doc, format)
    local fmt = format or DEFAULT_FORMAT
    local ok, data, code = self:updateProgress(server_url, token, book_uuid, progress_doc, fmt)
    if fmt ~= "ebook" then
        local unresolved = false
        if ok and type(data) == "table" and type(data.references) == "table" then
            unresolved = true
            for _, ref in ipairs(data.references) do
                if type(ref) == "string" and ref:find("#char=", 1, true) then
                    unresolved = false
                    break
                end
            end
        end
        if (not ok and code == 404) or unresolved then
            logger.info("StorytellerApi: format", fmt, "not usable (", code, "); retrying as ebook")
            ok, data, code = self:updateProgress(server_url, token, book_uuid, progress_doc, "ebook")
            fmt = "ebook"
        end
    end
    return ok, data, code, fmt
end

return StorytellerApi
