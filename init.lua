local modname = core.get_current_modname()

local version = "2.0.2.1"
local src_path = core.get_modpath(modname) .. "/src"

dofile(src_path .. "/api.lua")

core.log("action", "[Chunk Manager] Mod initialised, running version " .. version)

--[[

GNU Lesser General Public License, version 2.1
Copyright (C) Atlante(Smnoe01) <AtlanteWork@gmail.com>

GNU LESSER GENERAL PUBLIC LICENSE

Version 2.1, February 1999

--]]