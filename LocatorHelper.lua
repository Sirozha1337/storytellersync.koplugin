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
    if cached_data and cached_data.epub_spine and cached_data.spine_meta then
        logger.dbg("StorytellerSync: buildEpubSpine: loaded spine and spine_meta from cache")
        return cached_data.epub_spine, cached_data.epub_spine_map, cached_data.spine_meta
    end

    local Archiver = require("ffi/archiver")
    local arc = Archiver.Reader:new()
    if not arc:open(file) then
        logger.warn("StorytellerSync: buildEpubSpine: failed to open archive:", file)
        return nil
    end

    -- ── Scan entries to find container.xml and record uncompressed sizes ─
    local container_path = nil
    local file_sizes = {}
    for entry in arc:iterate() do
        if entry.mode == "file" then
            local p = entry.path
            local size_num = tonumber(entry.size) or 0
            file_sizes[p] = size_num
            file_sizes[p:lower()] = size_num

            -- Also index stripped leading ./ or /
            local clean_p = p:gsub("^%./", ""):gsub("^/+", "")
            file_sizes[clean_p] = size_num
            file_sizes[clean_p:lower()] = size_num

            local lp = p:lower()
            if lp == "meta-inf/container.xml" or lp:find("container%.xml$") then
                container_path = p
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

    -- ── 5. Compute Readium synthetic pages & chapter offsets ─────────────
    local spine_items = {}
    local total_readium_pages = 0
    for idx, href in ipairs(spine) do
        local clean_href = href:gsub("^%./", ""):gsub("^/+", "")
        local raw_size = file_sizes[clean_href]
            or file_sizes[clean_href:lower()]
            or file_sizes[href]
            or file_sizes[href:lower()]
        local size = tonumber(raw_size) or 1024
        local pages = math.max(1, math.ceil(size / 1024))
        spine_items[idx] = {
            index = idx,
            href = href,
            size = size,
            pages = pages,
            start_page = total_readium_pages, -- 0-based synthetic page offset
        }
        total_readium_pages = total_readium_pages + pages
    end

    if total_readium_pages == 0 then
        total_readium_pages = 1
    end

    local spine_meta = {
        total_pages = total_readium_pages,
        items = spine_items,
    }

    logger.dbg("StorytellerSync: buildEpubSpine: built spine with", #spine, "items, total Readium pages:", total_readium_pages)
    
    local data_to_save = cached_data or {}
    data_to_save.epub_spine = spine
    data_to_save.epub_spine_map = spine_map
    data_to_save.spine_meta = spine_meta
    cache_manager:saveCache(file, data_to_save)

    return spine, spine_map, spine_meta
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
    if not epub_spine or #epub_spine == 0 then
        logger.dbg("StorytellerSync: getCurrentChapterHref: spine not yet built")
        return nil
    end

    local xpointer = ui.document:getXPointer()
    if not xpointer then return nil end

    -- XPointers look like: /body/DocFragment[N]/body/...
    -- N is 1-based and maps directly to the EPUB spine order.
    local frag_idx_str = xpointer:match("^/body/DocFragment%[(%d+)%]")
    local frag_idx = tonumber(frag_idx_str)

    -- Handle single-chapter EPUBs where DocFragment might not be prefixed
    if not frag_idx and #epub_spine == 1 then
        frag_idx = 1
    end

    if not frag_idx then return nil end

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
-- @tparam table ui KOReader UI context
-- @tparam table epub_spine Array of spine hrefs
-- @tparam table|nil spine_meta Readium synthetic page metadata from buildEpubSpine
-- @treturn table|nil Readium locator or nil if we can't determine position
function LocatorHelper.buildCurrentLocator(ui, epub_spine, spine_meta)
    if not ui or not ui.document then return nil end

    local fragment_id = LocatorHelper.getCurrentFragmentId(ui)

    local xpointer = ui.document:getXPointer()
    local frag_idx_str = xpointer and xpointer:match("^/body/DocFragment%[(%d+)%]")
    local frag_idx = tonumber(frag_idx_str)

    -- Handle single-chapter EPUBs or fallback
    if not frag_idx and epub_spine and #epub_spine == 1 then
        frag_idx = 1
    end

    local href = (frag_idx and epub_spine and epub_spine[frag_idx]) or ""

    local total_progression = nil
    local in_chapter_progression = nil
    local position = nil

    if spine_meta and spine_meta.items and spine_meta.total_pages and frag_idx and spine_meta.items[frag_idx] then
        local item_meta = spine_meta.items[frag_idx]

        -- Calculate rendered chapter page boundaries via getPageFromXPointer
        local start_page = ui.document:getPageFromXPointer("/body/DocFragment[" .. frag_idx .. "]") or 1
        local next_page
        if epub_spine and frag_idx < #epub_spine then
            next_page = ui.document:getPageFromXPointer("/body/DocFragment[" .. (frag_idx + 1) .. "]")
        end
        if not next_page or next_page <= start_page then
            next_page = (ui.document.info.number_of_pages or 1) + 1
        end

        local chapter_pages = math.max(1, next_page - start_page)
        local current_page = ui.document:getCurrentPage() or 1
        local intra_page_pos = (ui.paging and ui.paging.getPagePosition and ui.paging:getPagePosition(current_page)) or 0

        local p = ((current_page - start_page) + intra_page_pos) / chapter_pages
        p = math.max(0, math.min(1, p))

        local continuous_pos = item_meta.start_page + p * item_meta.pages
        total_progression = math.max(0, math.min(1, continuous_pos / spine_meta.total_pages))
        in_chapter_progression = p
        position = math.floor(continuous_pos) + 1
    else
        logger.dbg("StorytellerSync: [Build] Not using spine_meta, falling back to global KOReader percent")

        -- Fallback to global KOReader percent if spine_meta is unavailable
        total_progression = LocatorHelper.getLastPercent(ui)
        in_chapter_progression = total_progression
    end

    logger.dbg("StorytellerSync: [Build] Fragment ID:", fragment_id, "Href:", href,
               "TotalProgression:", total_progression, "Progression:", in_chapter_progression, "Position:", position)

    -- We need at minimum a totalProgression to send
    if not total_progression then return nil end

    local locator = {
        href = href,
        type = "application/xhtml+xml",
        locations = {
            totalProgression = total_progression,
        },
    }

    if in_chapter_progression then
        locator.locations.progression = in_chapter_progression
    end

    if position then
        locator.locations.position = position
    end

    if fragment_id then
        locator.locations.fragments = { fragment_id }
        locator.locations.cssSelector = "#" .. fragment_id
    end

    return locator
end

--- Resolve a Readium locator to a target page number in KOReader using chapter href and progression.
-- @tparam table locator The Readium locator object
-- @tparam table ui KOReader UI context
-- @tparam table epub_spine Array of spine hrefs
-- @tparam table epub_spine_map Reverse map of href -> index
-- @treturn number|nil Target page number (1-based) or nil if cannot resolve
function LocatorHelper.getPageFromLocator(locator, ui, epub_spine, epub_spine_map)
    if not locator or not ui or not ui.document then return nil end

    local frag_idx = nil

    if locator.href and epub_spine_map then
        frag_idx = epub_spine_map[locator.href]
        if not frag_idx then
            local clean_href = locator.href:gsub("^%./", ""):gsub("^/+", "")
            frag_idx = epub_spine_map[clean_href]
                or epub_spine_map[clean_href:lower()]
                or epub_spine_map[locator.href:lower()]
        end
    end

    -- Single-chapter book fallback
    if not frag_idx and epub_spine and #epub_spine == 1 then
        frag_idx = 1
    end

    if not frag_idx then return nil end

    local start_page = ui.document:getPageFromXPointer("/body/DocFragment[" .. frag_idx .. "]") or 1
    local next_page
    if epub_spine and frag_idx < #epub_spine then
        next_page = ui.document:getPageFromXPointer("/body/DocFragment[" .. (frag_idx + 1) .. "]")
    end
    if not next_page or next_page <= start_page then
        next_page = (ui.document.info.number_of_pages or 1) + 1
    end

    local chapter_pages = math.max(1, next_page - start_page)
    local p = locator.locations and locator.locations.progression
    p = math.max(0, math.min(1, tonumber(p) or 0))

    local page_offset = math.min(chapter_pages - 1, math.floor(p * chapter_pages))
    local target_page = start_page + page_offset
    local max_pages = ui.document.info.number_of_pages or target_page
    target_page = math.max(1, math.min(max_pages, target_page))
    logger.dbg("LocatorHelper: getPageFromLocator -> href:", locator.href, "p:", p, "start_page:", start_page, "chapter_pages:", chapter_pages, "target_page:", target_page)
    return target_page
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
