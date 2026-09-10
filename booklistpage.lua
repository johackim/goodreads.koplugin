--[[--
A full-screen, paged list of books: cover on the left, title and a line under
it on the right, one tap to open one.

KOReader's own KeyValuePage shows two columns of text and no images, so this
is a cut-down cousin of it that draws a cover instead of a key. It knows
nothing about Goodreads: it is handed rows that are ready to show.

Each row is `{ title = …, subtitle = …, cover = <image file>, callback = … }`.
]]

local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local Button = require("ui/widget/button")
local CloseButton = require("closebutton")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextWidget = require("ui/widget/textwidget")
local TopContainer = require("ui/widget/container/topcontainer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")
local Input = Device.input
local Screen = Device.screen
local T = require("ffi/util").template

local ROW_HEIGHT = 80       -- tall enough for a readable cover thumbnail
local PAGE_PADDING = 10     -- room between the list and the screen edges
local ROW_PADDING = 20      -- room around one row's contents
local COVER_GAP = 10        -- between a cover and the text beside it
local RULE_HEIGHT = 2       -- the line under the title

-- The title bar --------------------------------------------------------------

local BookListTitle = VerticalGroup:extend{
    page = nil,  -- the BookListPage the close button closes
    title = "",
    width = nil,
    align = "left",
    title_face = Font:getFace("tfont"),
}

function BookListTitle:init()
    local close_button = CloseButton(self.page)
    table.insert(self, OverlapGroup:new{
        dimen = { w = self.width },
        TextWidget:new{
            text = self.title,
            max_width = self.width - close_button:getSize().w,
            face = self.title_face,
        },
        close_button,
    })
    table.insert(self, LineWidget:new{
        dimen = Geom:new{ w = self.width, h = Screen:scaleBySize(RULE_HEIGHT) },
        background = Blitbuffer.COLOR_DARK_GRAY,
        style = "solid",
    })
    table.insert(self, VerticalSpan:new{ width = Screen:scaleBySize(5) })
end

-- One row --------------------------------------------------------------------

local BookListRow = InputContainer:extend{
    title = nil,
    subtitle = nil,
    cover = nil,  -- image file to show on the left of the row
    callback = nil,
    width = nil,
    height = nil,
    title_face = Font:getFace("smallinfofont"),
    subtitle_face = Font:getFace("xx_smallinfofont"),
}

function BookListRow:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    if self.callback and Device:isTouchDevice() then
        self.ges_events.Tap = {
            GestureRange:new{ ges = "tap", range = self.dimen },
        }
    end
    -- The cover keeps a book's 2:3 shape; the text gets what is left.
    local cover_width = math.floor(self.height * 2 / 3)
    local gap = Screen:scaleBySize(COVER_GAP)
    local padding = Screen:scaleBySize(ROW_PADDING)
    local text_width = self.width - cover_width - gap
    -- Both lines share the row, so each is given half of its height.
    local function line(text, face)
        return TopContainer:new{
            padding = 0,
            dimen = Geom:new{ w = text_width, h = self.height / 2 },
            TextWidget:new{
                text = text,
                max_width = text_width - 2 * padding,
                face = face,
            },
        }
    end
    self[1] = FrameContainer:new{
        padding = padding,
        bordersize = 0,
        width = self.width,
        height = self.height,
        HorizontalGroup:new{
            align = "center",
            ImageWidget:new{
                file = self.cover,
                width = cover_width,
                height = self.height,
            },
            HorizontalSpan:new{ width = gap },
            VerticalGroup:new{
                line(self.title, self.title_face),
                line(self.subtitle, self.subtitle_face),
            },
        },
    }
end

--- Blinks the row, then runs its callback, the way KOReader's own lists do.
-- The callback waits for the blink to reach the screen, so the tap is seen
-- before the window it opens covers the list.
function BookListRow:flashAndRun()
    local frame = self[1]
    local function repaint(refresh)
        UIManager:widgetRepaint(frame, frame.dimen.x, frame.dimen.y)
        UIManager:setDirty(nil, function() return refresh, frame.dimen end)
    end
    frame.invert = true
    repaint("fast")
    UIManager:tickAfterNext(function()
        self.callback()
        frame.invert = false
        repaint("ui")
    end)
end

function BookListRow:onTap()
    if not self.callback then return true end
    if G_reader_settings:isFalse("flash_ui") then
        self.callback()
    else
        self:flashAndRun()
    end
    return true
end

-- The page itself ------------------------------------------------------------

local BookListPage = InputContainer:extend{
    title = "",
    rows = nil,  -- {{ title, subtitle, cover, callback }, ...}
    current_page = 1,
    page_count = 1,
}

