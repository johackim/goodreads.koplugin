--[[--
Reads a Goodreads shelf through its public RSS export and keeps it offline.

The Goodreads API is gone, but `review/list_rss` still serves a whole shelf,
100 books at a time. We walk every page once and store what we get: the books
in one Lua file, one cover image per book. Browsing afterwards reads only
those, so it works with the Wi-Fi off.

This module holds no state of its own. It parses, downloads and filters;
whoever calls it decides what to keep in memory.
]]

local DataStorage = require("datastorage")
local dump = require("dump")
local http = require("socket.http")
local lfs = require("libs/libkoreader-lfs")
local ltn12 = require("ltn12")
local rapidjson = require("rapidjson")
local socket = require("socket")
local socketutil = require("socketutil")
local util = require("util")

local BOOKS_PER_FEED_PAGE = 100  -- what Goodreads gives us per page
local MAX_FEED_PAGES = 200       -- a stop, should the feed never run short
local MAX_DESCRIPTION = 1200     -- descriptions are most of the file's weight
local COVER_WIDTH = 318          -- the widest Goodreads serves, and only ~20kB
local BOOKS_PER_RATINGS_CALL = 100  -- 200 in one call is refused by their firewall

-- Our own files sit next to this one. A plugin installed by hand is not
-- under the KOReader folder, so a fixed path would not find them.
local PLUGIN_DIR = debug.getinfo(1, "S").source:match("^@?(.*)/[^/]*$")

local Shelf = {}

local function libraryPath()
    return DataStorage:getSettingsDir() .. "/goodreads_library.lua"
end

local function coversPath()
    return DataStorage:getDataDir() .. "/cache/goodreads_covers"
end

--- Where this book's cover is kept on the device.
function Shelf.coverPath(book)
    return coversPath() .. "/" .. book.id .. ".jpg"
end

local function hasCover(book)
    return lfs.attributes(Shelf.coverPath(book), "mode") == "file"
end

--- The image to show for a book: the cover we downloaded, or the stand-in
-- shipped with the plugin when we have none. Both views use this, so a book
-- without a cover looks the same everywhere.
function Shelf.coverFile(book)
    if hasCover(book) then return Shelf.coverPath(book) end
    return PLUGIN_DIR .. "/goodreadsnophoto.png"
end

-- Reading the feed ----------------------------------------------------------

local function trim(text)
    return (text:match("^%s*(.-)%s*$"))
end

--- Turns a username into the number the feed needs.
-- goodreads.com/<name> answers 301 towards /user/show/<number>-<name>, so a
-- HEAD request is enough and never fetches a page.
local function resolveUsername(name)
    socketutil:set_timeout()
    local _, _, headers = http.request{
        url = "https://www.goodreads.com/" .. name,
        method = "HEAD",
        redirect = false,
    }
    socketutil:reset_timeout()
    if type(headers) ~= "table" or type(headers.location) ~= "string" then return nil end
    return headers.location:match("/user/show/(%d+)")
end

--- Works out whose shelf to read, from whatever was typed: a user number, a
-- username, a profile address, or a whole feed address.
-- Returns the number and, when a feed address carried one, its private key.
-- Only a username costs a request; every other form is read on the spot.
function Shelf.findUser(typed)
    typed = trim(typed or "")
    if typed == "" then return nil end
    -- A feed address is the only form that can carry a key, which a private
    -- shelf needs.
    local from_feed = typed:match("/review/list_rss/(%d+)")
    if from_feed then return from_feed, typed:match("[?&]key=([^&]+)") end
    local from_profile = typed:match("/user/show/(%d+)")
    if from_profile then return from_profile end
    if typed:match("^%d+$") then return typed end
    return resolveUsername(typed)
end

--- The shelf as the feed wants it. Goodreads spells "everything" as "#ALL#",
-- which has to be escaped; anything else is a plain shelf name.
function Shelf.encodeShelf(name)
    name = trim(name or "")
    if name == "" or name:lower() == "all" then return "%23ALL%23" end
    return (name:gsub("[^%w%-_]", function(char)
        return string.format("%%%02X", string.byte(char))
    end))
