--[[--
Storyteller Queue - Offline Sync Queue

Persists unpushed reading progress updates to disk using KOReader's Persist module.
Queued items are drained and sent when network connectivity is restored.

@module StorytellerQueue
]]--

local DataStorage = require("datastorage")
local Persist = require("persist")
local logger = require("logger")

local QUEUE_PATH = DataStorage:getSettingsDir() .. "/storyteller_sync_queue.lua"
local MAX_AGE = 28 * 24 * 3600 -- 4 weeks in seconds
local MAX_ENTRIES = 100

local StorytellerQueue = {}

function StorytellerQueue:_storage()
    if not self._persist then
        self._persist = Persist:new{ path = QUEUE_PATH, codec = "dump" }
    end
    return self._persist
end

function StorytellerQueue:load()
    local storage = self:_storage()
    if not storage:exists() then return {} end
    local data, err = storage:load()
    if not data or type(data) ~= "table" then
        if err then
            logger.warn("StorytellerQueue: failed to load queue:", err)
        end
        return {}
    end
    return data
end

function StorytellerQueue:save(queue)
    local ok, err = self:_storage():save(queue)
    if not ok then
        logger.warn("StorytellerQueue: failed to save queue:", err)
    end
end

--- Queue a progress update for later retry.
-- Deduplicates by book_uuid so only the newest position is kept per book.
-- @tparam table item { book_uuid = string, progress_doc = table, format = string }
function StorytellerQueue:push(item)
    if not item or not item.book_uuid or not item.progress_doc then
        logger.warn("StorytellerQueue: invalid item to push")
        return
    end

    local queue = self:load()
    local now = os.time()
    item.queued_at = now

    local filtered = {}
    for _, entry in ipairs(queue) do
        local is_same_book = (entry.book_uuid == item.book_uuid)
        local is_expired = (now - (entry.queued_at or 0)) >= MAX_AGE
        local is_valid_v3 = (type(entry.progress_doc) == "table")
        if not is_same_book and not is_expired and is_valid_v3 then
            table.insert(filtered, entry)
        end
    end

    table.insert(filtered, item)

    while #filtered > MAX_ENTRIES do
        table.remove(filtered, 1)
    end

    self:save(filtered)
    logger.dbg("StorytellerQueue: queued progress for book:", item.book_uuid, "queue total:", #filtered)
end

--- Remove any queued progress update for a specific book UUID.
-- @tparam string book_uuid
function StorytellerQueue:remove(book_uuid)
    if not book_uuid then return end
    local queue = self:load()
    if #queue == 0 then return end

    local filtered = {}
    local removed = false
    for _, entry in ipairs(queue) do
        if entry.book_uuid == book_uuid then
            removed = true
        else
            table.insert(filtered, entry)
        end
    end

    if removed then
        self:save(filtered)
        logger.dbg("StorytellerQueue: removed confirmed book from queue:", book_uuid)
    end
end

--- Attempt to send all queued items in order.
-- @tparam function send_func function(item) -> bool success, int http_status_code
-- @treturn number Number of successfully processed/cleared items
function StorytellerQueue:drain(send_func)
    local queue = self:load()
    if #queue == 0 then return 0 end

    logger.info("StorytellerQueue: draining", #queue, "queued items")
    local processed = 0

    for i, item in ipairs(queue) do
        -- Drop legacy v2 queue items that lack progress_doc
        if type(item.progress_doc) ~= "table" then
            logger.info("StorytellerQueue: dropping legacy v2 queued item for book:", item.book_uuid)
            processed = processed + 1
        else
            local ok, code = send_func(item)
            local is_permanent = type(code) == "number" and (code >= 400 and code < 500 and code ~= 429)
            if ok or is_permanent then
                -- Success (200/201) or permanent status (409 conflict, 404 not found, 401 unauth, other 4xx errors)
                if not ok and code ~= 409 then
                    logger.warn("StorytellerQueue: dropping queued item due to permanent client error:", code, item.book_uuid)
                end
                processed = processed + 1
            else
                -- Network error or temporary server 5xx: keep this and all subsequent items
                local remaining = {}
                for j = i, #queue do
                    table.insert(remaining, queue[j])
                end
                self:save(remaining)
                logger.info("StorytellerQueue: processed", processed, ", remaining in queue:", #remaining)
                return processed
            end
        end
    end

    -- All items processed
    self:save({})
    logger.info("StorytellerQueue: successfully drained all", processed, "items")
    return processed
end

--- Peek at the queued item for a specific book UUID if present.
-- @tparam string book_uuid
-- @treturn table|nil
function StorytellerQueue:peek(book_uuid)
    if not book_uuid then return nil end
    local queue = self:load()
    for _, entry in ipairs(queue) do
        if entry.book_uuid == book_uuid and type(entry.progress_doc) == "table" then
            return entry
        end
    end
    return nil
end

function StorytellerQueue:count()
    return #self:load()
end

function StorytellerQueue:clear()
    self:save({})
end

return StorytellerQueue
