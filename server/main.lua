local config = require 'config.server'
local sharedConfig = require 'config.shared'

local function isPlayerNearBus(src)
    local ped = GetPlayerPed(src)
    local coords = GetEntityCoords(ped)
    for _, v in pairs(sharedConfig.npcLocations.locations) do
        local dist = #(coords - vec3(v.x, v.y, v.z))
        if dist < 20 then
            return true
        end
    end
    return false
end

lib.callback.register('qbx_busjob:server:spawnBus', function(source, model, coords)
    local src = source
    local ped = GetPlayerPed(src)

    local netId = qbx.spawnVehicle({ model = model, spawnSource = coords, warp = GetPlayerPed(source) })
    if not netId or netId == 0 then return end
    local veh = NetworkGetEntityFromNetworkId(netId)
    if not veh or veh == 0 then return end

    local plate = locale('info.bus_plate') .. tostring(math.random(1000, 9999))
    SetVehicleNumberPlateText(veh, plate)
    TriggerClientEvent('vehiclekeys:client:SetOwner', source, plate)
    return netId
end)

RegisterNetEvent('qbx_busjob:server:payRentBus', function(amount, type)
    local src = source
    local player = exports.qbx_core:GetPlayer(src)
    if player.Functions.RemoveMoney(type, amount) then
        exports.qbx_core:Notify(src, locale('success.rent_bus'), 'success', 7500)
    end
end)

RegisterNetEvent('qbx_busjob:server:DistancePay', function(amount)
    local src = source
    local player = exports.qbx_core:GetPlayer(src)
    if not isPlayerNearBus(src) then return DropPlayer(src, locale('error.exploit_attempt')) end
    local payment = amount
    player.Functions.AddMoney('cash', payment)
end)

RegisterNetEvent('qbx_busjob:server:NpcPay', function(amount)
    local src = source
    local player = exports.qbx_core:GetPlayer(src)
    if not isPlayerNearBus(src) then return DropPlayer(src, locale('error.exploit_attempt')) end
    local payment = amount
    if math.random(1, 100) < config.bonusChance then
        payment = payment + config.bonusPay
    end
    player.Functions.AddMoney('cash', payment)
end)

RegisterNetEvent('qbx_busjob:server:returnRentBus', function(amount, type)
    local src = source
    local player = exports.qbx_core:GetPlayer(src)
    if player.Functions.AddMoney(type, amount * (sharedConfig.returnVehPercentage/100)) then
        exports.qbx_core:Notify(src, locale('info.bus_returned'), 'success', 7500)
    end
end)