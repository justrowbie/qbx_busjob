local config = require 'config.client'
local sharedConfig = require 'config.shared'
local route = 1
local max = #sharedConfig.npcLocations.locations
local busBlip = nil
local vehicleZone
local deliverZone
local pickupZone
local busParkingZone

local NpcData = {
    Active = false,
    LastNpc = nil,
    LastDeliver = nil,
    Npc = {},
    NpcBlip = nil,
    DeliveryBlip = nil,
    NpcTaken = false,
    NpcDelivered = false,
    CountDown = 180
}

local BusData = {
    Active = false,
}

local busPed = nil

-- Functions
local function enumerateEntitiesWithinDistance(entities, isPlayerEntities, coords, maxDistance)
	local nearbyEntities = {}
	if coords then
		coords = vec3(coords.x, coords.y, coords.z)
	else
		coords = GetEntityCoords(cache.ped)
	end
	for k, entity in pairs(entities) do
		local distance = #(coords - GetEntityCoords(entity))
		if distance <= maxDistance then
			nearbyEntities[#nearbyEntities + 1] = isPlayerEntities and k or entity
		end
	end
	return nearbyEntities
end

local function getVehiclesInArea(coords, maxDistance) -- Vehicle inspection in designated area
	return enumerateEntitiesWithinDistance(GetGamePool('CVehicle'), false, coords, maxDistance)
end

local function isSpawnPointClear(coords, maxDistance) -- Check the spawn point to see if it's empty or not:
	return #getVehiclesInArea(coords, maxDistance) == 0
end

local function getVehicleSpawnPoint()
    local near = nil
	local distance = 10000
	for k, v in pairs(config.busSpawns) do
        if isSpawnPointClear(vec3(v.x, v.y, v.z), 2.5) then
            local pos = GetEntityCoords(cache.ped)
            local cur_distance = #(pos - vec3(v.x, v.y, v.z))
            if cur_distance < distance then
                distance = cur_distance
                near = k
            end
        end
    end
	return near
end

local function resetNpcTask()
    NpcData = {
        Active = false,
        LastNpc = nil,
        LastDeliver = nil,
        Npc = nil,
        NpcBlip = nil,
        DeliveryBlip = nil,
        NpcTaken = false,
        NpcDelivered = false,
    }
end

local function removeBusBlip()
    if not busBlip then return end
    RemoveBlip(busBlip)
    busBlip = nil
end

local function removeNPCBlip()
    if NpcData.DeliveryBlip then
        RemoveBlip(NpcData.DeliveryBlip)
        NpcData.DeliveryBlip = nil
    end

    if NpcData.NpcBlip then
        RemoveBlip(NpcData.NpcBlip)
        NpcData.NpcBlip = nil
    end
end

local function updateBlip()
    if not config.useBlips then return end
    if sharedConfig.usingJob then
        if table.type(QBX.PlayerData) == 'empty' or (QBX.PlayerData.job.name ~= "bus" and busBlip) then
            removeBusBlip()
            return
        elseif (QBX.PlayerData.job.name == "bus" and not busBlip) then
            local coords = config.locations.main.coords
            busBlip = AddBlipForCoord(coords.x, coords.y, coords.z)
            SetBlipSprite(busBlip, 513)
            SetBlipDisplay(busBlip, 4)
            SetBlipScale(busBlip, 0.6)
            SetBlipAsShortRange(busBlip, true)
            SetBlipColour(busBlip, 2)
            BeginTextCommandSetBlipName("STRING")
            AddTextComponentSubstringPlayerName(locale('info.bus_depot'))
            EndTextCommandSetBlipName(busBlip)
            return
        end
    else
        removeBusBlip()
        if not busBlip then
            local coords = config.locations.main.coords
            busBlip = AddBlipForCoord(coords.x, coords.y, coords.z)
            SetBlipSprite(busBlip, 513)
            SetBlipDisplay(busBlip, 4)
            SetBlipScale(busBlip, 0.6)
            SetBlipAsShortRange(busBlip, true)
            SetBlipColour(busBlip, 2)
            BeginTextCommandSetBlipName("STRING")
            AddTextComponentSubstringPlayerName(locale('info.bus_depot'))
            EndTextCommandSetBlipName(busBlip)
        end
    end
end

local function isPlayerVehicleABus()
    if not cache.vehicle then return false end
    local veh = GetEntityModel(cache.vehicle)

    for i = 1, #config.allowedVehicles, 1 do
        if veh == config.allowedVehicles[i].model then
            return true
        end
    end

    if veh == `dynasty` then
        return true
    end

    return false
end

local function nextStop()
    route = route <= (max - 1) and route + 1 or 1
end

local function removePed(ped)
    SetTimeout(60000, function()
        DeletePed(ped)
    end)
end

local function getDeliveryLocation()
    nextStop()
    removeNPCBlip()
    NpcData.DeliveryBlip = AddBlipForCoord(sharedConfig.npcLocations.locations[route].x, sharedConfig.npcLocations.locations[route].y, sharedConfig.npcLocations.locations[route].z)
    SetBlipColour(NpcData.DeliveryBlip, 3)
    SetBlipRoute(NpcData.DeliveryBlip, true)
    SetBlipRouteColour(NpcData.DeliveryBlip, 3)
    NpcData.LastDeliver = route
    local inRange = false
    local shownTextUI = false
    deliverZone = lib.zones.sphere({
        name = "qbx_busjob_bus_deliver",
        coords = vec3(sharedConfig.npcLocations.locations[route].x, sharedConfig.npcLocations.locations[route].y, sharedConfig.npcLocations.locations[route].z),
        radius = 10,
        debug = config.debugPoly,
        onEnter = function()
            inRange = true
            if not shownTextUI then
                lib.showTextUI(locale('info.busstop_text'))
                shownTextUI = true
            end
        end,
        inside = function()
            if IsControlJustPressed(0, 38) then
                TaskLeaveVehicle(NpcData.Npc, cache.vehicle, 0)
                SetEntityAsMissionEntity(NpcData.Npc, false, true)
                SetEntityAsNoLongerNeeded(NpcData.Npc)
                local targetCoords = sharedConfig.npcLocations.locations[NpcData.LastNpc]
                TaskGoStraightToCoord(NpcData.Npc, targetCoords.x, targetCoords.y, targetCoords.z, 1.0, -1, 0.0, 0.0)
                lib.notify({
                    title = locale('info.bus_job'),
                    description = locale('info.dropped_off'),
                    type = 'success'
                })
                removeNPCBlip()
                removePed(NpcData.Npc)
                resetNpcTask()
                nextStop()
                TriggerEvent('qbx_busjob:client:DoBusNpc')
                lib.hideTextUI()
                shownTextUI = false
                deliverZone:remove()
                deliverZone = nil
            end
        end,
        onExit = function()
            lib.hideTextUI()
            shownTextUI = false
            inRange = false
        end
    })
end

local function busGarage()
    local vehicleMenu = {}
    for _, v in pairs(config.allowedVehicles) do
        vehicleMenu[#vehicleMenu + 1] = {
            title = locale('info.bus'),
            event = "qbx_busjob:client:TakeVehicle",
            args = {model = v.model, price = v.rent},
            icon = 'fa-solid fa-bus'
        }
    end
    lib.registerContext({
        id = 'qbx_busjob_open_garage_context_menu',
        title = locale('info.bus_header'),
        options = vehicleMenu
    })
    lib.showContext('qbx_busjob_open_garage_context_menu')
end

local function updateZone()
    if config.useTarget then
        if busPed then DeletePed(busPed) end
        lib.requestModel(`a_m_m_indian_01`)
        busPed = CreatePed(3, `a_m_m_indian_01`, config.pedLoc.x, config.pedLoc.y, config.pedLoc.z, config.pedLoc.w, false, true)
        SetModelAsNoLongerNeeded(`a_m_m_indian_01`)
        SetBlockingOfNonTemporaryEvents(busPed, true)
        FreezeEntityPosition(busPed, true)
        SetEntityInvincible(busPed, true)
        exports.interact:RemoveLocalEntityInteraction(busPed, 'qbx_busjob_ped')
        if sharedConfig.usingJob then
            exports.interact:AddLocalEntityInteraction({
                entity = busPed,
                name = 'qbx_busjob_ped',
                id = 'qbx_busjob_ped',
                distance = 3.0,
                interactDst = 2.0,
                groups = 'bus',
                options = {
                    {
                        label = locale('info.request_bus_target'),
                        event = 'qbx_busjob:client:requestBus',
                    },
                }
            })
        else
            exports.interact:AddLocalEntityInteraction({
                entity = busPed,
                name = 'qbx_busjob_ped',
                id = 'qbx_busjob_ped',
                distance = 3.0,
                interactDst = 2.0,
                options = {
                    {
                        label = locale('info.request_bus_target'),
                        event = 'qbx_busjob:client:requestBus',
                    },
                }
            })
        end
    else
        if vehicleZone then
            vehicleZone:remove()
            vehicleZone = nil
        end

        if table.type(QBX.PlayerData) == 'empty' or QBX.PlayerData.job.name ~= 'bus' then return end

        local inRange = false
        local shownTextUI = false
        vehicleZone = lib.zones.sphere({
            name = "qbx_busjob_bus_main",
            coords = config.locations.garage.coords.xyz,
            radius = 5,
            debug = config.debugPoly,
            onEnter = function()
                inRange = true
            end,
            inside = function()
                if not isPlayerVehicleABus() then
                    if not shownTextUI then
                        lib.showTextUI(locale('info.bus_job_vehicles'))
                        shownTextUI = true
                    end
                    if IsControlJustReleased(0, 38) then
                        busGarage()
                        lib.hideTextUI()
                        shownTextUI = false
                    end
                else
                    if not shownTextUI then
                        lib.showTextUI(locale('info.bus_stop_work'))
                        shownTextUI = true
                    end
                    if IsControlJustReleased(0, 38) then
                        if not NpcData.Active or NpcData.Active and not NpcData.NpcTaken then
                            if cache.vehicle then
                                BusData.Active = false
                                DeleteVehicle(cache.vehicle)
                                removeNPCBlip()
                                lib.hideTextUI()
                                shownTextUI = false
                                resetNpcTask()
                            end
                        else
                            lib.notify({
                                title = locale('info.bus_job'),
                                description = locale('error.drop_off_passengers'),
                                type = 'error'
                            })
                        end
                    end
                end
            end,
            onExit = function()
                shownTextUI = false
                inRange = false
                Wait(1000)
                lib.hideTextUI()
            end
        })
    end
end

local function setupBusParkingZone()
    busParkingZone = lib.zones.box({
        coords = vec3(config.locations.garage.coords.x, config.locations.garage.coords.y, config.locations.main.coords.z),
        size = vec3(10.0, 40.0, 4.0),
        rotation = -10,
        debug = config.debugPoly,
        inside = function()
            if IsControlJustReleased(0, 38) then
                if not NpcData.Active or NpcData.Active and not NpcData.NpcTaken then
                    if cache.vehicle then
                        BusData.Active = false
                        DeleteVehicle(cache.vehicle)
                        removeNPCBlip()
                        lib.hideTextUI()
                        shownTextUI = false
                        resetNpcTask()
                    end
                else
                    lib.notify({
                        title = locale('info.bus_job'),
                        description = locale('error.drop_off_passengers'),
                        type = 'error'
                    })
                end
            end
        end,
        onEnter = function()
            lib.showTextUI(locale('info.bus_stop_work'))
        end,
        onExit = function()
            lib.hideTextUI()
        end
    })
end

local function destroyBusParkingZone()
    if not busParkingZone then return end

    busParkingZone:remove()
    busParkingZone = nil
end

local function checkRentType(data)
    local money = QBX.PlayerData.money
    if money.cash >= data.price then
        return 'cash'
    elseif money.bank >= data.price then
        return 'bank'
    end
    return false
end

local function init()
    if sharedConfig.usingJob then
        if QBX.PlayerData.job.name == 'bus' then
            updateBlip()
            updateZone()
            setupBusParkingZone()
        end
    else
        updateBlip()
        updateZone()
        setupBusParkingZone()
    end
end

-- onExit()

RegisterNetEvent('qbx_busjob:client:requestBus', function()
    busGarage()
end)

RegisterNetEvent("qbx_busjob:client:TakeVehicle", function(data)
    if BusData.Active then
        lib.notify({
            title = locale('info.bus_job'),
            description = locale('error.one_bus_active'),
            type = 'error'
        })
        return
    end

    local SpawnPoint = getVehicleSpawnPoint()
    local rentPayType = checkRentType(data)
    if rentPayType then
        TriggerServerEvent('qbx_busjob:server:payRentBus', data.price, rentPayType)
        if SpawnPoint then
            local coords = config.busSpawns[SpawnPoint]
            local CanSpawn = isSpawnPointClear(coords, 2.0)
            if CanSpawn then
                local netId = lib.callback.await('qbx_busjob:server:spawnBus', false, data.model, coords)
                Wait(300)
                if not netId or netId == 0 or not NetworkDoesEntityExistWithNetworkId(netId) then
                    lib.notify({
                        title = locale('info.bus_job'),
                        description = locale('error.failed_to_spawn'),
                        type = 'error'
                    })
                    return
                end

                local veh = NetToVeh(netId)
                if veh == 0 then
                    lib.notify({
                        title = locale('info.bus_job'),
                        description = locale('error.failed_to_spawn'),
                        type = 'error'
                    })
                    return
                end

                exports['cdn-fuel']:SetFuel(veh, 100)
                SetVehicleEngineOn(veh, true, true, false)
                lib.hideContext()
                TriggerEvent('qbx_busjob:client:DoBusNpc')
            else
                exports.qbx_core:Notify(locale('info.no_spawn_point'), 'error')
            end
        else
            exports.qbx_core:Notify(locale('info.no_spawn_point'), 'error')
            return
        end
    else
        exports.qbx_core:Notify(locale('error.no_money'), 'error')
        return
    end
end)

-- Events
AddEventHandler('onResourceStart', function(resourceName)
    -- handles script restarts
    if GetCurrentResourceName() ~= resourceName then return end
    init()
end)

RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
    init()
end)

