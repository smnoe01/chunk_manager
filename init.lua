local S = core.get_translator("chunk_manager")
local version = "1.0.4"
local src_path = core.get_modpath("chunk_manager") .. "/src"

dofile(src_path .. "/api.lua")

core.log("action", "[CHUNK PERFORM] Mod initialised, running version " .. version)
