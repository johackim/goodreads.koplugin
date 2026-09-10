--[[--
Browses your own Goodreads shelves on the device.

Goodreads retired its API, so this plugin reads the RSS export of your shelf
instead. One sync stores every book and its cover locally; everything after
that -- browsing, searching, opening a book -- reads only what is stored, and
needs no connection.

This file is the plugin's face: the menu, the dialogs, and turning stored
books into the strings the two windows show. Reading and storing the shelf
belongs to goodreadsshelf.lua.
]]

local BookListPage = require("booklistpage")
local DataStorage = require("datastorage")
local GoodreadsBook = require("goodreadsbook")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local MultiInputDialog = require("ui/widget/multiinputdialog")
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
    { id = "ratings", text = _("Most rated") },
}

--- 5756911 reads better as 5,756,911. Both the list and the card show the
-- count, so it is put in shape once, here, where their data is prepared.
local function readableNumber(number)
    local digits = tostring(number)
    return (digits:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end

--- The order with this name, falling back to the first: a name saved by an
-- older version must never leave the menu without a label.
local function sortOrderNamed(name)
    for _unused, order in ipairs(SORT_ORDERS) do
        if order.id == name then return order end
    end
    return SORT_ORDERS[1]
end

--- Some feed entries carry no author at all, and both windows have to name
-- one, so they name the same thing.
local function authorOf(book)
    return book.author or _("Unknown author")
end

--- Why a pass did not finish, in words to show the reader. Both passes of a
-- sync answer in the same two words, so both are read here.
local function reasonText(why)
    if why == "stopped" then return _("you stopped it") end
    return why or _("it did not finish")
end

--- The line under a book's title in the list.
local function subtitleOf(book)
    if not book.ratings then return authorOf(book) end
    return authorOf(book) .. " · " .. T(_("%1 ratings"), readableNumber(book.ratings))
end

--- The fields GoodreadsBook shows, taken from one of our records.
-- What we do not know is left out rather than spelled "N/A": the card simply
-- omits it, the way the Goodreads app does.
local function detailsOf(book)
    return {
        title       = book.title,
        author      = authorOf(book),
        series      = book.series,
        rating      = book.rating,
        pages       = book.pages,
        release     = book.year,
        cover       = Shelf.coverFile(book),
        ratings     = book.ratings and readableNumber(book.ratings),
        -- The detail page renders this as HTML, so keep the paragraphs.
        description = (book.description or _("No description.")):gsub("\n", "<br/>"),
    }
end

local Goodreads = WidgetContainer:extend{
    name = "goodreads",
}

function Goodreads:init()
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/goodreadssettings.lua")
    self.user = self.settings:readSetting("user") or ""
    self.shelf = self.settings:readSetting("shelf") or "All"
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

function Goodreads:tell(text)
    UIManager:show(InfoMessage:new{ text = text })
end

-- The menu is left open behind these windows on purpose: they cover it while
-- they are up, and closing one brings the Goodreads menu back where it was,
-- instead of dropping out to the file browser.

function Goodreads:showBooks(title, books)
    if #books == 0 then
        self:tell(_("No book found."))
        return
    end
    local rows = {}
    for _unused, book in ipairs(Shelf.sorted(books, self.sort_order)) do
        table.insert(rows, {
            title    = book.title,
            subtitle = subtitleOf(book),
            cover    = Shelf.coverFile(book),
            callback = function()
                UIManager:show(GoodreadsBook:new{ details = detailsOf(book) })
            end,
        })
    end
    UIManager:show(BookListPage:new{
        title = T("%1 (%2)", title, #books),
        rows = rows,
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

--- Reads the whole shelf, then counts ratings and downloads the covers it
-- does not have yet. Every pass can be stopped by tapping.
function Goodreads:sync(everything)
    if self.user == "" then
        self:tell(_("Set your Goodreads account first."))
        return
    end
    if NetworkMgr:willRerunWhenOnline(function() self:sync() end) then return end

    -- Resolving a username needs the network, so it waits until we have it.
    local user_id, key = Shelf.findUser(self.user)
    if not user_id then
        -- A username is looked up over the network, so a wrong name and a
        -- bad connection both land here; say so rather than blame the name.
        self:tell(T(_("Could not look up the Goodreads user “%1”.\n\nCheck the name and the connection, or enter your user number instead."),
            self.user))
        return
    end
    local shelf = Shelf.encodeShelf(self.shelf)

    Trapper:wrap(function()
        -- A re-sync only has to read as far as the books we already hold;
        -- asking for everything rebuilds from scratch instead.
        local stored = everything and {} or self:getBooks()
        local read_books, whole_shelf, why = Shelf.fetchBooks(user_id, key, shelf,
            function(page, found)
                return Trapper:info(T(
                    _("Reading your shelf…\n\nPage %1, %2 books so far\n\nTap to stop."), page, found))
            end, stored)
        -- Keep what is stored unless the whole shelf came through: a sync cut
        -- short, by a lost connection or by tapping stop, must not replace a
        -- full library with a partial one. Which of the two it was decides
        -- what the reader should do about it.
        if not whole_shelf then
            Trapper:reset()
            self:tell(why == "stopped"
                and T(_("Sync stopped, so your books were left as they were.\n\nIt had read %1 books."),
                    #read_books)
                or T(_("Could not read your whole shelf, so your books were left as they were.\n\nIt gave up after %1 books. Check the connection and try again."),
                    #read_books))
            return
        end

        local books = Shelf.merged(read_books, stored)
        -- Only books we have no count for, which after a partial read is just
        -- the new ones; after a full one, all of them.
        local uncounted = {}
        for _unused, book in ipairs(books) do
            if not book.ratings then table.insert(uncounted, book) end
        end
        -- How many ratings each book has, which the feed never says. This is
        -- what "Most rated" sorts on, and what the card shows.
        local ranked, why_not = Shelf.fetchRatings(uncounted, function(done, total)
            return Trapper:info(T(
                _("Counting ratings…\n\n%1 of %2\n\nTap to stop."), done, total))
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
            done = done .. "\n" .. T(
                _("Sorting by “Most rated” is unavailable: %1."), reasonText(why_not))
        end
        self:tell(done)
    end)
end

function Goodreads:editAccount()
    local dialog
    dialog = MultiInputDialog:new{
        title = _("Goodreads account"),
        fields = {
            {
                text = self.user,
                -- A private shelf is only readable through its own feed
                -- address, the one place its key is written down, so the
                -- field has to take a whole address as readily as a name.
                hint = _("Username, user number or RSS address"),
            },
            {
                text = self.shelf,
                hint = _("Shelf, or All"),
            },
        },
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Save"),
                callback = function()
                    local user, shelf = unpack(dialog:getFields())
                    self.user = user
                    self.shelf = shelf
                    self:remember("user", user)
                    self:remember("shelf", shelf)
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
                callback = function() self:search() end,
            },
            {
                text = _("Sync from Goodreads"),
                keep_menu_open = true,
                help_text = _("Reads only what you added since last time. Hold to read the whole shelf again, which also picks up books you removed or moved between shelves."),
                callback = function() self:sync() end,
                hold_callback = function() self:sync(true) end,
            },
            {
                text_func = function()
                    if self.user == "" then return _("Goodreads account") end
                    return T(_("Account: %1 / %2"), self.user, self.shelf)
                end,
                keep_menu_open = true,
                help_text = _("Your username is enough for a public shelf. A private one is only readable through its RSS address, which carries the key that unlocks it: open your shelf on goodreads.com and copy the address behind the RSS link at the bottom."),
                callback = function() self:editAccount() end,
            },
        },
    }
end

return Goodreads
