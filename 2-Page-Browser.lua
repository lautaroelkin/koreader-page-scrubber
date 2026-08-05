--[[
    2-page-scrubber.lua
    Page scrubber overlay (Kindle E-ink optimized slow hold and loop protection)
    with an inline page-thumbnail grid in the central zone, between the top
    and bottom bars.

    We do NOT reuse KOReader's PageBrowserWidget itself: that widget hardcodes
    Screen:getWidth()/Screen:getHeight() throughout its init, gesture handlers
    (onTap/onSwipe/onPinch/onSpread/onHold) and TOC-ribbon math, builds its own
    fullscreen TitleBar and its own bottom BookMapRow ribbon, and none of that
    is expressed in terms of a configurable self.dimen. Forcing it into a
    mid-screen rectangle would mean monkey-patching every one of those
    Screen:getWidth/getHeight() call sites — fragile across KOReader versions,
    and exactly the kind of intervention that risks buffer corruption / a lost
    widget hierarchy on async thumbnail rendering.

    Instead we call the same underlying service PageBrowserWidget itself uses
    to fetch bitmaps -- ReaderThumbnail's ui.thumbnail:getPageThumbnail(page,
    w, h, batch_id, callback) -- and paint the resulting blitbuffers ourselves,
    directly into our own rectangle, with our own tap handling and our own
    memory cleanup. Standard rectangular tiles, no rounded masks, no floating
    windows -- just our own layout instead of the native one's.
]]--

local Blitbuffer      = require("ffi/blitbuffer")
local Device          = require("device")
local Dispatcher      = require("dispatcher")
local Event           = require("ui/event")
local Font            = require("ui/font")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local InputContainer  = require("ui/widget/container/inputcontainer")
local ReaderUI        = require("apps/reader/readerui")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local logger          = require("logger")
local _               = require("gettext")

local Screen = Device.screen

local function paintPill(bb, px, py, pw, ph, color)
    if pw <= 0 or ph <= 0 then return end
    local r = math.min(pw, ph) / 2.0
    for row = 0, ph - 1 do
        local dy = (row + 0.5) - ph * 0.5
        local inset = math.abs(dy) < r and math.ceil(r - math.sqrt(r*r - dy*dy)) or 0
        local rw = pw - 2 * inset
        if rw > 0 then bb:paintRect(px + inset, py + row, rw, 1, color) end
    end
end

local function paintCircle(bb, cx, cy, r, color)
    if r <= 0 then return end
    for row = -r, r do
        local half = math.floor(math.sqrt(r*r - row*row) + 0.5)
        if half > 0 then bb:paintRect(cx - half, cy + row, half * 2, 1, color) end
    end
end

local function paintRoundRect(bb, x, y, w, h, r, color)
    if w <= 0 or h <= 0 then return end
    r = math.min(r, math.floor(w / 2), math.floor(h / 2))
    if r <= 0 then bb:paintRect(x, y, w, h, color); return end
    if w - 2*r > 0 then bb:paintRect(x + r, y,         w - 2*r, h,         color) end
    bb:paintRect(x,     y + r,     r,       math.max(1, h - 2*r), color)
    bb:paintRect(x+w-r, y + r,     r,       math.max(1, h - 2*r), color)
    for j = 0, r - 1 do
        local arc = math.ceil(math.sqrt(r*r - (r-j-0.5)*(r-j-0.5)))
        if arc > 0 then
            bb:paintRect(x + r - arc, y + j,         arc, 1, color)
            bb:paintRect(x + w - r,   y + j,         arc, 1, color)
            bb:paintRect(x + r - arc, y + h - 1 - j, arc, 1, color)
            bb:paintRect(x + w - r,   y + h - 1 - j, arc, 1, color)
        end
    end
end

local ProgressSlider = {}
ProgressSlider.__index = ProgressSlider

function ProgressSlider:new(o)
    local obj = setmetatable(o or {}, self)
    obj.knob_r = Screen:scaleBySize(10)
    obj.height = obj.knob_r * 2 + Screen:scaleBySize(6)
    obj.dimen   = Geom:new{ x = 0, y = 0, w = obj.width or 0, h = obj.height }
    obj._dragging = false
    return obj
end

function ProgressSlider:getSize() return self.dimen end

function ProgressSlider:_valueToX(v)
    local range = self.value_max - self.value_min
    if range == 0 then return self.knob_r end
    return self.knob_r + (v - self.value_min) / range * ((self.width or 0) - self.knob_r * 2)
end

