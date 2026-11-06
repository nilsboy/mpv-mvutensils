-- Toggle MVUtensils frame interpolation at runtime.
--
-- Adds or removes the vapoursynth filter bound to the bundled mvutensils.vpy
-- script. Configure with script-opts, e.g. in mpv.conf:
--   script-opts=mvu-toggle-vpy=/path/to/mvutensils.vpy
-- or in script-opts/mvu-toggle.conf:
--   vpy=/path/to/mvutensils.vpy

local mp = require "mp"
local msg = require "mp.msg"
local utils = require "mp.utils"
local opts = require "mp.options"

local options = {
    vpy = "",
    label = "mvu",
}

opts.read_options(options, "mvu-toggle")

local enabled = false

local function script_path()
    local info = debug.getinfo(1, "S")
    local dir = info.source:match("@?(.*/)")
    return dir or "./"
end

local function resolve_vpy()
    if options.vpy ~= "" then
        return options.vpy
    end
    -- Default to vapoursynth/mvutensils.vpy at the root of the repo or snap.
    return utils.join_path(script_path(), "../../vapoursynth/mvutensils.vpy")
end

local function toggle()
    if enabled then
        mp.commandv("vf", "remove", "@" .. options.label)
        enabled = false
        mp.osd_message("MVUtensils: off")
        return
    end

    local vpy = resolve_vpy()
    if not utils.file_info(vpy) then
        msg.error("mvutensils.vpy not found: " .. vpy)
        mp.osd_message("MVUtensils: script not found", 3)
        return
    end

    mp.commandv("vf", "add", "@" .. options.label .. ":vapoursynth=" .. vpy)
    enabled = true
    mp.osd_message("MVUtensils: on")
end

mp.add_key_binding(nil, "toggle-mvu", toggle)
mp.register_script_message("toggle-mvu", toggle)
