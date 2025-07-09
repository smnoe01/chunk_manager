--[[
    Chunk Manager - Preloader Configuration
    This file is part of the Chunk Manager mod for Luanti.
    It provides a formspec interface for configuring preloader settings.
                            [Disable]
--]]

local modname = core.get_current_modname()
local S = core.get_translator(modname)

local config_keys = {
    "view_distance", "emergency_view_distance", "max_cache_size", "emergency_cache_size",
    "prediction_interval", "emergency_prediction_interval", "timeout_threshold",
    "queue_size_threshold", "cache_miss_threshold", "emergence_time_threshold",
    "thermal_decay", "compression_threshold", "max_timeouts", "suspend_duration",
    "batch_size", "batch_interval", "unload_timeout", "max_players_reduction",
    "max_emergence_times", "thermal_decay_interval", "compression_batch_size",
    "max_operations_per_tick",
}

local function load_config()
    for _, key in ipairs(config_keys) do
        preloader.config[key] = tonumber(core.settings:get(key)) or preloader.config[key]
    end
    preloader.config.async_processing = core.settings:get_bool("async_processing") or preloader.config.async_processing
end

local function save_config()
    for key, value in pairs(preloader.config) do
        if type(value) == "boolean" then
            core.settings:set_bool(key, value)
        else
            core.settings:set(key, tostring(value))
        end
    end
    core.settings:write()
end

local function reset_config()
    preloader.config = table.copy(preloader.config)
end

local function build_formspec()
    local c = preloader.config
    return string.format([[
        size[14,16]
        label[0.5,0.5;%s]
        button_exit[11,0.2;2.5,0.8;close;%s]
        
        label[0,1.8;%s:]field[4.5,2;2,0.8;view_distance;;%g]
        label[7,1.8;%s:]field[12,2;2,0.8;emergency_view_distance;;%g]
        label[0,2.6;%s:]field[4.5,2.8;2,0.8;max_cache_size;;%g]
        label[7,2.6;%s:]field[12,2.8;2,0.8;emergency_cache_size;;%g]

        label[0,4.37;%s:]field[4.5,4.5;2,0.8;prediction_interval;;%g]
        label[7,4.37;%s:]field[12,4.5;2,0.8;emergency_prediction_interval;;%g]
        label[0,5.1;%s:]field[4.5,5.3;2,0.8;thermal_decay_interval;;%g]
        label[7,5.1;%s:]field[12,5.3;2,0.8;batch_interval;;%g]
        
        label[0,6.8;%s:]field[4.5,7;2,0.8;timeout_threshold;;%g]
        label[7,6.8;%s:]field[12,7;2,0.8;queue_size_threshold;;%g]
        label[0,7.6;%s:]field[4.5,7.8;2,0.8;cache_miss_threshold;;%g]
        label[7,7.6;%s:]field[12,7.8;2,0.8;emergence_time_threshold;;%g]
        label[0,8.4;%s:]field[4.5,8.6;2,0.8;compression_threshold;;%g]
        label[7,8.4;%s:]field[12,8.6;2,0.8;thermal_decay;;%g]
        
        label[0,10.1;%s:]field[4.5,10.3;2,0.8;max_timeouts;;%g]
        label[7,10.1;%s:]field[12,10.3;2,0.8;suspend_duration;;%g]
        label[0,10.9;%s:]field[4.5,11.1;2,0.8;batch_size;;%g]
        label[7,10.9;%s:]field[12,11.1;2,0.8;unload_timeout;;%g]
        label[0,11.7;%s:]field[4.5,11.9;2,0.8;max_players_reduction;;%g]
        label[7,11.7;%s:]field[12,11.9;2,0.8;max_emergence_times;;%g]
        label[0,12.5;%s:]field[4.5,12.7;2,0.8;compression_batch_size;;%g]
        label[7,12.5;%s:]field[12,12.7;2,0.8;max_operations_per_tick;;%g]
        
        label[0,14.45;%s:]checkbox[3.5,14.3;async_processing;%s;%s]
        
        button[0.5,15.2;2.5,0.8;save;%s]
        button[3.5,15.2;2.5,0.8;reset;%s]
        button[6.5,15.2;2.5,0.8;reload;%s]
        button[9.5,15.2;2.5,0.8;apply;%s]
    ]], 
        S("Chunk Manager - Preloader Configuration"),
        S("Close"),
        S("View Distance"), c.view_distance,
        S("Emergency Distance"), c.emergency_view_distance,
        S("Max Cache Size"), c.max_cache_size,
        S("Emergency Cache"), c.emergency_cache_size,
        S("Prediction Interval"), c.prediction_interval,
        S("Emergency Prediction"), c.emergency_prediction_interval,
        S("Decay Interval"), c.thermal_decay_interval,
        S("Batch Interval"), c.batch_interval,
        S("Timeout Threshold"), c.timeout_threshold,
        S("Queue Size Threshold"), c.queue_size_threshold,
        S("Cache Miss Threshold"), c.cache_miss_threshold,
        S("Emergence Time Threshold"), c.emergence_time_threshold,
        S("Compression Threshold"), c.compression_threshold,
        S("Thermal Decay"), c.thermal_decay,
        S("Max Timeouts"), c.max_timeouts,
        S("Suspend Duration"), c.suspend_duration,
        S("Batch Size"), c.batch_size,
        S("Unload Timeout"), c.unload_timeout,
        S("Max Players Reduction"), c.max_players_reduction,
        S("Max Emergence Times"), c.max_emergence_times,
        S("Compression Batch Size"), c.compression_batch_size,
        S("Max Operations Per Tick"), c.max_operations_per_tick,
        S("Async Processing"), S("Enable"), c.async_processing and "true" or "false",
        S("Save"), S("Reset"), S("Reload"), S("Apply")
    )