function ProgressSlider:_xToValue(lx)
    local range = self.value_max - self.value_min
    local frac = (lx - self.knob_r) / math.max(1, (self.width or 0) - self.knob_r * 2)
    frac = math.max(0, math.min(1, frac))
    return math.floor(self.value_min + frac * range + 0.5)
end

function ProgressSlider:paintTo(bb, x, y)
    self.dimen.x = x; self.dimen.y = y
    local w, h = self.width or 0, self.height
    local r = self.knob_r
    local cy = math.floor(y + h / 2)
    
    paintPill(bb, x, cy - Screen:scaleBySize(2), w, Screen:scaleBySize(4), Blitbuffer.COLOR_LIGHT_GRAY)
    local frac = (self.value - self.value_min) / math.max(1, self.value_max - self.value_min)
    local fw = math.floor(frac * w + 0.5)
    
    if fw > 0 then paintPill(bb, x, cy - Screen:scaleBySize(2), fw, Screen:scaleBySize(4), Blitbuffer.COLOR_BLACK) end

    local kx = math.floor(x + self:_valueToX(self.value))
    paintCircle(bb, kx, cy, r, Blitbuffer.COLOR_WHITE)
    paintCircle(bb, kx, cy, r - Screen:scaleBySize(3), Blitbuffer.COLOR_BLACK)
end

function ProgressSlider:handleTap(ges)
    if not self.dimen or not ges.pos:intersectWith(self.dimen) then return false end
    local v = self:_xToValue(ges.pos.x - self.dimen.x)
    if v ~= self.value then 
        self.value = v
        if self.on_change then self.on_change(v) end 
    end
    return true
end

function ProgressSlider:handlePan(ges)
    if self._dragging then
        local v = self:_xToValue(ges.pos.x - (self.dimen.x or 0))
        if v ~= self.value then 
            self.value = v
            if self.on_change then self.on_change(v) end 
        end
        return true
    end
    if not (self.dimen and ges.pos:intersectWith(self.dimen)) then return false end
    local dir = ges.direction
    if dir == "north" or dir == "south" then return false end
    self._dragging = true
    local v = self:_xToValue(ges.pos.x - self.dimen.x)
    if v ~= self.value then 
        self.value = v
        if self.on_change then self.on_change(v) end 
    end
    return true
end

function ProgressSlider:handlePanRelease(ges)
    if not self._dragging then return false end
    self._dragging = false
    local v = self:_xToValue(ges.pos.x - (self.dimen.x or 0))
    if v ~= self.value then 
        self.value = v
    end
    if self.on_change then self.on_change(self.value) end 
    return true
end

local PageScrubber = InputContainer:extend{ name = "page_scrubber", transparent = true }

