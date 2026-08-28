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
}
options.read_options(opts, "playlist_manager")

local title_cache = {}
local fetching    = {}
local fetch_queue = {}
local fetch_active = false

-- Serializes the mpv-add-item* handlers so items are resolved and inserted
-- one at a time, in arrival order - see process_add_queue below.
local add_queue  = {}
local add_active = false

-- Persists resolved titles across mpv restarts, so a video already
-- resolved in a previous session doesn't re-pay yt-dlp startup + a
-- network round-trip just because this session's in-memory title_cache
-- starts empty. Deliberately hardcoded, not a script-opt - nothing here
-- needs to be user-configurable. Lives in this file rather than
-- perpetual-playlist's own persisted state (a different file, a
-- different concern - the playlist itself) precisely so neither plugin
-- depends on the other being installed for its own feature to work.
local title_cache_file = mp.command_native({"expand-path", "~/.local/state/mpv/playlist_manager_titles.json"})

local function load_title_cache()
    local f = io.open(title_cache_file, "r")
    if not f then return end
    local content = f:read("*a")
    f:close()

    local ok, parsed = pcall(utils.parse_json, content)
    if ok and type(parsed) == "table" then
        title_cache = parsed
    end
end
load_title_cache()

local function save_title_cache()
    local f = io.open(title_cache_file, "w")
    if not f then
        -- io.open(path, "w") does not create missing parent directories
        -- on its own - only the file itself, and only if the directory
        -- is already there. Without this fallback, a fresh install/
        -- machine where that directory doesn't yet exist would make
        -- every save silently no-op forever. Only shell out to mkdir -p
        -- here, in this rare fallback path (once, on actual write
        -- failure), not proactively on every script load.
        pcall(function()
            local dir = utils.split_path(title_cache_file) -- split_path returns (dir, filename); only dir wanted here
            mp.command_native({
                name = "subprocess",
                args = { "mkdir", "-p", dir },
                playback_only = false,
                capture_stdout = false,
                capture_stderr = false,
            })
        end)
        f = io.open(title_cache_file, "w")
    end
    if f then
        f:write(utils.format_json(title_cache))
        f:close()
    end
end

-- Tracks the absolute playlist index for the next "mpv-add-item-next" or
-- "mpv-add-item-play" insert/relocation (see the handlers below - both
-- share this same state, since either kind of call landing an item
-- "right after current" should continue from wherever the last one left
-- off). nil means "no next-batch in progress" - recompute fresh from
-- playlist-pos on the next insert. Reset whenever playlist-pos actually
-- changes (see the observer near the end of this file), so a stale batch
-- never keeps appending after an old position once real navigation has
-- happened.
local next_insert_index = nil

-- Distinguishes "more items from the same mpv-remote add invocation"
-- (share a batch ID, stay in the order given relative to each other)
-- from "a separate, later mpv-remote add call" (different ID, or none at
-- all - see the handlers below), which should always insert right after
-- whatever's currently playing rather than continuing to append after
-- wherever the previous call's items landed.
local last_next_batch_id = nil

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

-- Visual constants. Style mirrors ModernZ: \bord1, explicit \1c/\3c colors.
--   font_size=24  background_alpha=80(=0x50)  corner_radius=8
--   padding=10    focused_color=#222222  focused_back_color=#FFFFFF  match_color=#0088FF
local FONT_SIZE   = 24
local CHAR_W      = FONT_SIZE * 0.6          -- conservative fallback: ~14 px/char at fs24 for proportional Latin fonts

