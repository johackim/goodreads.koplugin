--[[--
Browses your own Goodreads shelves on the device.

Goodreads retired its API, so this plugin reads the RSS export of your shelf
instead. One sync stores every book and its cover locally; everything after
that -- browsing, searching, opening a book -- reads only what is stored, and
needs no connection.
]]

local DataStorage = require("datastorage")
local DoubleKeyValuePage = require("doublekeyvaluepage")
local GoodreadsBook = require("goodreadsbook")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local Shelf = require("goodreadsshelf")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local N_ = _.ngettext
local T = require("ffi/util").template

-- Repainting the progress popup costs more than a cover download, so during
-- the long cover pass we only refresh it every so often.
local COVERS_PER_REFRESH = 20

local SORT_ORDERS = {
    { id = "recent", text = _("Recently added") },
    { id = "title",  text = _("Title") },
    { id = "author", text = _("Author") },
    { id = "rating", text = _("Average rating") },
    { id = "popularity", text = _("Most rated") },
}

--- The order with this name, falling back to the first: a name saved by an
-- older version must never leave the menu without a label.
local function sortOrderNamed(name)
    for _unused, order in ipairs(SORT_ORDERS) do
        if order.id == name then return order end
    end
    return SORT_ORDERS[1]
end

local Goodreads = WidgetContainer:extend{
    name = "goodreads",
}

function Goodreads:init()
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/goodreadssettings.lua")
    self.feed_url = self.settings:readSetting("feed_url") or ""
    self.sort_order = self.settings:readSetting("sort_order") or SORT_ORDERS[1].id
    self.ui.menu:registerToMainMenu(self)
end

function Goodreads:remember(key, value)
    self.settings:saveSetting(key, value)
    self.settings:flush()
end

--- The synced books, read from disk the first time they are asked for.
function Goodreads:getBooks()
    if not self.books then
        self.books = Shelf.load()
    end
    return self.books
end

-- The menu is left open behind these windows on purpose: they cover it while
-- they are up, and closing one brings the Goodreads menu back where it was,
-- instead of dropping out to the file browser.

--- The fields GoodreadsBook expects, taken from one of our records.
-- What we do not know is left out rather than spelled "N/A": the card simply
-- omits it, the way the Goodreads app does.
local function detailsOf(book)
    return {
        title       = book.title,
        author      = book.author or _("Unknown author"),
        series      = book.series,
        rating      = book.rating,
        pages       = book.pages,
        release     = book.year,
        cover       = Shelf.coverFile(book),
        -- The detail page renders this as HTML, so keep the paragraphs.
        description = (book.description or _("No description.")):gsub("\n", "<br/>"),
    }
end

