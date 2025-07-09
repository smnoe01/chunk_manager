--[[

Attribution-NoDerivatives 4.0 International
Atlante (AtlanteEtDocteur@gmail.com)
=======================================================================

Creative Commons Corporation ("Creative Commons") is not a law firm and
does not provide legal services or legal advice. Distribution of
Creative Commons public licenses does not create a lawyer-client or
other relationship. Creative Commons makes its licenses and related
information available on an "as-is" basis. Creative Commons gives no
warranties regarding its licenses, any material licensed under their
terms and conditions, or any related information. Creative Commons
disclaims all liability for damages resulting from their use to the
fullest extent possible.

--]]


local modname = core.get_current_modname()
local S = core.get_translator(modname)

local preloader = {}

preloader.enabled = true
preloader.emergency_mode = false
preloader.suspended = false
preloader.performance_test_running = false
preloader.performance_test_start_time = 0

preloader.config = {
    view_distance = tonumber(core.settings:get("view_distance")) or 5.0, -- Distance en chunks
    emergency_view_distance = tonumber(core.settings:get("emergency_view_distance")) or 3.0, -- Distance en chunks en mode d'urgence
    max_cache_size = tonumber(core.settings:get("emergency_view_distance")) or 1000.0, -- Taille maximale de la cache en Mo
    emergency_cache_size = tonumber(core.settings:get("emergency_cache_size")) or 500.0, -- Taille maximale de la cache en mode d'urgence en Mo
    prediction_interval = tonumber(core.settings:get("prediction_interval")) or 1.0, -- Intervalle de prédiction en secondes
    emergency_prediction_interval = tonumber(core.settings:get("emergency_prediction_interval")) or 1.0, -- Intervalle de prédiction en mode d'urgence en secondes

    timeout_threshold = tonumber(core.settings:get("timeout_threshold")) or 5.0, -- Temps d'attente maximal pour une émergence en secondes
    queue_size_threshold = tonumber(core.settings:get("queue_size_threshold")) or 50.0, -- Taille maximale de la file d'attente avant d'activer le mode d'urgence
    cache_miss_threshold = tonumber(core.settings:get("cache_miss_threshold")) or 0.7, -- Seuil de taux de cache manqué avant d'activer le mode d'urgence
    emergence_time_threshold = tonumber(core.settings:get("emergence_time_threshold")) or 1.0, -- Temps d'émergence maximal avant d'activer le mode d'urgence en secondes
    thermal_decay = tonumber(core.settings:get("thermal_decay")) or 0.95,
    compression_threshold = tonumber(core.settings:get("compression_threshold")) or 100.0, -- Taille minimale des données de chunk pour la compression en octets
    max_timeouts = tonumber(core.settings:get("max_timeouts")) or 10.0, -- Nombre maximal de timeouts avant de suspendre le système
    suspend_duration = tonumber(core.settings:get("suspend_duration")) or 5.0, -- Durée de la suspension du système en secondes
    batch_size = tonumber(core.settings:get("batch_size")) or 5.0, -- Taille maximale d'un lot de chunks à traiter en une fois
    batch_interval = tonumber(core.settings:get("batch_interval")) or 0.1, -- Intervalle entre les traitements de lots en secondes
    unload_timeout = tonumber(core.settings:get("unload_timeout")) or 30.0, -- Temps d'inactivité maximal d'un chunk avant de le décharger en secondes
    max_players_reduction = tonumber(core.settings:get("max_players_reduction")) or 0.8, -- Réduction de la distance de vue en cas de nombreux joueurs
    max_emergence_times = tonumber(core.settings:get("max_emergence_times")) or 50.0, -- Nombre maximal de temps d'émergence à conserver pour le calcul de la moyenne
    thermal_decay_interval = tonumber(core.settings:get("thermal_decay_interval")) or 10.0,
    compression_batch_size = tonumber(core.settings:get("compression_batch_size")) or 10.0, -- Taille maximale du lot de données à compresser en une fois
    max_operations_per_tick = tonumber(core.settings:get("max_operations_per_tick")) or 5.0, -- Nombre maximal d'opérations à effectuer par tick
    async_processing = core.settings:get_bool("async_processing") or true, -- Utiliser le traitement asynchrone pour les émergences
}