end

local function update_config_from_fields(fields)
    for _, key in ipairs(config_keys) do
        if fields[key] then
            local value = tonumber(fields[key])
            if value then
                preloader.config[key] = value
            end
        end
    end

    if fields.async_processing then
        preloader.config.async_processing = fields.async_processing == "true"
    end
end

core.register_on_player_receive_fields(function(player, formname, fields)
    if formname ~= "chunk_manager" then return end
    local name = player:get_player_name()

    if not core.check_player_privs(name, {server=true}) then
        core.chat_send_player(name, S("You don't have the necessary privileges to modify this configuration."))
        return
    end

    if fields.save then
        update_config_from_fields(fields)
        save_config()
        core.chat_send_player(name, S("Configuration saved successfully!"))

    elseif fields.reset then
        reset_config()
        core.show_formspec(name, "chunk_manager", build_formspec())
        core.chat_send_player(name, S("Configuration reset to default values."))

    elseif fields.reload then
        load_config()
        core.show_formspec(name, "chunk_manager", build_formspec())
        core.chat_send_player(name, S("Configuration reloaded from settings."))

    elseif fields.apply then
        update_config_from_fields(fields)
        core.chat_send_player(name, S("Configuration applied temporarily (not saved)."))
    end
end)

core.register_chatcommand("chunk_manager", {
    description = S("Open chunk management interface"),
    privs = {server = true},
    func = function(name, param)
        local player = core.get_player_by_name(name)
        if not player then
            return false, S("Player not found.")
        end

        core.show_formspec(name, "chunk_manager", build_formspec())
        return true, S("Chunk management interface opened.")
    end,
})

core.register_chatcommand("chunk_status", {
    description = S("Display current preloader configuration"),
    privs = {server = true},
    func = function(name, param)
        local status = S("=== Preloader Configuration ===") .. "\n"
        for key, value in pairs(preloader.config) do
            status = status .. key .. ": " .. tostring(value) .. "\n"
        end
        return true, status
    end,
})

load_config()