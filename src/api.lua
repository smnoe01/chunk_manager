local S = core.get_translator("chunk_manager")

local chunk_manager = {}

local CONFIG = {
    max_emerges_per_step = tonumber(core.settings:get("max_emerges_per_step")) or 3, -- Maximum number of emerges per globalstep
    cache_timeout = tonumber(core.settings:get("cache_timeout")) or 30, -- Cache timeout in seconds
    cleanup_interval = tonumber(core.settings:get("cleanup_interval")) or 100, -- cleanup interval in globalsteps
    prediction_distance = tonumber(core.settings:get("prediction_distance")) or 75, -- Distance to predict chunk loads
    min_velocity_threshold = tonumber(core.settings:get("min_velocity_threshold")) or 0.5, -- Minimum velocity to consider for prediction
    max_cache_size = tonumber(core.settings:get("max_cache_size")) or 1000, -- Maximum number of cached chunks
    chunk_unload_timeout = tonumber(core.settings:get("chunk_unload_timeout")) or 60, -- seconds
    unload_check_interval = tonumber(core.settings:get("unload_check_interval")) or 30, -- seconds
    emerge_timeout = tonumber(core.settings:get("emerge_timeout")) or 10.0, -- emerge timeout in seconds
    emerge_timeout_threshold = tonumber(core.settings:get("emerge_timeout_threshold")) or 3, -- number of timeouts before suspension
    view_range_players = {
        low = {max = tonumber(core.settings:get("view_range_low_max")) or 10, range = tonumber(core.settings:get("view_range_low_range")) or 3}, -- low player count
        medium = {max = tonumber(core.settings:get("view_range_medium_max")) or 5, range = tonumber(core.settings:get("view_range_medium_range")) or 5}, -- medium player count
        high = {max = tonumber(core.settings:get("view_range_high_max")) or 0, range = tonumber(core.settings:get("view_range_high_range")) or 8}, -- high player count
    },
    extreme_load_thresholds = { -- thresholds for emergency mode activation
        velocity_threshold = tonumber(core.settings:get("extreme_velocity_threshold")) or 2.0, -- velocity threshold for high load
        emergency_cache_size = tonumber(core.settings:get("emergency_cache_size")) or 500, -- cache size during emergency mode
        emergency_emerges_per_step = tonumber(core.settings:get("emergency_emerges_per_step")) or 1, --  maximum emerges per step during emergency mode
        throttle_prediction = core.settings:get_bool("throttle_prediction") or true, -- throttle prediction during emergency mode
        queue_size_threshold = tonumber(core.settings:get("queue_size_threshold")) or 25, -- queue size threshold for high load
        emerge_time_threshold = tonumber(core.settings:get("emerge_time_threshold")) or 5.0, -- emerge time threshold for high load
        cache_miss_ratio = tonumber(core.settings:get("cache_miss_ratio")) or 0.7, -- cache miss ratio threshold for high load
        max_processing_time = tonumber(core.settings:get("max_processing_time")) or 0.05, -- maximum processing time per step in seconds
        consecutive_overload_threshold = tonumber(core.settings:get("consecutive_overload_threshold")) or 3, -- number of consecutive overloads before emergency mode
        emergence_timeout_threshold = tonumber(core.settings:get("emergence_timeout_threshold")) or 8.0 -- emergence timeout threshold in seconds
    }
}

local chunk_cache = {}
local emerge_queue = {}
local player_data = {}
local cleanup_counter = 0
local cache_size = 0
local loaded_chunks = {}
local unload_counter = 0
local pending_emerges = {}
local emerge_timeouts = 0
local emerge_pause_enabled = false
local manual_emergency_mode = false

local system_load = {
    high_velocity_players = 0,
    total_emerges_queued = 0,
    last_load_check = 0,
    emergency_mode = false,
    processing_times = {},
    emerge_times = {},
    cache_hits = 0,
    cache_misses = 0,
    consecutive_overload = 0,
    last_emerge_start = 0,
    emergence_suspended = false,
    suspension_reason = "",
    suspension_start = 0
}

local spatial_prediction = {
    look_ahead_multiplier = 2.5,
    side_prediction_angle = 45, -- degrees
    vertical_prediction_range = 32,
    direction_cache = {}
}