function PageScrubber:init()
    local ui  = self.ui
    local doc = ui.document

    self._old_can_do = Device.canDoSwipeAnimation
    Device.canDoSwipeAnimation = function() return false end
    
    self._saved_swipe_animations = Screen.swipe_animations
    Screen.swipe_animations = false

    self._origin_page = (ui.paging and ui.paging:getCurrentPage()) or (ui.view and ui.view.state and ui.view.state.page) or 1
    self._cur_page    = self._origin_page
    self._total_pages = (doc and doc.getPageCount and doc:getPageCount()) or 1
    self._pressed_btn = nil
    self._closing     = false
    self._hold_token  = 0
    self._hold_active = false

    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    local pad = Screen:scaleBySize(16)

    local top_h     = Screen:scaleBySize(62)
    local top_bar_y = 0
    self._top_bar_dimen = Geom:new{ x = 0, y = top_bar_y, w = sw, h = top_h }

    self.font_ch = Font:getFace("cfont", Screen:scaleBySize(19))
    self.font_in = Font:getFace("cfont", Screen:scaleBySize(14))
    
    self._cbtn_sz  = Screen:scaleBySize(46)
    self.max_title_w = sw - pad * 6 - self._cbtn_sz * 2
    
    self.tw_chapter  = TextWidget:new{ text = "", face = self.font_ch, fgcolor = Blitbuffer.COLOR_BLACK, max_width = self.max_title_w }
    self.tw_info     = TextWidget:new{ text = "", face = self.font_in, fgcolor = Blitbuffer.COLOR_DARK_GRAY }

    self.tw_chapter:setText(_("—"))
    self.tw_info:setText("100% · 9999 / 9999")

    local ch_h = self.tw_chapter:getSize().h
    local info_h = self.tw_info:getSize().h

    self._slider = ProgressSlider:new{
        width     = sw - pad * 4,
        value     = self._cur_page,
        value_min = 1,
        value_max = self._total_pages,
        ticks     = nil,
    }
    local slider_h = self._slider:getSize().h

    local p_top    = Screen:scaleBySize(8)
    local spacing1 = Screen:scaleBySize(3)
    local spacing2 = Screen:scaleBySize(4)
    local spacing3 = Screen:scaleBySize(8)
    local mark_sz  = Screen:scaleBySize(40)
    local p_bot    = Screen:scaleBySize(8)

    local bar_h = p_top + ch_h + spacing1 + info_h + spacing2 + slider_h + spacing3 + mark_sz + p_bot
    local bar_y = sh - bar_h
    self._bar_dimen = Geom:new{ x = 0, y = bar_y, w = sw, h = bar_h }

    local grid_y_avail = bar_y - top_h
    self._grid_dimen = Geom:new{ x = 0, y = top_h, w = sw, h = grid_y_avail }
    self._grid_cols = 3
    self._grid_rows = 1
    self._grid_margin = Screen:scaleBySize(10)
    self._grid_item_h = grid_y_avail - 2 * self._grid_margin
    self._grid_item_w = math.floor(self._grid_item_h * sw / sh)
    self._grid_tiles      = {}
    self._grid_start_page = nil
    self._grid_batch_id   = nil
    self._grid_batch_seq  = 0
    self._grid_disabled = not (ui.thumbnail and ui.thumbnail.getPageThumbnail)

    self.tw_lib      = TextWidget:new{ text = "\u{F015}", face = Font:getFace("cfont", Screen:scaleBySize(18)), fgcolor = Blitbuffer.COLOR_BLACK }
    self.tw_fn       = TextWidget:new{ text = "⚙",   face = Font:getFace("cfont", Screen:scaleBySize(18)), fgcolor = Blitbuffer.COLOR_BLACK }
    self.tw_bm       = TextWidget:new{ text = "\u{F0F6}", face = Font:getFace("cfont", Screen:scaleBySize(15)), fgcolor = Blitbuffer.COLOR_BLACK }
    self.tw_toc      = TextWidget:new{ text = "☰",   face = Font:getFace("cfont", Screen:scaleBySize(22)), fgcolor = Blitbuffer.COLOR_BLACK }
    self.tw_aa       = TextWidget:new{ text = "Aa",  face = Font:getFace("cfont", Screen:scaleBySize(16)), fgcolor = Blitbuffer.COLOR_BLACK }
    self.tw_x        = TextWidget:new{ text = "✕",   face = Font:getFace("cfont", Screen:scaleBySize(22)), fgcolor = Blitbuffer.COLOR_BLACK }

    self.tw_ch_l     = TextWidget:new{ text = "‹‹",  face = Font:getFace("cfont", Screen:scaleBySize(24)), fgcolor = Blitbuffer.COLOR_BLACK }
    self.tw_ch_r     = TextWidget:new{ text = "››",  face = Font:getFace("cfont", Screen:scaleBySize(24)), fgcolor = Blitbuffer.COLOR_BLACK }

    local font_ctrl  = Font:getFace("cfont", Screen:scaleBySize(20))
    self.tw_ctrl_prev = TextWidget:new{ text = "‹", face = font_ctrl, fgcolor = Blitbuffer.COLOR_BLACK }
    self.tw_ctrl_mark = TextWidget:new{ text = "\u{F097}", face = font_ctrl, fgcolor = Blitbuffer.COLOR_BLACK }
    self.tw_ctrl_next = TextWidget:new{ text = "›", face = font_ctrl, fgcolor = Blitbuffer.COLOR_BLACK }

    self._slider.on_change = function(v)
        self:_gotoPage(v)
    end

    self:_updateTexts()

    local top_sz    = Screen:scaleBySize(44)
    local spacing   = Screen:scaleBySize(8)
    local left_base = Screen:scaleBySize(14)
    local right_base = sw - Screen:scaleBySize(14)
    local top_y     = top_bar_y + math.floor((top_h - top_sz) / 2)

    self._x_dimen   = Geom:new{ x = right_base - top_sz, y = top_y, w = top_sz, h = top_sz }
    
    self._lib_dimen = Geom:new{ x = left_base, y = top_y, w = top_sz, h = top_sz }
    self._fn_dimen  = Geom:new{ x = self._lib_dimen.x + top_sz + spacing, y = top_y, w = top_sz, h = top_sz }
    self._bm_dimen  = Geom:new{ x = self._fn_dimen.x + top_sz + spacing, y = top_y, w = top_sz, h = top_sz }
    self._toc_dimen = Geom:new{ x = self._bm_dimen.x + top_sz + spacing, y = top_y, w = top_sz, h = top_sz }
    self._aa_dimen  = Geom:new{ x = self._toc_dimen.x + top_sz + spacing, y = top_y, w = top_sz, h = top_sz }
    
    local current_y = bar_y + p_top
    self.ch_y_pos = current_y
    current_y = current_y + ch_h + spacing1

    self.info_y_pos = current_y
    current_y = current_y + info_h + spacing2

    self.slider_y_pos = current_y
    current_y = current_y + slider_h + spacing3

    self.ctrl_y_pos = current_y

    local side_sz = Screen:scaleBySize(34)
    local ctrl_sp = Screen:scaleBySize(10)
    local total_ctrl_w = side_sz * 2 + mark_sz + ctrl_sp * 2
    local ctrl_x = math.floor((sw - total_ctrl_w) / 2)

    self._ctrl_prev_dimen = Geom:new{ x = ctrl_x, y = self.ctrl_y_pos + math.floor((mark_sz - side_sz)/2), w = side_sz, h = side_sz }
    self._ctrl_mark_dimen = Geom:new{ x = ctrl_x + side_sz + ctrl_sp, y = self.ctrl_y_pos, w = mark_sz, h = mark_sz }
    self._ctrl_next_dimen = Geom:new{ x = ctrl_x + side_sz + mark_sz + ctrl_sp * 2, y = self.ctrl_y_pos + math.floor((mark_sz - side_sz)/2), w = side_sz, h = side_sz }

    local text_center_x = math.floor(sw / 2)
    self._prev_ch_dimen = Geom:new{ x = text_center_x - math.floor(self.max_title_w / 2) - self._cbtn_sz - Screen:scaleBySize(6), y = self.ch_y_pos, w = self._cbtn_sz, h = self._cbtn_sz }
    self._next_ch_dimen = Geom:new{ x = text_center_x + math.floor(self.max_title_w / 2) + Screen:scaleBySize(6), y = self.ch_y_pos, w = self._cbtn_sz, h = self._cbtn_sz }

    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }

    if Device:hasKeys() then
        self.key_events = {
            Close = { { Device.input.group.Back } },
            PrevPage = { { Device.input.group.PgBack } },
            NextPage = { { Device.input.group.PgFwd } }
        }
    end

    self.ges_events = {
        Tap         = { GestureRange:new{ ges = "tap",          range = self.dimen } },
        Pan         = { GestureRange:new{ ges = "pan",          range = self.dimen } },
        PanRelease  = { GestureRange:new{ ges = "pan_release",  range = self.dimen } },
        Swipe       = { GestureRange:new{ ges = "swipe",        range = self.dimen } },
        Hold        = { GestureRange:new{ ges = "hold",         range = self.dimen } },
        HoldRelease = { GestureRange:new{ ges = "hold_release", range = self.dimen } },
        Release     = { GestureRange:new{ ges = "release",      range = self.dimen } },
    }

    if not self._grid_disabled then
        self:_updateGridPages()
    end

    -- Forzar un refresco completo inicial para limpiar el fondo de texto en E-ink
    UIManager:setDirty(nil, "full")
