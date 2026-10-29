--[[--
Helper utilities for Storyteller Progress API v3 (OPDS Progression v1.0).

Handles building v3 Progression Documents, detecting book format
("ebook" vs "readaloud"), formatting ISO 8601 UTC timestamps, and
resolving CREngine XPointers with cross-format fallback.

@module LocatorHelper
]]--

local Math = require("optmath")
local logger = require("logger")
local time = require("ui/time")

local LocatorHelper = {}

--- Format a time.realtime() fts value (or current time) as ISO 8601 UTC string with milliseconds.
-- Example: "2026-10-20T19:46:18.388Z"
-- @tparam[opt] number realtime_fts Fixed-point timestamp from time.realtime()
-- @treturn string ISO 8601 UTC timestamp
function LocatorHelper.formatIso8601(realtime_fts)
    realtime_fts = realtime_fts or time.realtime()
    local sec, usec = time.split_s_us(realtime_fts)
    sec = sec or os.time()
    local ms = math.floor((usec or 0) / 1000)
    return os.date("!%Y-%m-%dT%H:%M:%S", sec) .. string.format(".%03dZ", ms)
end

--- Build the OPDS Progression v1.0 device object.
-- device.id must be a syntactically valid URI and stable across sessions.
-- @treturn table { id = "urn:uuid:...", name = "KOReader" }
function LocatorHelper.getDeviceObject()
    local raw_id = G_reader_settings and G_reader_settings:readSetting("device_id")
    local device_id = (raw_id and raw_id ~= "") and ("urn:uuid:" .. raw_id) or "urn:koreader:device"
    return {
        id = device_id,
        name = "KOReader",
    }
end

--- Get current reading completion fraction in [0, 1].
-- @tparam table ui KOReader ReaderUI instance
-- @treturn number Float in [0, 1]
function LocatorHelper.getLastPercent(ui)
    if not ui or not ui.document then return 0 end
    local pct
    if ui.document.info.has_pages then
        pct = ui.paging and Math.roundPercent(ui.paging:getLastPercent())
    else
        pct = ui.rolling and Math.roundPercent(ui.rolling:getLastPercent())
    end
    return math.max(0, math.min(1, pct or 0))
end

--- Get total page count of the current document.
-- @tparam table ui KOReader ReaderUI instance
-- @treturn number|nil Page count or nil
function LocatorHelper.getPageCount(ui)
    if ui and ui.document and ui.document.getPageCount then
        local count = ui.document:getPageCount()
        if count and count > 0 then
            return count
        end
    end
    return nil
end

--- Get current chapter title from ReaderToc if available.
-- @tparam table ui KOReader ReaderUI instance
-- @treturn string|nil Chapter title or nil if unavailable/empty
function LocatorHelper.getCurrentChapterTitle(ui)
    if not ui or not ui.toc or not ui.document then return nil end
    local page = ui.document:getCurrentPage()
    if not page then return nil end
    local ok, title = pcall(ui.toc.getTocTitleByPage, ui.toc, page)
    if ok and type(title) == "string" and title ~= "" and title ~= "\u{2013}" then
        return title
    end
    return nil
end

--- Check whether an HTML fragment contains Storyteller readaloud sentence spans
-- (<span id="{chapterId}-s{N}">). Generic markers such as epub:type are NOT
-- sufficient: nearly every commercial EPUB uses them.
-- @tparam string html
-- @treturn boolean
function LocatorHelper.hasReadaloudMarkup(html)
    if type(html) ~= "string" then return false end
    return html:find('id="[^"]*%-s%d+"') ~= nil
end