preloader.stats = {
    queue_size = 0,
    cache_hits = 0,
    cache_misses = 0,
    emergence_times = {},
    timeout_count = 0,
    chunks_loaded = 0,
    chunks_unloaded = 0,
    predictions_made = 0,
    emergency_activations = 0
}

preloader.cache = {}
preloader.thermal_data = {}
preloader.prediction_queue = {}
preloader.batch_queue = {}
preloader.player_data = {}
preloader.timeouts = {}
preloader.suspend_time = 0
preloader.cache_keys = {}
preloader.last_thermal_decay = 0
preloader.compression_queue = {}
preloader.operations_this_tick = 0
preloader.tick_start_time = 0

local function string_split(str, delimiter)
    local result = {}
    local pattern = "([^" .. delimiter .. "]+)"
    for match in string.gmatch(str, pattern) do
        table.insert(result, match)
    end
    return result
end

-- Permet obtenir la clé (ID) d'un chunk à partir de sa position
local function get_chunk_key(pos)
    local chunk_size = 16
    local cx = math.floor(pos.x / chunk_size)
    local cy = math.floor(pos.y / chunk_size)
    local cz = math.floor(pos.z / chunk_size)
    return cx .. "," .. cy .. "," .. cz
end

local function compress_chunk_data(data)
    if #data > preloader.config.compression_threshold then
        table.insert(preloader.compression_queue, {data = data, callback = nil})
        return data
    end
    return data
end