end

function PageScrubber:onPrevPage() self:_gotoPage(self._cur_page - 1); return true end
function PageScrubber:onNextPage() self:_gotoPage(self._cur_page + 1); return true end

function PageScrubber:_getChapter(page)
    if self.ui.toc then
        local t = self.ui.toc:getTocTitleByPage(page)
        if t and t ~= "" then return t end
    end
    return _("—")
end

function PageScrubber:_isCurrentPageBookmarked()
    local bookmarked = false
    pcall(function()
        if self.ui.view and self.ui.view.dogear_visible then
            bookmarked = true
        end
    end)
    return bookmarked
end

function PageScrubber:_updateTexts()
    local pct = math.floor(self._cur_page / math.max(1, self._total_pages) * 100)
    self.tw_chapter:setText(self:_getChapter(self._cur_page))
    self.tw_info:setText(pct .. "%  ·  " .. self._cur_page .. " / " .. self._total_pages)
end

function PageScrubber:_gridSlotDimen(idx)
    local gd, m = self._grid_dimen, self._grid_margin
    local w, h  = self._grid_item_w, self._grid_item_h
    local mid_x = gd.x + math.floor((gd.w - w) / 2)
    local y     = gd.y + m
    local offsets = { -(w + m), 0, (w + m) }
    return Geom:new{ x = mid_x + offsets[idx], y = y, w = w, h = h }
end

