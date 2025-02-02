if GetConvar('qbx:enablequeue', 'true') == 'false' then return end

-- Disable hardcap because it kicks the player when the server is full

---@param resource string
AddEventHandler('onResourceStarting', function(resource)
    if resource == 'hardcap' then
        lib.print.info('Preventing hardcap from starting...')
        CancelEvent()
    end
end)

if GetResourceState('hardcap'):find('start') then
    lib.print.info('Stopping hardcap...')
    StopResource('hardcap')
end

-- Queue code

local config = require 'config.queue'
local maxPlayers = GlobalState.MaxPlayers

---Player license to queue position map.
---@type table<string, integer>
local playerPositions = {}
local queueSize = 0

---@param license string
local function enqueue(license)
    queueSize += 1
    playerPositions[license] = queueSize
end

---@param license string
local function dequeue(license)
    local pos = playerPositions[license]

    queueSize -= 1
    playerPositions[license] = nil

    -- decrease the positions of players who are after the current player in queue
    for k, v in pairs(playerPositions) do
        if v > pos then
            playerPositions[k] -= 1
        end
    end
end

---Map of player licenses that passed the queue and are downloading server content.
---Needs to be saved because these players won't be part of regular player counts such as `GetNumPlayerIndices`.
---@type table<string, { source: Source, timestamp: integer }>
local joiningPlayers = {}
local joiningPlayerCount = 0

---@param license string
local function removePlayerJoining(license)
    if joiningPlayers[license] then
        joiningPlayerCount -= 1
    end
    joiningPlayers[license] = nil
end

---@param license string
local function awaitPlayerJoinsOrDisconnects(license)
    local joiningData
    while true do
        joiningData = joiningPlayers[license]

        -- wait until the player finally joins or disconnects while installing server content
        -- this may result in waiting ~2 additional minutes if the player disconnects as FXServer will think that the player exists
        while DoesPlayerExist(joiningData.source --[[@as string]]) do
            Wait(1000)
        end

        -- wait until either the player reconnects or was disconnected for too long
        while joiningPlayers[license] and joiningPlayers[license].source == joiningData.source and (os.time() - joiningData.timestamp) < config.joiningTimeoutSeconds do
            Wait(1000)
        end

        -- if the player disconnected for too long stop waiting for them
        if joiningPlayers[license] and joiningPlayers[license].source == joiningData.source then
            removePlayerJoining(license)
            break
        end
    end
end

---@param source Source
---@param license string
local function updatePlayerJoining(source, license)
    if not joiningPlayers[license] then
        joiningPlayerCount += 1
    end
    joiningPlayers[license] = { source = source, timestamp = os.time() }
end

---@type table<string, true>
local timingOut = {}

---@param license string
---@return boolean shouldDequeue
local function awaitPlayerTimeout(license)
    timingOut[license] = true

    Wait(config.timeoutSeconds * 1000)

    -- if timeout data wasn't consumed then the player hasn't reconnected
    if timingOut[license] then
        timingOut[license] = nil
        return true
    end

    return false
end

---@param license string
---@return boolean playerTimingOut
local function isPlayerTimingOut(license)
    local playerTimingOut = timingOut[license] or false
    timingOut[license] = nil
    return playerTimingOut
end

---@param source Source
---@param license string
---@param deferrals Deferrals
local function awaitPlayerQueue(source, license, deferrals)
    if joiningPlayers[license] then
        -- the player was in the middle of joining, so let them in
        updatePlayerJoining(source, license)
        deferrals.done()
        return
    end

    local playerTimingOut = isPlayerTimingOut(license)

    if playerPositions[license] and not playerTimingOut then
        deferrals.done(Lang:t('error.already_in_queue'))
        return
    end

    if not playerTimingOut then
        enqueue(license)
    end

    -- wait until the player disconnected or until there are available slots and the player is first in queue
    while DoesPlayerExist(source --[[@as string]]) and ((GetNumPlayerIndices() + joiningPlayerCount) >= maxPlayers or playerPositions[license] > 1) do
        deferrals.update(Lang:t('info.in_queue', {
            queuePos = playerPositions[license],
            queueSize = queueSize,
        }))

        Wait(1000)
    end

    -- if the player disconnected while waiting in queue
    if not DoesPlayerExist(source --[[@as string]]) then
        if awaitPlayerTimeout(license) then
            dequeue(license)
        end
        return
    end

    updatePlayerJoining(source, license)
    dequeue(license)
    deferrals.done()

    awaitPlayerJoinsOrDisconnects(license)
end

return {
    awaitPlayerQueue = awaitPlayerQueue,
    removePlayerJoining = removePlayerJoining,
}