end

-- `sort` is a Goodreads ordering name, or nil for its default, which lists the
-- books newest-added first. Asking for "date_added" by name is not the same
-- thing: it agrees at the start but drifts apart deeper in the shelf, so when
-- we want the default order we say nothing at all.
local function feedPageUrl(user_id, key, shelf, sort, page)
    return string.format(
        "https://www.goodreads.com/review/list_rss/%s?shelf=%s&page=%d%s%s",
        user_id, shelf or "%23ALL%23", page,
        key and ("&key=" .. key) or "",
        sort and ("&sort=" .. sort) or "")
end

local HTML_ENTITIES = { quot = '"', apos = "'", lt = "<", gt = ">", amp = "&", nbsp = " " }

local function decodeEntities(text)
    text = text:gsub("&#(%d+);", function(code)
        code = tonumber(code)
        -- Plain ASCII only; anything else is left alone rather than mangled.
        return code < 128 and string.char(code) or nil
    end)
    return (text:gsub("&(%a+);", HTML_ENTITIES))
end

--- The text of one tag inside a feed item, unwrapped from CDATA if need be.
local function tagText(item, tag)
    local text = item:match("<" .. tag .. "[^>]*>(.-)</" .. tag .. ">")
    if not text then return nil end
    text = trim(text:match("^%s*<!%[CDATA%[(.-)%]%]>%s*$") or text)
    return text ~= "" and decodeEntities(text) or nil
end

--- Goodreads writes descriptions in HTML; the detail page wants readable text.
local function asPlainText(html)
    if not html then return nil end
    local text = trim(html:gsub("<br%s*/?>", "\n"):gsub("<[^>]->", ""))
    if text == "" then return nil end
    if #text > MAX_DESCRIPTION then text = text:sub(1, MAX_DESCRIPTION) .. "…" end
    return text
end

--- Turns one feed page into book records.
-- Pure: it only reads the string it is given.
function Shelf.parsePage(feed_xml)
    local books = {}
    for item in feed_xml:gmatch("<item>(.-)</item>") do
        local full_title = tagText(item, "title")
        if full_title then
            table.insert(books, {
                id      = tagText(item, "book_id"),
                -- A title ends with "(Some Series, #2)" when the book is
                -- part of one: show the series on its own line instead.
                title   = trim(full_title:gsub("%s*%(.-#%d+%)%s*$", "")),
                series  = full_title:match("%((.-#%d+)%)%s*$"),
                author  = tagText(item, "author_name"),
                pages   = tagText(item, "num_pages"),
                year    = tagText(item, "book_published"),
                rating  = tagText(item, "average_rating"),
                shelves = tagText(item, "user_shelves"),
                image   = tagText(item, "book_large_image_url"),
                description = asPlainText(tagText(item, "book_description")),
            })
        end
    end
    return books
end

-- Some cover addresses end with size markers -- "._SX318_.jpg", sometimes
-- "._SX318_SY475_.jpg" -- and those we can swap for the width we want. The
-- rest end with nothing, and serve one fixed image: appending a marker is
-- silently ignored (same bytes back), and the "m" folder that would hold a
-- smaller copy is missing about a third of the time, answering 403. So an
-- address without markers is used exactly as it is.
local SIZED_ENDING = "%._S[XY]%d+_[%w_]*%.jpg$"

--- The cover URL to store for a book, or nothing when there is no cover to
-- fetch: Goodreads answers those with a grey stand-in, and we have our own.
function Shelf.coverUrl(book)
    if not book.image or book.image:find("/nophoto/", 1, true) then return nil end
    -- gsub leaves an address without markers untouched, which is what we want.
    return (book.image:gsub(SIZED_ENDING, "._SX" .. COVER_WIDTH .. "_.jpg"))
end

-- Downloading ---------------------------------------------------------------