--- Detect whether the currently open EPUB is a Storyteller readaloud EPUB or a standard ebook.
-- Storyteller readaloud EPUBs mark up sentences with <span id="{chapterId}-s{N}">.
-- Result is cached on the document instance so detection runs at most once per page until found.
-- @tparam table ui KOReader ReaderUI instance
-- @treturn string "readaloud" or "ebook"
function LocatorHelper.detectBookFormat(ui)
    if not ui or not ui.document or ui.document.info.has_pages then
        return "ebook"
    end

    if ui.document._storyteller_book_format then
        return ui.document._storyteller_book_format
    end

    -- 1. Check current XPointer or current page HTML for Storyteller sentence spans
    local page = ui.document:getCurrentPage()
    if page then
        local xp_start = ui.document:getPageXPointer(page)
        local xp_end = ui.document:getPageXPointer(page + 1)
        if xp_start then
            local ok_html, html
            if xp_end then
                ok_html, html = pcall(ui.document.getHTMLFromXPointers, ui.document, xp_start, xp_end, 0)
            else
                ok_html, html = pcall(ui.document.getHTMLFromXPointer, ui.document, xp_start, 0)
            end
            if ok_html and type(html) == "string" then
                if LocatorHelper.hasReadaloudMarkup(html) then
                    ui.document._storyteller_book_format = "readaloud"
                    logger.dbg("StorytellerSync: Detected book format: readaloud")
                    return "readaloud"
                elseif #html > 200 then
                    -- Substantial text page without any readaloud sentence spans
                    ui.document._storyteller_book_format = "ebook"
                    logger.dbg("StorytellerSync: Detected book format: ebook")
                    return "ebook"
                end
            end
        end
    end

    return "ebook"
end

--- Get the active CREngine XPointer for the current reading position.
-- Prefers ui.rolling:getLastProgress() (which tracks the canonical top-of-page XPointer)
-- with fallback to ui.document:getXPointer().
-- @tparam table ui KOReader ReaderUI instance
-- @treturn string|nil Raw CREngine XPointer (e.g. "/body/DocFragment[8]/...")
function LocatorHelper.getCurrentXPointer(ui)
    if not ui or not ui.document then return nil end
    local xp
    if ui.rolling and ui.rolling.getLastProgress then
        xp = ui.rolling:getLastProgress()
    end
    if not xp or xp == "" then
        xp = ui.document:getXPointer()
    end
    if xp and xp ~= "" then
        return xp
    end
    return nil
end

--- Build a v3 Progression Document for the current reader position.
-- @tparam table ui KOReader ReaderUI instance
-- @tparam[opt] string modified_iso Pre-captured ISO 8601 timestamp when user arrived at page
-- @treturn table|nil v3 progress document { modified, device, progression, references, title? }
-- @treturn string|nil Detected book format ("ebook" or "readaloud")
function LocatorHelper.buildProgressDocument(ui, modified_iso)
    if not ui or not ui.document then return nil, nil end

    local xpointer = LocatorHelper.getCurrentXPointer(ui)
    if not xpointer then return nil, nil end

    local format = LocatorHelper.detectBookFormat(ui)

    local doc = {
        modified = modified_iso or LocatorHelper.formatIso8601(),
        device = LocatorHelper.getDeviceObject(),
        progression = LocatorHelper.getLastPercent(ui),
        references = {
            "#crengine(" .. xpointer .. ")",
        },
    }

    local title = LocatorHelper.getCurrentChapterTitle(ui)
    if title then
        doc.title = title
    end

    logger.dbg("StorytellerSync: [Build v3] format:", format, "modified:", doc.modified,
               "progression:", doc.progression, "xpointer:", xpointer, "title:", title)

    return doc, format
end

--- Extract the raw CREngine XPointer string from a v3 progress document's references array.
-- Looks for "#crengine(/body...)" and returns "/body...".
-- @tparam table progress_doc v3 Progression Document
-- @treturn string|nil Raw XPointer or nil
function LocatorHelper.extractCrengineXPointer(progress_doc)
    if not progress_doc or type(progress_doc.references) ~= "table" then
        return nil
    end
    for _, ref in ipairs(progress_doc.references) do
        if type(ref) == "string" then
            local xp = ref:match("^#crengine%((.+)%)$")
            if xp and xp ~= "" then
                return xp
            end
        end
    end
    return nil
end

--- Extract an element ID fragment from a v3 progress document's references array if present.
-- Example: "OEBPS/Barn_9780307797858_epub_col2_r1.htm#col2-s0" -> "col2-s0"
-- Skips "#char=", "#crengine(", "#epubcfi(", and audio "#t=" fragments.
-- @tparam table progress_doc v3 Progression Document
-- @treturn string|nil Element ID or nil
function LocatorHelper.extractElementId(progress_doc)
    if not progress_doc or type(progress_doc.references) ~= "table" then
        return nil
    end
    for _, ref in ipairs(progress_doc.references) do
        if type(ref) == "string" and not ref:match("^#") then
            local frag = ref:match("#([^#]+)$")
            if frag and frag ~= ""
               and not frag:match("^char=")
               and not frag:match("^t=")
               and not frag:match("^crengine%(")
               and not frag:match("^epubcfi%(") then
                return frag
            end
        end
    end
    return nil