function PageScrubber:_updateGridPages()
    if self._grid_disabled or self._closing then return end
    local thumbnail = self.ui.thumbnail

    if self._grid_batch_id then
        thumbnail:cancelPageThumbnailRequests(self._grid_batch_id)
    end
    self._grid_batch_seq = self._grid_batch_seq + 1
    local batch_id = "page_scrubber_grid_" .. tostring(self._grid_batch_seq)
    self._grid_batch_id = batch_id

    local nb_items = self._grid_cols * self._grid_rows
    self._grid_tiles = {}

    for idx = 1, nb_items do
        local page = self._cur_page + (idx - 2)
        local slot = { page = (page >= 1 and page <= self._total_pages) and page or nil }
        self._grid_tiles[idx] = slot
        if slot.page then
            local delayed = thumbnail:getPageThumbnail(slot.page, self._grid_item_w, self._grid_item_h, batch_id,
                function(tile, resp_batch_id, async_response)
                    if resp_batch_id ~= self._grid_batch_id then return end
                    if not tile then return end
                    self:_setGridTile(idx, tile)
                    if async_response then
                        UIManager:setDirty(self, "ui", self:_gridSlotDimen(idx))
                    end
                end)
            slot.loading = delayed and true or false
        end
    end
    UIManager:setDirty(self, "ui", self._grid_dimen)
end

function PageScrubber:_setGridTile(idx, tile)
    local slot = self._grid_tiles[idx]
    if not slot then return end
    slot.tile_bb = tile.bb
    slot.loading = false
end

function PageScrubber:_paintGrid(bb)
    local nb_items = self._grid_cols * self._grid_rows
    for idx = 1, nb_items do
        local slot = self._grid_tiles[idx]
        local rect = self:_gridSlotDimen(idx)
        bb:paintRect(rect.x, rect.y, rect.w, rect.h, Blitbuffer.COLOR_WHITE)
        if slot and slot.page then
            if slot.tile_bb then
                local tw, th = slot.tile_bb:getWidth(), slot.tile_bb:getHeight()
                local ox = rect.x + math.floor((rect.w - tw) / 2)
                local oy = rect.y + math.floor((rect.h - th) / 2)
                bb:blitFrom(slot.tile_bb, ox, oy, 0, 0, tw, th)
            elseif slot.loading then
                bb:paintRect(rect.x + math.floor(rect.w / 2) - 1, rect.y + math.floor(rect.h / 2) - 1,
                    2, 2, Blitbuffer.COLOR_GRAY)
            end
            local is_cur = (slot.page == self._cur_page)
            local border = is_cur and Screen:scaleBySize(3) or Screen:scaleBySize(1)
            bb:paintBorder(rect.x, rect.y, rect.w, rect.h, border, Blitbuffer.COLOR_BLACK, 0)
        end
    end
end

function PageScrubber:_gotoPage(page)
    if self._closing then return end
    self._cur_page = math.max(1, math.min(self._total_pages, page))
    self._slider.value = self._cur_page
    self:_updateTexts()

    self.ui:handleEvent(Event:new("GotoPage", self._cur_page))

    if not self._grid_disabled then
        self:_updateGridPages()
    end

    UIManager:setDirty(self, "ui", self.dimen)
end

function PageScrubber:_flashAndDo(btn_id, rect, action_func)
    if self._closing then return end
    self._pressed_btn = btn_id
    UIManager:setDirty(self, "ui", rect)
    UIManager:scheduleIn(0.05, function()
        self._pressed_btn = nil
        action_func()
    end)
end

function PageScrubber:paintTo(bb, x, y)
    local ok, err = pcall(function() self:_paintToImpl(bb, x, y) end)
    if not ok then logger.warn("page-scrubber paintTo error:", err) end
end

