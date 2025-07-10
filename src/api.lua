local modname = core.get_current_modname()
local S = core.get_translator(modname)

local chunk_manager = {}

chunk_manager.enabled = true
chunk_manager.emergency_mode = false
chunk_manager.suspended = false

chunk_manager.config = {
    view_distance = tonumber(core.settings:get("view_distance")) or 5.0,
    emergency_view_distance = tonumber(core.settings:get("emergency_view_distance")) or 3.0,
    max_cache_size = tonumber(core.settings:get("max_cache_size")) or 1000.0,
    emergency_cache_size = tonumber(core.settings:get("emergency_cache_size")) or 500.0,
    prediction_interval = tonumber(core.settings:get("prediction_interval")) or 1.0,
    emergency_prediction_interval = tonumber(core.settings:get("emergency_prediction_interval")) or 1.0,
    timeout_threshold = tonumber(core.settings:get("timeout_threshold")) or 5.0,
    queue_size_threshold = tonumber(core.settings:get("queue_size_threshold")) or 50.0,
    cache_miss_threshold = tonumber(core.settings:get("cache_miss_threshold")) or 0.7,
    emergence_time_threshold = tonumber(core.settings:get("emergence_time_threshold")) or 1.0,
    compression_threshold = tonumber(core.settings:get("compression_threshold")) or 100.0,
    max_timeouts = tonumber(core.settings:get("max_timeouts")) or 10.0,
    suspend_duration = tonumber(core.settings:get("suspend_duration")) or 5.0,
    batch_size = tonumber(core.settings:get("batch_size")) or 5.0,
    batch_interval = tonumber(core.settings:get("batch_interval")) or 0.1,
    unload_timeout = tonumber(core.settings:get("unload_timeout")) or 30.0,
    max_players_reduction = tonumber(core.settings:get("max_players_reduction")) or 0.8,
    compression_batch_size = tonumber(core.settings:get("compression_batch_size")) or 10.0,
    max_operations_per_tick = tonumber(core.settings:get("max_operations_per_tick")) or 5.0,
    async_processing = core.settings:get_bool("async_processing") or true,
}

chunk_manager.cache = {}
chunk_manager.prediction_queue = {}
chunk_manager.batch_queue = {}
chunk_manager.player_data = {}
chunk_manager.suspend_time = 0
chunk_manager.cache_keys = {}
chunk_manager.compression_queue = {}
chunk_manager.operations_this_tick = 0
chunk_manager.timeout_count = 0
chunk_manager.cache_hits = 0
chunk_manager.cache_misses = 0
chunk_manager.emergence_times = {}

local function string_split(str, delimiter)
    local result = {}
    local pattern = "([^" .. delimiter .. "]+)"
    for match in string.gmatch(str, pattern) do
        table.insert(result, match)
    end
    return result
end

local function get_chunk_key(pos)
    local chunk_size = 16
    local cx = math.floor(pos.x / chunk_size)
    local cy = math.floor(pos.y / chunk_size)
    local cz = math.floor(pos.z / chunk_size)
    return cx .. "," .. cy .. "," .. cz
end

local function compress_chunk_data(data)
    if #data > chunk_manager.config.compression_threshold then
        table.insert(chunk_manager.compression_queue, {data = data, callback = nil})
        return data
    end
    return data
end

local function process_compression_queue()
    local processed = 0
    while #chunk_manager.compression_queue > 0 and processed < chunk_manager.config.compression_batch_size do
        local item = table.remove(chunk_manager.compression_queue, 1)
        if item.data then
            local compressed = core.compress(item.data, "deflate")
            if item.callback then
                item.callback(compressed)
            end
        end
        processed = processed + 1
    end
end

local function decompress_chunk_data(data)
    if type(data) == "string" and data:sub(1, 1) == "\x78" then
        return core.decompress(data, "deflate")
    end
    return data
end

