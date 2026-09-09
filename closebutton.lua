--[[--
KOReader removed `ui/widget/closebutton` in 2023, but this plugin's two windows
draw their own title bar and still need the "×" that closes them. This is the
modern equivalent, built the way TitleBar builds its own.

`allow_flash` is off on purpose. A button normally highlights itself, redraws,
then runs its callback. When that callback closes the very window the button
sits in, the redraw lands on a window that no longer exists: it stays on screen
until some later tap forces a repaint. KOReader says as much where the option
is declared -- "set to false for any IconButton that may close its container".
]]

local IconButton = require("ui/widget/iconbutton")
local Size = require("ui/size")

--- An "×" at the right end of a title bar, closing `window` when tapped.
-- The padding keeps it off the screen edges, where it would look clipped, and
-- widens the tap area towards the middle of the bar.
return function(window)
    return IconButton:new{
        icon = "close",
        overlap_align = "right",
        allow_flash = false,
        show_parent = window,
        padding = Size.padding.large,
        callback = function() window:onClose() end,
    }
end