function PageScrubber:_paintToImpl(bb, x, y)
    local sw   = Screen:getWidth()
    local pad  = Screen:scaleBySize(16)
    local bd   = self._bar_dimen
    local td   = self._top_bar_dimen

    bb:paintRect(td.x, td.y, td.w, td.h, Blitbuffer.COLOR_WHITE)
    bb:paintRect(td.x, td.y + td.h - Screen:scaleBySize(2), td.w, Screen:scaleBySize(2), Blitbuffer.COLOR_BLACK)

    bb:paintRect(bd.x, bd.y, bd.w, bd.h, Blitbuffer.COLOR_WHITE)
    bb:paintRect(bd.x, bd.y, bd.w, Screen:scaleBySize(2), Blitbuffer.COLOR_BLACK)

    if not self._grid_disabled then
        local gd = self._grid_dimen
        bb:paintRect(gd.x, gd.y, gd.w, gd.h, Blitbuffer.COLOR_WHITE)
        self:_paintGrid(bb)
    end

    local function drawFloatingBtn(btn_id, dimen, tw)
        local is_pressed = (self._pressed_btn == btn_id)
        local fg_color = is_pressed and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
        local cx = dimen.x + math.floor(dimen.w / 2)
        local cy = dimen.y + math.floor(dimen.h / 2)
        
        if btn_id == "ctrl_prev" or btn_id == "ctrl_mark" or btn_id == "ctrl_next" or btn_id == "ch_l" or btn_id == "ch_r" then
            tw.fgcolor = fg_color
            local tsz = tw:getSize()
            local y_offset = 0
            if tw.text == "\u{F097}" or tw.text == "\u{F02E}" or tw.text == "\u{F015}" then
                y_offset = Screen:scaleBySize(1)
            elseif tw.text == "‹‹" or tw.text == "››" then
                y_offset = -Screen:scaleBySize(1)
            end
            tw:paintTo(bb, cx - math.floor(tsz.w / 2), cy - math.floor(tsz.h / 2) + y_offset)
            return
        end

        if btn_id == "x" or btn_id == "bm" or btn_id == "toc" or btn_id == "aa" or btn_id == "fn" or btn_id == "lib" then
            local bg_color = is_pressed and Blitbuffer.COLOR_BLACK or nil
            
            if bg_color then
                paintRoundRect(bb, dimen.x, dimen.y, dimen.w, dimen.h, Screen:scaleBySize(8), bg_color)
            end
            
            tw.fgcolor = fg_color
            local tsz = tw:getSize()
            local y_offset = 0
            if tw.text == "\u{F015}" or tw.text == "\u{F0F6}" then
                y_offset = Screen:scaleBySize(1)
            end
            tw:paintTo(bb, cx - math.floor(tsz.w / 2), cy - math.floor(tsz.h / 2) + y_offset)
            return
        end
    end

    drawFloatingBtn("lib", self._lib_dimen, self.tw_lib)
    drawFloatingBtn("fn", self._fn_dimen, self.tw_fn)
    drawFloatingBtn("bm", self._bm_dimen, self.tw_bm)
    drawFloatingBtn("toc", self._toc_dimen, self.tw_toc)
    drawFloatingBtn("aa", self._aa_dimen, self.tw_aa)
    drawFloatingBtn("x", self._x_dimen, self.tw_x)

    drawFloatingBtn("ch_l", self._prev_ch_dimen, self.tw_ch_l)
    drawFloatingBtn("ch_r", self._next_ch_dimen, self.tw_ch_r)

    local is_marked = self:_isCurrentPageBookmarked()
    self.tw_ctrl_mark:setText(is_marked and "\u{F02E}" or "\u{F097}")

    drawFloatingBtn("ctrl_prev", self._ctrl_prev_dimen, self.tw_ctrl_prev)
    drawFloatingBtn("ctrl_mark", self._ctrl_mark_dimen, self.tw_ctrl_mark)
    drawFloatingBtn("ctrl_next", self._ctrl_next_dimen, self.tw_ctrl_next)

    local csz_tw = self.tw_chapter:getSize()
    self.tw_chapter:paintTo(bb, math.floor((sw - csz_tw.w) / 2), self.ch_y_pos)

    local isz = self.tw_info:getSize()
    self.tw_info:paintTo(bb, math.floor((sw - isz.w) / 2), self.info_y_pos)

    local slider_x = pad * 2
    self._slider.value = self._cur_page
    self._slider:paintTo(bb, slider_x, self.slider_y_pos)
end

function PageScrubber:_closeReturn()
    if self._closing then return end
    self._closing = true
    self:_cancelHold()
    if self._cur_page ~= self._origin_page then
        self.ui:handleEvent(Event:new("GotoPage", self._origin_page))
    end
    UIManager:close(self)
end

function PageScrubber:_closeStay()
    if self._closing then return end
    self._closing = true
    self:_cancelHold()
    UIManager:close(self)
end

function PageScrubber:_closeAndShow(event_name)
    if self._closing then return end
    self._closing = true
    self:_cancelHold()
    UIManager:close(self)

    UIManager:scheduleIn(0.15, function()
        local ok, err = pcall(function() self.ui:handleEvent(Event:new(event_name)) end)
        if not ok then
            logger.warn("page-scrubber: evento", event_name, "falló:", err)
        end
    end)
end

function PageScrubber:_closeAndOpenMenu()
    if self._closing then return end
    self._closing = true
    self:_cancelHold()
    local ui = self.ui
    UIManager:close(self)
    
    UIManager:scheduleIn(0.15, function()
        if ui and ui.menu and ui.menu.onShowMenu then
            ui.menu:onShowMenu()
        end
    end)