local function add_to_cache(chunk_key, data, priority)
    if not chunk_key or not data then return end

    local compressed_data = compress_chunk_data(data)

    if not chunk_manager.cache[chunk_key] then
        table.insert(chunk_manager.cache_keys, chunk_key)
    end

    chunk_manager.cache[chunk_key] = {
        data = compressed_data,
        priority = priority,
        timestamp = os.time(),
        access_count = 1
    }
end

local function get_from_cache(chunk_key)
    local cached = chunk_manager.cache[chunk_key]
    if cached then
        cached.access_count = cached.access_count + 1
        cached.timestamp = os.time()
        chunk_manager.cache_hits = chunk_manager.cache_hits + 1
        return decompress_chunk_data(cached.data)
    else
        chunk_manager.cache_misses = chunk_manager.cache_misses + 1
        return nil
    end
end

local function remove_from_cache(chunk_key)
    if not chunk_key then return end

    chunk_manager.cache[chunk_key] = nil

    for i = #chunk_manager.cache_keys, 1, -1 do
        if chunk_manager.cache_keys[i] == chunk_key then
            table.remove(chunk_manager.cache_keys, i)
        end
    end
end

local function cleanup_cache()
    local cache_size = #chunk_manager.cache_keys
    local max_size = chunk_manager.emergency_mode and chunk_manager.config.emergency_cache_size or chunk_manager.config.max_cache_size

    if cache_size <= max_size then
        return
    end

    local priority_order = {CRITICAL = 4, HIGH = 3, MEDIUM = 2, LOW = 1, BACKGROUND = 0}

    local function compare_chunks(a, b)
        local data_a = chunk_manager.cache[a]
        local data_b = chunk_manager.cache[b]

        if not data_a or not data_b then
            if not data_a and not data_b then
                return false
            end
            return data_a ~= nil
        end

        if data_a.priority ~= data_b.priority then
            return priority_order[data_a.priority] > priority_order[data_b.priority]
        end

        return data_a.timestamp > data_b.timestamp
    end

    local batch_size = math.min(cache_size, chunk_manager.config.max_operations_per_tick * 2)
    local chunks_to_sort = {}

    for i = 1, batch_size do
        local key = chunk_manager.cache_keys[i]
        if key and chunk_manager.cache[key] then
            table.insert(chunks_to_sort, key)
        end
    end

    table.sort(chunks_to_sort, compare_chunks)

    local to_remove = math.min(cache_size - max_size, chunk_manager.config.max_operations_per_tick)
    for i = #chunks_to_sort, math.max(1, #chunks_to_sort - to_remove + 1), -1 do
        local chunk_key = chunks_to_sort[i]
        if chunk_key and chunk_manager.cache[chunk_key] then
            remove_from_cache(chunk_key)
        end
    end
end

local function check_system_load()
    local queue_size = #chunk_manager.prediction_queue + #chunk_manager.batch_queue
    local total_cache_ops = chunk_manager.cache_hits + chunk_manager.cache_misses
    local cache_miss_ratio = total_cache_ops > 0 and (chunk_manager.cache_misses / total_cache_ops) or 0
    local avg_emergence_time = 0

    if #chunk_manager.emergence_times > 0 then
        local sum = 0
        for _, time in ipairs(chunk_manager.emergence_times) do
            sum = sum + time
        end
        avg_emergence_time = sum / #chunk_manager.emergence_times
    end

    local should_emergency = queue_size > chunk_manager.config.queue_size_threshold or
                             cache_miss_ratio > chunk_manager.config.cache_miss_threshold or
                             avg_emergence_time > chunk_manager.config.emergence_time_threshold

    if should_emergency and not chunk_manager.emergency_mode then
        chunk_manager.emergency_mode = true
    elseif not should_emergency and chunk_manager.emergency_mode then
        chunk_manager.emergency_mode = false
    end

    if chunk_manager.timeout_count > chunk_manager.config.max_timeouts then
        chunk_manager.suspended = true
        chunk_manager.suspend_time = os.time() + chunk_manager.config.suspend_duration
    end

    if chunk_manager.suspended and os.time() > chunk_manager.suspend_time then
        chunk_manager.suspended = false
        chunk_manager.timeout_count = 0
    end
