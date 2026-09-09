local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local CloseButton = require("closebutton")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local Font = require("ui/font")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")
local Screen = Device.screen
local T = require("ffi/util").template

local GoodreadsBook = InputContainer:extend{
    padding = Size.padding.fullscreen,
}

function GoodreadsBook:init()
    self.small_font_face = Font:getFace("smallffont")
    self.medium_font_face = Font:getFace("ffont")
    self.large_font_face = Font:getFace("largeffont")
    self.screen_width = Screen:getWidth()
    self.screen_height = Screen:getHeight()
    -- We hide whatever is below us, so UIManager must repaint it when we go.
    self.covers_fullscreen = true
    -- Say outright that we take the whole screen. Left to itself, the frame
    -- reports the size of its contents, and only that much would be redrawn,
    -- leaving the page underneath showing below us.
    self.dimen = Geom:new{ x = 0, y = 0, w = self.screen_width, h = self.screen_height }
    if Device:hasKeys() then
        self.key_events = { Close = { { "Back" } } }
    end
    UIManager:setDirty(self, function()
        return "ui", self.dimen
    end)
    self[1] = FrameContainer:new{
        width = self.screen_width,
        height = self.screen_height,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        self:getStatusContent(self.screen_width),
    }
end

function GoodreadsBook:getStatusContent(width)
    local close_button = CloseButton(self)
    local close_height = close_button:getSize().h
    return VerticalGroup:new{
        align = "left",
        OverlapGroup:new{
            dimen = Geom:new{ w = width, h = close_height },
            close_button,
        },
        self:genBookCard(close_height),
    }
end

--- One row of five stars showing an average out of 5, rounded to the nearest.
function GoodreadsBook:genStars(average, size)
    local stars = HorizontalGroup:new{ align = "center" }
    local filled = math.floor(average + 0.5)
    for index = 1, 5 do
        table.insert(stars, IconWidget:new{
            icon = index <= filled and "star.full" or "star.empty",
            width = size,
            height = size,
        })
    end
    return stars
end

--- The book's card: title and author across the top, then the cover beside
-- the description, as the Goodreads app lays it out.
-- `top_height` is the room the close bar above us already took.
function GoodreadsBook:genBookCard(top_height)
    local width = self.screen_width - 2 * self.padding
    local cover_width = math.floor(width * 0.28)

    -- The heading is built and finished first, because measuring a group
    -- freezes the offsets it paints its children at: anything added after a
    -- getSize() call would be laid out at a nil offset and crash on paint.
    local heading = VerticalGroup:new{ align = "left" }
    local function add(widget)
        table.insert(heading, LeftContainer:new{
            dimen = Geom:new{ w = width, h = widget:getSize().h },
            widget,
        })
    end

    add(TextBoxWidget:new{
        text = self.dates.title,
        face = self.large_font_face,
        width = width,
        alignment = "left",
    })
    add(VerticalSpan:new{ width = Size.span.vertical_default })
    add(TextBoxWidget:new{
        text = T(_("By %1"), self.dates.author),
        face = self.medium_font_face,
        width = width,
        alignment = "left",
    })
    add(VerticalSpan:new{ width = Size.span.vertical_default })

    -- Rating line. Anything we do not know is simply left out, so a book with
    -- no rating shows no stars rather than an empty row of them.
    local facts = {}
    local average = tonumber(self.dates.rating)
    if average then table.insert(facts, self.dates.rating) end
    if self.dates.pages then table.insert(facts, T(_("%1 pages"), self.dates.pages)) end
    if self.dates.release then table.insert(facts, self.dates.release) end
    if self.dates.series then table.insert(facts, self.dates.series) end
    if #facts > 0 then
        local summary = TextWidget:new{
            text = " " .. table.concat(facts, "  ·  "),
            face = self.small_font_face,
        }
        local rating_line = HorizontalGroup:new{ align = "center" }
        if average then
            table.insert(rating_line, self:genStars(average, summary:getSize().h))
        end
        table.insert(rating_line, summary)
        add(rating_line)
    end
    add(VerticalSpan:new{ width = Size.span.vertical_large })

    -- Now that the heading is complete, the rest of the page is the body's.
    -- The cover shares that height rather than assuming a tall window: in a
    -- short one it would otherwise run off the bottom edge.
    local body_height = self.screen_height - heading:getSize().h
        - top_height - 3 * self.padding
    local gap = math.floor(width * 0.04)
    local body = HorizontalGroup:new{
        align = "top",
        ImageWidget:new{
            file = self.dates.cover,
            width = cover_width,
            height = math.min(math.floor(cover_width * 1.5), body_height),
            -- Covers are not all the same shape; 0 means fit inside that box
            -- and keep the proportions, instead of stretching to fill it.
            scale_factor = 0,
        },
        HorizontalSpan:new{ width = gap },
        ScrollHtmlWidget:new{
            html_body = self.dates.description,
            css = [[
                @page { margin: 0; font-family: 'Noto Sans'; }
                body { margin: 0; line-height: 1.3; text-align: justify; }
            ]],
            width = width - cover_width - gap,
            height = body_height,
            dialog = self,
        },
    }

    local card = VerticalGroup:new{ align = "left", heading, body }
    return LeftContainer:new{
        dimen = Geom:new{ w = self.screen_width, h = card:getSize().h },
        HorizontalGroup:new{
            HorizontalSpan:new{ width = self.padding },
            card,
        },
    }
end

function GoodreadsBook:onAnyKeyPressed()
    return self:onClose()
end

function GoodreadsBook:onClose()
    UIManager:close(self, "flashui")
    return true
end

return GoodreadsBook