end

function PageScrubber:_startHold(action)
    self._hold_active = true
    self._hold_token = self._hold_token + 1
    local current_token = self._hold_token
    
    local delay = 1.1
    local max_steps = 25
    local steps = 0

    local function rep()
        if not self._hold_active or self._closing or self._hold_token ~= current_token then 
            self:_cancelHold()
            return 
        end
        
        steps = steps + 1
        if steps > max_steps then
            self:_cancelHold()
            return
        end
        
        if action == "prev" then 
            if self._cur_page > 1 then 
                self:_gotoPage(self._cur_page - 1) 
            else 
                self:_cancelHold(); return 
            end
        elseif action == "next" then 
            if self._cur_page < self._total_pages then 
                self:_gotoPage(self._cur_page + 1) 
            else 
                self:_cancelHold(); return 
            end
        end
        
        UIManager:scheduleIn(delay, rep)
    end
    
    UIManager:scheduleIn(delay, rep)
end

function PageScrubber:_cancelHold()
    self._hold_active = false
    self._hold_token = self._hold_token + 1
end

function PageScrubber:onHide()
    self:_cancelHold()
end

function PageScrubber:_prevChapter()
    local ui = self.ui
    if ui.toc then
        local p = ui.toc:getPreviousChapter(self._cur_page)
        if p then self:_gotoPage(p) end
    end
end

function PageScrubber:_nextChapter()
    local ui = self.ui
    if ui.toc then
        local p = ui.toc:getNextChapter(self._cur_page)
        if p then self:_gotoPage(p) end
    end
end

function PageScrubber:onTap(_, ges)
    self:_cancelHold()
    if self._closing then return true end

    if self._lib_dimen and ges.pos:intersectWith(self._lib_dimen) then
        self:_flashAndDo("lib", self._lib_dimen, function() self:_closeAndShow("Home") end)
        return true
    end
    if self._fn_dimen and ges.pos:intersectWith(self._fn_dimen) then
        self:_flashAndDo("fn", self._fn_dimen, function() self:_closeAndOpenMenu() end)
        return true
    end
    if self._bm_dimen and ges.pos:intersectWith(self._bm_dimen) then
        self:_flashAndDo("bm", self._bm_dimen, function() self:_closeAndShow("ShowBookmark") end)
        return true
    end
    if self._toc_dimen and ges.pos:intersectWith(self._toc_dimen) then
        self:_flashAndDo("toc", self._toc_dimen, function() self:_closeAndShow("ShowToc") end)
        return true
    end
    if self._aa_dimen and ges.pos:intersectWith(self._aa_dimen) then
        self:_flashAndDo("aa", self._aa_dimen, function() self:_closeAndShow("ShowConfigMenu") end)
        return true
    end
    if self._x_dimen and ges.pos:intersectWith(self._x_dimen) then
        self:_flashAndDo("x", self._x_dimen, function() self:_closeReturn() end)
        return true
    end

    if self._ctrl_prev_dimen and ges.pos:intersectWith(self._ctrl_prev_dimen) then
        self:_flashAndDo("ctrl_prev", self._ctrl_prev_dimen, function()
            self.ui:handleEvent(Event:new("GotoPreviousBookmarkFromPage", false))
            local new_page = (self.ui.paging and self.ui.paging:getCurrentPage())
                or (self.ui.view and self.ui.view.state and self.ui.view.state.page)
                or self._cur_page
            self:_gotoPage(new_page)
        end)
        return true
    end
    if self._ctrl_mark_dimen and ges.pos:intersectWith(self._ctrl_mark_dimen) then
        self:_flashAndDo("ctrl_mark", self._ctrl_mark_dimen, function()
            self:_closeAndShow("ToggleBookmark")
        end)
        return true
    end
    if self._ctrl_next_dimen and ges.pos:intersectWith(self._ctrl_next_dimen) then
        self:_flashAndDo("ctrl_next", self._ctrl_next_dimen, function()
            self.ui:handleEvent(Event:new("GotoNextBookmarkFromPage", false))
            local new_page = (self.ui.paging and self.ui.paging:getCurrentPage())
                or (self.ui.view and self.ui.view.state and self.ui.view.state.page)
                or self._cur_page
            self:_gotoPage(new_page)
        end)
        return true
    end
    if self._prev_ch_dimen and ges.pos:intersectWith(self._prev_ch_dimen) then
        self:_flashAndDo("ch_l", self._prev_ch_dimen, function() self:_prevChapter() end)
        return true
    end
    if self._next_ch_dimen and ges.pos:intersectWith(self._next_ch_dimen) then
        self:_flashAndDo("ch_r", self._next_ch_dimen, function() self:_nextChapter() end)
        return true
    end
    if self._slider:handleTap(ges) then return true end
    
    if self._bar_dimen and ges.pos:intersectWith(self._bar_dimen) then
        return true
    end

    if self._top_bar_dimen and ges.pos:intersectWith(self._top_bar_dimen) then
        return true
    end

    if not self._grid_disabled and self._grid_dimen and ges.pos:intersectWith(self._grid_dimen) then
        local nb_items = self._grid_cols * self._grid_rows
        for idx = 1, nb_items do
            local rect = self:_gridSlotDimen(idx)
            if ges.pos:intersectWith(rect) then
                local slot = self._grid_tiles[idx]
                if slot and slot.page then
                    if idx == 2 then
                        self._cur_page = slot.page
                        self.ui:handleEvent(Event:new("GotoPage", slot.page))
                        self:_closeStay()
                    else
                        self:_gotoPage(slot.page)
                    end
                end
                return true
            end
        end
        return true
    end

    return true
