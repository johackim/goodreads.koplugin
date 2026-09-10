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

local BOOKS_PER_FEED_PAGE = 100     -- what Goodreads gives us per page
local MAX_FEED_PAGES = 200          -- a stop, should the feed never run short
local MAX_DESCRIPTION = 1200        -- descriptions are most of the file's weight
local COVER_WIDTH = 318             -- the widest Goodreads serves, and only ~20kB
local BOOKS_PER_RATINGS_CALL = 100  -- 200 in one call is refused by their firewall
local TRIES_PER_REQUEST = 3         -- a weak connection drops the odd request

-- Our own files sit next to this one. A plugin installed by hand is not
-- under the KOReader folder, so a fixed path would not find them.
local PLUGIN_DIR = debug.getinfo(1, "S").source:match("^@?(.*)/[^/]*$")

local Shelf = {}

-- Where things are kept on the device ---------------------------------------

local function libraryPath()
    return DataStorage:getSettingsDir() .. "/goodreads_library.lua"
end

local function coversPath()
    return DataStorage:getDataDir() .. "/cache/goodreads_covers"
end

local function coverPath(book)
    return coversPath() .. "/" .. book.id .. ".jpg"
end

local function hasCover(book)
    return lfs.attributes(coverPath(book), "mode") == "file"
end

--- The image to show for a book: the cover we downloaded, or the stand-in
-- shipped with the plugin when we have none. Both views use this, so a book
-- without a cover looks the same everywhere.
function Shelf.coverFile(book)
    if hasCover(book) then return coverPath(book) end
    return PLUGIN_DIR .. "/goodreadsnophoto.png"
end

-- Reading the feed ----------------------------------------------------------

local function trim(text)
    return (text:match("^%s*(.-)%s*$"))
end

--- Turns a username into the number the feed needs.
-- goodreads.com/<name> answers 301 towards /user/show/<number>-<name>, so a
-- HEAD request is enough and never fetches a page.
-- The default allowance is far too short here: no body comes back, but an
-- e-reader still needs seconds to look up the name and shake hands over TLS.
local function resolveUsername(name)
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
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

-- We never name an ordering: left alone the feed lists the books newest-added
-- first, which is the order we want and the one the early stop relies on.
-- Asking for "date_added" by name is not the same thing -- it agrees at the
-- start but drifts apart deeper in the shelf.
local function feedPageUrl(user_id, key, shelf, page)
    return string.format(
        "https://www.goodreads.com/review/list_rss/%s?shelf=%s&page=%d%s",
        user_id, shelf, page,
        key and ("&key=" .. key) or "")
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
local function parsePage(feed_xml)
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

-- Downloading ---------------------------------------------------------------

--- Fetches one address, returning its body, or nothing if that failed.
-- How long to wait depends on what is coming, so every caller says: the
-- default LuaSocket allows (5s to connect, 15s in all) is too short for an
-- e-reader on Wi-Fi, and too short an allowance simply ends the sync early.
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

--- The ids of a list of books, to look one up by.
local function idsOf(books)
    local ids = {}
    for _unused, book in ipairs(books) do
        ids[book.id] = true
    end
    return ids
end

-- The three passes below all call `report` as they go and stop early if it
-- returns false, which is how a tap on the screen stops a sync.

