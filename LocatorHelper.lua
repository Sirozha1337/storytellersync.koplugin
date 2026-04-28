local logger = require("logger")
local Math = require("optmath")

local LocatorHelper = {}

local function urlDecode(str)
    return (str:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end))
end

--- Parse an EPUB file and return an ordered array of spine hrefs.
-- Each entry corresponds to a CREngine DocFragment index (1-based).
-- Uses Archiver.Reader to read META-INF/container.xml → OPF → spine.
-- @string file  Absolute path to the .epub file
-- @treturn table|nil  Array {[1]=href, [2]=href, ...} or nil on failure
function LocatorHelper.buildEpubSpine(file)
    local CacheManager = require("CacheManager")
    local cache_manager = CacheManager:new()
    local cached_data = cache_manager:loadCache(file)
    if cached_data and cached_data.epub_spine then
        logger.dbg("StorytellerSync: buildEpubSpine: loaded spine from cache")
        return cached_data.epub_spine, cached_data.epub_spine_map
    end

    local Archiver = require("ffi/archiver")
    local arc = Archiver.Reader:new()
    if not arc:open(file) then
        logger.warn("StorytellerSync: buildEpubSpine: failed to open archive:", file)
        return nil
    end

    -- ── Scan entries to find the exact container.xml path ────────────────
    -- (case-insensitive, since some EPUBs capitalise differently)
    local container_path = nil
    for entry in arc:iterate() do
        logger.dbg("StorytellerSync: buildEpubSpine: entry:", entry.path, "mode:", entry.mode)
        if entry.mode == "file" then
            local lp = entry.path:lower()
            if lp == "meta-inf/container.xml" or lp:find("container%.xml$") then
                container_path = entry.path
            end
        end
    end
    logger.dbg("StorytellerSync: buildEpubSpine: container_path:", tostring(container_path))

    if not container_path then
        logger.warn("StorytellerSync: buildEpubSpine: META-INF/container.xml not found in:", file)
        arc:close()
        return nil
    end

    -- ── 1. Read META-INF/container.xml to get the OPF path ───────────────
    local container_xml = arc:extractToMemory(container_path)
    if not container_xml then
        logger.warn("StorytellerSync: buildEpubSpine: extractToMemory failed for:", container_path)
        arc:close()
        return nil
    end

    -- Extract full-path attribute from <rootfile full-path="..."/>
    local opf_path = container_xml:match('full%-path%s*=%s*"([^"]+)"') or container_xml:match("full%-path%s*=%s*'([^']+)'")
    if not opf_path then
        logger.warn("StorytellerSync: buildEpubSpine: could not find OPF path in container.xml")
        arc:close()
        return nil
    end
    logger.dbg("StorytellerSync: buildEpubSpine: OPF path:", opf_path)

    -- ── 2. Read the OPF file ─────────────────────────────────────────────
    local opf_xml = arc:extractToMemory(opf_path)
    arc:close()
    if not opf_xml then
        logger.warn("StorytellerSync: buildEpubSpine: OPF not found at:", opf_path)
        return nil
    end

    -- Determine the OPF directory so we can resolve relative hrefs
    local opf_dir = opf_path:match("^(.*)/[^/]+$")
    if opf_dir then
        opf_dir = opf_dir .. "/"
    else
        opf_dir = ""
    end

    -- ── 3. Build id → href map from <manifest> ───────────────────────────
    local id_to_href = {}
    for item_tag in opf_xml:gmatch("<item[^>]+>") do
        local id   = item_tag:match('[%s]id%s*=%s*"([^"]+)"') or item_tag:match("[%s]id%s*=%s*'([^']+)'")
        local href = item_tag:match('[%s]href%s*=%s*"([^"]+)"') or item_tag:match("[%s]href%s*=%s*'([^']+)'")
        if id and href then
            id_to_href[id] = opf_dir .. urlDecode(href)
        end
    end

    -- ── 4. Walk <spine> to produce the ordered list ──────────────────────
    local spine_section = opf_xml:match("<spine[^>]*>(.-)</spine>")
    if not spine_section then
        logger.warn("StorytellerSync: buildEpubSpine: no <spine> element found")
        return nil
    end

    local spine = {}
    local spine_map = {}
    local t_insert = table.insert
    for itemref_tag in spine_section:gmatch("<itemref[^>]+>") do
        local idref = itemref_tag:match('idref%s*=%s*"([^"]*)"')
        if not idref then
            idref = itemref_tag:match("idref%s*=%s*'([^']*)'") 
        end
        if idref then
            local href = id_to_href[idref]
            if href then
                t_insert(spine, href)
                spine_map[href] = #spine
            else
                logger.warn("StorytellerSync: buildEpubSpine: no manifest item for idref:", idref)
            end
        end
    end

    if #spine == 0 then
        logger.warn("StorytellerSync: buildEpubSpine: spine is empty")
        return nil
    end

    logger.dbg("StorytellerSync: buildEpubSpine: built spine with", #spine, "items")
    
    local data_to_save = cached_data or {}
    data_to_save.epub_spine = spine
    data_to_save.epub_spine_map = spine_map
    cache_manager:saveCache(file, data_to_save)

    return spine, spine_map
end

local function getCurrentPageHtml(ui)
    if not ui.document or ui.document.info.has_pages then
        return nil
    end

    local page = ui.document:getCurrentPage()
    if not page then return nil end

    local xp_start = ui.document:getPageXPointer(page)
    local xp_end = ui.document:getPageXPointer(page + 1)
    
    if not xp_start then return nil end

    local ok_html, html
    if xp_end then
        ok_html, html = pcall(ui.document.getHTMLFromXPointers, ui.document, xp_start, xp_end, 0)
    else
        ok_html, html = pcall(ui.document.getHTMLFromXPointer, ui.document, xp_start, 0)
    end

    if not ok_html or not html then return nil end
    return html, page
end

--- Extract the first Storyteller sentence span ID from the current page.
-- Storyteller marks up EPUBs with <span id="{chapterId}-s{N}">
-- @treturn string|nil The fragment ID (e.g., "chapter1-s42") or nil
function LocatorHelper.getCurrentFragmentId(ui)
    local html, page = getCurrentPageHtml(ui)
    
    logger.dbg("StorytellerSync: getCurrentFragmentId: page", page, "html size", html and string.len(html) or 0)
    if not html then
        logger.dbg("StorytellerSync: getCurrentFragmentId: Could not get HTML from page")
        return nil
    end

    -- Find the first span with a Storyteller sentence ID pattern: id="xxx-sN"
    local storyteller_id_pattern = 'id="([^"]*%-s%d+)"'
    -- When not found, fallback to any id attribute
    local general_id_pattern = 'id="([^"]+)"'

    local fragment = LocatorHelper.getFragmentIdWithPattern(html, storyteller_id_pattern)
    if not fragment then
        fragment = LocatorHelper.getFragmentIdWithPattern(html, general_id_pattern)
    end
    return fragment
end

function LocatorHelper.getFragmentIdWithPattern(html, pattern)
    local fragment = html:match(pattern)
    if fragment then
        -- CREngine prepends internal fragment IDs with "_doc_fragment_" prefix
        fragment = fragment:gsub("^_doc_fragment_%d+_%s*", "")
    end
    return fragment
end

--- Get the href of the current EPUB chapter from the parsed spine.
-- Extracts the DocFragment index from the current XPointer (1-based N in
-- DocFragment[N]) and returns the corresponding entry in the pre-built
-- spine table. Falls back to nil when the spine is unavailable.
-- @treturn string|nil EPUB href (e.g. "OEBPS/chapter3.xhtml") or nil
function LocatorHelper.getCurrentChapterHref(ui, epub_spine)
    if not ui.document or ui.document.info.has_pages then
        return nil
    end

    -- Ensure spine is available
    if not epub_spine then
        logger.dbg("StorytellerSync: getCurrentChapterHref: spine not yet built")
        return nil
    end

    local xpointer = ui.document:getXPointer()
    if not xpointer then return nil end

    -- XPointers look like: /body/DocFragment[N]/body/...
    -- N is 1-based and maps directly to the EPUB spine order.
    local frag_idx_str = xpointer:match("^/body/DocFragment%[(%d+)%]")
    if not frag_idx_str then return nil end

    local frag_idx = tonumber(frag_idx_str)
    local href = epub_spine[frag_idx]
    if not href then
        logger.warn("StorytellerSync: getCurrentChapterHref: no spine entry for DocFragment", frag_idx)
        return nil
    end

    logger.dbg("StorytellerSync: getCurrentChapterHref: DocFragment", frag_idx, "→", href)
    return href
end

function LocatorHelper.getLastPercent(ui)
    if ui.document.info.has_pages then
        return Math.roundPercent(ui.paging:getLastPercent())
    else
        return Math.roundPercent(ui.rolling:getLastPercent())
    end
end

function LocatorHelper.getPageCount(ui)
    if ui.document and ui.document.getPageCount then
        local count = ui.document:getPageCount()
        if count and count > 0 then
            return count
        end
    end
    
    return nil
end

--- Build a Readium locator for the current position.
-- @treturn table|nil Readium locator or nil if we can't determine position
function LocatorHelper.buildCurrentLocator(ui, epub_spine)
    local fragment_id = LocatorHelper.getCurrentFragmentId(ui)
    local href = LocatorHelper.getCurrentChapterHref(ui, epub_spine) or ""
    local percentage = LocatorHelper.getLastPercent(ui)

    logger.dbg("StorytellerSync: [Build] Fragment ID:", fragment_id, "Href:", href, "Percentage:", percentage)
    -- We need at minimum a percentage to send
    if not percentage then return nil end

    local locator = {
        href = href,
        type = "application/xhtml+xml",
        locations = {
            totalProgression = percentage,
        },
    }

    if fragment_id then
        locator.locations.fragments = { fragment_id }
        locator.locations.cssSelector = "#" .. fragment_id
    end

    return locator
end

--- Create an XPath for navigation from a locator object.
-- Finds the DocFragment index from the epub_spine_map to construct the CREngine-specific anchor.
-- @tparam table locator The Readium locator
-- @tparam table epub_spine_map The reverse map href -> index
-- @treturn string|nil The constructed anchor string or nil
function LocatorHelper.createXPathFromLocator(locator, epub_spine_map)
    if not locator or not locator.locations or not locator.locations.fragments or not epub_spine_map then
        return nil
    end

    local fragment = locator.locations.fragments[1]
    local href = locator.href
    if not fragment or not href then
        return nil
    end

    -- Remove any leading '#' from fragment
    if fragment:sub(1, 1) == "#" then
        fragment = fragment:sub(2)
    end

    -- Find the doc fragment index by looking up the href in epub_spine_map
    -- CREngine uses 0-based DocFragment indices internally for its internal anchors.
    -- The spine index we built is 1-based, so we subtract 1.
    local frag_index = epub_spine_map[href]
    if frag_index then
        return "#_doc_fragment_" .. (frag_index - 1) .. "_ " .. fragment
    else
        return "#" .. fragment
    end
end

--- Check if two locators represent the same reading position
-- @tparam table loc1 First locator
-- @tparam table loc2 Second locator
-- @treturn boolean True if they represent the same position
function LocatorHelper.locatorsEqual(loc1, loc2)
    if not loc1 or not loc2 then return false end
    if loc1.href ~= loc2.href then return false end
    
    local frag1 = loc1.locations and loc1.locations.fragments and loc1.locations.fragments[1]
    local frag2 = loc2.locations and loc2.locations.fragments and loc2.locations.fragments[1]
    if frag1 ~= frag2 then return false end
    
    local p1 = loc1.locations and loc1.locations.totalProgression
    local p2 = loc2.locations and loc2.locations.totalProgression
    if p1 and p2 then
        -- Use a small epsilon to account for minor floating point differences
        if math.abs(p1 - p2) > 0.0001 then return false end
    elseif p1 ~= p2 then
        return false
    end
    
    return true
end

return LocatorHelper