function BookListPage:init()
    self.dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() }
    -- We hide whatever is below us, so UIManager must repaint it when we go.
    self.covers_fullscreen = true
    if Device:hasKeys() then
        self.key_events = {
            Close = { { "Back" }, doc = "close page" },
            NextPage = { { Input.group.PgFwd }, doc = "next page" },
            PrevPage = { { Input.group.PgBack }, doc = "prev page" },
        }
    end
    if Device:isTouchDevice() then
        self.ges_events.Swipe = {
            GestureRange:new{ ges = "swipe", range = self.dimen },
        }
    end

    local chevron_left, chevron_right = "chevron.left", "chevron.right"
    if BD.mirroredUILayout() then
        chevron_left, chevron_right = chevron_right, chevron_left
    end
    self.previous_page_button = Button:new{
        icon = chevron_left,
        callback = function() self:goToPage(self.current_page - 1) end,
        bordersize = 0,
        show_parent = self,
    }
    self.next_page_button = Button:new{
        icon = chevron_right,
        callback = function() self:goToPage(self.current_page + 1) end,
        bordersize = 0,
        show_parent = self,
    }
    -- They start hidden, and stay so on a list that fits one page. Measuring
    -- the footer while they are hidden also means a list gets the same number
    -- of rows however many pages it turns out to have.
    self.previous_page_button:hide()
    self.next_page_button:hide()
    self.page_number = Button:new{
        text = "",
        bordersize = 0,
        margin = Screen:scaleBySize(20),
        text_font_face = "pgfont",
        text_font_bold = false,
    }
    self.footer = HorizontalGroup:new{
        self.previous_page_button,
        self.page_number,
        self.next_page_button,
    }

    local padding = Screen:scaleBySize(PAGE_PADDING)
    self.row_width = self.dimen.w - 2 * padding
    self.row_height = Screen:scaleBySize(ROW_HEIGHT)
    self.row_margin = self.row_height / 6
    self.title_bar = BookListTitle:new{
        title = self.title,
        width = self.row_width,
        page = self,
    }
    local list_height = self.dimen.h - self.title_bar:getSize().h - self.footer:getSize().h
    self.rows_per_page = math.floor(list_height / (self.row_height + 2 * self.row_margin))
    self.page_count = math.ceil(#self.rows / self.rows_per_page)
    self.row_list = VerticalGroup:new{}
    self:showCurrentPage()

    self[1] = FrameContainer:new{
        height = self.dimen.h,
        padding = padding,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        OverlapGroup:new{
            dimen = self.dimen:copy(),
            VerticalGroup:new{
                align = "left",
                self.title_bar,
                self.row_list,
            },
            BottomContainer:new{
                dimen = self.dimen:copy(),
                self.footer,
            },
        },
    }
end

--- Shows the page with this number, if there is one. Anything outside the
-- list is ignored, so the last page simply stays put on a swipe.
function BookListPage:goToPage(number)
    if number < 1 or number > self.page_count or number == self.current_page then return end
    self.current_page = number
    self:showCurrentPage()
end

function BookListPage:showCurrentPage()
    self.footer:resetLayout()
    self.row_list:clear()
    local first = (self.current_page - 1) * self.rows_per_page + 1
    for index = first, math.min(first + self.rows_per_page - 1, #self.rows) do
        local row = self.rows[index]
        table.insert(self.row_list, VerticalSpan:new{ width = self.row_margin })
        table.insert(self.row_list, BookListRow:new{
            width = self.row_width,
            height = self.row_height,
            title = row.title,
            subtitle = row.subtitle,
            cover = row.cover,
            callback = row.callback,
            show_parent = self,
        })
        table.insert(self.row_list, VerticalSpan:new{ width = self.row_margin })
    end
    self.page_number:setText(T(_("Page %1 of %2"), self.current_page, self.page_count))
    -- A single page needs no arrows at all; on any other they show, greyed
    -- out at the two ends of the list.
    self.previous_page_button:showHide(self.page_count > 1)
    self.next_page_button:showHide(self.page_count > 1)
    self.previous_page_button:enableDisable(self.current_page > 1)
    self.next_page_button:enableDisable(self.current_page < self.page_count)

    UIManager:setDirty(self, function()
        return "ui", self.dimen
    end)
end

function BookListPage:onNextPage()
    self:goToPage(self.current_page + 1)
    return true
end

function BookListPage:onPrevPage()
    self:goToPage(self.current_page - 1)
    return true
end

function BookListPage:onSwipe(arg, ges_ev)
    local direction = BD.flipDirectionIfMirroredUILayout(ges_ev.direction)
    if direction == "west" then
        self:goToPage(self.current_page + 1)
        return true
    elseif direction == "east" then
        self:goToPage(self.current_page - 1)
        return true
    elseif direction == "south" then
        -- A swipe down closes the page: easier than reaching for the "×".
        self:onClose()
    elseif direction ~= "north" then
        -- A diagonal swipe: repaint the whole screen, and let it through --
        -- a long one is also how a screenshot is taken.
        UIManager:setDirty(nil, "full")
        return false
    end
end

function BookListPage:onClose()
    UIManager:close(self)
    return true
end

return BookListPage