end

local function predict_player_movement(player)
    local name = player:get_player_name()
    local pos = player:get_pos()
    local look_dir = player:get_look_dir()
    local velocity = player:get_velocity()

    if not chunk_manager.player_data[name] then
        chunk_manager.player_data[name] = {
            last_pos   = pos,
            last_time  = os.time(),
            speed      = 0,
            direction  = look_dir
        }
    end

    local player_data = chunk_manager.player_data[name]
    local dt = os.time() - player_data.last_time

    if dt > 0 then
        local distance = vector.distance(pos, player_data.last_pos)
        player_data.speed     = distance / dt
        player_data.last_pos  = pos
        player_data.last_time = os.time()
        player_data.direction = look_dir
    end

    local predictions = {}
    local view_distance = chunk_manager.emergency_mode and chunk_manager.config.emergency_view_distance or chunk_manager.config.view_distance
    local player_count   = #core.get_connected_players()

    if player_count > 5 then
        view_distance = math.floor(view_distance * chunk_manager.config.max_players_reduction)
    end

    local current_chunk = get_chunk_key(pos)
    table.insert(predictions, {pos = pos, priority = "CRITICAL", chunk = current_chunk})

    for i = 1, view_distance do
        local predicted_pos = vector.add(pos, vector.multiply(look_dir, i * 16))
        local chunk_key = get_chunk_key(predicted_pos)
        table.insert(predictions, {pos = predicted_pos, priority = "HIGH", chunk = chunk_key})
    end

    if player_data.speed > 0 then
        local movement_prediction = vector.add(pos, vector.multiply(velocity, 2.0))
        local chunk_key = get_chunk_key(movement_prediction)
        table.insert(predictions, {pos = movement_prediction, priority = "MEDIUM", chunk = chunk_key})

        local lateral_offsets = {
            {x = 16,  y = 0, z = 0},
            {x = -16, y = 0, z = 0},
            {x = 0,   y = 0, z = 16},
            {x = 0,   y = 0, z = -16}
        }

        for _, offset in ipairs(lateral_offsets) do
            local lateral_pos = vector.add(movement_prediction, offset)
            local lateral_chunk_key = get_chunk_key(lateral_pos)
            table.insert(predictions, {pos = lateral_pos, priority = "LOW", chunk = lateral_chunk_key})
        end
    end

    return predictions
end

local function queue_emergence(pos, priority)
    if chunk_manager.suspended then
        return
    end

    local chunk_key = get_chunk_key(pos)

    if get_from_cache(chunk_key) then
        return
    end

    if priority == "CRITICAL" or priority == "HIGH" then
        table.insert(chunk_manager.prediction_queue, {pos = pos, priority = priority, chunk = chunk_key, timestamp = os.time()})
    else
        table.insert(chunk_manager.batch_queue, {pos = pos, priority = priority, chunk = chunk_key, timestamp = os.time()})
    end
end

local function process_emergence_queue()
    if #chunk_manager.prediction_queue == 0 then return end

    local item = table.remove(chunk_manager.prediction_queue, 1)
    local start_time = os.time()

    core.emerge_area(item.pos, item.pos, function(blockpos, action, calls_remaining, param)
        local end_time = os.time()
        local emergence_time = end_time - start_time

        table.insert(chunk_manager.emergence_times, emergence_time)
        if #chunk_manager.emergence_times > 50 then
            table.remove(chunk_manager.emergence_times, 1)
        end

        if action == core.emerge_cancelled or action == core.emerge_errored then
            chunk_manager.timeout_count = chunk_manager.timeout_count + 1
        else
            add_to_cache(item.chunk, "chunk_data", item.priority)
        end
    end, item)