local BG_ALPHA    = 0x50   -- background_alpha = 80 = 0x50 in the select script
local CORNER      = 8
local PAD         = 10
local LH          = FONT_SIZE * 1.2
-- Full-height fill (mirroring console.lua's calculate_max_lines()) leaves too little
-- breathing room for a media-player overlay when the playlist is long, so cap it at a
-- size that still shows a solid number of rows without dominating the screen.
local MAX_VISIBLE = math.min(math.floor((720 - PAD * 2) / LH - 1.5), 12)

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
    local key = text
    if text_width_cache[key] then return text_width_cache[key] end
    local w = 0
    if text_measure_osd and text_measure_osd.update then
        local W = get_virt_w()
        text_measure_osd.res_x = W
        text_measure_osd.res_y = 720
        text_measure_osd.data  =
            ("{\\fs%d\\bord0\\q2\\an7\\pos(0,0)}"):format(FONT_SIZE) .. text
        local bounds = text_measure_osd:update()
        if bounds and bounds.x0 and bounds.x1 then
            w = math.max(0, bounds.x1 - bounds.x0)
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
        args = {"yt-dlp", "--no-playlist", "--flat-playlist", "-sJ", url},
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
                save_title_cache()
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
    local max_w  = W - PAD * 4

    local full = prefix .. msg
    local cw   = math.min(measure_text(full), max_w)

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

    local clip   = ("\\clip(0,0,%d,%d)"):format(math.floor(x + cw), H)
    ass:new_event()
    ass:an(4)
    ass:pos(x, y + FONT_SIZE / 2)
    ass:append(("{\\bord1\\1c&H%s&\\3c&H000000&\\fs%d\\fsp0\\q2%s}"):format(col, FONT_SIZE, clip))
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

    local prompt_text = "Select a playlist entry: " .. search_query

    -- Measure dialog width from the widest string across all titles and the prompt.
    -- Uses real libass bounds (same as modernz's estimate_text_width) so the dialog
    -- is exactly as wide as its content, not an over-wide character-count estimate.
    local cw = measure_text(prompt_text)
    for i = 0, #playlist - 1 do
        local t = "→ " .. (get_playlist_item_title(i) or "")
        local w = measure_text(t)
        if w > cw then cw = w end
    end
    -- Evict cache when it grows large to prevent unbounded memory use.
    local cache_count = 0
    for _ in pairs(text_width_cache) do cache_count = cache_count + 1 end
    if cache_count > 200 then text_width_cache = {} end
    cw = math.min(cw, W - PAD * 4)

    -- Clamp cursor into the current filtered list
    if n > 0 then cursor = math.max(0, math.min(cursor, n - 1)) end

    local scroll = n > 0 and math.max(0, math.min(cursor - math.floor(vis / 2), n - vis)) or 0

    local x = (W - cw) / 2
    local y = H / 2 - (vis_max + 1.5) * LH / 2  -- anchored to full-size top; only height shrinks

    local clip        = ("\\clip(0,0,%d,%d)"):format(math.floor(x + cw), H)
    -- Style mirrors ModernZ: explicit text/outline colors, no \r reset.
    local sty         = ("{\\bord1\\1c&HFFFFFF&\\3c&H000000&\\fs%d\\fsp0\\q2%s}"):format(FONT_SIZE, clip)
    -- Focused: dark text (#222222) over the white highlight box drawn below
    local focused_sty = ("{\\bord0\\1c&H222222&\\3c&H000000&\\fs%d\\fsp0\\q2%s}"):format(FONT_SIZE, clip)

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
    -- Cursor: 1-unit-wide ASS drawing + \xbord0.5 on each side → ~1px thin bar,
    -- matching the cursor glyph used by mpv's built-in mp.input select dialog.
    local cglyph = ("{\\r\\blur0\\1c&HFFFFFF&\\3c&HFFFFFF&\\xbord0.5\\ybord0\\xshad0\\yshad1\\p4\\pbo24}" ..
                    "m 0 0 l 1 0 l 1 %d l 0 %d{\\p0}"):format(FONT_SIZE * 8, FONT_SIZE * 8)
    ass:new_event()
    ass:an(7)
    ass:pos(x, y)
    ass:append(sty .. prompt_text .. cglyph)

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

    -- ── Counter ──────────────────────────────────────────────────────────────
    -- Item counter (current/total), top-right of the box. Always shown, regardless
    -- of whether the list is currently scrollable.
    if n > 0 then
        ass:new_event()
        ass:an(9)
        ass:pos(x + cw, y)
        ass:append(("{\\bord1\\1c&HFFFFFF&\\3c&H000000&\\fs%d\\fsp0\\q2}"):format(FONT_SIZE))
        ass:append((cursor + 1) .. "/" .. n)
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
    mp.remove_key_binding("pl-enter-meta")
    mp.remove_key_binding("pl-right")
    mp.remove_key_binding("pl-left")
    mp.remove_key_binding("pl-esc")
    mp.remove_key_binding("pl-unicode")
    mp.remove_key_binding("pl-bs")
    mp.remove_key_binding("pl-del")
    mp.remove_key_binding("pl-del-meta")
    mp.remove_key_binding("pl-vim-up")
    mp.remove_key_binding("pl-vim-up-meta")
    mp.remove_key_binding("pl-vim-down")
    mp.remove_key_binding("pl-vim-down-meta")
    mp.remove_key_binding("pl-vim-right")
    mp.remove_key_binding("pl-vim-right-meta")
    mp.remove_key_binding("pl-vim-left")
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

    local function do_enter()
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
    end
    mp.add_forced_key_binding("ENTER",      "pl-enter",      do_enter)
    mp.add_forced_key_binding("meta+ENTER", "pl-enter-meta", do_enter)

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
        if char == "" or char:match("%c") then return end
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

    local function vim_up()
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
    end
    local function vim_down()
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
    end
    local function vim_right()
        if not moving and search_query == "" then
            move_origin = cursor
            moving = true
            draw_playlist()
        end
    end
    local function vim_left()
        if moving then moving = false; draw_playlist() end
    end
    mp.add_forced_key_binding("ctrl+k",  "pl-vim-up",         vim_up)
    mp.add_forced_key_binding("meta+k",  "pl-vim-up-meta",    vim_up)
    mp.add_forced_key_binding("ctrl+j",  "pl-vim-down",       vim_down)
    mp.add_forced_key_binding("meta+j",  "pl-vim-down-meta",  vim_down)
    mp.add_forced_key_binding("ctrl+l",  "pl-vim-right",      vim_right)
    mp.add_forced_key_binding("meta+l",  "pl-vim-right-meta", vim_right)
    mp.add_forced_key_binding("ctrl+h",  "pl-vim-left",       vim_left)

    local function delete_item()
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
    end
    mp.add_forced_key_binding("ctrl+BS", "pl-del",      delete_item)
    mp.add_forced_key_binding("meta+BS", "pl-del-meta", delete_item)
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
    -- Redraw for an external removal (e.g. perpetual_playlist.lua's
    -- drop_finished_items) happening while the dialog is open - the
    -- playlist-pos observer below doesn't reliably catch this: dropping
    -- the currently-playing *first* item shifts the next item into that
    -- same numeric index (0 -> 0), so playlist-pos never actually changes
    -- value and its own observer never fires, leaving the dialog stale
    -- until closed and reopened. This observer is the one that does
    -- reliably fire on any count change regardless of *which* index
    -- changed, so it's the right place for this rather than trying to
    -- catch it via playlist-pos.
    if open then draw_playlist() end
end)
mp.observe_property("playlist-pos", "number", function()
    -- Real navigation invalidates any in-progress "mpv-add-item-next"
    -- batch - a later, unrelated one should recompute its base position
    -- fresh rather than keep appending after a now-stale index.
    next_insert_index = nil
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

    show_toast("Added: " .. raw, true)

    if open then draw_playlist() end
end)

-- Runs yt-dlp to check whether `item` is actually a playlist (a directory
-- or channel/playlist URL that expands into many videos) rather than a
-- single video. Only meaningful for URLs - local files/directories are
-- returned unchanged here and handled directly in add_single_item() via
-- loadlist instead, which resolves a local directory without needing
-- yt-dlp at all.
--
-- mpv's own loadfile only resolves a playlist URL lazily - only once mpv
-- actually gets around to playing that specific entry - so a playlist
-- queued behind something that's currently playing would otherwise sit
-- as a single inert entry until playback naturally reaches it. Nothing
-- is lost, but it looks broken and can stay that way indefinitely.
-- Pre-resolving here instead makes it expand immediately.
--
-- Async (mp.command_native_async, not the blocking mp.command_native): a
-- synchronous subprocess call here used to freeze mpv's whole script
-- thread - OSD, dialog, input, everything - for yt-dlp's startup + a
-- network round-trip on every URL add, compounding badly across a
-- multi-item batch. Callers must serialize their own calls (see
-- process_add_queue below) if they need results in a stable order. Any
-- failure (non-zero exit, unparseable JSON, not actually a playlist)
-- calls back with the item unchanged, so a single video, an unsupported
-- site, or a transient network hiccup degrade to today's lazy-loadfile
-- behavior rather than blocking the add.
local function resolve_playlist_entries_async(item, callback)
    if not is_url(item) then
        callback({ item })
        return
    end

    mp.command_native_async({
        name = "subprocess",
        args = {"yt-dlp", "--no-warnings", "--flat-playlist", "-sJ", item},
        capture_stdout = true,
        capture_stderr = true,
    }, function(_, res)
        if not res or res.status ~= 0 or not res.stdout or res.stdout == "" then
            callback({ item })
            return
        end

        local ok, data = pcall(utils.parse_json, res.stdout)
        if not ok or type(data) ~= "table" or data._type ~= "playlist"
           or type(data.entries) ~= "table" or #data.entries == 0 then
            callback({ item })
            return
        end

        local entries = {}
        local seeded_any = false
        for _, entry in ipairs(data.entries) do
            if entry.url then
                if entry.title then
                    -- Seeds the title cache from data we already have, so
                    -- fetch_url_title() below is a no-op for these instead of
                    -- firing a redundant yt-dlp call per expanded entry.
                    title_cache[normalize_url(entry.url)] = entry.title
                    seeded_any = true
                end
                table.insert(entries, entry.url)
            end
        end
        -- One save for the whole expansion, not one per entry - a single
        -- playlist URL can expand into dozens of entries at once.
        if seeded_any then save_title_cache() end

        callback(#entries > 0 and entries or { item })
    end)
end

-- Serializes the mpv-add-item* handlers below so items are resolved and
-- inserted strictly in arrival order, one at a time - same one-job-at-a-
-- time shape as process_fetch_queue/fetch_active above, needed here so
-- next_insert_index/last_next_batch_id (shared across all three handlers)
-- are only ever touched by one in-flight job at once. `job` is a
-- function(done) that must call done() exactly once when it has fully
-- finished (including all its add_single_item calls), so the queue can
-- move on to the next one.
local function process_add_queue()
    if add_active or #add_queue == 0 then return end
    add_active = true
    local job = table.remove(add_queue, 1)
    job(function()
        add_active = false
        process_add_queue()
    end)
end

local function enqueue_add(job)
    add_queue[#add_queue + 1] = job
    process_add_queue()
end

-- Used by add_single_item's "play" mode when `item` is already somewhere
-- in the playlist, rather than silently skipping it (today's dedup
-- behavior for "last"/"next") or leaving it exactly where it was (which
-- could be far from the current entry, making whatever plays after it
-- nonsensical):
--
-- - If it's ahead of the current entry (the common case - something
--   queued for later, now wanted immediately), move it to take the
--   current entry's own slot - pushing the current entry (and
--   everything after it) one slot later, unchanged relative order -
--   consuming this batch's next insertion slot the same as a
--   freshly-inserted item would. Once this (and any other batch items)
--   finish playing, the interrupted current entry naturally plays next,
--   and the playlist continues exactly as it would have otherwise -
--   nothing is skipped or orphaned by the interruption.
-- - If it's at or before the current entry (replaying the current item,
--   or something already watched), leave history alone and just play it
--   in place - reordering the past is more surprising than useful, and
--   no batch slot is consumed since nothing was actually placed there.
--
-- Returns the index to hand to playlist-play-index (never nil - item's
-- presence was already confirmed by the caller's is_in_playlist check).
local function relocate_for_play(item)
    local norm = normalize_url(item)
    local existing_index = nil
    for i, entry in ipairs(mp.get_property_native("playlist") or {}) do
        if normalize_url(entry.filename) == norm then
            existing_index = i - 1 -- playlist indices are 0-based, ipairs is 1-based
            break
        end
    end

    local current_pos = mp.get_property_number("playlist-pos", -1)
    if current_pos < 0 or existing_index <= current_pos then
        return existing_index
    end

    local is_batch_start = next_insert_index == nil
    if is_batch_start then
        next_insert_index = current_pos
    end
    local target = next_insert_index

    if existing_index ~= target then
        -- playlist-move's own documented "paradox": moving index1 to
        -- take index2's place lands the entry AT index2 when index1 >
        -- index2, but one slot EARLIER (index2 - 1) when index1 < index2
        -- (removing index1 first shifts index2 back by one before the
        -- entry lands). existing_index > target always holds here
        -- (target <= current_pos < existing_index by definition, and the
        -- == case is skipped above), so this always lands exactly at
        -- `target`.
        mp.commandv("playlist-move", existing_index, target)
    end
    next_insert_index = next_insert_index + 1
    return target
end

-- Adds one already-resolved item (never a playlist URL by this point -
-- see resolve_playlist_entries_async above). `mode` is one of:
--   "last" - append to the end, starting playback only if idle
--   "next" - insert right after whatever's currently playing, without
--            interrupting it
--   "play" - insert (or relocate, if already present - see
--            relocate_for_play above) right BEFORE whatever's currently
--            playing - taking its slot and pushing it (and everything
--            after it) one later - then force playback to the new item
--            immediately, interrupting whatever's currently playing.
--            Once the new item(s) finish, the interrupted entry plays
--            next and the playlist carries on exactly as it would have
--            otherwise, instead of skipping straight past it.
-- `quiet` suppresses the per-item toast/redraw, used when the caller is
-- about to show a single aggregate toast instead (a playlist expanding
-- into many entries shouldn't fire one toast per video).
--
-- Returns (added, index): `added` is true if the item ended up in the
-- playlist one way or another (freshly inserted, or an existing
-- duplicate reused/relocated for "play" mode); `index` is the item's
-- resulting playlist index, only meaningful for "next"/"play" modes
-- (used by the mpv-add-item-play handler to know what to hand to
-- playlist-play-index for the batch's first item) - nil otherwise.
--
-- Tries loadlist before loadfile, but ONLY for local paths, never URLs:
-- loadlist resolves a local directory immediately (same purpose as
-- --playlist), where loadfile would only resolve it lazily once actually
-- played, and cleanly fails (via mp.commandv's own true/nil+error return)
-- for a plain local file, making loadfile there a no-op fallback.
--
-- Deliberately NOT tried for URLs, even though the same "clean failure"
-- held for a bogus/unsupported one in testing: for a normal YouTube watch
-- URL, loadlist does NOT fail the way a local plain file does - it
-- "succeeds" by pulling in YouTube's autoplay/"up next" mix as a giant
-- playlist (83 unrelated videos in testing, for a single watch URL).
-- Playlist URLs are already handled correctly ahead of this, by
-- resolve_playlist_entries_async's yt-dlp pre-expansion - any URL reaching this
-- function is either a genuine single video, or (rare fallback) a
-- playlist yt-dlp itself failed to resolve, and either way it must go
-- through loadfile, not loadlist.
local function add_single_item(item, mode, quiet)
    if is_in_playlist(item) then
        if mode ~= "play" then
            if not quiet then show_toast("Already in playlist", false) end
            return false, nil
        end
        local index = relocate_for_play(item)
        fetch_url_title(item)
        if not quiet then
            show_toast("Playing now: " .. item, true)
            if open then draw_playlist() end
        end
        return true, index
    end

    local try_loadlist = not is_url(item)
    local index = nil

    if mode == "last" then
        if not (try_loadlist and mp.commandv("loadlist", item, "append-play")) then
            mp.commandv("loadfile", item, "append-play")
        end
    else -- "next" or "play"
        -- Only "next" mode's very first insert of a fresh batch is
        -- allowed to kick off playback (*-play) if the player was idle.
        -- Using -play for every item would race: loadfile/loadlist
        -- return before the file actually starts loading (per their own
        -- docs), so a later insert fired moments later can still see
        -- "nothing playing yet" and hijack playback out from under an
        -- earlier item. Plain insert-at for the rest sidesteps that race
        -- entirely - by then something is either already playing, or
        -- about to be. "play" mode never uses the -play variant at all:
        -- it always forces an explicit playlist-play-index afterward
        -- (see the mpv-add-item-play handler) regardless of idle state,
        -- so starting playback here too would be redundant at best and
        -- racy at worst.
        --
        -- The anchor itself differs by mode: "next" inserts AFTER the
        -- current entry (pos + 1), leaving it alone and still playing.
        -- "play" inserts AT the current entry's own slot (pos), pushing
        -- it (and everything after it) one later instead - so once the
        -- new item(s) finish, the interrupted entry plays next and the
        -- playlist carries on exactly as it would have otherwise. If
        -- nothing is playing at all (idle), there's no current entry to
        -- insert before or after, so both modes just insert at the
        -- front.
        local is_batch_start = next_insert_index == nil
        if is_batch_start then
            local pos = mp.get_property_number("playlist-pos", -1)
            if pos < 0 then
                next_insert_index = 0
            elseif mode == "play" then
                next_insert_index = pos
            else
                next_insert_index = pos + 1
            end
        end

        local flag
        if mode == "next" then
            flag = is_batch_start and "insert-at-play" or "insert-at"
        else
            flag = "insert-at"
        end
        index = next_insert_index
        if not (try_loadlist and mp.commandv("loadlist", item, flag, tostring(index))) then
            mp.commandv("loadfile", item, flag, tostring(index))
        end
        next_insert_index = next_insert_index + 1
    end

    fetch_url_title(item)

    if not quiet then
        local verb = "Added: "
        if mode == "next" then verb = "Added next: "
        elseif mode == "play" then verb = "Playing now: " end
        show_toast(verb .. item, true)
        if open then draw_playlist() end
    end

    return true, index
end

-- Entry point for `mpv-remote add last`, sent over the IPC socket as
-- `script-message-to playlist_manager mpv-add-item <item>` instead of a
-- raw `loadfile` - so an item that's already in the running instance's
-- playlist gets ignored the same way ctrl+v/paste-url ignores one,
-- instead of briefly being added and only cleaned up after the fact by
-- dedup_playlist() below. A playlist URL or directory is pre-resolved
-- into its individual entries first (see resolve_playlist_entries_async),
-- so they all show up immediately instead of one inert placeholder.
--
-- Runs as a queued job (see process_add_queue/enqueue_add above) rather
-- than inline, since resolve_playlist_entries_async is async - queueing
-- keeps multiple items landing in the playlist in arrival order without
-- blocking the dialog/player while each one resolves.
mp.register_script_message("mpv-add-item", function(item)
    if not item or item == "" then return end
    enqueue_add(function(done)
        resolve_playlist_entries_async(item, function(entries)
            if #entries == 1 then
                add_single_item(entries[1], "last", false)
                done()
                return
            end

            local added = 0
            for _, entry in ipairs(entries) do
                if add_single_item(entry, "last", true) then
                    added = added + 1
                end
            end
            show_toast("Added " .. added .. " item(s) from playlist", true)
            if open then draw_playlist() end
            done()
        end)
    end)
end)

-- Entry point for `mpv-remote add next` - see mpv-add-item above for the
-- playlist/directory pre-resolution and the toast-batching rationale, and
-- add_single_item for the absolute-index insertion logic (inserting right
-- after whatever's currently playing instead of appending to the end,
-- preserving order across multiple items - including every entry of an
-- expanded playlist - via next_insert_index).
--
-- batch_id (mpv-remote's own PID, or empty/missing for anything else that
-- might send this message by hand) distinguishes multiple items from the
-- *same* mpv-remote add invocation, which should stay in the order given
-- relative to each other (next_insert_index left alone - it's mid-batch),
-- from a separate, later invocation, which should always land right
-- after whatever's currently playing rather than continuing to append
-- after wherever the previous call's items ended up. A missing/empty
-- batch_id always counts as "new" (the safer default), so this only ever
-- suppresses a reset when there's positive evidence it's a continuation.
-- Shared with mpv-add-item-play below - either kind of call landing an
-- item "right after current" continues from wherever the last one left
-- off, regardless of which of the two messages sent it.
-- Runs as a queued job, same rationale as mpv-add-item above. The
-- batch_id/next_insert_index check below runs when the job actually
-- executes (i.e. when its turn in the queue comes up), not when the
-- message arrives - an earlier item from the same batch may still be
-- queued/resolving, and only once it has actually run does
-- next_insert_index reflect the batch's true state.
mp.register_script_message("mpv-add-item-next", function(item, batch_id)
    if not item or item == "" then return end
    enqueue_add(function(done)
        if not batch_id or batch_id == "" or batch_id ~= last_next_batch_id then
            next_insert_index = nil
            last_next_batch_id = batch_id
        end

        resolve_playlist_entries_async(item, function(entries)
            if #entries == 1 then
                add_single_item(entries[1], "next", false)
                done()
                return
            end

            local added = 0
            for _, entry in ipairs(entries) do
                if add_single_item(entry, "next", true) then
                    added = added + 1
                end
            end
            show_toast("Added " .. added .. " item(s) next from playlist", true)
            if open then draw_playlist() end
            done()
        end)
    end)
end)

-- Entry point for `mpv-remote add` (bare, no next/last keyword) - "play
-- now". See mpv-add-item above for the playlist/directory pre-resolution
-- and toast-batching rationale, mpv-add-item-next for the batch_id/
-- next_insert_index mechanics (shared with this handler), and
-- add_single_item/relocate_for_play for exactly how an item ends up
-- positioned.
--
-- The key difference from mpv-add-item-next: once every given item has
-- been inserted (or, for a duplicate, relocated - see relocate_for_play),
-- the FIRST item given is forced to start playing immediately via
-- playlist-play-index, interrupting whatever's currently playing -
-- insert-at-play only starts playback if the player was idle, which
-- isn't enough here. Only the first item's index is used for this; the
-- rest just land in their batch-assigned slots in order, exactly like
-- mpv-add-item-next, and play out naturally once the first one ends.
-- Runs as a queued job, same rationale as mpv-add-item/mpv-add-item-next
-- above.
mp.register_script_message("mpv-add-item-play", function(item, batch_id)
    if not item or item == "" then return end
    enqueue_add(function(done)
        if not batch_id or batch_id == "" or batch_id ~= last_next_batch_id then
            next_insert_index = nil
            last_next_batch_id = batch_id
        end

        -- Only the very first job of a fresh batch is allowed to force
        -- playback via playlist-play-index below - mpv-remote's `add`
        -- sends one separate message per URL given on the command line,
        -- so with more than one URL this handler runs once per URL, not
        -- once for the whole batch. Without this guard, EVERY invocation
        -- would compute its own "first entry" and re-fire
        -- playlist-play-index, and since jobs run in arrival order, the
        -- LAST URL given would always win and hijack playback away from
        -- the actual first item the user asked to play.
        -- next_insert_index being nil here - checked now, when this job
        -- actually starts running, not when its message arrived - is
        -- exactly "no item from this batch has claimed a slot yet", the
        -- same signal add_single_item itself uses internally for
        -- is_batch_start.
        local is_first_of_batch = next_insert_index == nil

        resolve_playlist_entries_async(item, function(entries)
            local quiet_each = #entries > 1
            local first_index = nil
            local added = 0

            for i, entry in ipairs(entries) do
                local ok, index = add_single_item(entry, "play", quiet_each)
                if ok then
                    added = added + 1
                    if i == 1 then first_index = index end
                end
            end

            if is_first_of_batch and first_index then
                mp.commandv("playlist-play-index", tostring(first_index))
            end

            if quiet_each then
                show_toast("Playing " .. added .. " item(s) from playlist", true)
                if open then draw_playlist() end
            end
            done()
        end)
    end)
end)