local function process_compression_queue()
    local processed = 0
    while #preloader.compression_queue > 0 and processed < preloader.config.compression_batch_size do
        local item = table.remove(preloader.compression_queue, 1)
        if item.data then
            --core.log("info", "Compressing chunk data of size " .. #item.data)
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
        --core.log("info", "Decompressing chunk data")
        return core.decompress(data, "deflate")
    end
    return data
end

local function update_thermal_data(chunk_key)
    if not preloader.thermal_data[chunk_key] then
        preloader.thermal_data[chunk_key] = 0
    end
    preloader.thermal_data[chunk_key] = preloader.thermal_data[chunk_key] + 1
    --core.log("info", "Updated thermal data for chunk " .. chunk_key .. " to " .. preloader.thermal_data[chunk_key])
end

local function decay_thermal_data()
    local current_time = os.time()
    if current_time - preloader.last_thermal_decay < preloader.config.thermal_decay_interval then
        return
    end

    preloader.last_thermal_decay = current_time
    local processed = 0
    local keys_to_remove = {}

    for chunk_key, value in pairs(preloader.thermal_data) do
        if processed >= preloader.config.max_operations_per_tick then
            break
        end

        preloader.thermal_data[chunk_key] = value * preloader.config.thermal_decay
        if preloader.thermal_data[chunk_key] < 0.1 then
            table.insert(keys_to_remove, chunk_key)
        end
        processed = processed + 1
    end

    for _, chunk_key in ipairs(keys_to_remove) do
        preloader.thermal_data[chunk_key] = nil
        --core.log("info", "Decayed thermal data for chunk " .. chunk_key)
    end
end

-- Ajoute un chunk à la cache avec les données compresser
local function add_to_cache(chunk_key, data, priority)
    if not chunk_key or not data then return end

    local compressed_data = compress_chunk_data(data)

    if not preloader.cache[chunk_key] then
        table.insert(preloader.cache_keys, chunk_key)
    end

    preloader.cache[chunk_key] = {
        data = compressed_data,
        priority = priority,
        timestamp = os.time(),
        access_count = 1
    }

    update_thermal_data(chunk_key)
    --core.log("info", "Added chunk " .. chunk_key .. " to cache with priority " .. priority)
end

-- Récupère un chunk depuis la cache
local function get_from_cache(chunk_key)
    local cached = preloader.cache[chunk_key]
    if cached then
        cached.access_count = cached.access_count + 1
        cached.timestamp = os.time()

        update_thermal_data(chunk_key)

        preloader.stats.cache_hits = preloader.stats.cache_hits + 1
        core.log("info", "Cache hit for chunk " .. chunk_key)

        return decompress_chunk_data(cached.data)
    else
        preloader.stats.cache_misses = preloader.stats.cache_misses + 1
        core.log("warning", "Cache miss for chunk " .. chunk_key)

        return nil
    end
end

-- Supprime un chunk de la cache
local function remove_from_cache(chunk_key)
    if not chunk_key then return end

    preloader.cache[chunk_key] = nil

    for i = #preloader.cache_keys, 1, -1 do
        if preloader.cache_keys[i] == chunk_key then
            table.remove(preloader.cache_keys, i)
        end
    end
end

-- Synchronise la cache pour éviter les entrées orphelines
-- Orphelines = les entrer qui ne sont pas référencer dans cache_keys
local function synchronize_cache()
    local valid_keys = {}

    for i, key in ipairs(preloader.cache_keys) do
        if preloader.cache[key] then
            table.insert(valid_keys, key)
        else
            core.log("warning", "Warning: Found orphaned key in cache_keys: " .. key)
        end
    end

    preloader.cache_keys = valid_keys

    for chunk_key, _ in pairs(preloader.cache) do
        local found = false
        for _, key in ipairs(preloader.cache_keys) do
            if key == chunk_key then
                found = true
                break
            end
        end
        if not found then
            core.log("warning", "Warning: Found orphaned entry in cache: " .. chunk_key)
            table.insert(preloader.cache_keys, chunk_key)
        end
    end
end

-- Vide la cache
local function cleanup_cache()
    synchronize_cache()

    local cache_size = #preloader.cache_keys
    local max_size = preloader.emergency_mode and preloader.config.emergency_cache_size or preloader.config.max_cache_size

    if cache_size <= max_size then
        return
    end

    --core.log("info", "Cache cleanup triggered, current size: " .. cache_size .. ", max: " .. max_size)

    local priority_order = {CRITICAL = 4, HIGH = 3, MEDIUM = 2, LOW = 1, BACKGROUND = 0}

    local function compare_chunks(a, b)
        local data_a = preloader.cache[a]
        local data_b = preloader.cache[b]

        if not data_a or not data_b then
            if not data_a and not data_b then
                return false
            end
            return data_a ~= nil
        end

        if data_a.priority ~= data_b.priority then
            return priority_order[data_a.priority] > priority_order[data_b.priority]
        end

        local thermal_a = preloader.thermal_data[a] or 0
        local thermal_b = preloader.thermal_data[b] or 0
        if thermal_a ~= thermal_b then
            return thermal_a > thermal_b
        end

        return data_a.timestamp > data_b.timestamp
    end

    local batch_size = math.min(cache_size, preloader.config.max_operations_per_tick * 2)
    local chunks_to_sort = {}

    for i = 1, batch_size do
        local key = preloader.cache_keys[i]
        if key and preloader.cache[key] then
            table.insert(chunks_to_sort, key)
        end
    end

    table.sort(chunks_to_sort, compare_chunks)

    local to_remove = math.min(cache_size - max_size, preloader.config.max_operations_per_tick)
    for i = #chunks_to_sort, math.max(1, #chunks_to_sort - to_remove + 1), -1 do
        local chunk_key = chunks_to_sort[i]
        if chunk_key and preloader.cache[chunk_key] then
            remove_from_cache(chunk_key)
            --core.log("info", "Removed chunk " .. chunk_key .. " from cache")
            preloader.stats.chunks_unloaded = preloader.stats.chunks_unloaded + 1
        end
    end
end

-- Vérifie la charge du système et active/désactive le mode d'urgence si nécessaire
local function check_system_load()
    local queue_size = #preloader.prediction_queue + #preloader.batch_queue
    local total_cache_ops = preloader.stats.cache_hits + preloader.stats.cache_misses
    local cache_miss_ratio = total_cache_ops > 0 and (preloader.stats.cache_misses / total_cache_ops) or 0
    local avg_emergence_time = 0

    if #preloader.stats.emergence_times > 0 then
        local sum = 0
        for _, time in ipairs(preloader.stats.emergence_times) do
            sum = sum + time
        end
        avg_emergence_time = sum / #preloader.stats.emergence_times
    end

    --core.log("info", "System load check - Queue: " .. queue_size .. ", Cache miss ratio: " .. cache_miss_ratio .. ", Avg emergence time: " .. avg_emergence_time)

    local should_emergency = queue_size > preloader.config.queue_size_threshold or
                            cache_miss_ratio > preloader.config.cache_miss_threshold or
                            avg_emergence_time > preloader.config.emergence_time_threshold

    if should_emergency and not preloader.emergency_mode then
        preloader.emergency_mode = true
        preloader.stats.emergency_activations = preloader.stats.emergency_activations + 1
        core.log("info", "EMERGENCY MODE ACTIVATED - System overloaded!")
    elseif not should_emergency and preloader.emergency_mode then
        preloader.emergency_mode = false
        core.log("info", "Emergency mode deactivated - System stabilized")
    end

    if preloader.stats.timeout_count > preloader.config.max_timeouts then
        preloader.suspended = true
        preloader.suspend_time = os.time() + preloader.config.suspend_duration
        core.log("warning", "SYSTEM SUSPENDED - Too many timeouts: " .. preloader.stats.timeout_count)
    end

    if preloader.suspended and os.time() > preloader.suspend_time then
        preloader.suspended = false
        preloader.stats.timeout_count = 0
        core.log("info", "System resumed from suspension")
    end
end

-- Prédit le mouvement du joueur pour généré les chunks nécessaires (Direction, Regard, Vitesse)
local function predict_player_movement(player)
    local name = player:get_player_name()
    local pos = player:get_pos()
    local look_dir = player:get_look_dir()
    local velocity = player:get_velocity()

    if not preloader.player_data[name] then
        preloader.player_data[name] = {
            last_pos   = pos,
            last_time  = os.time(),
            speed      = 0,
            direction  = look_dir
        }
    end

    local player_data = preloader.player_data[name]
    local dt = os.time() - player_data.last_time

    if dt > 0 then
        local distance = vector.distance(pos, player_data.last_pos)
        player_data.speed     = distance / dt
        player_data.last_pos  = pos
        player_data.last_time = os.time()
        player_data.direction = look_dir
    end

    local predictions = {}
    local view_distance = preloader.emergency_mode and preloader.config.emergency_view_distance or preloader.config.view_distance
    local player_count   = #core.get_connected_players()

    if player_count > 5 then
        view_distance = math.floor(view_distance * preloader.config.max_players_reduction)
        core.log("info", "Reduced view distance to " .. view_distance .. " due to " .. player_count .. " players")
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
            {x = 16,  y = 0, z = 0}, -- Droite
            {x = -16, y = 0, z = 0}, -- Gauche
            {x = 0,   y = 0, z = 16}, -- Avant
            {x = 0,   y = 0, z = -16} -- Arrière
        }

        for _, offset in ipairs(lateral_offsets) do
            local lateral_pos = vector.add(movement_prediction, offset)
            local lateral_chunk_key = get_chunk_key(lateral_pos)
            table.insert(predictions, {pos = lateral_pos, priority = "LOW", chunk = lateral_chunk_key})
        end
    end

    --core.log("info", "Generated " .. #predictions .. " predictions for player " .. name .. " (speed: " .. player_data.speed .. ")")
    preloader.stats.predictions_made = preloader.stats.predictions_made + #predictions

    return predictions
end

-- Mettre en file d'attente une demande d'émergence pour un chunk
local function queue_emergence(pos, priority)
    if preloader.suspended then
        core.log("info", "Emergence suspended, ignoring request for " .. core.pos_to_string(pos))
        return
    end

    local chunk_key = get_chunk_key(pos)

    if get_from_cache(chunk_key) then
        core.log("warning", "Chunk already cached: " .. chunk_key)
        return
    end

    if priority == "CRITICAL" or priority == "HIGH" then
        table.insert(preloader.prediction_queue, {pos = pos, priority = priority, chunk = chunk_key, timestamp = os.time()})
        --core.log("info", "Added to prediction queue: " .. chunk_key .. " (priority: " .. priority .. ")")
    else
        table.insert(preloader.batch_queue, {pos = pos, priority = priority, chunk = chunk_key, timestamp = os.time()})
        --core.log("info", "Added to batch queue: " .. chunk_key .. " (priority: " .. priority .. ")")
    end

    preloader.stats.queue_size = #preloader.prediction_queue + #preloader.batch_queue
end

-- Traite la file d'attente des émergences pour les chunks critiques (4)
local function process_emergence_queue()
    if #preloader.prediction_queue == 0 then return end

    local item = table.remove(preloader.prediction_queue, 1)
    local start_time = os.time()

    --core.log("info", "Processing emergence for chunk " .. item.chunk .. " at " .. core.pos_to_string(item.pos))

    core.emerge_area(item.pos, item.pos, function(blockpos, action, calls_remaining, param)
        local end_time = os.time()
        local emergence_time = end_time - start_time

        table.insert(preloader.stats.emergence_times, emergence_time)
        if #preloader.stats.emergence_times > preloader.config.max_emergence_times then
            table.remove(preloader.stats.emergence_times, 1)
        end

        if action == core.emerge_cancelled or action == core.emerge_errored then
            preloader.stats.timeout_count = preloader.stats.timeout_count + 1
            core.log("warning", "Emergence failed for chunk " .. item.chunk .. " - action: " .. action)
        else
            add_to_cache(item.chunk, "chunk_data", item.priority)
            preloader.stats.chunks_loaded = preloader.stats.chunks_loaded + 1
            --core.log("info", "Emergence completed for chunk " .. item.chunk .. " in " .. emergence_time .. "s")
        end
    end, item)

    preloader.stats.queue_size = #preloader.prediction_queue + #preloader.batch_queue
end

-- Permet de traiter la file d'attente des émergences pour les chunks en batch
local function process_batch_queue()
    if #preloader.batch_queue == 0 then return end

    local batch = {}
    for i = 1, math.min(preloader.config.batch_size, #preloader.batch_queue) do
        table.insert(batch, table.remove(preloader.batch_queue, 1))
    end

    --core.log("info", "Processing batch of " .. #batch .. " chunks")

    for _, item in ipairs(batch) do
        local start_time = os.time()

        core.emerge_area(item.pos, item.pos, function(blockpos, action, calls_remaining, param)
            local end_time = os.time()
            local emergence_time = end_time - start_time

            if action ~= core.emerge_cancelled and action ~= core.emerge_errored then
                add_to_cache(item.chunk, "chunk_data", item.priority)
                preloader.stats.chunks_loaded = preloader.stats.chunks_loaded + 1
                --core.log("warning", "Batch emergence completed for chunk " .. item.chunk)
            else
                core.log("warning", "Batch emergence failed for chunk " .. item.chunk)
            end
        end, item)
    end

    preloader.stats.queue_size = #preloader.prediction_queue + #preloader.batch_queue
end

-- Décharge les chunks anciens qui ne sont plus nécessaires
local function unload_old_chunks()
    local current_time = os.time()
    local players = core.get_connected_players()
    local chunks_to_remove = {}
    local processed = 0

    for chunk_key, cache_data in pairs(preloader.cache) do
        if processed >= preloader.config.max_operations_per_tick then
            break
        end

        local age = current_time - cache_data.timestamp

        if age > preloader.config.unload_timeout then
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
        preloader.thermal_data[chunk_key] = nil
        preloader.stats.chunks_unloaded = preloader.stats.chunks_unloaded + 1
        core.log("info", "Unloaded old chunk " .. chunk_key)
    end
end

-- Boucle principale
local function main_loop()
    if not preloader.enabled then return end

    preloader.tick_start_time = os.time()
    preloader.operations_this_tick = 0

    process_compression_queue()

    if preloader.config.async_processing then
        if preloader.operations_this_tick < preloader.config.max_operations_per_tick then
            decay_thermal_data()
            preloader.operations_this_tick = preloader.operations_this_tick + 1
        end

        if preloader.operations_this_tick < preloader.config.max_operations_per_tick then
            check_system_load()
            preloader.operations_this_tick = preloader.operations_this_tick + 1
        end

        if preloader.operations_this_tick < preloader.config.max_operations_per_tick then
            cleanup_cache()
            preloader.operations_this_tick = preloader.operations_this_tick + 1
        end

        if preloader.operations_this_tick < preloader.config.max_operations_per_tick then
            unload_old_chunks()
            preloader.operations_this_tick = preloader.operations_this_tick + 1
        end
    else
        decay_thermal_data()
        check_system_load()
        cleanup_cache()
        unload_old_chunks()
    end

    local players = core.get_connected_players()
    local interval = preloader.emergency_mode and preloader.config.emergency_prediction_interval or preloader.config.prediction_interval

    local players_processed = 0
    local max_players_per_tick = preloader.emergency_mode and 2 or 4

    for _, player in ipairs(players) do
        if players_processed >= max_players_per_tick then
            break
        end

        local predictions = predict_player_movement(player)

        local predictions_processed = 0
        for _, prediction in ipairs(predictions) do
            if predictions_processed >= preloader.config.max_operations_per_tick then
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

local function reset_stats()
    preloader.stats = {
        queue_size = 0,
        cache_hits = 0,
        cache_misses = 0,
        emergence_times = {},
        timeout_count = 0,
        chunks_loaded = 0,
        chunks_unloaded = 0,
        predictions_made = 0,
        emergency_activations = 0
    }

    core.log("info", "Statistics reset")
end

core.register_chatcommand("chunk_manager_status", {
    params = "",
    description = S("Show preloader status"),
    privs = {server = true},
    func = function(name, param)
        local cache_size = #preloader.cache_keys

        local status = "Preloader Status:\n"
        status = status .. "Enabled: " .. tostring(preloader.enabled) .. "\n"
        status = status .. "Emergency Mode: " .. tostring(preloader.emergency_mode) .. "\n"
        status = status .. "Suspended: " .. tostring(preloader.suspended) .. "\n"
        status = status .. "Cache Size: " .. cache_size .. "\n"
        status = status .. "Queue Size: " .. preloader.stats.queue_size .. "\n"
        status = status .. "Cache Hits: " .. preloader.stats.cache_hits .. "\n"
        status = status .. "Cache Misses: " .. preloader.stats.cache_misses .. "\n"
        status = status .. "Chunks Loaded: " .. preloader.stats.chunks_loaded .. "\n"
        status = status .. "Chunks Unloaded: " .. preloader.stats.chunks_unloaded .. "\n"
        status = status .. "Predictions Made: " .. preloader.stats.predictions_made .. "\n"
        status = status .. "Emergency Activations: " .. preloader.stats.emergency_activations

        return true, status
    end
})

core.register_chatcommand("chunk_manager_emergency", {
    params = "",
    description = S("Toggle emergency mode"),
    privs = {server = true},
    func = function(name, param)
        preloader.emergency_mode = not preloader.emergency_mode

        core.log("warning", "Emergency mode " .. (preloader.emergency_mode and "ACTIVATED" or "DEACTIVATED") .. " by " .. name)

        return true, S("Emergency mode ") .. (preloader.emergency_mode and S("enabled") or S("disabled"))
    end
})

core.register_chatcommand("chunk_manager_cleanup", {
    params = "",
    description = S("Force cache cleanup"),
    privs = {server = true},
    func = function(name, param)
        preloader.cache = {}
        preloader.cache_keys = {}
        preloader.thermal_data = {}
        preloader.prediction_queue = {}
        preloader.batch_queue = {}

        reset_stats()

        core.log("info", "Forced cleanup executed by " .. name)

        return true, S("Cache and queues cleared")
    end
})

core.register_chatcommand("chunk_manager_suspend", {
    params = "",
    description = S("Suspend chunk manager temporarily"),
    privs = {server = true},
    func = function(name, param)
        preloader.suspended = true
        preloader.suspend_time = os.time() + preloader.config.suspend_duration

        core.log("warning", "System suspended by " .. name .. " for " .. preloader.config.suspend_duration .. "s")

        return true, S("Chunk Manager suspended for ") .. preloader.config.suspend_duration .. "s"
    end
})

core.register_on_mods_loaded(function()
    core.after(1, main_loop)
end)

core.register_globalstep(function(dtime)
    if #preloader.batch_queue > 0 then
        process_batch_queue()
    end

    if #preloader.compression_queue > 0 then
        process_compression_queue()
    end
end)

return preloader