local priority_system = {
    CRITICAL = 5,    -- player chunk
    HIGH = 4,        -- look direction
    MEDIUM = 3,      -- mouvement prediction
    LOW = 2,         -- Lateral prediction 
    BACKGROUND = 1   -- general preload
}

local batch_system = {
    max_batch_size = 4,
    batch_queue = {},
    processing_batch = false,
    batch_timeout = 5.0 -- secondes
}

local smart_cache = {
    compression_threshold = 1024, -- bytes
    access_patterns = {},
    prediction_cache = {},
    thermal_data = {}
}



local function get_chunk_pos(pos)
    return {
        x = math.floor(pos.x / 16) * 16,
        y = math.floor(pos.y / 16) * 16,
        z = math.floor(pos.z / 16) * 16
    }
end


local function get_cache_key(pos)
    return string.format("%d,%d,%d",
        math.floor(pos.x / 16),
        math.floor(pos.y / 16),
        math.floor(pos.z / 16)
    )
end


local function track_chunk_load(pos)
    local chunk_pos = get_chunk_pos(pos)
    local key = get_cache_key(chunk_pos)
    loaded_chunks[key] = {
        pos = chunk_pos,
        last_access = core.get_us_time(),
        load_time = core.get_us_time()
    }
end


local function update_chunk_access(pos)
    local chunk_pos = get_chunk_pos(pos)
    local key = get_cache_key(chunk_pos)
    if loaded_chunks[key] then
        loaded_chunks[key].last_access = core.get_us_time()
    end
end


local function is_chunk_near_players(chunk_pos, max_distance)
    max_distance = max_distance or 80

    for _, player in ipairs(core.get_connected_players()) do
        local player_pos = player:get_pos()
        local distance = vector.distance(player_pos, chunk_pos)
        if distance <= max_distance then
            return true
        end
    end
    return false
end


local function check_emerge_timeouts()
    local current_time = core.get_us_time()
    local timeout_threshold = CONFIG.emerge_timeout * 1000000
    local timed_out_count = 0

    for emerge_id, emerge_info in pairs(pending_emerges) do
        if current_time - emerge_info.start_time > timeout_threshold then
            pending_emerges[emerge_id] = nil
            timed_out_count = timed_out_count + 1
            emerge_timeouts = emerge_timeouts + 1
        end
    end

    if timed_out_count > 0 then
        core.log("warning", "Emerge timeout detected: " .. timed_out_count .. " operations timed out")
    end

    if emerge_timeouts >= CONFIG.emerge_timeout_threshold then
        if not system_load.emergence_suspended then
            system_load.emergence_suspended = true
            system_load.suspension_reason = "emerge_timeout"
            system_load.suspension_start = current_time
            core.log("warning", "Non-priority emerges suspended due to timeout issues")
        end
    end

    if system_load.emergence_suspended and 
       (current_time - system_load.suspension_start) > 30000000 then
        system_load.emergence_suspended = false
        emerge_timeouts = 0
        core.log("action", "Emerge suspension lifted after cooldown period")
    end
end


local function calculate_chunk_priority(pos, player_pos, player_look_dir, player_velocity)
    local distance = vector.distance(pos, player_pos)
    local look_alignment = vector.dot(vector.normalize(vector.subtract(pos, player_pos)), player_look_dir)
    local velocity_alignment = vector.length(player_velocity) > 0 and
                              vector.dot(vector.normalize(vector.subtract(pos, player_pos)),
                                       vector.normalize(player_velocity)) or 0

    if distance < 16 then
        return priority_system.CRITICAL
    elseif look_alignment > 0.7 and distance < 48 then
        return priority_system.HIGH
    elseif velocity_alignment > 0.5 and distance < 64 then
        return priority_system.MEDIUM
    elseif distance < 80 then
        return priority_system.LOW
    else
        return priority_system.BACKGROUND
    end
end


local function unload_unused_chunks()
    local current_time = core.get_us_time()
    local timeout_us = CONFIG.chunk_unload_timeout * 1000000
    local unloaded_count = 0

    for key, chunk_info in pairs(loaded_chunks) do
        local age = current_time - chunk_info.last_access

        if age > timeout_us and not is_chunk_near_players(chunk_info.pos, 32) then
            core.delete_area(chunk_info.pos, vector.add(chunk_info.pos, {x=15, y=15, z=15}))

            if chunk_cache[key] then
                chunk_cache[key] = nil
                cache_size = cache_size - 1
            end

            loaded_chunks[key] = nil
            unloaded_count = unloaded_count + 1

            core.log("action", "Chunk unloaded: " .. key .. " (unused for " .. 
                    string.format("%.1f", age/1000000) .. "s)")
        end
    end

    if unloaded_count > 0 then
        core.log("action", "Automatic unload: " .. unloaded_count .. " chunks freed")
    end

    return unloaded_count
