-- Resolves titles for URL playlist entries via yt-dlp and provides a
-- playlist dialog matching mpv's built-in select style, with keyboard-driven
-- navigation, reordering, and search.
-- Wire it up via input.conf:
--   p script-binding playlist_manager/select-playlist
-- and modernz.conf:
--   playlist_mbtn_left_command=script-binding playlist_manager/select-playlist

local utils   = require "mp.utils"
local msg     = require "mp.msg"
local assdraw = require "mp.assdraw"
local options = require "mp.options"

local opts = {
    -- Set to false to disable yt-dlp title resolution for URL entries.
    resolve_url_titles = true,
    -- Font for dialog text. Set to "" to use the OSD default font.
    font = "mpv-osd-symbols",
}
options.read_options(opts, "playlist_manager")

local title_cache = {}
local fetching    = {}
local fetch_queue = {}
local fetch_active = false

local overlay           = mp.create_osd_overlay("ass-events")
local toast_overlay     = mp.create_osd_overlay("ass-events")
local text_measure_osd  = mp.create_osd_overlay("ass-events")
-- hidden = true  → never appears on screen
-- compute_bounds = true → update() actually returns {x0,y0,x1,y1} bounds
text_measure_osd.hidden         = true
text_measure_osd.compute_bounds = true
local text_width_cache  = {}
local toast_timer   = nil
local cursor        = 0
local moving        = false
local move_origin   = 0
local open          = false
local search_query  = ""
local draw_playlist  -- forward declaration (defined later, used in process_fetch_queue)

-- Visual constants. Style mirrors ModernZ: \bord1, explicit \1c/\3c colors, \fn from opts.font.
--   font_size=24  background_alpha=80(=0x50)  corner_radius=8
--   padding=10    focused_color=#222222  focused_back_color=#FFFFFF  match_color=#0088FF
local FONT_SIZE   = 24
local CHAR_W      = FONT_SIZE * 600 / 1320  -- libass maps \fs to hhea height (1320), not UPM (1000)

local BG_ALPHA    = 0x50   -- background_alpha = 80 = 0x50 in the select script
local CORNER      = 8
local PAD         = 10
local LH          = FONT_SIZE * 1.2
local MAX_VISIBLE = 12

-- Returns the virtual canvas width that keeps pixels square for the current display
--   res_y = 720 (fixed), res_x = 720 * display_aspect (dynamic).
-- On a 16:9 screen this is 1280; on ultrawide it grows proportionally,
-- so the dialog content stays the same physical size on every display.
local function get_virt_w()
    local osd = mp.get_property_native("osd-dimensions") or {}
    local ar  = osd.aspect
    if not ar or ar <= 0 then
        ar = (osd.w and osd.h and osd.h > 0) and (osd.w / osd.h) or (16 / 9)
    end
    return math.floor(720 * ar)
end

