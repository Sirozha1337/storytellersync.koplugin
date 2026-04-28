-- CacheManager - Storyteller Sync caching system
-- Stores parsed EPUB spine data to avoid re-parsing on every book open
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local DocSettings = require("docsettings")
local CacheFileName = "storytellersync_cache.lua"

local CacheManager = {}

function CacheManager:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

-- Get cache file path for a book
function CacheManager:getCachePath(book_path)
    if not book_path then
        return nil
    end

    local cache_dir = DocSettings:getSidecarDir(book_path)
    local cache_file = cache_dir .. "/" .. CacheFileName

    return cache_file
end

-- Ensure directory exists
function CacheManager:ensureDirectory(path)
    local dir = path:match("(.+)/[^/]+$")
    if not dir then
        return false
    end

    local attr = lfs.attributes(dir)
    if attr and attr.mode == "directory" then
        return true
    end

    local success, err = lfs.mkdir(dir)
    if not success then
        logger.warn("CacheManager: Failed to create directory:", err or "unknown error")
        return false
    end

    return true
end

-- Save data to cache (v1.0 format)
function CacheManager:saveCache(book_path, data)
    if not book_path or not data then
        logger.warn("CacheManager: Cannot save cache - invalid parameters")
        return false
    end

    local cache_file = self:getCachePath(book_path)
    if not cache_file then
        logger.warn("CacheManager: Cannot determine cache path")
        return false
    end

    if not self:ensureDirectory(cache_file) then
        logger.warn("CacheManager: Cannot create cache directory")
        return false
    end

    -- Add metadata
    data.cached_at = os.time()
    data.last_read_at = os.time()
    data.cache_version = "1.0"

    -- Serialize and write
    local success, err = pcall(function()
        local f, open_err = io.open(cache_file, "w")

        if not f then
            logger.warn("CacheManager: Cannot open file for writing:", cache_file, open_err)
            return false
        end

        local serialized_data = self:serialize(data)

        if not serialized_data then
            logger.warn("CacheManager: Failed to serialize data")
            f:close()
            return false
        end

        f:write("-- Storyteller Sync Cache v1.0\n")
        f:write("-- Generated: " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n\n")
        f:write("return " .. serialized_data)
        f:close()

        logger.info("CacheManager: Saved cache to:", cache_file)
        return true
    end)

    if not success then
        logger.warn("CacheManager: Failed to save cache:", err or "unknown error")
        return false
    end

    return success
end

-- Load data from cache
function CacheManager:loadCache(book_path)
    if not book_path then
        return nil
    end

    local cache_file = self:getCachePath(book_path)
    if not cache_file then
        return nil
    end

    local attr = lfs.attributes(cache_file)
    if not attr then
        logger.info("CacheManager: No cache file found")
        return nil
    end

    local success, data = pcall(function()
        return dofile(cache_file)
    end)

    if not success or not data then
        logger.warn("CacheManager: Failed to load cache:", data or "unknown error")
        return nil
    end

    -- Check cache version
    if data.cache_version ~= "1.0" then
        logger.warn("CacheManager: Cache version mismatch (got", data.cache_version, ", need 1.0), ignoring")
        return nil
    end

    logger.info("CacheManager: Loaded cache from:", cache_file)
    if data.cached_at then
        local cache_age_days = math.floor((os.time() - data.cached_at) / 86400)
        logger.info("CacheManager: Cache age:", cache_age_days, "days")
    end

    return data
end

-- Serialize Lua table to string
function CacheManager:serialize(obj, indent, seen)
    indent = indent or ""
    seen = seen or {}

    local t = type(obj)

    if t == "table" then
        if seen[obj] then
            return "{--[[circular reference]]}"
        end
        seen[obj] = true

        local s = "{\n"
        for k, v in pairs(obj) do
            if type(v) ~= "function" and type(v) ~= "userdata" and type(v) ~= "thread" then
                s = s .. indent .. "  "
                if type(k) == "string" then
                    if k:match("^[%a_][%w_]*$") then
                        s = s .. k .. " = "
                    else
                        s = s .. "[" .. string.format("%q", k) .. "] = "
                    end
                else
                    s = s .. "[" .. tostring(k) .. "] = "
                end
                s = s .. self:serialize(v, indent .. "  ", seen) .. ",\n"
            end
        end
        s = s .. indent .. "}"
        return s
    elseif t == "string" then
        return string.format("%q", obj)
    elseif t == "number" or t == "boolean" then
        return tostring(obj)
    elseif t == "nil" then
        return "nil"
    else
        return "nil"
    end
end

-- Clear cache for a book
function CacheManager:clearCache(book_path)
    local cache_file = self:getCachePath(book_path)
    if cache_file then
        local success, err = os.remove(cache_file)
        if success then
            logger.info("CacheManager: Cleared cache:", cache_file)
            return true
        else
            logger.warn("CacheManager: Failed to clear cache:", err or "unknown")
            return false
        end
    end
    return false
end

return CacheManager