function Goodreads:showBooks(title, books)
    if #books == 0 then
        UIManager:show(InfoMessage:new{ text = _("No book found.") })
        return
    end
    local rows = {}
    for _unused, book in ipairs(Shelf.sorted(books, self.sort_order)) do
        -- Second field is the line shown large, first is the smaller one below.
        table.insert(rows, {
            book.author or _("Unknown author"),
            book.title,
            book = book,
            callback = function()
                UIManager:show(GoodreadsBook:new{ dates = detailsOf(book) })
            end,
        })
    end
    UIManager:show(DoubleKeyValuePage:new{
        title = T("%1 (%2)", title, #books),
        kv_pairs = rows,
    })
end

--- One entry per shelf, fullest first: on a large library nearly everything
-- sits on "to-read", so the useful shelves have to come up early.
function Goodreads:shelfMenu()
    local items = {}
    for _unused, shelf in ipairs(Shelf.shelves(self:getBooks())) do
        table.insert(items, {
            text = T("%1 (%2)", shelf.name, shelf.count),
            keep_menu_open = true,
            callback = function()
                self:showBooks(shelf.name, Shelf.onShelf(self:getBooks(), shelf.name))
            end,
        })
    end
    return items
end

function Goodreads:sortMenu()
    local items = {}
    for _unused, order in ipairs(SORT_ORDERS) do
        table.insert(items, {
            text = order.text,
            radio = true,
            keep_menu_open = true,
            checked_func = function() return self.sort_order == order.id end,
            callback = function()
                self.sort_order = order.id
                self:remember("sort_order", order.id)
            end,
        })
    end
    return items
end

function Goodreads:search()
    local dialog
    dialog = InputDialog:new{
        title = _("Search your books"),
        input_hint = _("Title or author"),
        buttons = {{
            {
                text = _("Cancel"),
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Find"),
                is_enter_default = true,
                callback = function()
                    local text = dialog:getInputText()
                    UIManager:close(dialog)
                    self:showBooks(T(_("Results for “%1”"), text),
                        Shelf.matching(self:getBooks(), text))
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- Reads the whole shelf, then downloads the covers it does not have yet.
-- Both passes can be stopped by tapping; whatever was fetched is kept.
function Goodreads:sync()
    local user_id, key, shelf = Shelf.parseFeedUrl(self.feed_url)
    if not user_id then
        UIManager:show(InfoMessage:new{
            text = _("Set your Goodreads RSS feed address first."),
        })
        return
    end
    if NetworkMgr:willRerunWhenOnline(function() self:sync() end) then return end

    Trapper:wrap(function()
        local books, whole_shelf = Shelf.fetchBooks(user_id, key, shelf, function(page, found)
            return Trapper:info(T(
                _("Reading your shelf…\n\nPage %1, %2 books so far\n\nTap to stop."), page, found))
        end)
        -- Keep what is stored unless the whole shelf came through: a sync cut
        -- short, by a lost connection or by tapping stop, must not replace a
        -- full library with a partial one.
        if not whole_shelf then
            Trapper:reset()
            UIManager:show(InfoMessage:new{
                text = T(_("Sync did not finish, so your books were left as they were.\n\nIt stopped after %1 books."),
                    #books),
            })
            return
        end
        -- Reading the shelf a second time, ordered by ratings count, is what
        -- makes "Most rated" possible: the feed carries no such number, only
        -- Goodreads' own ordering.
        local ranked = Shelf.rankByRatings(user_id, key, shelf, books, function(page, seen)
            return Trapper:info(T(
                _("Ranking by number of ratings…\n\nPage %1, %2 books so far\n\nTap to stop."),
                page, seen))
        end)
        Shelf.save(books)
        self.books = books
        Shelf.fetchCovers(books, function(done, total)
            if done % COVERS_PER_REFRESH ~= 0 and done ~= total then return true end
            return Trapper:info(T(
                _("Downloading covers…\n\n%1 of %2\n\nTap to stop."), done, total))
        end)
        Trapper:reset()
        local done = T(N_("%1 book on your device.", "%1 books on your device.", #books), #books)
        if not ranked then
            done = done .. "\n" .. _("Sorting by “Most rated” is unavailable: that pass did not finish.")
        end
        UIManager:show(InfoMessage:new{ text = done })
    end)
end

function Goodreads:editFeedUrl()
    local dialog
    dialog = InputDialog:new{
        title = _("Goodreads RSS feed address"),
        input = self.feed_url,
        description = _([[
On Goodreads, open My Books and copy the RSS link at the bottom of the page.

A public profile needs nothing more than its number, so you may drop the "key" part of the address. Keep it only if your profile is private -- it is then a private key to your shelves.]]),
        buttons = {{
            {
                text = _("Cancel"),
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    self.feed_url = dialog:getInputText()
                    self:remember("feed_url", self.feed_url)
                    UIManager:close(dialog)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Goodreads:addToMainMenu(menu_items)
    menu_items.goodreads = {
        text = _("Goodreads"),
        -- KOReader dropped this plugin in 2021, so "goodreads" is no longer in
        -- its menu ordering. Without a hint the entry lands in the first menu
        -- labelled "NEW:"; this files it under Tools.
        sorting_hint = "tools",
        sub_item_table = {
            {
                text_func = function()
                    return T(_("My books (%1)"), #self:getBooks())
                end,
                keep_menu_open = true,
                callback = function()
                    self:showBooks(_("My books"), self:getBooks())
                end,
            },
            {
                text = _("Browse by shelf"),
                keep_menu_open = true,
                sub_item_table_func = function() return self:shelfMenu() end,
            },
            {
                text_func = function()
                    return T(_("Sort by: %1"), sortOrderNamed(self.sort_order).text)
                end,
                keep_menu_open = true,
                sub_item_table_func = function() return self:sortMenu() end,
            },
            {
                text = _("Search your books"),
                separator = true,
                keep_menu_open = true,
                callback = function()
                    self:search()
                end,
            },
            {
                text = _("Sync from Goodreads"),
                keep_menu_open = true,
                callback = function() self:sync() end,
            },
            {
                text = _("RSS feed address"),
                keep_menu_open = true,
                callback = function() self:editFeedUrl() end,
            },
        },
    }
end

return Goodreads
