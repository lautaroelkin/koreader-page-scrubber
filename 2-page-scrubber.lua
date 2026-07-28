--[[
    2-page-scrubber.lua
    Page scrubber overlay (Robust Bookmark & Rounded Chapters Version).
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
    obj.knob_r = Screen:scaleBySize(12)
    obj.height = obj.knob_r * 2 + Screen:scaleBySize(16)
    obj.dimen   = Geom:new{ w = obj.width or 0, h = obj.height }
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
    
    paintPill(bb, x, cy - Screen:scaleBySize(2), w, Screen:scaleBySize(4), Blitbuffer.COLOR_DARK_GRAY)
    local frac = (self.value - self.value_min) / math.max(1, self.value_max - self.value_min)
    local fw = math.floor(frac * w + 0.5)
    
    if fw > 0 then paintPill(bb, x, cy - Screen:scaleBySize(2), fw, Screen:scaleBySize(4), Blitbuffer.COLOR_WHITE) end
    
    if self.ticks and type(self.ticks) == "table" then
        for _, tick in ipairs(self.ticks) do
            if type(tick) == "number" then
                local tx = math.floor(x + self:_valueToX(math.max(1, math.floor(tick * self.value_max + 0.5))))
                bb:paintRect(tx, cy - Screen:scaleBySize(4), Screen:scaleBySize(2), Screen:scaleBySize(8), Blitbuffer.COLOR_BLACK)
            end
        end
    end

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

    if self.ui.paging and type(self.ui.paging.enterSkimMode) == "function" then
        pcall(function() self.ui.paging:enterSkimMode() end)
    end

    self._origin_page = (ui.paging and ui.paging:getCurrentPage()) or (ui.view and ui.view.state and ui.view.state.page) or 1
    self._cur_page    = self._origin_page
    self._total_pages = (doc and doc.getPageCount and doc:getPageCount()) or 1
    self._pressed_btn = nil
    self._closing     = false
    self._hold_token  = 0
    self._hold_active = false
    self._hold_count  = 0

    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    local pad = Screen:scaleBySize(16)

    local bar_h     = Screen:scaleBySize(150)
    local bar_y     = sh - bar_h
    self._bar_dimen = Geom:new{ x = 0, y = bar_y, w = sw, h = bar_h }

    local win_pad  = Screen:scaleBySize(28)
    local win_x    = win_pad
    local win_y    = Screen:scaleBySize(40)
    local win_w    = sw - win_pad * 2
    local win_h    = bar_y - win_y - Screen:scaleBySize(12)
    self._win_dimen = Geom:new{ x = win_x, y = win_y, w = win_w, h = win_h }

    self._cbtn_sz  = Screen:scaleBySize(60)
    local slider_w = sw - pad * 4
    
    local toc_ticks = nil
    if self.ui.toc and type(self.ui.toc.getTocTicksFlattened) == "function" then
        pcall(function() toc_ticks = self.ui.toc:getTocTicksFlattened() end)
    end

    self._slider = ProgressSlider:new{
        width     = slider_w,
        value     = self._cur_page,
        value_min = 1,
        value_max = self._total_pages,
        ticks     = toc_ticks,
    }
    
    self._slider.on_change = function(v)
        self:_gotoPage(v)
    end

    self.font_ch = Font:getFace("cfont", Screen:scaleBySize(25))
    self.font_in = Font:getFace("cfont", Screen:scaleBySize(19))
    self.max_title_w = sw - pad * 8 - self._cbtn_sz * 2
    
    self.tw_chapter = TextWidget:new{ text = "", face = self.font_ch, fgcolor = Blitbuffer.COLOR_WHITE, max_width = self.max_title_w }
    self.tw_info = TextWidget:new{ text = "", face = self.font_in, fgcolor = Blitbuffer.COLOR_LIGHT_GRAY }
    
    self.tw_x     = TextWidget:new{ text = "✕", face = Font:getFace("cfont", Screen:scaleBySize(26)), fgcolor = Blitbuffer.COLOR_WHITE }
    self.tw_toc   = TextWidget:new{ text = "☰", face = Font:getFace("cfont", Screen:scaleBySize(26)), fgcolor = Blitbuffer.COLOR_WHITE }
    self.tw_bm    = TextWidget:new{ text = "★", face = Font:getFace("cfont", Screen:scaleBySize(24)), fgcolor = Blitbuffer.COLOR_WHITE }
    self.tw_arr_l = TextWidget:new{ text = "‹", face = Font:getFace("cfont", Screen:scaleBySize(42)), fgcolor = Blitbuffer.COLOR_WHITE }
    self.tw_arr_r = TextWidget:new{ text = "›", face = Font:getFace("cfont", Screen:scaleBySize(42)), fgcolor = Blitbuffer.COLOR_WHITE }
    self.tw_ch_l  = TextWidget:new{ text = "‹‹", face = Font:getFace("cfont", Screen:scaleBySize(30)), fgcolor = Blitbuffer.COLOR_WHITE }
    self.tw_ch_r  = TextWidget:new{ text = "››", face = Font:getFace("cfont", Screen:scaleBySize(30)), fgcolor = Blitbuffer.COLOR_WHITE }

    self:_updateTexts()

    local x_sz    = Screen:scaleBySize(56)
    local spacing = Screen:scaleBySize(12)
    local xbx     = win_x + win_w - x_sz - Screen:scaleBySize(16)
    local bmbx    = xbx - x_sz - spacing
    local tocbx   = bmbx - x_sz - spacing
    local by      = win_y + Screen:scaleBySize(16)

    self._x_dimen   = Geom:new{ x = xbx, y = by, w = x_sz, h = x_sz }
    self._bm_dimen  = Geom:new{ x = bmbx, y = by, w = x_sz, h = x_sz }
    self._toc_dimen = Geom:new{ x = tocbx, y = by, w = x_sz, h = x_sz }
    
    local arr_sz  = Screen:scaleBySize(60)
    local arr_y   = win_y + math.floor((win_h - arr_sz) / 2)
    self._prev_dimen = Geom:new{ x = win_x + Screen:scaleBySize(16), y = arr_y, w = arr_sz, h = arr_sz }
    self._next_dimen = Geom:new{ x = win_x + win_w - arr_sz - Screen:scaleBySize(16), y = arr_y, w = arr_sz, h = arr_sz }

    local row1_y = bar_y + Screen:scaleBySize(14)
    local text_center_x = math.floor(sw / 2)
    
    self._prev_ch_dimen = Geom:new{ x = text_center_x - math.floor(self.max_title_w / 2) - self._cbtn_sz - Screen:scaleBySize(8), y = row1_y, w = self._cbtn_sz, h = self._cbtn_sz }
    self._next_ch_dimen = Geom:new{ x = text_center_x + math.floor(self.max_title_w / 2) + Screen:scaleBySize(8), y = row1_y, w = self._cbtn_sz, h = self._cbtn_sz }

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

function PageScrubber:_isBookmarked(page)
    local res = false
    pcall(function()
        local bm_mod = self.ui.bookmark or (self.ui.readModule and self.ui:readModule("ReaderBookmark"))
        if not bm_mod then return end
        
        if type(bm_mod.hasBookmark) == "function" then
            if bm_mod:hasBookmark(page) then
                res = true
                return
            end
        end
        if type(bm_mod.isBookmarked) == "function" then
            if bm_mod:isBookmarked(page) then
                res = true
                return
            end
        end
        
        local bookmarks = bm_mod.bookmarks or (bm_mod.getBookmarkList and bm_mod:getBookmarkList())
        if type(bookmarks) == "table" then
            for _, bm in ipairs(bookmarks) do
                local bm_page = nil
                if type(bm.page) == "number" then
                    bm_page = bm.page
                elseif bm.pos then
                    if type(bm.pos.page) == "number" then
                        bm_page = bm.pos.page
                    elseif type(self.ui.document.getPageFromPos) == "function" then
                        pcall(function() bm_page = self.ui.document:getPageFromPos(bm.pos) end)
                    end
                elseif type(self.ui.document.getPageFromPos) == "function" then
                    pcall(function() bm_page = self.ui.document:getPageFromPos(bm) end)
                end
                
                if bm_page == page then
                    res = true
                    break
                end
            end
        end
    end)
    return res
end

function PageScrubber:_updateTexts()
    local pct = math.floor(self._cur_page / math.max(1, self._total_pages) * 100)
    self.tw_chapter:setText(self:_getChapter(self._cur_page))
    self.tw_info:setText(pct .. "%  ·  " .. self._cur_page .. " / " .. self._total_pages)
    self.ch_y_pos = self._bar_dimen.y + Screen:scaleBySize(12)
end

function PageScrubber:_gotoPage(page)
    if self._closing then return end
    self._cur_page = math.max(1, math.min(self._total_pages, page))
    self._slider.value = self._cur_page
    self:_updateTexts()
    
    self.ui:handleEvent(Event:new("GotoPage", self._cur_page))
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
    local wd   = self._win_dimen

    local mask_color = Blitbuffer.COLOR_BLACK
    if wd.y > 0 then bb:paintRect(0, 0, sw, wd.y, mask_color) end
    if wd.x > 0 then bb:paintRect(0, wd.y, wd.x, wd.h, mask_color) end
    local rw = sw - (wd.x + wd.w)
    if rw > 0 then bb:paintRect(wd.x + wd.w, wd.y, rw, wd.h, mask_color) end
    local bh = bd.y - (wd.y + wd.h)
    if bh > 0 then bb:paintRect(0, wd.y + wd.h, sw, bh, mask_color) end

    local thick = Screen:scaleBySize(3)
    local border_color = Blitbuffer.COLOR_WHITE
    bb:paintRect(wd.x - thick, wd.y - thick, wd.w + thick*2, thick, border_color)
    bb:paintRect(wd.x - thick, wd.y + wd.h, wd.w + thick*2, thick, border_color)
    bb:paintRect(wd.x - thick, wd.y, thick, wd.h, border_color)
    bb:paintRect(wd.x + wd.w, wd.y, thick, wd.h, border_color)

    local function drawFloatingBtn(dimen, tw, text_offset_x, force_invert)
        local is_pressed = (self._pressed_btn == tw.text) or force_invert
        local bg_color = is_pressed and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
        local fg_color = is_pressed and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
        
        local cx = dimen.x + math.floor(dimen.w / 2)
        local cy = dimen.y + math.floor(dimen.h / 2)
        
        if tw.text == "✕" or tw.text == "☰" or tw.text == "★" or tw.text == "‹‹" or tw.text == "››" then
            paintRoundRect(bb, dimen.x, dimen.y, dimen.w, dimen.h, Screen:scaleBySize(8), Blitbuffer.COLOR_WHITE)
            paintRoundRect(bb, dimen.x + Screen:scaleBySize(2), dimen.y + Screen:scaleBySize(2), dimen.w - Screen:scaleBySize(4), dimen.h - Screen:scaleBySize(4), Screen:scaleBySize(6), bg_color)
        else
            paintCircle(bb, cx, cy, math.floor(dimen.w / 2), Blitbuffer.COLOR_WHITE)
            paintCircle(bb, cx, cy, math.floor(dimen.w / 2) - Screen:scaleBySize(2), bg_color)
        end
        
        tw.fgcolor = fg_color
        local tsz = tw:getSize()
        tw:paintTo(bb, cx - math.floor(tsz.w / 2) + (text_offset_x or 0), cy - math.floor(tsz.h / 2) - Screen:scaleBySize(3))
    end

    drawFloatingBtn(self._x_dimen, self.tw_x)
    
    local is_bm = self:_isBookmarked(self._cur_page)
    drawFloatingBtn(self._bm_dimen, self.tw_bm, 0, is_bm)
    
    drawFloatingBtn(self._toc_dimen, self.tw_toc)
    
    drawFloatingBtn(self._prev_dimen, self.tw_arr_l, -Screen:scaleBySize(2))
    drawFloatingBtn(self._next_dimen, self.tw_arr_r, Screen:scaleBySize(2))

    bb:paintRect(bd.x, bd.y, bd.w, bd.h, Blitbuffer.COLOR_BLACK)
    bb:paintRect(bd.x, bd.y, bd.w, Screen:scaleBySize(2), Blitbuffer.COLOR_WHITE)

    drawFloatingBtn(self._prev_ch_dimen, self.tw_ch_l)
    drawFloatingBtn(self._next_ch_dimen, self.tw_ch_r)

    local csz_tw = self.tw_chapter:getSize()
    self.tw_chapter:paintTo(bb, math.floor((sw - csz_tw.w) / 2), self.ch_y_pos)

    local isz = self.tw_info:getSize()
    local info_y = self.ch_y_pos + csz_tw.h + Screen:scaleBySize(2)
    self.tw_info:paintTo(bb, math.floor((sw - isz.w) / 2), info_y)

    local slider_x = pad * 2
    local slider_y = bd.y + bd.h - Screen:scaleBySize(45)
    self._slider.value = self._cur_page
    self._slider:paintTo(bb, slider_x, slider_y)
end

function PageScrubber:_closeReturn()
    if self._closing then return end
    self._closing = true
    self:_cancelHold()
    if self._cur_page ~= self._origin_page then
        self.ui:handleEvent(Event:new("GotoPage", self._origin_page))
    end
    if self.ui.paging then 
        pcall(function() self.ui.paging:exitSkimMode() end) 
    end
    UIManager:close(self)
end

function PageScrubber:_closeStay()
    if self._closing then return end
    self._closing = true
    self:_cancelHold()
    if self.ui.paging then 
        pcall(function() self.ui.paging:exitSkimMode() end) 
    end
    UIManager:close(self)
end

function PageScrubber:_closeAndShow(event_name)
    if self._closing then return end
    self._closing = true
    self:_cancelHold()
    if self.ui.paging then 
        pcall(function() self.ui.paging:exitSkimMode() end) 
    end
    UIManager:close(self)
    
    UIManager:scheduleIn(0.15, function()
        self.ui:handleEvent(Event:new(event_name))
    end)
end

function PageScrubber:_startHold(action)
    self._hold_active = true
    self._hold_token = self._hold_token + 1
    self._hold_count = 0
    local current_token = self._hold_token
    
    local initial_delay = 0.01
    local function rep()
        if not self._hold_active or self._closing or self._hold_token ~= current_token or self._hold_count >= 4 then 
            self:_cancelHold()
            return 
        end
        
        self._hold_count = self._hold_count + 1

        if action == "prev" then 
            if self._cur_page > 1 then self:_gotoPage(self._cur_page - 1) else self:_cancelHold(); return end
        elseif action == "next" then 
            if self._cur_page < self._total_pages then self:_gotoPage(self._cur_page + 1) else self:_cancelHold(); return end
        end
        
        UIManager:scheduleIn(0.005, rep)
    end
    UIManager:scheduleIn(initial_delay, rep)
end

function PageScrubber:_cancelHold()
    self._hold_active = false
    self._hold_token = self._hold_token + 1
    self._hold_count = 0
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
    if self._x_dimen and ges.pos:intersectWith(self._x_dimen) then
        self:_flashAndDo("✕", self._x_dimen, function() self:_closeReturn() end)
        return true
    end
    if self._toc_dimen and ges.pos:intersectWith(self._toc_dimen) then
        self:_flashAndDo("☰", self._toc_dimen, function() self:_closeAndShow("ShowToc") end)
        return true
    end
    if self._bm_dimen and ges.pos:intersectWith(self._bm_dimen) then
        self:_flashAndDo("★", self._bm_dimen, function() self:_closeAndShow("ShowBookmark") end)
        return true
    end
    if self._prev_dimen and ges.pos:intersectWith(self._prev_dimen) then
        self:_flashAndDo("‹", self._prev_dimen, function() self:_gotoPage(self._cur_page - 1) end)
        return true
    end
    if self._next_dimen and ges.pos:intersectWith(self._next_dimen) then
        self:_flashAndDo("›", self._next_dimen, function() self:_gotoPage(self._cur_page + 1) end)
        return true
    end
    if self._prev_ch_dimen and ges.pos:intersectWith(self._prev_ch_dimen) then
        self:_flashAndDo("‹‹", self._prev_ch_dimen, function() self:_prevChapter() end)
        return true
    end
    if self._next_ch_dimen and ges.pos:intersectWith(self._next_ch_dimen) then
        self:_flashAndDo("››", self._next_ch_dimen, function() self:_nextChapter() end)
        return true
    end
    if self._slider:handleTap(ges) then return true end
    
    if self._win_dimen and ges.pos:intersectWith(self._win_dimen) then
        self:_closeStay(); return true
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
    if self._prev_dimen and ges.pos:intersectWith(self._prev_dimen) then
        self:_startHold("prev"); return true
    end
    if self._next_dimen and ges.pos:intersectWith(self._next_dimen) then
        self:_startHold("next"); return true
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
    
    if self._old_can_do then
        Device.canDoSwipeAnimation = self._old_can_do
    end
    if self._saved_swipe_animations ~= nil then
        Screen.swipe_animations = self._saved_swipe_animations
    end

    if self.tw_chapter then self.tw_chapter:free() end
    if self.tw_info then self.tw_info:free() end
    if self.tw_x then self.tw_x:free() end
    if self.tw_toc then self.tw_toc:free() end
    if self.tw_bm then self.tw_bm:free() end
    if self.tw_arr_l then self.tw_arr_l:free() end
    if self.tw_arr_r then self.tw_arr_r:free() end
    if self.tw_ch_l then self.tw_ch_l:free() end
    if self.tw_ch_r then self.tw_ch_r:free() end

    if self.ui.paging then
        pcall(function() self.ui.paging:exitSkimMode() end)
    end
end

function PageScrubber:onClose()
    self:_closeReturn()
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