-- Measure the rendered pixel width of `text` in FONT_SIZE on the current virtual
-- canvas, using the same libass-bounds technique as modernz's estimate_text_width().
-- Falls back to CHAR_W * #text if the overlay API is unavailable.
local function measure_text(text)
    if not text or #text == 0 then return 0 end
    local key = text:gsub("%d", "0")  -- normalise digits so "123" and "456" share a cache entry
    if text_width_cache[key] then return text_width_cache[key] end
    local w = 0
    if text_measure_osd and text_measure_osd.update then
        local W = get_virt_w()
        text_measure_osd.res_x = W
        text_measure_osd.res_y = 720
        local fn_tag = opts.font ~= "" and ("\\fn" .. opts.font) or ""
        text_measure_osd.data  =
            ("{\\fs%d\\bord0\\q2\\an7\\pos(0,0)%s}"):format(FONT_SIZE, fn_tag) .. key
        local bounds = text_measure_osd:update()
        if bounds and bounds.x0 and bounds.x1 then
            local bearing_correction = FONT_SIZE * 0.08 * 2
            w = math.max(0, (bounds.x1 - bounds.x0) - bearing_correction)
        end
    end
    if w == 0 then w = math.ceil(#text * CHAR_W) end  -- fallback
    text_width_cache[key] = w
    return w
end

local function normalize_url(path)
    if not path then return path end
    return path:gsub("^ytdl://https?://", "https://"):gsub("^ytdl://", "https://")
end

local function is_url(path)
    return type(path) == "string" and path:match("^https?://") ~= nil
end

-- Broader check for paste validation: any scheme:// URL or magnet link.
local function is_valid_url(s)
    return type(s) == "string"
        and (s:match("^%a[%a%d+%-%.]*://") or s:match("^magnet:")) ~= nil
end

local function is_in_playlist(item)
    local norm = normalize_url(item)
    for _, entry in ipairs(mp.get_property_native("playlist") or {}) do
        if normalize_url(entry.filename) == norm then return true end
    end
    return false
end

local function strip_filename(path)
    local name = path:match("([^/\\]+)$") or path
    name = name:match("^(.+)%.[^%.]+$") or name
    return name:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
end

local function get_playlist_item_title(index)
    local title = mp.get_property("playlist/" .. index .. "/title")
    if title and title ~= "" then return title end
    local filename = normalize_url(mp.get_property("playlist/" .. index .. "/filename"))
    if not filename then return nil end
    return title_cache[filename] or (is_url(filename) and filename or strip_filename(filename))
end

local function process_fetch_queue()
    if fetch_active or #fetch_queue == 0 then return end
    local url = table.remove(fetch_queue, 1)
    if title_cache[url] then process_fetch_queue(); return end
    fetch_active = true
    fetching[url] = true
    mp.command_native_async({
        name = "subprocess",
        args = {"yt-dlp", "--no-playlist", "--flat-playlist", "-sJ", "--no-config", url},
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
    }, function(_, res)
        fetching[url] = nil
        fetch_active = false
        if res.status == 0 then
            local json = utils.parse_json(res.stdout)
            if json and json.title then
                title_cache[url] = json.title
                if open then draw_playlist() end
            end
        else
            msg.warn("yt-dlp failed for " .. url)
        end
        process_fetch_queue()
    end)
end

local function fetch_url_title(url)
    if not opts.resolve_url_titles then return end
    url = normalize_url(url)
    if not is_url(url) or title_cache[url] or fetching[url] then return end
    for _, queued in ipairs(fetch_queue) do
        if queued == url then return end
    end
    fetch_queue[#fetch_queue + 1] = url
    process_fetch_queue()
end

local function fetch_all()
    if not opts.resolve_url_titles then return end
    for _, entry in ipairs(mp.get_property_native("playlist") or {}) do
        if not entry.title or entry.title == "" then
            fetch_url_title(entry.filename)
        end
    end
end

-- Removes duplicate playlist entries, keeping the first occurrence of each
-- filename. Called whenever playlist-count rises so every ingestion path
-- (command-line arguments, loadfile, playlist-append, IPC, etc.) is covered.
local function dedup_playlist()
    local playlist = mp.get_property_native("playlist") or {}
    local seen     = {}
    local to_remove = {}
    for i = 0, #playlist - 1 do
        local norm = normalize_url(playlist[i + 1].filename) or playlist[i + 1].filename
        if seen[norm] then
            to_remove[#to_remove + 1] = i
        else
            seen[norm] = true
        end
    end
    -- Remove in reverse order so earlier indices stay valid.
    for i = #to_remove, 1, -1 do
        mp.commandv("playlist-remove", to_remove[i])
    end
end

-- Returns a list of 0-based playlist indices whose title contains search_query.
-- When the query is empty every index is returned in order.
local function compute_filtered(playlist)
    if search_query == "" then
        local result = {}
        for i = 0, #playlist - 1 do result[#result + 1] = i end
        return result
    end
    local q = search_query:lower()
    local result = {}
    for i = 0, #playlist - 1 do
        local t = (get_playlist_item_title(i) or ""):lower()
        if t:find(q, 1, true) then result[#result + 1] = i end
    end
    return result
end

-- Wraps the first occurrence of query in text with the select script's
-- match_color (#0088FF = ASS FF8800), then restores to restore_color.
local function highlight_match(text, query, restore_color)
    if query == "" then return text end
    local s, e = text:lower():find(query:lower(), 1, true)
    if not s then return text end
    return text:sub(1, s - 1)
           .. "{\\1c&HFF8800&}"    -- #0088FF (match_color default in select script) in ASS BGR
           .. text:sub(s, e)
           .. ("{\\1c&H%s&}"):format(restore_color)
           .. text:sub(e + 1)
end

local function show_toast(msg, success)
    if toast_timer then toast_timer:kill(); toast_timer = nil end

    local W, H   = get_virt_w(), 720
    local prefix = success and "✓ " or "✗ "
    local full   = prefix .. msg

    local cw = math.min(measure_text(full), W - PAD * 4)

    local x   = PAD * 2
    local y   = PAD * 2
    -- ASS BGR: 44EE44 = RGB(68,238,68) green; 3C3CDC = RGB(220,60,60) red
    local col = success and "44EE44" or "3C3CDC"

    local ass = assdraw.ass_new()

    ass:new_event()
    ass:an(7)
    ass:pos(x, y)
    ass:append(("{\\bord0\\blur0\\1c&H000000&\\1a&H%02X&\\4a&Hff&}"):format(BG_ALPHA))
    ass:draw_start()
    local TPAD = PAD / 2   -- tighter vertical padding for single-line toast
    ass:round_rect_cw(-PAD, -TPAD, cw + PAD, FONT_SIZE + TPAD, CORNER, CORNER)
    ass:draw_stop()

    local fn_tag = opts.font ~= "" and ("\\fn" .. opts.font) or ""
    ass:new_event()
    ass:an(4)
    ass:pos(x, y + FONT_SIZE / 2)
    ass:append(("{\\bord1\\1c&H%s&\\3c&H000000&\\fs%d\\q2%s}"):format(col, FONT_SIZE, fn_tag))
    ass:append(prefix)
    ass:append("{\\1c&HFFFFFF&}")
    ass:append(msg)

    toast_overlay.res_x = W
    toast_overlay.res_y = H
    toast_overlay.z     = 2001
    toast_overlay.data  = ass.text
    toast_overlay:update()

    toast_timer = mp.add_timeout(3, function()
        toast_overlay.data = ""
        toast_overlay:remove()
        toast_timer = nil
    end)
end

draw_playlist = function()
    local playlist = mp.get_property_native("playlist") or {}
    if #playlist == 0 then return end

    local pos      = mp.get_property_number("playlist-pos", -1)
    -- Dynamic virtual resolution: res_y=720 fixed, res_x adapts to display aspect.
    -- Matches the select script and ModernZ — no stretching on ultrawide screens.
    local H        = 720
    local W        = get_virt_w()
    local filtered = compute_filtered(playlist)
    local n        = #filtered
    local vis      = math.min(math.max(n, 1), MAX_VISIBLE)
    -- vis_max anchors the dialog's top edge to where the full-size dialog sits.
    -- This keeps the position fixed while the height shrinks to match search results.
    local vis_max  = math.min(math.max(#playlist, 1), MAX_VISIBLE)

    local prompt = search_query ~= "" and ("Select a playlist entry: " .. search_query) or "Select a playlist entry: "

    -- Measure dialog width from the widest string across all titles and the prompt.
    -- Uses real libass bounds (same as modernz's estimate_text_width) so the dialog
    -- is exactly as wide as its content, not an over-wide character-count estimate.
    local cw = measure_text(prompt)
    for i = 0, #playlist - 1 do
        local t = "→ " .. (get_playlist_item_title(i) or "")
        local w = measure_text(t)
        if w > cw then cw = w end
    end
    -- Clear the cache after each draw so stale entries don't accumulate indefinitely.
    text_width_cache = {}
    cw = math.min(cw, W - PAD * 4)

    -- Clamp cursor into the current filtered list
    if n > 0 then cursor = math.max(0, math.min(cursor, n - 1)) end

    local scroll = n > 0 and math.max(0, math.min(cursor - math.floor(vis / 2), n - vis)) or 0

    local x = (W - cw) / 2
    local y = H / 2 - (vis_max + 1.5) * LH / 2  -- anchored to full-size top; only height shrinks

    local clip        = ("\\clip(0,0,%d,%d)"):format(math.floor(x + cw), H)
    local fn_tag      = opts.font ~= "" and ("\\fn" .. opts.font) or ""
    -- Style mirrors ModernZ: explicit text/outline colors, no \r reset, no blur/fsp overrides
    local sty         = ("{\\bord1\\1c&HFFFFFF&\\3c&H000000&\\fs%d\\q2%s%s}"):format(FONT_SIZE, fn_tag, clip)
    -- Focused: dark text (#222222) over the white highlight box drawn below
    local focused_sty = ("{\\bord0\\1c&H222222&\\3c&H000000&\\fs%d\\q2%s%s}"):format(FONT_SIZE, fn_tag, clip)

    local ass = assdraw.ass_new()

    -- ── Background ──────────────────────────────────────────────────────────
    ass:new_event()
    ass:an(7)
    ass:pos(x, y)
    ass:append(("{\\bord0\\blur0\\1c&H000000&\\1a&H%02X&\\4a&Hff&}"):format(BG_ALPHA))
    ass:draw_start()
    ass:round_rect_cw(-PAD, -PAD, cw + PAD, (vis + 1.5) * LH + PAD, CORNER, CORNER)
    ass:draw_stop()

    -- ── Prompt ──────────────────────────────────────────────────────────────
    ass:new_event()
    ass:an(7)
    ass:pos(x, y)
    ass:append(sty .. prompt)

    -- ── Items ───────────────────────────────────────────────────────────────
    if n == 0 then
        ass:new_event()
        ass:an(4)
        ass:pos(x, y + 2 * LH)
        ass:append(sty .. "  (no matches)")
    else
        for r = 0, vis - 1 do
            local fi  = scroll + r       -- position in filtered list (0-based)
            if fi >= n then break end
            local idx = filtered[fi + 1] -- actual 0-based playlist index

            local cy = y + (r + 2) * LH
            local ty = y + (r + 1.5) * LH

            -- White highlight box for focused row (focused_back_color=#FFFFFF in select script)
            if fi == cursor then
                ass:new_event()
                ass:an(7)
                ass:pos(x - PAD, ty)
                ass:append("{\\bord0\\blur0\\4a&Hff&\\1c&HFFFFFF&}")
                ass:draw_start()
                ass:rect_cw(0, 0, cw + PAD * 2, LH)
                ass:draw_stop()
            end

            local prefix
            if   fi == cursor and moving then prefix = "→ "
            elseif idx == pos            then prefix = "▶ "
            else                              prefix = "  "
            end

            -- Highlight the matched substring; restore colour differs per row state
            -- (focused row has dark #222222 text on white; others have white text)
            local raw   = get_playlist_item_title(idx) or ""
            local title = highlight_match(raw, search_query,
                                          fi == cursor and "222222" or "FFFFFF")

            ass:new_event()
            ass:an(4)
            ass:pos(x, cy)
            ass:append((fi == cursor and focused_sty or sty) .. prefix .. title)
        end
    end

    -- ── Scrollbar ────────────────────────────────────────────────────────────
    if n > vis then
        local area_h = vis * LH
        local bar_h  = math.max((vis / n) * area_h, 8)
        local bar_y  = y + 1.5 * LH + (scroll / n) * area_h
        ass:new_event()
        ass:an(7)
        ass:pos(x + cw + PAD - 4, bar_y)
        ass:append("{\\bord0\\blur0\\4a&Hff&\\1c&HFFFFFF&\\1a&H88&}")
        ass:draw_start()
        ass:rect_cw(0, 0, 3, bar_h)
        ass:draw_stop()
    end

    overlay.res_x = W
    overlay.res_y = H
    overlay.z     = 2000
    overlay.data  = ass.text
    overlay:update()
end

local function close_playlist()
    open   = false
    moving = false
    overlay.data = ""
    overlay:remove()
    mp.remove_key_binding("pl-up")
    mp.remove_key_binding("pl-down")
    mp.remove_key_binding("pl-enter")
    mp.remove_key_binding("pl-right")
    mp.remove_key_binding("pl-left")
    mp.remove_key_binding("pl-esc")
    mp.remove_key_binding("pl-unicode")
    mp.remove_key_binding("pl-bs")
    mp.remove_key_binding("pl-del")
end

local function show_playlist_selector()
    if open then return end

    local playlist = mp.get_property_native("playlist")
    if not playlist or #playlist == 0 then
        mp.osd_message("Playlist empty")
        return
    end

    open         = true
    search_query = ""
    cursor       = mp.get_property_number("playlist-pos", 0)
    moving       = false
    draw_playlist()

    mp.add_forced_key_binding("UP", "pl-up", function()
        if moving then
            local count = mp.get_property_number("playlist-count", 0)
            if cursor > 0 then
                mp.commandv("playlist-move", cursor, cursor - 1)
                cursor = cursor - 1
            else
                mp.commandv("playlist-move", 0, count)
                cursor = count - 1
            end
            draw_playlist()
        else
            local n = #compute_filtered(mp.get_property_native("playlist") or {})
            cursor = (cursor - 1 + n) % n
            draw_playlist()
        end
    end)

    mp.add_forced_key_binding("DOWN", "pl-down", function()
        if moving then
            local count = mp.get_property_number("playlist-count", 0)
            if cursor < count - 1 then
                mp.commandv("playlist-move", cursor, cursor + 2)
                cursor = cursor + 1
            else
                mp.commandv("playlist-move", count - 1, 0)
                cursor = 0
            end
            draw_playlist()
        else
            local n = #compute_filtered(mp.get_property_native("playlist") or {})
            cursor = (cursor + 1) % n
            draw_playlist()
        end
    end)

    mp.add_forced_key_binding("ENTER", "pl-enter", function()
        if moving then
            moving = false
            draw_playlist()
        else
            local filtered = compute_filtered(mp.get_property_native("playlist") or {})
            if #filtered > 0 then
                local idx = filtered[cursor + 1]
                close_playlist()
                mp.set_property("playlist-pos", idx)
            end
        end
    end)

    -- Reordering is blocked while a search filter is active
    mp.add_forced_key_binding("RIGHT", "pl-right", function()
        if not moving and search_query == "" then
            move_origin = cursor
            moving = true
            draw_playlist()
        end
    end)

    mp.add_forced_key_binding("LEFT", "pl-left", function()
        if moving then moving = false; draw_playlist() end
    end)

    mp.add_forced_key_binding("ESC", "pl-esc", function()
        if moving then
            -- Restore item to its original position before moving mode was entered
            if cursor ~= move_origin then
                if cursor > move_origin then
                    mp.commandv("playlist-move", cursor, move_origin)
                else
                    mp.commandv("playlist-move", cursor, move_origin + 1)
                end
            end
            cursor = move_origin
            moving = false
            draw_playlist()
        elseif search_query ~= "" then
            search_query = ""
            cursor = math.max(0, mp.get_property_number("playlist-pos", 0))
            draw_playlist()
        else
            close_playlist()
        end
    end)

    -- Capture every printable character typed by the user for real-time filtering.
    -- Uses the same "any_unicode" mechanism that mp.input.select() uses internally.
    mp.add_forced_key_binding("any_unicode", "pl-unicode", function(event)
        if moving or event.event == "up" then return end
        local char = event.key_text or ""
        if char == "" then return end
        search_query = search_query .. char
        cursor = 0
        draw_playlist()
    end, {complex = true, repeatable = true})

    -- Backspace removes the last UTF-8 character from the search query
    mp.add_forced_key_binding("BS", "pl-bs", function()
        if search_query ~= "" then
            search_query = search_query:gsub("[%z\1-\127\194-\253][\128-\191]*$", "")
            if search_query == "" then
                cursor = math.max(0, mp.get_property_number("playlist-pos", 0))
            end
            draw_playlist()
        end
    end, {repeatable = true})

    mp.add_forced_key_binding("ctrl+BS", "pl-del", function()
        if moving then return end
        local playlist = mp.get_property_native("playlist") or {}
        local filtered = compute_filtered(playlist)
        if #filtered == 0 then return end
        local idx = filtered[cursor + 1]
        mp.commandv("playlist-remove", idx)
        local new_filtered = compute_filtered(mp.get_property_native("playlist") or {})
        local n = #new_filtered
        if n == 0 then close_playlist(); return end
        cursor = math.max(0, math.min(cursor, n - 1))
        draw_playlist()
    end)
end

local prev_playlist_count = 0
mp.observe_property("playlist-count", "number", function(_, count)
    count = count or 0
    if count > prev_playlist_count then
        dedup_playlist()
        fetch_all()
    end
    -- Re-read the actual count after dedup so removals don't look like additions.
    prev_playlist_count = mp.get_property_number("playlist-count", 0)
end)
mp.observe_property("playlist-pos", "number", function()
    if open then draw_playlist() end
end)
mp.add_key_binding(nil, "select-playlist", show_playlist_selector)

mp.add_key_binding("ctrl+v", "paste-url", function()
    local raw = (mp.get_property("clipboard/text") or ""):match("^%s*(.-)%s*$")

    if raw == "" then
        show_toast("Clipboard is empty", false)
        return
    end

    if not is_valid_url(raw) and not utils.file_info(raw) then
        show_toast("Not a valid URL or file", false)
        return
    end

    if is_in_playlist(raw) then
        show_toast("Already in playlist", false)
        return
    end

    mp.commandv("loadfile", raw, "append-play")
    fetch_url_title(raw)

    local label = #raw > 55 and (raw:sub(1, 52) .. "…") or raw
    show_toast("Added: " .. label, true)

    if open then draw_playlist() end
end)