end

--- Resolve a remote v3 progress document to a valid CREngine XPointer in the currently open document.
-- Handles differences between standard "ebook" DOMs and "readaloud" DOMs (where Storyteller
-- injects <span id="...-sN"> wrappers around sentences) as well as CREngine anchor fallbacks.
-- @tparam table progress_doc v3 Progression Document from server
-- @tparam table ui KOReader ReaderUI instance
-- @treturn string|nil Valid XPointer in the local document, or nil if none could be resolved
function LocatorHelper.resolveXPointerInDocument(progress_doc, ui)
    if not progress_doc or not ui or not ui.document then return nil end
    local doc = ui.document

    local raw_xp = LocatorHelper.extractCrengineXPointer(progress_doc)
    if raw_xp then
        -- 1. Direct match in local DOM
        if doc:isXPointerInDocument(raw_xp) then
            return raw_xp
        end

        -- 2. Try CREngine's normalized XPointer lookup
        if doc.getNormalizedXPointer then
            local norm_xp = doc:getNormalizedXPointer(raw_xp)
            if norm_xp and norm_xp ~= "" and doc:isXPointerInDocument(norm_xp) then
                logger.dbg("LocatorHelper: Resolved via getNormalizedXPointer:", norm_xp)
                return norm_xp
            end
        end

        -- 3. Cross-format fallback (readaloud XPointer -> standard ebook DOM):
        -- Strip injected /span[N] wrapper segments before /text()[M].K or at the end
        local stripped_span_xp = raw_xp:gsub("/span%[%d+%](/text%(%)%[%d+%]%.%d+)$", "/text()[1].0")
        if stripped_span_xp == raw_xp then
            stripped_span_xp = raw_xp:gsub("/span%[%d+%]", "")
        end
        if stripped_span_xp ~= raw_xp and doc:isXPointerInDocument(stripped_span_xp) then
            logger.dbg("LocatorHelper: Resolved by stripping readaloud <span>:", stripped_span_xp)
            return stripped_span_xp
        end

        -- 4. Walk up parent DOM nodes until we hit a valid block/container node in the local DOM
        -- (e.g. /body[1]/DocFragment[8]/body[1]/div[1]/p[1])
        local candidate = raw_xp:gsub("/text%(%)[^/]*$", "")
        while candidate and candidate ~= "" and candidate:find("/") do
            if doc:isXPointerInDocument(candidate) then
                logger.dbg("LocatorHelper: Resolved via ancestor node XPointer:", candidate)
                return candidate
            end
            local parent = candidate:match("^(.+)/[^/]+$")
            if not parent or parent == candidate or parent == "/body" or parent == "/body[1]" then
                break
            end
            candidate = parent
        end
    end

    -- 5. Fallback to element ID anchor (e.g. "#_doc_fragment_7_ col2-s0" or "#col2-s0")
    local elem_id = LocatorHelper.extractElementId(progress_doc)
    if elem_id then
        if raw_xp then
            local frag_idx = tonumber(raw_xp:match("/DocFragment%[(%d+)%]"))
            if frag_idx and frag_idx >= 1 then
                local cre_anchor = "#_doc_fragment_" .. (frag_idx - 1) .. "_ " .. elem_id
                if doc:isXPointerInDocument(cre_anchor) then
                    logger.dbg("LocatorHelper: Resolved via DocFragment element ID:", cre_anchor)
                    return cre_anchor
                end
            end
        end
        local plain_anchor = "#" .. elem_id
        if doc:isXPointerInDocument(plain_anchor) then
            logger.dbg("LocatorHelper: Resolved via plain element ID:", plain_anchor)
            return plain_anchor
        end
    end

    return nil
end

--- Check if two v3 progress documents represent the same reading position.
-- @tparam table doc1 First progress document
-- @tparam table doc2 Second progress document
-- @treturn boolean True if they represent the same position
function LocatorHelper.positionsEqual(doc1, doc2)
    if not doc1 or not doc2 then return false end

    local xp1 = LocatorHelper.extractCrengineXPointer(doc1)
    local xp2 = LocatorHelper.extractCrengineXPointer(doc2)
    if xp1 and xp2 then
        return xp1 == xp2
    end

    if doc1.progression and doc2.progression then
        return math.abs(doc1.progression - doc2.progression) <= 0.0001
    end

    return false
end

return LocatorHelper