end

local function process_batch_queue()
    if #chunk_manager.batch_queue == 0 then return end

    local batch = {}
    for i = 1, math.min(chunk_manager.config.batch_size, #chunk_manager.batch_queue) do
        table.insert(batch, table.remove(chunk_manager.batch_queue, 1))
    end

    for _, item in ipairs(batch) do
        core.emerge_area(item.pos, item.pos, function(blockpos, action, calls_remaining, param)
            if action ~= core.emerge_cancelled and action ~= core.emerge_errored then
                add_to_cache(item.chunk, "chunk_data", item.priority)
            end
        end, item)
    end
end

local function unload_old_chunks()
    local current_time = os.time()
    local players = core.get_connected_players()
    local chunks_to_remove = {}
    local processed = 0

    for chunk_key, cache_data in pairs(chunk_manager.cache) do
        if processed >= chunk_manager.config.max_operations_per_tick then
            break
        end

        local age = current_time - cache_data.timestamp

        if age > chunk_manager.config.unload_timeout then
            local should_unload = true

            local parts = string_split(chunk_key, ",")
            if #parts >= 3 then
                local chunk_pos = {
                    x = tonumber(parts[1]) * 16,
                    y = tonumber(parts[2]) * 16,
                    z = tonumber(parts[3]) * 16
                }

                for _, player in ipairs(players) do
                    local player_pos = player:get_pos()
                    local distance = vector.distance(player_pos, chunk_pos)

                    if distance < 200 then
                        should_unload = false
                        break
                    end
                end

                if should_unload then
                    table.insert(chunks_to_remove, chunk_key)
                end
            end
        end
        processed = processed + 1
    end

    for _, chunk_key in ipairs(chunks_to_remove) do
        remove_from_cache(chunk_key)
    end
end

local function main_loop()
    if not chunk_manager.enabled then return end

    chunk_manager.operations_this_tick = 0

    process_compression_queue()

    if chunk_manager.config.async_processing then
        if chunk_manager.operations_this_tick < chunk_manager.config.max_operations_per_tick then
            check_system_load()
            chunk_manager.operations_this_tick = chunk_manager.operations_this_tick + 1
        end

        if chunk_manager.operations_this_tick < chunk_manager.config.max_operations_per_tick then
            cleanup_cache()
            chunk_manager.operations_this_tick = chunk_manager.operations_this_tick + 1
        end

        if chunk_manager.operations_this_tick < chunk_manager.config.max_operations_per_tick then
            unload_old_chunks()
            chunk_manager.operations_this_tick = chunk_manager.operations_this_tick + 1
        end
    else
        check_system_load()
        cleanup_cache()
        unload_old_chunks()
    end

    local players = core.get_connected_players()
    local interval = chunk_manager.emergency_mode and chunk_manager.config.emergency_prediction_interval or chunk_manager.config.prediction_interval

    local players_processed = 0
    local max_players_per_tick = chunk_manager.emergency_mode and 2 or 4

    for _, player in ipairs(players) do
        if players_processed >= max_players_per_tick then
            break
        end

        local predictions = predict_player_movement(player)

        local predictions_processed = 0
        for _, prediction in ipairs(predictions) do
            if predictions_processed >= chunk_manager.config.max_operations_per_tick then
                break
            end
            queue_emergence(prediction.pos, prediction.priority)
            predictions_processed = predictions_processed + 1
        end

        players_processed = players_processed + 1
    end

    process_emergence_queue()

    core.after(interval, main_loop)
end

core.register_on_mods_loaded(function()
    core.after(1, main_loop)
end)

core.register_globalstep(function(dtime)
    if #chunk_manager.batch_queue > 0 then
        process_batch_queue()
    end

    if #chunk_manager.compression_queue > 0 then
        process_compression_queue()
    end
end)

return chunk_manager