RegisterNetEvent('QBCore:Client:OnPlayerUnload', function()
    destroyBusParkingZone()
end)

RegisterNetEvent('QBCore:Player:SetPlayerData', function()
    if sharedConfig.usingJob then
        init()
    end
end)

RegisterNetEvent('qbx_busjob:client:DoBusNpc', function()
    if not isPlayerVehicleABus() then
        lib.notify({
            title = locale('info.bus_job'),
            description = locale('error.not_in_bus'),
            type = 'error'
        })
        return
    end

    if not NpcData.Active then
        -- local Gender = math.random(1, #config.npcSkins)
        -- local PedSkin = math.random(1, #config.npcSkins[Gender])
        -- local model = joaat(config.npcSkins[Gender][PedSkin])
        -- lib.requestModel(model, 10000)
        -- NpcData.Npc = CreatePed(3, model, sharedConfig.npcLocations.locations[route].x, sharedConfig.npcLocations.locations[route].y, sharedConfig.npcLocations.locations[route].z - 0.98, sharedConfig.npcLocations.locations[route].w, false, true)
        -- SetModelAsNoLongerNeeded(model)
        -- PlaceObjectOnGroundProperly(NpcData.Npc)
        -- FreezeEntityPosition(NpcData.Npc, true)
        NpcData.Npc = {}
        removeNPCBlip()
        NpcData.NpcBlip = AddBlipForCoord(sharedConfig.npcLocations.locations[route].x, sharedConfig.npcLocations.locations[route].y, sharedConfig.npcLocations.locations[route].z)
        SetBlipColour(NpcData.NpcBlip, 2)
        SetBlipRoute(NpcData.NpcBlip, true)
        SetBlipRouteColour(NpcData.NpcBlip, 2)
        NpcData.LastNpc = route
        NpcData.Active = true
        local inRange = false
        local shownTextUI = false
        local freeSeat = 0
        pickupZone = lib.zones.sphere({
            name = "qbx_busjob_bus_pickup",
            coords = vec3(sharedConfig.npcLocations.locations[route].x, sharedConfig.npcLocations.locations[route].y, sharedConfig.npcLocations.locations[route].z),
            radius = 10,
            debug = config.debugPoly,
            onEnter = function()
                inRange = true
                if not shownTextUI then
                    lib.showTextUI(locale('info.busstop_text'))
                    shownTextUI = true
                end
                CreateThread(function()
                    repeat
                        Wait(0)
                        if IsControlJustPressed(0, 38) then
                            lib.notify({
                                title = locale('info.bus_job'),
                                description = locale('info.goto_busstop'),
                                type = 'info'
                            })
                            removeNPCBlip()
                            getDeliveryLocation()
                            NpcData.NpcTaken = true
                            TriggerServerEvent('qbx_busjob:server:NpcPay')
                            lib.hideTextUI()
                            shownTextUI = false
                            pickupZone:remove()
                            pickupZone = nil
                            break
                        end
                    until not inRange
                end)
            end,
            inside = function()
                if IsControlJustPressed(0, 44) then
                    exports.qbx_core:Notify('Seorang penumpang menghampiri', 'success', 2500)
                    local maxSeats = GetVehicleMaxNumberOfPassengers(cache.vehicle)
                    local vehicle = GetVehiclePedIsIn(cache.ped)
                    local vehCoords = GetEntityCoords(cache.vehicle)
                    local playerCoords = GetEntityCoords(cache.ped)
                    local closestPed = lib.getNearbyPeds(playerCoords, 20)
                    print('maxSeats', maxSeats, 'vehicle', vehicle)
                    for i=1, #closestPed do
                        local pedNetId = PedToNet(closestPed[i].ped)
                        print('pedNetId', pedNetId)
                        if pedNetId then
                            if NpcData.Npc[pedNetId] then
                                return
                            else
                                local pedPass = NetToPed(pedNetId)
                                print('freeSeat',freeSeat)
                                if not IsPedInAnyVehicle(pedPass) and not IsPedAPlayer(pedPass) and not IsPedDeadOrDying(pedPass, true) then
                                    freeSeat = freeSeat + 1
                                    ClearPedTasksImmediately(pedPass)
                                    if IsEntityPositionFrozen(pedPass) then
                                        FreezeEntityPosition(pedPass, false)
                                    end
                                    SetRelationshipBetweenGroups(0, GetPedRelationshipGroupHash(pedPass), GetHashKey("PLAYER"))
                                    SetRelationshipBetweenGroups(0, GetHashKey("PLAYER"), GetPedRelationshipGroupHash(pedPass))
                                    SetVehicleDoorsLocked(vehicle, 0)
                                    SetBlockingOfNonTemporaryEvents(pedPass)
                                    TaskEnterVehicle(pedPass, vehicle, -1, freeSeat, 2.0, 1, 0)
                                    SetPedKeepTask(pedPass, true)
                                    CreateThread(function()
                                        while true do
                                            if IsPedInVehicle(pedPass, vehicle, false) then
                                                print('taken',pedPass)
                                                TaskSetBlockingOfNonTemporaryEvents(pedPass, true)
                                                SetBlockingOfNonTemporaryEvents(pedPass, true)
                                                SetEveryoneIgnorePlayer(PlayerId(), true)
                                                ClearPedTasks(pedPass)
                                                NpcData.Npc[pedNetId] = true
                                                break
                                            end
                                            Wait(100)
                                        end
                                    end)
                                end
                            end
                        end
                    end
                end
            end,
            onExit = function()
                lib.hideTextUI()
                shownTextUI = false
                inRange = false
            end
        })
    else
        lib.notify({
            title = locale('info.bus_job'),
            description = locale('error.already_driving_bus'),
            type = 'info'
        })
    end
end)

CreateThread(function()
    init()
end)