end


local function compress_chunk_data(data)
    local serialized = core.serialize(data)
    if #serialized > smart_cache.compression_threshold then
        return {
            compressed = true,
            data = serialized,
            original_size = #serialized,
            compressed_size = math.floor(#serialized * 0.6)
        }
    end
    return {
        compressed = false,
        data = data,
        original_size = #serialized,
        compressed_size = #serialized
    }
end

local function decompress_chunk_data(cached_data)
    if cached_data.compressed then
        return core.deserialize(cached_data.data)
    end
    return cached_data.data
end

local function update_thermal_data(pos)
    local key = get_cache_key(pos)
    local current_time = core.get_us_time()
    if not smart_cache.thermal_data[key] then
        smart_cache.thermal_data[key] = {
            access_count = 0,
            last_access = current_time,
            temperature = 0
        }
    end

    local thermal = smart_cache.thermal_data[key]
    local time_diff = (current_time - thermal.last_access) / 100000

    thermal.temperature = thermal.temperature * math.exp(-time_diff / 300)

    thermal.temperature = thermal.temperature + 1.0
    thermal.access_count = thermal.access_count + 1
    thermal.last_access = current_time

    return thermal.temperature
end


local function cache_chunk(pos, data)
    local key = get_cache_key(pos)
    local current_time = core.get_us_time()

    if cache_size >= CONFIG.max_cache_size then
        chunk_manager.cleanup_cache(true)
    end

    if not chunk_cache[key] then
        cache_size = cache_size + 1
    end

    local compressed_data = compress_chunk_data(data)
    local temperature = update_thermal_data(pos)

    chunk_cache[key] = {
        data = compressed_data,
        timestamp = current_time,
        access_count = 1,
        last_access = current_time,
        temperature = temperature,
        memory_footprint = compressed_data.compressed_size
    }

    track_chunk_load(pos)
end


local function get_cached_chunk(pos)
    local key = get_cache_key(pos)
    local cached = chunk_cache[key]
    local current_time = core.get_us_time()

    if cached then
        local age = (current_time - cached.timestamp) / 1000000
        local temperature = update_thermal_data(pos)

        local dynamic_timeout = temperature > 5.0 and CONFIG.cache_timeout * 2 or CONFIG.cache_timeout
        if age < dynamic_timeout then
            cached.access_count = cached.access_count + 1
            cached.last_access = current_time
            cached.temperature = temperature
            system_load.cache_hits = system_load.cache_hits + 1

            update_chunk_access(pos)
            return decompress_chunk_data(cached.data)
        else
            chunk_cache[key] = nil
            cache_size = cache_size - 1
        end
    end
    system_load.cache_misses = system_load.cache_misses + 1
    return nil
end


local function process_batch_emerge()
    if batch_system.processing_batch or #batch_system.batch_queue == 0 then
        return
    end

    local batch = {}
    local batch_size = math.min(batch_system.max_batch_size, #batch_system.batch_queue)

    for i = 1, batch_size do
        table.insert(batch, table.remove(batch_system.batch_queue, 1))
    end

    if #batch == 0 then
        return
    end

    batch_system.processing_batch = true
    local completed = 0
    local batch_start_time = core.get_us_time()

    for _, task in ipairs(batch) do
        local cached = get_cached_chunk(task.pos1)
        if cached then
            if task.callback then
                task.callback()
            end
            completed = completed + 1
            if completed == #batch then
                batch_system.processing_batch = false
            end
        else
            core.emerge_area(task.pos1, task.pos2, function(blockpos, action, calls_remaining)
                if calls_remaining == 0 then
                    cache_chunk(task.pos1, {
                        loaded = true,
                        action = action,
                        timestamp = core.get_us_time()
                    })
                    if task.callback then
                        task.callback()
                    end
                    completed = completed + 1
                    if completed == #batch then
                        batch_system.processing_batch = false
                    end
                end
            end)
        end
    end

    core.after(batch_system.batch_timeout, function()
        if batch_system.processing_batch then
            batch_system.processing_batch = false
            core.log("warning", "Batch emerge timeout - forcing completion")
        end
    end)
end


local function get_optimal_view_range()
    local player_count = #core.get_connected_players()

    if system_load.emergency_mode or manual_emergency_mode then
        return math.max(2, CONFIG.view_range_players.low.range - 1)
    end

    for _, config in pairs(CONFIG.view_range_players) do
        if player_count > config.max then
            return config.range
        end
    end

    return CONFIG.view_range_players.high.range
end


local function check_system_load()
    local current_time = core.get_us_time()
    if current_time - system_load.last_load_check < 2000000 then
        return
    end

    local start_time = current_time
    system_load.last_load_check = current_time
    local player_count = #core.get_connected_players()
    local high_velocity_count = 0

    for _, data in pairs(player_data) do
        if vector.length(data.velocity) > CONFIG.extreme_load_thresholds.velocity_threshold then
            high_velocity_count = high_velocity_count + 1
        end
    end

    system_load.high_velocity_players = high_velocity_count
    system_load.total_emerges_queued = #emerge_queue

    local total_cache_requests = system_load.cache_hits + system_load.cache_misses
    local cache_miss_ratio = total_cache_requests > 0 and (system_load.cache_misses / total_cache_requests) or 0

    local avg_emerge_time = 0
    if #system_load.emerge_times > 0 then
        local sum = 0
        for _, time in ipairs(system_load.emerge_times) do
            sum = sum + time
        end
        avg_emerge_time = sum / #system_load.emerge_times
    end

    local avg_processing_time = 0
    if #system_load.processing_times > 0 then
        local sum = 0
        for _, time in ipairs(system_load.processing_times) do
            sum = sum + time
        end
        avg_processing_time = sum / #system_load.processing_times
    end

    local performance_issues = {
        queue_overload = #emerge_queue > CONFIG.extreme_load_thresholds.queue_size_threshold,
        slow_emerges = avg_emerge_time > CONFIG.extreme_load_thresholds.emerge_time_threshold,
        cache_inefficient = cache_miss_ratio > CONFIG.extreme_load_thresholds.cache_miss_ratio,
        slow_processing = avg_processing_time > CONFIG.extreme_load_thresholds.max_processing_time,
        high_velocity = high_velocity_count > player_count * 0.3,
        emerge_timeout = avg_emerge_time > CONFIG.extreme_load_thresholds.emergence_timeout_threshold
    }

    local active_issues = 0
    for _, has_issue in pairs(performance_issues) do
        if has_issue then
            active_issues = active_issues + 1
        end
    end

    local is_overloaded = active_issues >= 2

    if is_overloaded then
        system_load.consecutive_overload = system_load.consecutive_overload + 1
    else
        system_load.consecutive_overload = 0
    end

    local should_emergency = system_load.consecutive_overload >= CONFIG.extreme_load_thresholds.consecutive_overload_threshold

    if should_emergency and not system_load.emergency_mode and not manual_emergency_mode then
        system_load.emergency_mode = true
        local issue_names = {}
        for name, has_issue in pairs(performance_issues) do
            if has_issue then
                table.insert(issue_names, name)
            end
        end
        core.log("warning", "Emergency mode activated - Issues detected: " .. table.concat(issue_names, ", ") .. 
                    " (Queue: " .. #emerge_queue .. ", Cache miss: " .. string.format("%.2f", cache_miss_ratio) .. 
                    ", Emerge time: " .. string.format("%.2f", avg_emerge_time) .. "s)")
    elseif not should_emergency and system_load.emergency_mode and not manual_emergency_mode then
        system_load.emergency_mode = false
        core.log("action", "Emergency mode deactivated - Performance stabilized")
    end

    if performance_issues.emerge_timeout and not system_load.emergence_suspended then
        system_load.emergence_suspended = true
        system_load.suspension_reason = "slow_emerges"
        system_load.suspension_start = current_time
        core.log("warning", "Non-priority emerges suspended due to slow emergence times")
    end

    local processing_time = (core.get_us_time() - start_time) / 1000000
    table.insert(system_load.processing_times, processing_time)
    if #system_load.processing_times > 10 then
        table.remove(system_load.processing_times, 1)
    end

    if total_cache_requests > 1000 then
        system_load.cache_hits = math.floor(system_load.cache_hits * 0.8)
        system_load.cache_misses = math.floor(system_load.cache_misses * 0.8)
    end

    check_emerge_timeouts()
end


local function set_player_view_range(player, range)
    if player and player:is_player() then
        local name = player:get_player_name()
        if player_data[name] then
            player_data[name].view_range = range
        end
    end
end



local function update_player_prediction(player, dtime)
    local pos = player:get_pos()
    local name = player:get_player_name()
    local look_dir = player:get_look_dir()
    local look_horizontal = player:get_look_horizontal()

    if not player_data[name] then
        player_data[name] = {
            pos = pos,
            velocity = {x=0, y=0, z=0},
            last_emerge = 0,
            view_range = get_optimal_view_range(),
            look_dir = look_dir,
            look_horizontal = look_horizontal
        }
        return
    end

    local data = player_data[name]
    local old_pos = data.pos
    local velocity = vector.divide(vector.subtract(pos, old_pos), dtime)

    -- Calculate look direction based on player look
    local movement_weight = math.min(vector.length(velocity) / 5.0, 1.0)
    local look_weight = 1.0 - movement_weight

    local combined_dir = vector.add(
        vector.multiply(vector.normalize(velocity), movement_weight),
        vector.multiply(look_dir, look_weight)
    )

    data.velocity = velocity
    data.pos = pos
    data.look_dir = look_dir
    data.look_horizontal = look_horizontal

    if vector.length(velocity) > CONFIG.min_velocity_threshold or 
       vector.distance(look_dir, data.look_dir or look_dir) > 0.1 then

        local prediction_distance = (system_load.emergency_mode or manual_emergency_mode) and
                                   CONFIG.prediction_distance * 0.5 or
                                   CONFIG.prediction_distance

        local main_future_pos = vector.add(pos, vector.multiply(combined_dir, prediction_distance))

        local angle_rad = math.rad(spatial_prediction.side_prediction_angle)
        local cos_angle = math.cos(angle_rad)
        local sin_angle = math.sin(angle_rad)

        local left_dir = {
            x = look_dir.x * cos_angle - look_dir.z * sin_angle,
            y = look_dir.y,
            z = look_dir.x * sin_angle + look_dir.z * cos_angle
        }

        local right_dir = {
            x = look_dir.x * cos_angle + look_dir.z * sin_angle,
            y = look_dir.y,
            z = -look_dir.x * sin_angle + look_dir.z * cos_angle
        }

        local left_pos = vector.add(pos, vector.multiply(left_dir, prediction_distance * 0.7))
        local right_pos = vector.add(pos, vector.multiply(right_dir, prediction_distance * 0.7))

        local current_time = core.get_us_time()
        local emerge_interval = (system_load.emergency_mode or manual_emergency_mode) and 3000000 or 1500000

        if current_time - data.last_emerge > emerge_interval then
            chunk_manager.queue_emerge(main_future_pos, main_future_pos, function()
                core.log("action", "Primary chunk preloaded for " .. name)
            end, 3)

            -- Low priority on side predictions
            chunk_manager.queue_emerge(left_pos, left_pos, nil, 2)
            chunk_manager.queue_emerge(right_pos, right_pos, nil, 2)

            data.last_emerge = current_time
        end
    end
end


function chunk_manager.queue_emerge(pos1, pos2, callback, priority)
    if not priority then
        local closest_player = nil
        local min_distance = math.huge

        for _, player in ipairs(core.get_connected_players()) do
            local player_pos = player:get_pos()
            local distance = vector.distance(pos1, player_pos)
            if distance < min_distance then
                min_distance = distance
                closest_player = player
            end
        end

        if closest_player then
            local player_name = closest_player:get_player_name()
            local player_data_entry = player_data[player_name]
            if player_data_entry then
                priority = calculate_chunk_priority(
                    pos1, 
                    player_data_entry.pos, 
                    player_data_entry.look_dir or {x=0, y=0, z=1}, 
                    player_data_entry.velocity
                )
            end
        end
    end
    priority = priority or priority_system.BACKGROUND

    if emerge_pause_enabled then
        return
    end

    if system_load.emergence_suspended and priority < priority_system.MEDIUM then
        return
    end

    table.insert(emerge_queue, {
        pos1 = pos1,
        pos2 = pos2,
        callback = callback,
        priority = priority,
        timestamp = core.get_us_time()
    })

    table.sort(emerge_queue, function(a, b)
        if a.priority ~= b.priority then
            return a.priority > b.priority
        end
        return a.timestamp < b.timestamp
    end)
end


local function process_emerge_queue()
    if emerge_pause_enabled then
        return
    end

    local max_emerges = (system_load.emergency_mode or manual_emergency_mode) and 
                       CONFIG.extreme_load_thresholds.emergency_emerges_per_step or 
                       CONFIG.max_emerges_per_step

    local processed = 0
    local high_priority_processed = 0
    while #emerge_queue > 0 and processed < max_emerges do
        local task = table.remove(emerge_queue, 1)

        if system_load.emergence_suspended and task.priority < priority_system.MEDIUM then
            break
        end

        if task.priority >= priority_system.HIGH then
            -- Faste emerge for high priority tasks
            local cached = get_cached_chunk(task.pos1)
            if cached then
                if task.callback then
                    task.callback()
                end
            else
                local emerge_id = core.get_us_time() .. "_" .. tostring(math.random(1000, 9999))
                system_load.last_emerge_start = core.get_us_time()

                pending_emerges[emerge_id] = {
                    start_time = system_load.last_emerge_start,
                    pos1 = task.pos1,
                    pos2 = task.pos2,
                    priority = task.priority
                }

                core.emerge_area(task.pos1, task.pos2, function(blockpos, action, calls_remaining)
                    if calls_remaining == 0 then
                        local emerge_time = (core.get_us_time() - system_load.last_emerge_start) / 1000000
                        table.insert(system_load.emerge_times, emerge_time)
                        if #system_load.emerge_times > 10 then
                            table.remove(system_load.emerge_times, 1)
                        end

                        pending_emerges[emerge_id] = nil
                        cache_chunk(task.pos1, {
                            loaded = true,
                            action = action,
                            timestamp = core.get_us_time()
                        })
                        if task.callback then
                            task.callback()
                        end
                    end
                end)
            end
            processed = processed + 1
            high_priority_processed = high_priority_processed + 1
        else
            table.insert(batch_system.batch_queue, task)
        end
    end

    process_batch_emerge()
end


function chunk_manager.cleanup_cache(force)
    if not force and cleanup_counter < CONFIG.cleanup_interval then
        cleanup_counter = cleanup_counter + 1
        return
    end

    cleanup_counter = 0

    local players = core.get_connected_players()
    local active_areas = {}
    local current_time = core.get_us_time()

    local effective_cache_size = (system_load.emergency_mode or manual_emergency_mode) and
                                CONFIG.extreme_load_thresholds.emergency_cache_size or
                                CONFIG.max_cache_size

    for _, player in ipairs(players) do
        local pos = player:get_pos()
        local name = player:get_player_name()
        local view_range = (player_data[name] and player_data[name].view_range) or get_optimal_view_range()

        for x = -view_range, view_range do
            for z = -view_range, view_range do
                local chunk_pos = {
                    x = pos.x + (x * 16),
                    y = pos.y,
                    z = pos.z + (z * 16)
                }
                active_areas[get_cache_key(chunk_pos)] = true
            end
        end
    end

    local removed = 0
    local cache_entries = {}

    for key, cached in pairs(chunk_cache) do
        table.insert(cache_entries, {key = key, cached = cached})
    end

    table.sort(cache_entries, function(a, b)
        if active_areas[a.key] ~= active_areas[b.key] then
            return active_areas[a.key] and not active_areas[b.key]
        end
        return a.cached.last_access > b.cached.last_access
    end)

    for i, entry in ipairs(cache_entries) do
        local should_remove = false

        if cache_size > effective_cache_size then
            should_remove = true
        elseif not active_areas[entry.key] then
            local age = (current_time - entry.cached.last_access) / 1000000
            local age_threshold = (system_load.emergency_mode or manual_emergency_mode) and CONFIG.cache_timeout or CONFIG.cache_timeout * 2
            if age > age_threshold or entry.cached.access_count < 2 then
                should_remove = true
            end
        end

        if should_remove then
            chunk_cache[entry.key] = nil
            removed = removed + 1
            cache_size = cache_size - 1
        end
    end

    if removed > 0 then
        core.log("action", "Cache cleaned: " .. removed .. " entries removed")
    end
end


function chunk_manager.smart_get_node(pos, callback)
    local node = core.get_node_or_nil(pos)

    if node then
        update_chunk_access(pos)
        if callback then callback(node) end
        return node
    end

    chunk_manager.queue_emerge(pos, pos, function()
        local loaded_node = core.get_node(pos)
        if callback then callback(loaded_node) end
    end, 2)

    return nil
end


function chunk_manager.preload_area(pos1, pos2, callback)
    local chunks_to_load = {}

    for x = pos1.x, pos2.x, 16 do
        for z = pos1.z, pos2.z, 16 do
            local chunk_pos = {x = x, y = pos1.y, z = z}
            if not get_cached_chunk(chunk_pos) then
                table.insert(chunks_to_load, chunk_pos)
            end
        end
    end

    if #chunks_to_load == 0 then
        if callback then callback() end
        return
    end

    local loaded_count = 0

    for _, chunk_pos in ipairs(chunks_to_load) do
        chunk_manager.queue_emerge(chunk_pos, chunk_pos, function()
            loaded_count = loaded_count + 1
            if loaded_count == #chunks_to_load and callback then
                callback()
            end
        end)
    end
end


function chunk_manager.is_area_loaded(pos1, pos2)
    local min_x = math.min(pos1.x, pos2.x)
    local max_x = math.max(pos1.x, pos2.x)
    local min_z = math.min(pos1.z, pos2.z)
    local max_z = math.max(pos1.z, pos2.z)

    for x = min_x, max_x, 16 do
        for z = min_z, max_z, 16 do
            local chunk_pos = {x = x, y = pos1.y, z = z}
            if not get_cached_chunk(chunk_pos) then
                local node = core.get_node_or_nil(chunk_pos)
                if not node then
                    return false
                end
            end
        end
    end

    return true
end


function chunk_manager.get_stats()
    local total_cache_requests = system_load.cache_hits + system_load.cache_misses
    local cache_miss_ratio = total_cache_requests > 0 and (system_load.cache_misses / total_cache_requests) or 0

    local avg_emerge_time = 0
    if #system_load.emerge_times > 0 then
        local sum = 0
        for _, time in ipairs(system_load.emerge_times) do
            sum = sum + time
        end
        avg_emerge_time = sum / #system_load.emerge_times
    end

    local avg_processing_time = 0
    if #system_load.processing_times > 0 then
        local sum = 0
        for _, time in ipairs(system_load.processing_times) do
            sum = sum + time
        end
        avg_processing_time = sum / #system_load.processing_times
    end

    local loaded_chunks_count = 0
    for _ in pairs(loaded_chunks) do
        loaded_chunks_count = loaded_chunks_count + 1
    end

    local pending_emerges_count = 0
    for _ in pairs(pending_emerges) do
        pending_emerges_count = pending_emerges_count + 1
    end

    return {
        cache_size = cache_size,
        queue_size = #emerge_queue,
        active_players = #core.get_connected_players(),
        optimal_view_range = get_optimal_view_range(),
        emergency_mode = system_load.emergency_mode or manual_emergency_mode,
        high_velocity_players = system_load.high_velocity_players,
        total_emerges_queued = system_load.total_emerges_queued,
        cache_miss_ratio = cache_miss_ratio,
        avg_emerge_time = avg_emerge_time,
        avg_processing_time = avg_processing_time,
        consecutive_overload = system_load.consecutive_overload,
        loaded_chunks_count = loaded_chunks_count,
        pending_emerges = pending_emerges_count,
        emerge_timeouts = emerge_timeouts,
        emergence_suspended = system_load.emergence_suspended,
        suspension_reason = system_load.suspension_reason,
        emerge_pause_enabled = emerge_pause_enabled,
        manual_emergency_mode = manual_emergency_mode
    }
end


core.register_globalstep(function(dtime)
    local step_start_time = core.get_us_time()

    check_system_load()

    process_batch_emerge()

    process_emerge_queue()

    for _, player in ipairs(core.get_connected_players()) do
        update_player_prediction(player, dtime)
        local pos = player:get_pos()
        update_chunk_access(pos)
    end

    local optimal_range = get_optimal_view_range()
    for _, player in ipairs(core.get_connected_players()) do
        set_player_view_range(player, optimal_range)
    end

    chunk_manager.cleanup_cache()

    local current_time = core.get_us_time()
    for key, thermal in pairs(smart_cache.thermal_data) do
        local age = (current_time - thermal.last_access) / 1000000
        if age > 600 then -- 10 minutes
            smart_cache.thermal_data[key] = nil
        end
    end

    unload_counter = unload_counter + 1
    if unload_counter >= CONFIG.unload_check_interval then
        unload_counter = 0
        unload_unused_chunks()
    end

    local step_processing_time = (core.get_us_time() - step_start_time) / 1000000
    table.insert(system_load.processing_times, step_processing_time)
    if #system_load.processing_times > 10 then
        table.remove(system_load.processing_times, 1)
    end
end)


core.register_on_joinplayer(function(player)
    local name = player:get_player_name()
    player_data[name] = {
        pos = player:get_pos(),
        velocity = {x=0, y=0, z=0},
        last_emerge = 0,
        view_range = get_optimal_view_range()
    }
end)

core.register_on_leaveplayer(function(player)
    local name = player:get_player_name()
    player_data[name] = nil
end)

core.register_chatcommand("chunk_stats", {
    description = "Show detailed chunk processing statistics",
    privs = {server = true},
    func = function(name, param)
        local stats = chunk_manager.get_stats()
        local status_parts = {}
        if stats.emergency_mode then table.insert(status_parts, "EMERGENCY") end
        if stats.emergence_suspended then table.insert(status_parts, "SUSPENDED(" .. stats.suspension_reason .. ")") end
        if stats.emerge_pause_enabled then table.insert(status_parts, "PAUSED") end
        local status = #status_parts > 0 and table.concat(status_parts, "|") or "Normal"

        return true,
        "======= Chunk Statistics: =======\n" ..
        "Cache: " .. stats.cache_size .. " entries\n" ..
        "Queue: " .. stats.queue_size .. " tasks\n" ..
        "View range: " .. stats.optimal_view_range .. "\n" ..
        "Status: " .. status .. "\n" ..
        "Fast players: " .. stats.high_velocity_players .. "\n" ..
        "Cache miss: " .. string.format("%.1f", stats.cache_miss_ratio * 100) .. "%\n" ..
        "Emerge time: " .. string.format("%.2f", stats.avg_emerge_time) .. "s\n" ..
        "Processing time: " .. string.format("%.1f", stats.avg_processing_time * 1000) .. "ms\n" ..
        "Consecutive overload: " .. stats.consecutive_overload .. "\n" ..
        "Loaded chunks: " .. stats.loaded_chunks_count .. "\n" ..
        "Pending emerges: " .. stats.pending_emerges .. "\n" ..
        "Emerge timeouts: " .. stats.emerge_timeouts
    end
})

core.register_chatcommand("chunk_emergency", {
    description = "Enable or disable manual emergency mode (on/off)",
    privs = {server = true},
    func = function(name, param)
        param = param:lower()
        if param == "on" then
            manual_emergency_mode = true
            return true, "Manual emergency mode enabled"
        elseif param == "off" then
            manual_emergency_mode = false
            return true, "Manual emergency mode disabled"
        else
            return false, "Usage: /chunk_emergency [on|off]"
        end
    end
})

core.register_chatcommand("chunk_emerge_pause", {
    description = "Toggle automatic chunk emergence pause",
    privs = {server = true},
    func = function(name, param)
        emerge_pause_enabled = not emerge_pause_enabled
        local status = emerge_pause_enabled and "enabled" or "disabled"
        return true, "Emerge pause " .. status
    end
})

core.register_chatcommand("chunk_unload", {
    description = "Force unload of all unused chunks",
    privs = {server = true},
    func = function(name, param)
        local count = unload_unused_chunks()
        return true, "Forced unload: " .. count .. " chunks freed"
    end
})

core.register_chatcommand("chunk_cleanup", {
    description = "Perform a full cleanup of the chunk cache",
    privs = {server = true},
    func = function(name, param)
        chunk_manager.cleanup_cache(true)
        return true, "Cache cleanup performed"
    end
})

core.register_chatcommand("chunk_reset_suspension", {
    description = "Reset emergence suspension and clear timeouts",
    privs = {server = true},
    func = function(name, param)
        system_load.emergence_suspended = false
        system_load.suspension_reason = ""
        emerge_timeouts = 0
        return true, "Emergence suspension reset"
    end
})

core.log("action", "Chunk optimization system initialized")

return chunk_manager