end

function PageScrubber:onPan(_, ges)
    if self._closing then return true end
    if self._slider:handlePan(ges) then return true end
    self:_cancelHold()
    return true
end

function PageScrubber:onPanRelease(_, ges)
    self:_cancelHold()
    if self._closing then return true end
    if self._slider:handlePanRelease(ges) then return true end
    return true
end

function PageScrubber:onSwipe(_, ges)
    if self._closing then return true end
    if ges.direction == "west" then
        self:_gotoPage(self._cur_page + 1)
        return true
    elseif ges.direction == "east" then
        self:_gotoPage(self._cur_page - 1)
        return true
    end
    return false
end

function PageScrubber:onHold(_, ges)
    if self._closing then return true end
    if not self._grid_disabled and self._grid_dimen then
        if ges.pos:intersectWith(self:_gridSlotDimen(1)) then
            self:_startHold("prev"); return true
        end
        if ges.pos:intersectWith(self:_gridSlotDimen(3)) then
            self:_startHold("next"); return true
        end
    end
    return true
end

function PageScrubber:onHoldRelease(_, ges)
    self:_cancelHold()
    return true
end

function PageScrubber:onRelease(_, ges)
    self:_cancelHold()
    return true
end

function PageScrubber:onCloseWidget()
    self:_cancelHold()

    if not self._grid_disabled then
        if self._grid_batch_id and self.ui.thumbnail then
            self.ui.thumbnail:cancelPageThumbnailRequests(self._grid_batch_id)
        end
        self._grid_tiles = {}
        if self.ui.thumbnail and self.ui.thumbnail.tidyCache then
            self.ui.thumbnail:tidyCache()
        end
    end

    if self._old_can_do then
        Device.canDoSwipeAnimation = self._old_can_do
    end
    if self._saved_swipe_animations ~= nil then
        Screen.swipe_animations = self._saved_swipe_animations
    end

    if self.tw_chapter then self.tw_chapter:free() end
    if self.tw_info then self.tw_info:free() end
    if self.tw_toc then self.tw_toc:free() end
    if self.tw_bm then self.tw_bm:free() end
    if self.tw_aa then self.tw_aa:free() end
    if self.tw_fn then self.tw_fn:free() end
    if self.tw_lib then self.tw_lib:free() end
    if self.tw_x then self.tw_x:free() end
    if self.tw_ctrl_prev then self.tw_ctrl_prev:free() end
    if self.tw_ctrl_mark then self.tw_ctrl_mark:free() end
    if self.tw_ctrl_next then self.tw_ctrl_next:free() end
    if self.tw_ch_l then self.tw_ch_l:free() end
    if self.tw_ch_r then self.tw_ch_r:free() end
end

function PageScrubber:onClose()
    self:_closeStay()
    return true
end

Dispatcher:registerAction("page_scrubber_action", {
    category = "none",
    event    = "PageScrubber",
    title    = _("Page Scrubber"),
    reader   = true,
})

function ReaderUI:onPageScrubber()
    local ui = self
    if ui.document and type(ui.document.file) == "string" then
        local ext = ui.document.file:match("^.+(%..+)$")
        if ext then
            ext = ext:lower()
            if ext == ".pdf" or ext == ".cbr" or ext == ".cbz" or ext == ".cb7" or ext == ".cbt" or ext == ".djvu" then
                return
            end
        end
    end

    UIManager:nextTick(function()
        if not ui or not ui.document then return end
        UIManager:show(PageScrubber:new{ ui = ui, document = ui.document })
    end)
end

logger.info("page-scrubber patch: loaded")
