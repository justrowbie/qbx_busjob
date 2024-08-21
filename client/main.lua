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
    PreviousRoute = nil,
    CurrentRoute = nil,
    Npc = {},
    NpcBlip = nil,
    DeliveryBlip = nil,
    NpcTaken = false,
    NpcDelivered = false,
}

local BusData = {
    Active = false,
    Index = nil,
    PayPerNpc = 0,
    Model = nil,
    Price = 0
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
        PreviousRote = nil,
        CurrentRoute = nil,
        Npc = {},
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
    SetBlipColour(NpcData.DeliveryBlip, 2)
    SetBlipRoute(NpcData.DeliveryBlip, true)
    SetBlipRouteColour(NpcData.DeliveryBlip, 2)
    NpcData.CurrentRoute = route
    local inRange = false
    local shownTextUI = false
    local freeSeat = 1
    local pedPass = nil
    local distancePay = #(sharedConfig.npcLocations.locations[NpcData.CurrentRoute].xyz - sharedConfig.npcLocations.locations[NpcData.PreviousRoute].xyz) * BusData.PayPerNpc
    local controlPressed = false
    deliverZone = lib.zones.sphere({
        name = "qbx_busjob_bus_deliver",
        coords = vec3(sharedConfig.npcLocations.locations[route].x, sharedConfig.npcLocations.locations[route].y, sharedConfig.npcLocations.locations[route].z),
        radius = 10,
        debug = config.debugPoly,
        onEnter = function()
            inRange = true
            if #NpcData.Npc > 0 then
                local count = #NpcData.Npc
                CreateThread(function()
                    while count > 0 do
                        Wait(100)
                        lib.showTextUI(locale('info.stop_bus'))
                        if IsVehicleStopped(GetVehiclePedIsIn(cache.ped)) then
                            Wait(3000)
                            for index, ped in pairs(NpcData.Npc) do
                                print(index, ped)
                                count = count - 1
                                exports.qbx_core:Notify(locale('info.bus_job'), 'info', 7500, locale('info.dropped_off'))
                                pedPass = ped
                                TaskLeaveVehicle(pedPass, GetVehiclePedIsIn(cache.ped), 0)
                                SetEntityAsMissionEntity(pedPass, false, true)
                                SetEntityAsNoLongerNeeded(pedPass)
                                TaskWanderStandard(pedPass, 5, 5)
                                -- removePed(pedPass)
                                TriggerServerEvent('qbx_busjob:server:NpcPay', BusData.PayPerNpc)
                                NpcData.Npc[index] = nil
                                break
                            end
                            lib.showTextUI(locale('info.busstop_text'))
                            shownTextUI = true
                            exports.qbx_core:Notify(locale('info.bus_job'), 'info', 7500, locale('info.can_take_passenger'))
                        end
                    end
                end)
            else
                if not shownTextUI then
                    lib.showTextUI(locale('info.busstop_text'))
                    shownTextUI = true
                end
            end
        end,
        inside = function()
            if not controlPressed and IsControlJustPressed(0, 38) then
                controlPressed = true
                removeNPCBlip()
                resetNpcTask()
                NpcData.PreviousRoute = route
                local maxSeats = GetVehicleMaxNumberOfPassengers(cache.vehicle)
                local vehicle = GetVehiclePedIsIn(cache.ped)
                local playerCoords = GetEntityCoords(cache.ped)
                local closestPed = lib.getNearbyPeds(sharedConfig.npcLocations.locations[NpcData.PreviousRoute].xyz, 10)
                if #closestPed > 0 then 
                    exports.qbx_core:Notify(locale('info.bus_job'), 'success', 7500, locale('info.got_passenger'))
                    lib.showTextUI(locale('info.wait_boarding'))
                    for i=1, #closestPed, 1 do
                        pedPass = closestPed[i].ped
                        if freeSeat == maxSeats then return end
                        if pedPass and not IsPedInAnyVehicle(pedPass) and not IsPedAPlayer(pedPass) and not IsPedDeadOrDying(pedPass, true) then
                            Wait(6000)
                            if not IsVehicleSeatAccessible(pedPass, vehicle, freeSeat, false, true) then return end
                            exports.qbx_core:Notify(locale('info.bus_job'), 'info', 2500, locale('info.passenger_coming'))
                            NpcData.Npc[freeSeat] = pedPass
                            freeSeat = freeSeat + 1
                            ClearPedTasks(pedPass)
                            SetPedRelationshipGroupHash(pedPass, GetPedRelationshipGroupHash(pedPass))
                            SetRelationshipBetweenGroups(0, GetPedRelationshipGroupHash(pedPass), GetPedRelationshipGroupHash(pedPass))
                            SetRelationshipBetweenGroups(0, GetPedRelationshipGroupHash(pedPass), GetHashKey("PLAYER"))
                            SetRelationshipBetweenGroups(0, GetHashKey("PLAYER"), GetPedRelationshipGroupHash(pedPass))
                            SetVehicleDoorsLocked(vehicle, 0)
                            TaskEnterVehicle(pedPass, vehicle, -1, freeSeat, 2.0, 1, 0)
                            SetBlockingOfNonTemporaryEvents(pedPass, true)
                            SetPedConfigFlag(pedPass, 17, true)
                            SetPedConfigFlag(pedPass, 285, true)
                            SetPedConfigFlag(pedPass, 294, true)
                            SetPedConfigFlag(pedPass, 299, true)
                            CreateThread(function()
                                while inRange do
                                    if IsPedInVehicle(pedPass, vehicle, false) then
                                        TaskSetBlockingOfNonTemporaryEvents(pedPass, true)
                                        SetBlockingOfNonTemporaryEvents(pedPass, true)
                                        SetEveryoneIgnorePlayer(PlayerId(), true)
                                        ClearPedTasks(pedPass)
                                        break
                                    end
                                    Wait(100)
                                end
                            end)
                        end
                    end
                else
                    exports.qbx_core:Notify(locale('info.bus_job'), 'error', 7500, locale('info.no_passenger'))
                end
                lib.hideTextUI()
                shownTextUI = false
                deliverZone:remove()
                deliverZone = nil
                getDeliveryLocation()
                TriggerServerEvent('qbx_busjob:server:DistancePay', math.abs(math.floor(distancePay/10)))
                -- resetNpcTask()
                -- nextStop()
                -- TriggerEvent('qbx_busjob:client:DoBusNpc')
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
    for k, v in pairs(config.allowedVehicles) do
        vehicleMenu[#vehicleMenu + 1] = {
            title = v.label..locale('info.rent_price')..v.rent,
            event = "qbx_busjob:client:TakeVehicle",
            args = {model = v.model, price = v.rent, paypernpc = v.paypernpc, index = k},
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
                                TriggerEvent('qbx_busjob:client:returnVehicle', BusData.Price)
                                BusData.Active = false
                                BusData.PayPerNpc = 0
                                BusData.Model = nil
                                BusData.Index = nil
                                BusData.Price = 0
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
                        TriggerEvent('qbx_busjob:client:returnVehicle', BusData.Price)
                        Wait(100)
                        BusData.Active = false
                        BusData.PayPerNpc = 0
                        BusData.Model = nil
                        BusData.Index = nil
                        BusData.Price = 0
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

RegisterNetEvent('qbx_busjob:client:returnVehicle', function(rent)
    TriggerServerEvent('qbx_busjob:server:returnRentBus', rent, 'cash')
end)

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
                BusData.PayPerNpc = data.paypernpc
                BusData.Model = data.model
                BusData.Index = data.index
                BusData.Price = data.price
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
        NpcData.Npc = {}
        removeNPCBlip()
        NpcData.NpcBlip = AddBlipForCoord(sharedConfig.npcLocations.locations[route].x, sharedConfig.npcLocations.locations[route].y, sharedConfig.npcLocations.locations[route].z)
        SetBlipColour(NpcData.NpcBlip, 2)
        SetBlipRoute(NpcData.NpcBlip, true)
        SetBlipRouteColour(NpcData.NpcBlip, 2)
        NpcData.CurrentRoute = route
        NpcData.Active = true
        local inRange = false
        local shownTextUI = false
        local freeSeat = 1
        local pedPass = nil
        local distancePay = #(sharedConfig.npcLocations.locations[NpcData.CurrentRoute].xyz - config.pedLoc.xyz) * BusData.PayPerNpc
        local controlPressed = false
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
            end,
            inside = function()
                if not controlPressed and IsControlJustPressed(0, 38) then
                    controlPressed = true
                    NpcData.PreviousRoute = route
                    local maxSeats = GetVehicleMaxNumberOfPassengers(cache.vehicle)
                    local vehicle = GetVehiclePedIsIn(cache.ped)
                    local playerCoords = GetEntityCoords(cache.ped)
                    local closestPed = lib.getNearbyPeds(sharedConfig.npcLocations.locations[NpcData.CurrentRoute].xyz, 10)
                    if #closestPed > 0 then 
                        exports.qbx_core:Notify(locale('info.bus_job'), 'success', 7500, locale('info.got_passenger'))
                        lib.showTextUI(locale('info.wait_boarding'))
                        for i=1, #closestPed, 1 do
                            pedPass = closestPed[i].ped
                            if freeSeat == maxSeats then return end
                            if pedPass and not IsPedInAnyVehicle(pedPass) and not IsPedAPlayer(pedPass) and not IsPedDeadOrDying(pedPass, true) then
                                Wait(6000)
                                if not IsVehicleSeatAccessible(pedPass, GetVehiclePedIsIn(cache.ped), freeSeat, false, true) then return end
                                exports.qbx_core:Notify(locale('info.bus_job'), 'info', 2500, locale('info.passenger_coming'))
                                NpcData.Npc[freeSeat] = pedPass
                                freeSeat = freeSeat + 1
                                ClearPedTasks(pedPass)
                                SetPedRelationshipGroupHash(pedPass, GetPedRelationshipGroupHash(pedPass))
                                SetRelationshipBetweenGroups(0, GetPedRelationshipGroupHash(pedPass), GetPedRelationshipGroupHash(pedPass))
                                SetRelationshipBetweenGroups(0, GetPedRelationshipGroupHash(pedPass), GetHashKey("PLAYER"))
                                SetRelationshipBetweenGroups(0, GetHashKey("PLAYER"), GetPedRelationshipGroupHash(pedPass))
                                SetVehicleDoorsLocked(vehicle, 0)
                                TaskEnterVehicle(pedPass, vehicle, -1, freeSeat, 2.0, 1, 0)
                                SetBlockingOfNonTemporaryEvents(pedPass, true)
                                SetPedConfigFlag(pedPass, 17, true)
                                SetPedConfigFlag(pedPass, 285, true)
                                SetPedConfigFlag(pedPass, 294, true)
                                SetPedConfigFlag(pedPass, 299, true)
                                CreateThread(function()
                                    while inRange do
                                        if IsPedInVehicle(pedPass, vehicle, false) then
                                            TaskSetBlockingOfNonTemporaryEvents(pedPass, true)
                                            SetBlockingOfNonTemporaryEvents(pedPass, true)
                                            SetEveryoneIgnorePlayer(PlayerId(), true)
                                            ClearPedTasks(pedPass)
                                            break
                                        end
                                        Wait(100)
                                    end
                                end)
                            end
                        end
                    else
                        exports.qbx_core:Notify(locale('info.bus_job'), 'error', 7500, locale('info.no_passenger'))
                    end
                    lib.notify({
                        title = locale('info.bus_job'),
                        description = locale('info.goto_busstop'),
                        type = 'info'
                    })
                    removeNPCBlip()
                    getDeliveryLocation()
                    NpcData.NpcTaken = true
                    lib.hideTextUI()
                    shownTextUI = false
                    pickupZone:remove()
                    pickupZone = nil
                    TriggerServerEvent('qbx_busjob:server:DistancePay', math.abs(math.floor(distancePay/10)))
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