--- Reads the shelf, newest addition first.
--
-- It stops at the first page holding nothing `stored_books` does not already
-- have: the feed is ordered by when each book was added, so everything past
-- such a page is older still and already on the device. That turns a re-sync
-- from fifty pages into one. Pass an empty list to read the whole shelf.
--
-- A feed page is around 400kB, and Goodreads slows down the further into a
-- shelf you read -- measured at 0.5s for page 3 but 8s for page 50, on a fast
-- line -- so pages get the allowance meant for file downloads, and a page
-- that does not come is asked for again: a failed page looks exactly like the
-- short final page, so without retrying a single timeout would quietly pass
-- for the end of the shelf.
--
-- Returns the books read, whether the whole shelf came through, and when it
-- did not, why: "stopped" when the reader asked, "failed" when a page would
-- not come. Saying which matters -- one is a choice, the other a fault.
function Shelf.fetchBooks(user_id, key, shelf, report, stored_books)
    local known_ids = idsOf(stored_books)
    local books = {}
    for page = 1, MAX_FEED_PAGES do
        local feed_xml
        for _try = 1, TRIES_PER_REQUEST do
            if report(page, #books) == false then return books, false, "stopped" end
            feed_xml = download(feedPageUrl(user_id, key, shelf, page),
                socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
            if feed_xml then break end
        end
        if not feed_xml then return books, false, "failed" end

        local page_books = parsePage(feed_xml)
        local fresh = 0
        for _unused, book in ipairs(page_books) do
            table.insert(books, book)
            if not known_ids[book.id] then fresh = fresh + 1 end
        end
        -- A short page is the end of the shelf; a page with nothing new on it
        -- means the rest of the shelf is older still, and already stored.
        if #page_books < BOOKS_PER_FEED_PAGE or fresh == 0 then return books, true end
    end
    return books, true
end

--- The freshly read books, followed by the stored ones they do not replace.
-- Both lists are newest-first, so the result stays in that order.
function Shelf.merged(fresh, stored)
    local seen = idsOf(fresh)
    local all = {}
    for _unused, book in ipairs(fresh) do
        table.insert(all, book)
    end
    for _unused, book in ipairs(stored) do
        if not seen[book.id] then table.insert(all, book) end
    end
    return all
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
-- Returns a list lining up with `books`, or nil and a short reason. The
-- reason matters: this endpoint is undocumented, so when it stops answering
-- the reader should be told what it said rather than just that it failed.
local function requestRatings(books)
    local asks = {}
    for index, book in ipairs(books) do
        -- One aliased query per book, so a single call answers for all of them.
        asks[index] = string.format(
            "b%d:getBookByLegacyId(legacyId:%s){work{stats{ratingsCount}}}", index, book.id)
    end
    local body = rapidjson.encode({ query = "query{" .. table.concat(asks, " ") .. "}" })

    local sink = {}
    -- Each call opens a fresh TLS connection, and an e-reader's processor is
    -- slow at that handshake: too short an allowance ends it with "wantread"
    -- before it completes. This is the allowance the feed already needs.
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
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
    if code ~= 200 then return nil, tostring(code) end

    local reply = table.concat(sink)
    if reply == "" then return nil, "empty answer" end
    local decoded, answer = pcall(rapidjson.decode, reply)
    if not decoded or type(answer) ~= "table" then return nil, "unreadable answer" end
    if type(answer.data) ~= "table" then
        -- GraphQL puts its complaints in "errors".
        local complaint = answer.errors and answer.errors[1]
        return nil, complaint and tostring(complaint.message or complaint.errorType) or "no data"
    end
    local counts = {}
    for index = 1, #books do
        local found = answer.data["b" .. index]
        if type(found) == "table" and type(found.work) == "table"
                and type(found.work.stats) == "table" then
            counts[index] = found.work.stats.ratingsCount
        end
    end
    -- A book Goodreads has dropped or merged answers with null, and says so
    -- in "errors" beside the data: that is a good answer about a bad book,
    -- and costs that book its count and nothing more. Those books gather at
    -- the end of the list, having never been counted, so a whole batch of
    -- them is normal and must not read as a failure.
    -- A batch that answers nothing with nothing to explain it is another
    -- matter: the endpoint is undocumented, and an answer we no longer
    -- understand is better stopped on than quietly ordered by.
    if next(counts) == nil and not answer.errors then return nil, "no counts in answer" end
    return counts
end

--- Fills in how many ratings each book has.
-- Returns whether the whole library came back, and when it did not, why, in
-- the same words fetchBooks uses. The books are left as they were unless it
-- did, so a half-answered run cannot order the library on partial figures.
function Shelf.fetchRatings(books, report)
    local counted = {}
    local done = 0
    while done < #books do
        if report(done, #books) == false then return false, "stopped" end
        local batch = {}
        for index = done + 1, math.min(done + BOOKS_PER_RATINGS_CALL, #books) do
            table.insert(batch, books[index])
        end
        local counts, why
        for _try = 1, TRIES_PER_REQUEST do
            counts, why = requestRatings(batch)
            if counts then break end
            if report(done, #books) == false then return false, "stopped" end
        end
        if not counts then return false, why end
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

-- Some cover addresses end with size markers -- "._SX318_.jpg", sometimes
-- "._SX318_SY475_.jpg" -- and those we can swap for the width we want. The
-- rest end with nothing, and serve one fixed image: appending a marker is
-- silently ignored (same bytes back), and the "m" folder that would hold a
-- smaller copy is missing about a third of the time, answering 403. So an
-- address without markers is used exactly as it is.
local SIZED_ENDING = "%._S[XY]%d+_[%w_]*%.jpg$"

--- The cover address to fetch for a book, or nothing when there is no cover:
-- Goodreads answers those with a grey stand-in, and we have our own.
local function coverUrl(book)
    if not book.image or book.image:find("/nophoto/", 1, true) then return nil end
    -- gsub leaves an address without markers untouched, which is what we want.
    return (book.image:gsub(SIZED_ENDING, "._SX" .. COVER_WIDTH .. "_.jpg"))
end

--- Downloads the covers that are not on the device yet.
function Shelf.fetchCovers(books, report)
    util.makePath(coversPath())
    for index, book in ipairs(books) do
        if report(index, #books) == false then break end
        if not hasCover(book) then
            local url = coverUrl(book)
            local image = url and download(url,
                socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
            if image then
                writeFile(coverPath(book), image)
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
    for _unused, book in ipairs(books) do
        for _unused2, shelf in ipairs(shelvesOf(book)) do
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
    for _unused, book in ipairs(books) do
        for _unused2, name in ipairs(shelvesOf(book)) do
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
    for _unused, book in ipairs(books) do
        local haystack = ((book.title or "") .. " " .. (book.author or "")):lower()
        if haystack:find(wanted, 1, true) then
            table.insert(found, book)
        end
    end
    return found
end

return Shelf
