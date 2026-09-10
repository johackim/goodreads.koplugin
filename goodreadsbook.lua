--[[--
One book, full screen: title and author across the top, the rating and the
few facts we hold under them, then the cover beside the description.

It is handed a table of ready-made strings -- `details` -- and shows every
field that is there, leaving out the ones that are not.
]]

local Blitbuffer = require("ffi/blitbuffer")
local CloseButton = require("closebutton")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
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

local STARS = 5
local COVER_SHARE = 0.28  -- of the card's width, the rest is the description
local GAP_SHARE = 0.04    -- between the cover and the description
local COVER_RATIO = 1.5   -- a book cover is half as tall again as it is wide

local DESCRIPTION_CSS = [[
    @page { margin: 0; font-family: 'Noto Sans'; }
    body { margin: 0; line-height: 1.3; text-align: justify; }
]]

local GoodreadsBook = InputContainer:extend{
    details = nil,
    padding = Size.padding.fullscreen,
    title_face = Font:getFace("largeffont"),
    author_face = Font:getFace("ffont"),
    facts_face = Font:getFace("smallffont"),
}

--- One row of five stars showing an average out of 5, rounded to the nearest.
local function starsRow(average, size)
    local stars = HorizontalGroup:new{ align = "center" }
    local filled = math.floor(average + 0.5)
    for index = 1, STARS do
        table.insert(stars, IconWidget:new{
            icon = index <= filled and "star.full" or "star.empty",
            width = size,
            height = size,
        })
    end
    return stars
end

--- The short facts shown beside the stars, in reading order. Anything we do
-- not know is simply left out, so no line ever reads "N/A".
local function factsOf(details)
    local facts = {}
    local function add(fact) if fact then table.insert(facts, fact) end end
    add(tonumber(details.rating) and details.rating)
    add(details.ratings and T(_("%1 ratings"), details.ratings))
    add(details.pages and T(_("%1 pages"), details.pages))
    add(details.release)
    add(details.series)
    return facts
end

function GoodreadsBook:init()
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

    local close_button = CloseButton(self)
    local close_height = close_button:getSize().h
    self[1] = FrameContainer:new{
        width = self.screen_width,
        height = self.screen_height,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        VerticalGroup:new{
            align = "left",
            OverlapGroup:new{
                dimen = Geom:new{ w = self.screen_width, h = close_height },
                close_button,
            },
            self:bookCard(close_height),
        },
    }
end

--- Title, author and facts, then the cover beside the description, as the
-- Goodreads app lays it out.
-- `top_height` is the room the close bar above us already took.
function GoodreadsBook:bookCard(top_height)
    local width = self.screen_width - 2 * self.padding
    local cover_width = math.floor(width * COVER_SHARE)
    local gap = math.floor(width * GAP_SHARE)

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
    local function addText(text, face)
        add(TextBoxWidget:new{
            text = text,
            face = face,
            width = width,
            alignment = "left",
        })
    end

    addText(self.details.title, self.title_face)
    add(VerticalSpan:new{ width = Size.span.vertical_default })
    addText(T(_("By %1"), self.details.author), self.author_face)
    add(VerticalSpan:new{ width = Size.span.vertical_default })

    local facts = factsOf(self.details)
    if #facts > 0 then
        local summary = TextWidget:new{
            text = " " .. table.concat(facts, "  ·  "),
            face = self.facts_face,
        }
        local facts_line = HorizontalGroup:new{ align = "center" }
        -- A book with no rating shows no stars, rather than an empty row.
        local average = tonumber(self.details.rating)
        if average then
            table.insert(facts_line, starsRow(average, summary:getSize().h))
        end
        table.insert(facts_line, summary)
        add(facts_line)
    end
    add(VerticalSpan:new{ width = Size.span.vertical_large })

    -- Now that the heading is complete, the rest of the page is the body's.
    -- The cover shares that height rather than assuming a tall window: in a
    -- short one it would otherwise run off the bottom edge.
    local body_height = self.screen_height - heading:getSize().h
        - top_height - 3 * self.padding
    local body = HorizontalGroup:new{
        align = "top",
        ImageWidget:new{
            file = self.details.cover,
            width = cover_width,
            height = math.min(math.floor(cover_width * COVER_RATIO), body_height),
            -- Covers are not all the same shape; 0 means fit inside that box
            -- and keep the proportions, instead of stretching to fill it.
            scale_factor = 0,
        },
        HorizontalSpan:new{ width = gap },
        ScrollHtmlWidget:new{
            html_body = self.details.description,
            css = DESCRIPTION_CSS,
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

function GoodreadsBook:onClose()
    UIManager:close(self, "flashui")
    return true
end

return GoodreadsBook