--- Fetches one address, returning its body, or nothing if that failed.
-- How long to wait depends on what is coming. A cover is a few tens of
-- kilobytes and arrives at once. A feed page is around 400kB, and Goodreads
-- slows down the further into a shelf you read -- measured at 0.5s for page 3
-- but 8s for page 50, on a fast line -- so those get the allowance meant for
-- file downloads. Too short an allowance simply ends the sync early.
local function download(url, block_timeout, total_timeout)
    local body = {}
    socketutil:set_timeout(block_timeout, total_timeout)
    local code = socket.skip(1, http.request{ url = url, sink = ltn12.sink.table(body) })
    socketutil:reset_timeout()
    return code == 200 and table.concat(body) or nil
end

local function writeFile(path, content)
    local file = io.open(path, "wb")
    if not file then return false end
    file:write(content)
    file:close()
    return true
end

-- Both downloads below call `report` as they go and stop early if it returns
-- false. The feed cannot say how many pages it has, so it reports the page it
-- is on and the books found so far; covers report a plain count out of a total.

--- Walks the shelf one page at a time, handing each page's XML to `readPage`,
-- which returns how many books it found there.
-- Returns whether the whole shelf was read. A page that fails to arrive looks
-- exactly like the short final page, so without that answer a single timeout
-- would quietly pass for the end of the shelf.
local function walkShelf(user_id, key, shelf, sort, report, readPage)
    for page = 1, MAX_FEED_PAGES do
        if report(page) == false then return false end
        local feed_xml = download(feedPageUrl(user_id, key, shelf, sort, page),
            socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
        if not feed_xml then return false end
        -- A short page means we have reached the end of the shelf.
        if readPage(feed_xml) < BOOKS_PER_FEED_PAGE then return true end
    end
    return true
end

--- Reads every book on the shelf.
-- Returns the books and whether the whole shelf was read.
function Shelf.fetchBooks(user_id, key, shelf, report)
    local books = {}
    local whole_shelf = walkShelf(user_id, key, shelf, nil,
        function(page) return report(page, #books) end,
        function(feed_xml)
            local page_books = Shelf.parsePage(feed_xml)
            for _unused, book in ipairs(page_books) do
                table.insert(books, book)
            end
            return #page_books
        end)
    return books, whole_shelf
end

-- Goodreads' own web app reads book statistics from this GraphQL endpoint,
-- using a key it ships publicly; BiblioReads relies on the same one. The RSS
-- feed carries no ratings count at all, and this is the only place that gives
-- one. It is undocumented, so it may stop working without notice: a failure
-- here leaves the books untouched and only costs the "most rated" order.
local RATINGS_URL =
    "https://kxbwmqov6jgg3daaamb744ycu4.appsync-api.us-east-1.amazonaws.com/graphql"
local RATINGS_KEY = "da2-d2fyuybwsbf3poyquvbp2mbiwu"

--- Asks for the ratings counts of one batch of books.
-- Returns a list lining up with `books`, or nothing if the call failed.
local function requestRatings(books)
    local asks = {}
    for index, book in ipairs(books) do
        -- One aliased query per book, so a single call answers for all of them.
        asks[index] = string.format(
            "b%d:getBookByLegacyId(legacyId:%s){work{stats{ratingsCount}}}", index, book.id)
    end
    local body = rapidjson.encode({ query = "query{" .. table.concat(asks, " ") .. "}" })

    local sink = {}
    socketutil:set_timeout()
    local code = socket.skip(1, http.request{
        url = RATINGS_URL,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json",
            ["Content-Length"] = tostring(#body),
            ["X-Api-Key"] = RATINGS_KEY,
        },
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(sink),
    })
    socketutil:reset_timeout()
    if code ~= 200 then return nil end

    local decoded, answer = pcall(rapidjson.decode, table.concat(sink))
    if not decoded or type(answer) ~= "table" or type(answer.data) ~= "table" then
        return nil
    end
    local counts, found_any = {}, false
    for index = 1, #books do
        -- A book Goodreads no longer knows about answers with null.
        local found = answer.data["b" .. index]
        if type(found) == "table" and type(found.work) == "table"
                and type(found.work.stats) == "table" then
            counts[index] = found.work.stats.ratingsCount
            found_any = true
        end
    end
    -- A whole batch without a single count means the answer is not what we
    -- expect any more. Better to stop than to quietly order the library on
    -- nothing at all.
    if not found_any then return nil end
    return counts
end

--- Fills in how many ratings each book has.
-- Returns whether the whole library came back; the books are left as they were
-- if not, so a half-answered run cannot order the library on partial figures.
function Shelf.fetchRatings(books, report)
    local counted = {}
    local done = 0
    while done < #books do
        if report(done, #books) == false then return false end
        local batch = {}
        for index = done + 1, math.min(done + BOOKS_PER_RATINGS_CALL, #books) do
            table.insert(batch, books[index])
        end
        local counts = requestRatings(batch)
        if not counts then return false end
        for index = 1, #batch do
            counted[done + index] = counts[index]
        end
        done = done + #batch
    end
    for index, book in ipairs(books) do
        book.ratings = counted[index]
    end
    return true
end

--- Downloads the covers that are not on the device yet.
function Shelf.fetchCovers(books, report)
    util.makePath(coversPath())
    for index, book in ipairs(books) do
        if report(index, #books) == false then break end
        if not hasCover(book) then
            local url = Shelf.coverUrl(book)
            local image = url and download(url)
            if image then
                writeFile(Shelf.coverPath(book), image)
            end
        end
    end
end

-- Storing -------------------------------------------------------------------

function Shelf.save(books)
    return writeFile(libraryPath(), "return " .. dump(books))
end

--- The books stored by the last sync, or an empty list before the first one.
function Shelf.load()
    local read_library = loadfile(libraryPath())
    return read_library and read_library() or {}
end

-- Looking through the books -------------------------------------------------
-- All pure: they take a list of books and return a new one.

local function shelvesOf(book)
    local shelves = {}
    for shelf in (book.shelves or ""):gmatch("[^,]+") do
        table.insert(shelves, trim(shelf))
    end
    return shelves
end

--- Every shelf name with how many books it holds, fullest first.
function Shelf.shelves(books)
    local counts = {}
    for _, book in ipairs(books) do
        for _, shelf in ipairs(shelvesOf(book)) do
            counts[shelf] = (counts[shelf] or 0) + 1
        end
    end
    local shelves = {}
    for name, count in pairs(counts) do
        table.insert(shelves, { name = name, count = count })
    end
    table.sort(shelves, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        return a.name < b.name
    end)
    return shelves
end

--- The books filed under one shelf.
function Shelf.onShelf(books, shelf)
    local found = {}
    for _, book in ipairs(books) do
        for _, name in ipairs(shelvesOf(book)) do
            if name == shelf then
                table.insert(found, book)
                break
            end
        end
    end
    return found
end

--- How to compare two books for each order we offer.
-- There is no entry for "recent": the feed arrives newest-added first, so that
-- order is simply the one we stored, and needs no dates to compare.
local COMPARE_FOR = {
    title  = function(a, b) return (a.title or "") < (b.title or "") end,
    author = function(a, b) return (a.author or "") < (b.author or "") end,
    rating = function(a, b) return (tonumber(a.rating) or 0) > (tonumber(b.rating) or 0) end,
    -- Most rated first; a book we have no count for goes last.
    ratings = function(a, b) return (a.ratings or 0) > (b.ratings or 0) end,
}

--- The books in the given order, as a new list.
function Shelf.sorted(books, order)
    local compare = COMPARE_FOR[order]
    if not compare then return books end
    local ordered = {}
    for index, book in ipairs(books) do
        ordered[index] = book
    end
    table.sort(ordered, compare)
    return ordered
end

--- The books whose title or author contains `text`, whatever the case.
function Shelf.matching(books, text)
    local wanted = text:lower()
    local found = {}
    for _, book in ipairs(books) do
        local haystack = ((book.title or "") .. " " .. (book.author or "")):lower()
        if haystack:find(wanted, 1, true) then
            table.insert(found, book)
        end
    end
    return found
end

return Shelf
