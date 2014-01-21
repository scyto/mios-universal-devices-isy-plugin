--[[
	ISY Controller Plugin
	Copyright 2013 Garrett Power
]]
module ("L_ISYController1", package.seeall)

-- Load modules
local http = require('socket.http')
local mime = require('mime')
local url = require('socket.url')
local ltn12 = require('ltn12')
local lxp = require('lxp')

local DEBUG = false
local PARENT
local ISYCONTROLLER_SERVICEID = "urn:garrettwp-com:serviceId:ISYController1"
local SWITCH_SERVICEID = "urn:upnp-org:serviceId:SwitchPower1"
local DIMMER_SERVICEID = "urn:upnp-org:serviceId:Dimming1"
local LOCK_SERVICEID = "urn:micasaverde-com:serviceId:DoorLock1"
local SENSOR_SERVICEID = "urn:micasaverde-com:serviceId:SecuritySensor1"
local SCENE_SID = "urn:micasaverde-com:serviceId:SceneController1"
local HADEVICE_SID = "urn:micasaverde-com:serviceId:HaDevice1"
local TEMPSENSOR_SID = "urn:upnp-org:serviceId:TemperatureSensor1"
local TEMPSETPOINT_HEAT_SID = "urn:upnp-org:serviceId:TemperatureSetpoint1_Heat"
local TEMPSETPOINT_COOL_SID = "urn:upnp-org:serviceId:TemperatureSetpoint1_Cool"
local HVAC_MODE_SID = "urn:upnp-org:serviceId:HVAC_UserOperatingMode1"
local HVAC_FAN_MODE_SID = "urn:upnp-org:serviceId:HVAC_FanOperatingMode1"

local pidFile = "/var/run/isy_event_daemon.pid"
local initScriptPath = "/etc/init.d/isy_event_daemon"

local isyIP = ""
local isyPort = ""
local isyUser = ""
local isyPass = ""

local deviceMap = {}
local childToInsteonMap = {}
local insteonToChildMap = {}

local insteonDeviceCategory0 = {
    ['0'] = true,
    remoteLinc = {
        ['16'] = true
    }
}

local insteonDeviceCategory1 = {
    ['1'] = true,
    dimmerKPL = {
        ['5'] = true,
        ['9'] = true,
        ['12'] = true,
        ['27'] = true,
        ['28'] = true,
        ['41'] = true,
        ['65'] = true,
        ['66'] = true
    },
    dimmer = {
        ['0'] = true,
        ['1'] = true,
        ['2'] = true,
        ['3'] = true,
        ['4'] = true,
        ['6'] = true,
        ['7'] = true,
        ['10'] = true,
        ['11'] = true,
        ['13'] = true,
        ['14'] = true,
        ['19'] = true,
        ['23'] = true,
        ['24'] = true,
        ['25'] = true,
        ['26'] = true,
        ['29'] = true,
        ['30'] = true,
        ['31'] = true,
        ['32'] = true,
        ['33'] = true,
        ['34'] = true,
        ['36'] = true,
        ['39'] = true,
        ['42'] = true,
        ['43'] = true,
        ['44'] = true,
        ['45'] = true,
        ['48'] = true,
        ['49'] = true,
        ['50'] = true,
        ['58'] = true
    },
    fanLinc = {
        ['46'] = true
    }
}

local insteonDeviceCategory2 = {
    ['2'] = true,
    relayKPL = {
        ['5'] = true,
        ['15'] = true,
        ['30'] = true,
        ['32'] = true,
        ['37'] = true,
        ['44'] = true
    },
    relay = {
        ['6'] = true,
        ['7'] = true,
        ['8'] = true,
        ['9'] = true,
        ['10'] = true,
        ['11'] = true,
        ['12'] = true,
        ['13'] = true,
        ['14'] = true,
        ['16'] = true,
        ['17'] = true,
        ['18'] = true,
        ['20'] = true,
        ['21'] = true,
        ['22'] = true,
        ['23'] = true,
        ['24'] = true,
        ['25'] = true,
        ['26'] = true,
        ['28'] = true,
        ['31'] = true,
        ['33'] = true,
        ['34'] = true,
        ['35'] = true,
        ['41'] = true,
        ['42'] = true,
        ['55'] = true
    }
}

local insteonDeviceCategory7 = {
    ['7'] = true,
    iolinc = {
        ['0'] = true
    }
}

local insteonDeviceCategory16 = {
    ['16'] = true,
    motionSensor = {
        ['1'] = true,
        ['3'] = true,
        ['9'] = true
    }
}

local zwaveDeviceCategory4 = {
    ['4'] = true,
    relay = {
        ['16'] = true
    },
    dimmer = {
        ['17'] = true
    },
    lock = {
        ['64'] = true
    },
    thermostat = {
        ['8'] = true
    },
}

function log(text, level)
    luup.log("ISYController: " .. text, (level or 50))
end

function debugLog(text, level)
    if (DEBUG) then
        luup.log("ISYController: debug: " .. text, (level or 50))
    end
end

--
-- Min / Max Conversion
--
function minMaxConversion(max, value)
    local oldMin, oldMax, newMin, newMax

    if (max ~= nil and value ~= nil) then
        if (max == 100) then
            oldMin = 0
            oldMax = 255
            newMin = 0
            newMax = 100
        
        elseif (max == 255) then
            oldMin = 0
            oldMax = 100
            newMin = 0
            newMax = 255
            
        end    
        
        local oldRange = (oldMax - oldMin)  
        local newRange = (newMax - newMin)
        
        return math.floor(((((value - oldMin) * newRange) / oldRange) + newMin) + .5)
    end
end

--
-- Get child plugin id associated with insteon id
--
function getChild(insteonId)
    local child = insteonToChildMap[insteonId]
    debugLog("insteon id: " .. insteonId .. " = child: " .. child)
    
    return child
end

--
-- Get child plugin id associated with insteon id
--
function getInsteonId(deviceId)
    local insteonId = childToInsteonMap[insteonId]
    debugLog("child: " .. deviceId .. " = insteon id: " .. insteonId)
    
    return insteonId
end

--
-- Update variable if changed
-- Return true if changed or false if no change
--
function setIfChanged(serviceId, name, value, deviceId)
    local curValue = luup.variable_get(serviceId, name, deviceId)
    
    if ((value ~= curValue) or (curValue == nil)) then
        luup.variable_set(serviceId, name, value, deviceId)
        
        return true
        
    else
        return false
        
    end
end

--
-- Is daemon connected to isy
--
function daemonConnected()
    local netstat = "netstat -tn 2> /dev/null | grep ':9810' | grep " .. isyIP
    local n = io.popen(netstat)
    local output = n:read('*a')
    n:close()
    
    if (output ~= nil) then
        local t = {}
        for v in string.gmatch(output, "[^%s]+") do
            t[v] = true

        end

        if (t['ESTABLISHED']) then
            setIfChanged(ISYCONTROLLER_SERVICEID, "DaemonConnected", "Connected", PARENT)
        
        else        
            setIfChanged(ISYCONTROLLER_SERVICEID, "DaemonConnected", "Disconnected", PARENT)
            
        end
        
    else
        setIfChanged(ISYCONTROLLER_SERVICEID, "DaemonConnected", "Disconnected", PARENT)
        
    end
    
end

--
-- Is daemon running
--
function running()
    local f = io.open(pidFile, "r")
    if (f) then
        -- File exists
        f:close()
        
        setIfChanged(ISYCONTROLLER_SERVICEID, "DaemonRunning", "Running", PARENT)
        return true
     
    else
        setIfChanged(ISYCONTROLLER_SERVICEID, "DaemonRunning", "Stopped", PARENT)
        return false
    
    end
    
end

--
-- Intialize and Subscribe to ISY Even Daemon
--
function daemonInit()
    debugLog("Initializing and subscribing to ISY.")
    
    if (running()) then
        if (isyIP ~= nil and isyUser ~= nil and isyPass ~= nil) then
            local body = "<settings><pluginID>" .. PARENT .. "</pluginID><isyIP>" .. 
            isyIP .. "</isyIP><isyPort>" .. isyPort .. "</isyPort><isyUser>" .. 
            isyUser .. "</isyUser><isyPass>" .. isyPass .. "</isyPass></settings>"
            
            local t = {}
            local request, code, headers = http.request {
                url = "http://127.0.0.1:9810",
                method = "PUT HTTP/1.1",
                sink = ltn12.sink.table(t),
                source = ltn12.source.string(body),
                headers = {
                    ["Content-Length"] = tostring(body:len()),
                    ["Content-Type"] = "text/xml; charset=utf-8"
                }
            }
            
            if (code == 200) then
                debugLog("Successfully sent configuration data to ISY Event Daemon.")

                local t = {}
                local request, code, headers = http.request {
                    url = "http://127.0.0.1:9810",
                    method = "SUBSCRIBE HTTP/1.1",
                    sink = ltn12.sink.table(t)
                }
                
                if (code == 200) then
                    debugLog("Successfully issued subscribe to ISY Event Daemon.")

                end
            end
        end
    end
end

--
-- Event daemon stop function
--
function stop()
    local f = io.open(initScriptPath, "r")
    if (f) then
        debugLog("Stopping ISY Event Daemon.")
        
        -- File exists.
        f:close()
        --task("Stopping init script", 1)
        os.execute(initScriptPath .. " stop")
        --task("Stopped init script", 4)
        
        running()
    end
end

--
-- Event daemon start function
--
function start()
    local f = io.open(initScriptPath, "r")
    if (f) then
        debugLog("Starting ISY Event Daemon.")
        
        -- File exists.
        f:close()
        --task("Starting init script", 1)
        os.execute(initScriptPath .. " start")
        --task("Started init script", 4)
        
        running()
    end
end

--
-- Event daemon restart function
--
function restart()
    local f = io.open(initScriptPath, "r")
    if (f) then
        debugLog("Restarting ISY Event Daemon.")
            
        -- File exists.
        f:close()
        --task("Restarting init script", 1)
        os.execute(initScriptPath .. " stop")
        os.execute(initScriptPath .. " start")
        --task("Restarted init script", 4)
    
        running()    
    end
end

--
-- Send command to ISY Controller
--
function sendCommand(insteonId, type, cmd)
	if (type == "poll") then
		debugLog("Rest command: /rest/query/" .. url.escape(insteonId))
	
		local t = {}
		request, code, headers = http.request {
			url = "http://" .. isyIP .. ":" .. isyPort,
			method = "GET /rest/query/" .. url.escape(insteonId),
			sink = ltn12.sink.table(t),
			headers = {
				["Authorization"] = "Basic " .. (mime.b64(isyUser .. ":" .. isyPass))
			}
		}
	
		if (code == 200) then
			if (DEBUG == true) then
				httpResponse = table.concat(t)
				debugLog(httpResponse) 
			end
		end
		
	elseif (type == "command") then
		newCmd = string.gsub(cmd, "%s+", '%%20')
		
		debugLog("Rest command: " .. newCmd)
	
		local t = {}
		request, code, headers = http.request {
			url = "http://" .. isyIP .. ":" .. isyPort,
			method = "GET " .. newCmd,
			sink = ltn12.sink.table(t),
			headers = {
				["Authorization"] = "Basic " .. (mime.b64(isyUser .. ":" .. isyPass))
			}
		}
		
		if (code == 200) then
			if (DEBUG == true) then
				httpResponse = table.concat(t)
				debugLog(httpResponse) 
			end
		end

	elseif (type == "program") then
		local newCmd = insteonId .. "/" .. cmd
	
		debugLog("Rest command: /rest/programs/" .. newCmd)
	
		local t = {}
		request, code, headers = http.request {
			url = "http://" .. isyIP .. ":" .. isyPort,
			method = "GET /rest/programs/" .. newCmd,
			sink = ltn12.sink.table(t),
			headers = {
				["Authorization"] = "Basic " .. (mime.b64(isyUser .. ":" .. isyPass))
			}
		}
		
		if (code == 200) then
			if (DEBUG == true) then
				httpResponse = table.concat(t)
				debugLog(httpResponse) 
			end
		end

	else
		local newCmd = url.escape(insteonId) .. "/cmd/" .. cmd
	
		debugLog("Rest command: /rest/nodes/" .. newCmd)
	
		local t = {}
		request, code, headers = http.request {
			url = "http://" .. isyIP .. ":" .. isyPort,
			method = "GET /rest/nodes/" .. newCmd,
			sink = ltn12.sink.table(t),
			headers = {
				["Authorization"] = "Basic " .. (mime.b64(isyUser .. ":" .. isyPass))
			}
		}
		
		if (code == 200) then
			if (DEBUG == true) then
				httpResponse = table.concat(t)
				debugLog(httpResponse) 
			end
		end
	end
end

--
-- Insteon Controller (Category 0)
--
function insteonEventCategory0(node, command, action, subCat)
    local insteonId, subDev = string.match(node, "(%w+ %w+ %w+) (%w+)")  -- insteon id and sub device
    debugLog("insteonEventCategory0: insteonId " .. insteonId .. " subDev: " .. subDev)
    local time = os.time(os.date('*t'))

    -- RemoteLinc 4 Button Scene Controller
    if (insteonDeviceCategory0.remoteLinc[subCat]) then
        debugLog("RemoteLinc 4 Btn Scene: node " .. node .. " action: " .. action)
        local sceneId = getChild(insteonId)
        
        -- Scene Button
        -- We only care about DON and DOF events for scene controllers
        if (command == "DOF") then
            luup.variable_set(SCENE_SID, "sl_SceneDeactivated" , tonumber(subDev), sceneId)
            setIfChanged(HADEVICE_SID, 'LastUpdate', time, sceneId)
        
        elseif (command == "DON") then
            luup.variable_set(SCENE_SID, "sl_SceneActivated" , tonumber(subDev), sceneId)
            setIfChanged(HADEVICE_SID, 'LastUpdate', time, sceneId)
            
        end
    end
end

--
-- Insteon Dimmable Device (Category 1)
--
function insteonEventCategory1(node, command, action, subCat)
    local insteonId, subDev = string.match(node, "(%w+ %w+ %w+) (%w+)") -- insteon id and sub device
    local nodeParent = deviceMap[node].parent -- parent node of insteon device
    local time = os.time(os.date('*t'))
    
    -- KeypadLinc Dimmer
    if (insteonDeviceCategory1.dimmerKPL[subCat]) then
        debugLog("KeypadLinc Dimmer: node " .. node .. " action: " .. action)
        local deviceId = getChild(nodeParent)
        local sceneId = getChild(insteonId) 
        
        -- Main Device Switched
        if (nodeParent == node) then
            local result = false
            
            -- We only care about status changes
            if (command == "ST") then
                -- SwitchPower --
                
                -- Off
                if (action == "0") then
                    result = setIfChanged(SWITCH_SERVICEID, 'Status', 0, deviceId)
                    
                -- On
                else
                    result = setIfChanged(SWITCH_SERVICEID, 'Status', 1, deviceId)
                
                end
                
                -- Dimmer --
                local level = minMaxConversion(100, action)
                local result = setIfChanged(DIMMER_SERVICEID, 'LoadLevelStatus', level, deviceId)
                
                if (result) then
                    setIfChanged(HADEVICE_SID, 'LastUpdate', time, deviceId)
                end
            end
        end
        
        -- Scene Button
        -- We only care about DON and DOF events for scene controllers
        if (command == "DOF") then
            luup.variable_set(SCENE_SID, "sl_SceneDeactivated" , tonumber(subDev), sceneId)
            setIfChanged(HADEVICE_SID, 'LastUpdate', time, sceneId)
        
        elseif (command == "DON") then
            luup.variable_set(SCENE_SID, "sl_SceneActivated" , tonumber(subDev), sceneId)
            setIfChanged(HADEVICE_SID, 'LastUpdate', time, sceneId)
            
        end
        
    -- FanLinc
    elseif (insteonDeviceCategory1.fanLinc[subCat]) then
        debugLog("FanLinc: node " .. node .. " action: " .. action)
        local deviceId = getChild(node)
        local result = false
        
        -- We only care about status changes
        if (command == "ST") then
            -- SwitchPower --
            
            -- Off
            if (action == "0") then
                result = setIfChanged(SWITCH_SERVICEID, 'Status', 0, deviceId)
                
            -- On
            else
                result = setIfChanged(SWITCH_SERVICEID, 'Status', 1, deviceId)
            
            end
            
            -- FanLinc Dimmer
            local level = minMaxConversion(100, action)
            result = setIfChanged(DIMMER_SERVICEID, 'LoadLevelStatus', level, deviceId)
                
            if (result) then
                setIfChanged(HADEVICE_SID, 'LastUpdate', time, deviceId)
            end
        end
        
    -- Dimmer
    elseif (insteonDeviceCategory1.dimmer[subCat]) then
        debugLog("Dimmer: node " .. node .. " action: " .. action)
        local deviceId = getChild(nodeParent)
        local result = false
        
        -- We only care about status changes
        if (command == "ST") then
            -- SwitchPower --
            
            -- Off
            if (action == "0") then
                result = setIfChanged(SWITCH_SERVICEID, 'Status', 0, deviceId)
                
            -- On
            else
                result = setIfChanged(SWITCH_SERVICEID, 'Status', 1, deviceId)
            
            end
            
            local level = minMaxConversion(100, action)
            result = setIfChanged(DIMMER_SERVICEID, 'LoadLevelStatus', level, deviceId)
            
            if (result) then
                setIfChanged(HADEVICE_SID, 'LastUpdate', time, deviceId)
            end
        end
    end
end

--
-- Insteon Relay / Switch Device (Category 2)
--
function insteonEventCategory2(node, command, action, subCat)
    local insteonId, subDev = string.match(node, "(%w+ %w+ %w+) (%w+)")  -- insteon id and sub device
    local nodeParent = deviceMap[node].parent -- parent node of insteon device
    local time = os.time(os.date('*t'))

    -- KeypadLinc Relay
    if (insteonDeviceCategory2.relayKPL[subCat]) then
        debugLog("KeypadLinc Relay: node " .. node .. " action: " .. action)
        local deviceId = getChild(nodeParent)
        local sceneId = getChild(insteonId)
                
        -- Main Device Switched
        if (nodeParent == node) then
            local result = false
              
            -- We only care about status changes
            if (command == "ST") then      
                -- SwitchPower --
                
                -- Off
                if (action == "0") then
                    result = setIfChanged(SWITCH_SERVICEID, 'Status', 0, deviceId)
                    
                -- On
                else
                    result = setIfChanged(SWITCH_SERVICEID, 'Status', 1, deviceId)
                
                end
                
                if (result) then
                    setIfChanged(HADEVICE_SID, 'LastUpdate', time, deviceId)
                end
            end
        end
        
        -- Scene Button
        -- We only care about DON and DOF events for scene controllers
        if (command == "DOF") then
            luup.variable_set(SCENE_SID, "sl_SceneDeactivated" , tonumber(subDev), sceneId)
            setIfChanged(HADEVICE_SID, 'LastUpdate', time, sceneId)
        
        elseif (command == "DON") then
            luup.variable_set(SCENE_SID, "sl_SceneActivated" , tonumber(subDev), sceneId)
            setIfChanged(HADEVICE_SID, 'LastUpdate', time, sceneId)
            
        end
        
    -- Relay / Switch
    elseif (insteonDeviceCategory2.relay[subCat]) then
        debugLog("Relay: node " .. node .. " action: " .. action)
        local deviceId = getChild(nodeParent)
        local result = nil
          
        -- We only care about status changes
        if (command == "ST") then      
            -- SwitchPower --
            
            -- Off
            if (action == "0") then
                result = setIfChanged(SWITCH_SERVICEID, 'Status', 0, deviceId)
                
            -- On
            else
                result = setIfChanged(SWITCH_SERVICEID, 'Status', 1, deviceId)
            
            end
            
            if (result) then
                setIfChanged(HADEVICE_SID, 'LastUpdate', time, deviceId)
            end
        end
    end
end

--
-- Insteon Sensors and Actuators (Category 7)
--
function insteonEventCategory7(node, command, action, subCat)
    local insteonId, subDev = string.match(node, "(%w+ %w+ %w+) (%w+)")  -- insteon id and sub device
    debugLog("insteonEventCategory7: insteonId " .. insteonId .. " subDev: " .. subDev)
    local nodeParent = deviceMap[node].parent -- parent node of insteon device
    local time = os.time(os.date('*t'))

    -- IOLinc
    if (insteonDeviceCategory7.iolinc[subCat]) then
        debugLog("IOLinc: node " .. node .. " action: " .. action)
        local deviceId = getChild(nodeParent)
        debugLog("deviceId = " .. deviceId)
        local result = nil
         
        -- We only care about status changes
        if (command == "ST") then       
            -- Tripped --
            local reverse = luup.variable_get(SENSOR_SERVICEID, "Reverse", deviceId)
            if (reverse == nil) then
                debugLog("reverse is nil ")
                  luup.variable_set(SENSOR_SERVICEID, "Reverse", "0", deviceId)
                  reverse = "0"
            end

            debugLog("reverse = " .. reverse)

            -- not reversed
            if (reverse == "0") then

                -- secure (not tripped)
                if (action == "0") then
                    result = setIfChanged(SENSOR_SERVICEID, 'Tripped', 0, deviceId)
      
                -- tripped
                else
                    result = setIfChanged(SENSOR_SERVICEID, 'Tripped', 1, deviceId)
      
                end
                
            -- reversed
            else
                -- tripped
                if (action == "0") then
                    result = setIfChanged(SENSOR_SERVICEID, 'Tripped', 1, deviceId)
                  
                -- secure (not tripped)
                else
                    result = setIfChanged(SENSOR_SERVICEID, 'Tripped', 0, deviceId)
              
                end
            end
            
            if (result) then
                setIfChanged(HADEVICE_SID, 'LastUpdate', time, deviceId)
            end
        end
    end
end

--
-- Insteon Security / Health / Safety (Category 16)
--
function insteonEventCategory16(node, command, action, subCat)
    local insteonId, subDev = string.match(node, "(%w+ %w+ %w+) (%w+)")  -- insteon id and sub device
    debugLog("insteonEventCategory16: insteonId " .. insteonId .. " subDev: " .. subDev)
    local nodeParent = deviceMap[node].parent -- parent node of insteon device
    local time = os.time(os.date('*t'))

    -- Motion Sensor
    if (insteonDeviceCategory16.motionSensor[subCat]) then
        debugLog("MotionSensor: node " .. node .. " action: " .. action)
        local deviceId = getChild(nodeParent)
        local result = nil
         
        -- We only care about status changes
        if (command == "ST") then  
            -- secure (not tripped)
            if (action == "0") then
                result = setIfChanged(SENSOR_SERVICEID, 'Tripped', 0, deviceId)
          
            -- tripped
            else
                result = setIfChanged(SENSOR_SERVICEID, 'Tripped', 1, deviceId)
          
            end
            
            if (result) then
                setIfChanged(HADEVICE_SID, 'LastUpdate', time, deviceId)
            end
        end
    end
end


--
-- Z-Wave Relay / Dimmer Device (Category 4)
--
function zwaveEventCategory4(node, command, action, subCat)
    local insteonId, subDev = string.match(node, "(%w+ %w+ %w+) (%w+)")  -- insteon id and sub device
    local nodeParent = deviceMap[node].parent -- parent node of insteon device
    local time = os.time(os.date('*t'))

    -- Z-Wave Relay
    if (zwaveDeviceCategory4.relay[subCat]) then
        debugLog("Z-Wave Relay: node " .. node .. " action: " .. action)
        local deviceId = getChild(nodeParent)
                
        local result = nil
                
        -- SwitchPower --
        
        -- Off
        if (action == "0") then
            result = setIfChanged(SWITCH_SERVICEID, 'Status', 0, deviceId)
            
        -- On
        else
            result = setIfChanged(SWITCH_SERVICEID, 'Status', 1, deviceId)
        
        end
        
        if (result) then
            setIfChanged(HADEVICE_SID, 'LastUpdate', time, deviceId)
        end
        
    -- Dimmer
    elseif (zwaveDeviceCategory4.dimmer[subCat]) then
        debugLog("Z-Wave Dimmer: node " .. node .. " action: " .. action)
        local deviceId = getChild(nodeParent)
        
        local result = false
        
        -- SwitchPower --
        
        -- Off
        if (action == "0") then
            result = setIfChanged(SWITCH_SERVICEID, 'Status', 0, deviceId)
            
        -- On
        else
            result = setIfChanged(SWITCH_SERVICEID, 'Status', 1, deviceId)
        
        end
        
        result = setIfChanged(DIMMER_SERVICEID, 'LoadLevelStatus', action, deviceId)
        
        if (result) then
            setIfChanged(HADEVICE_SID, 'LastUpdate', time, deviceId)
        end
        
    -- Lock
    elseif (zwaveDeviceCategory4.lock[subCat]) then
        debugLog("Z-Wave Lock: node " .. node .. " action: " .. action)
        local deviceId = getChild(nodeParent)
        
        local result = false
        
        -- SwitchPower --
        
        -- Off
        if (action == "0") then
            result = setIfChanged(LOCK_SERVICEID, 'Status', 0, deviceId)
            
        -- On
        else
            result = setIfChanged(LOCK_SERVICEID, 'Status', 1, deviceId)
        
        end
        
        if (result) then
            setIfChanged(HADEVICE_SID, 'LastUpdate', time, deviceId)
        end

    -- Thermostat
    elseif (zwaveDeviceCategory4.thermostat[subCat]) then
        debugLog("Z-Wave Thermostat: node " .. node .. " action: " .. action)
        local deviceId = getChild(nodeParent)
        
        local result = false
        
        if (command == "ST") then
          -- current temperature --
          result = setIfChanged(TEMPSENSOR_SID, 'CurrentTemperature', action, deviceId)

        elseif (command == "CLISPH") then
          -- heat setpoint --
          result = setIfChanged(TEMPSETPOINT_HEAT_SID, 'CurrentSetpoint', action, deviceId)

        elseif (command == "CLISPC") then
          -- cool setpoint --
          result = setIfChanged(TEMPSETPOINT_COOL_SID, 'CurrentSetpoint', action, deviceId)

        elseif (command == "CLIMD") then
          -- mode --
          if (action == "0") then
            result = setIfChanged(HVAC_MODE_SID, 'ModeStatus', "Off", deviceId)

          elseif (action == "1") then
            result = setIfChanged(HVAC_MODE_SID, 'ModeStatus', "HeatOn", deviceId)

          elseif (action == "2") then
            result = setIfChanged(HVAC_MODE_SID, 'ModeStatus', "CoolOn", deviceId)

          elseif (action == "3") then
            result = setIfChanged(HVAC_MODE_SID, 'ModeStatus', "AutoChangeOver", deviceId)

          end

        elseif (command == "CLIFS") then
          -- fan --
          if (action == "0") then
            result = setIfChanged(HVAC_FAN_MODE_SID, 'Mode', "Auto", deviceId)
          elseif (action == "1") then
            result = setIfChanged(HVAC_FAN_MODE_SID, 'Mode', "ContinuousOn", deviceId)

          end
        end
        
        if (result) then
            setIfChanged(HADEVICE_SID, 'LastUpdate', time, deviceId)
        end
    end
end

--
-- Process incoming event from ISY Event Daemon
--
function processEvent(node, command, action)
    debugLog("processEvent: " .. node .. " command: " .. command .. " action: " .. action )
    if (deviceMap[node] ~= nil) then
        local family = deviceMap[node].family
        
        if (string.match(deviceMap[node].type, "^%d+%.%d+")) then
            local devCat, subCat = string.match(deviceMap[node].type, "^(%d+)%.(%d+)") -- category and sub-category of device
            
            -- Insteon
            if (family ~= nil and family == "1") then
                
                debugLog("Event family: " .. family .. " node: " .. node .. " dev cat: " .. devCat .. " sub cat: " .. subCat)
            
            	-- insteon controller event
                if (insteonDeviceCategory0[devCat]) then
                    insteonEventCategory0(node, command, action, subCat)
                  
                -- insteon dimmer event
                elseif (insteonDeviceCategory1[devCat]) then
                    insteonEventCategory1(node, command, action, subCat)
                    
                -- insteon relay / switch event
                elseif (insteonDeviceCategory2[devCat]) then
                    insteonEventCategory2(node, command, action, subCat)
                    
                -- insteon sensor / actuator event
                elseif (insteonDeviceCategory7[devCat]) then
                    insteonEventCategory7(node, command, action, subCat)
                    
                -- insteon security / health / safety event
                elseif (insteonDeviceCategory16[devCat]) then
                    insteonEventCategory16(node, command, action, subCat)
                    
                end
                
            -- Z-wave
            elseif (family ~= nil and family == "4") then 
                debugLog("Event family: " .. family .. " node: " .. node .. " dev cat: " .. devCat .. " sub cat: " .. subCat)
                   
                if (zwaveDeviceCategory4[devCat]) then
                  debugLog("Processing zwaveEventCategory4")
                    zwaveEventCategory4(node, command, action, subCat)
                else
                  debugLog("Not processing")
                    
                end
            end
        end
    
    else
        debugLog("Event node: " .. node .. " not recognized!")
        
    end
end

--
-- Node / Device status xml parser
-- Parser for single device status data 
-- returned using the /rest/status/nodeid api
--
function statusXMLParser(node)
    local result = {}        
    local nodeData = {}
    local property = {}
    local nodeId = node
                   
    local xmlParser = lxp.new({                  
        CharacterData = function (parser, string) 
            
        end,                                        
        StartElement = function (parser, name, attr)
        	-- start of properties data
        	if (name == "properties") then
        		nodeData = {}
        		property = {}
        		nodeData['address'] = nodeId
        		
        	else
        	
        		if (name == "property") then
					property[attr.id] = attr.value
				end
				
			end
			
        end,                                
        EndElement = function (parser, name) 
            -- if end of node data
            if (name == 'properties') then
            	nodeData['property'] = property
                table.insert(result, nodeData)
            
            end
        end                                                     
    })
    
    return {                                        
        parse = function(this, s) return xmlParser:parse(s) end,
        close = function(this) xmlParser:close() end,           
        result = function(this) return result end,              
    }                                                           
end

--
-- All Nodes / Devices status xml parser
-- Parser for status of all devices on data 
-- returned using the /rest/status/ api
--
function allStatusXMLParser()
    local result = {}        
    local nodeData = {}
    local property = {}
                   
    local xmlParser = lxp.new({                  
        CharacterData = function (parser, string) 
            
        end,                                        
        StartElement = function (parser, name, attr)
            -- start of node data
            if (name == 'node') then
                nodeData = {}
                property = {}
                nodeData['address'] = attr.id
                
            else
                if (name == "property") then
                    property[attr.id] = attr.value
                end
                
            end
        end,                                
        EndElement = function (parser, name) 
            -- if end of node data
            if (name == 'node') then
                nodeData['property'] = property
                table.insert(result, nodeData)
            end
        end                                                     
    })
    
    return {                                        
        parse = function(this, s) return xmlParser:parse(s) end,
        close = function(this) xmlParser:close() end,           
        result = function(this) return result end,              
    }                                                           
end

--
-- Node / Device config xml parser
-- Parser for data returned using the
-- /rest/nodes/devices api
--
function deviceXMLParser()
    local result = {}                            
    local variableName = nil
    local nodeData = {}
    local property = {}
                   
    local xmlParser = lxp.new({                  
        CharacterData = function (parser, string) 
            if (variableName) then         
                nodeData[variableName] = string       
            end
        end,                                        
        StartElement = function (parser, name, attr)
            -- start of node data
            if (name == 'node') then
                nodeData = {}
                property = {}
                
            else
                variableName = name                     
                --nodeData[name] = ""  
                
                if (name == "property") then
                    property[attr.id] = attr.value
                end
                
            end
        end,                                
        EndElement = function (parser, name) 
            -- if end of node data
            if (name == 'node') then
            	nodeData['property'] = property
                table.insert(result, nodeData)
            
            else
                variableName = nil 
                
            end
        end                                                     
    })
    
    return {                                        
        parse = function(this, s) return xmlParser:parse(s) end,
        close = function(this) xmlParser:close() end,           
        result = function(this) return result end,              
    }                                                           
end

--
-- Update device names
--
function updateDeviceNames()
    for k, v in pairs(deviceMap) do
        local node = k
        local name = v.name
        local family = v.family
        local type = v.type
        local parent = v.parent
        
        if (node == parent) then
            local insteonId, subDev = string.match(parent, "(%w+ %w+ %w+) (%w+)")
            local devCat, subCat = string.match(type, "^(%d+)%.(%d+)")
            
            -- Insteon items
            if (family ~= nil and family == "1") then
            
            	-- Controller
                if (insteonDeviceCategory0[devCat]) then
                
                	-- RemoteLinc
                    if (insteonDeviceCategory0.remoteLinc[subCat]) then
                        debugLog("Updating RemoteLinc name for: node " .. node)
                        
                        -- Scene Controller
                        luup.attr_set("name", string.format("%s SC", name), insteonToChildMap[insteonId])
                    end
                
                -- Dimmer
                elseif (insteonDeviceCategory1[devCat]) then
                    
                    -- KeypadLinc Dimmer
                    if (insteonDeviceCategory1.dimmerKPL[subCat]) then
                        debugLog("Updating KeypadLinc Dimmer name for: node " .. node)
                        
                        -- Dimmable light
                        luup.attr_set("name", string.format("%s", name), insteonToChildMap[parent])
                        
                        -- Scene Controller
                        luup.attr_set("name", string.format("%s SC", name), insteonToChildMap[insteonId])
                        
                    -- FanLinc
                    elseif (insteonDeviceCategory1.fanLinc[subCat]) then
                        debugLog("Updating FanLinc name for: node " .. node)
                        
                        -- Dimmable light
                        luup.attr_set("name", string.format("%s", name), insteonToChildMap[parent])
                        
                        -- Fan 
                        luup.attr_set("name", string.format("%s", deviceMap[insteonId .. " 2"].name), insteonToChildMap[string.format("%s", insteonId .. " 2")])
                        
                    -- Dimmer
                    elseif (insteonDeviceCategory1.dimmer[subCat]) then
                        debugLog("Updating Dimmer name for: node " .. node)
                        
                        luup.attr_set("name", string.format("%s", name), insteonToChildMap[parent])
                        
                    end
                    
                -- Relay / Switch
                elseif (insteonDeviceCategory2[devCat]) then
                    
                    -- KeypadLinc Relay
                    if (insteonDeviceCategory2.relayKPL[subCat]) then
                        debugLog("Updating KeypadLinc Relay name for: node " .. node)
                        
                        -- Binary light
                        luup.attr_set("name", string.format("%s", name), insteonToChildMap[parent])
                              
                        -- Scene Controller
                        luup.attr_set("name", string.format("%s SC", name), insteonToChildMap[insteonId])
                                    
                    -- Relay / Switch
                    elseif (insteonDeviceCategory2.relay[subCat]) then
                        debugLog("Updating Relay name for: node " .. node)
                        
                        luup.attr_set("name", string.format("%s", name), insteonToChildMap[parent])
                    end
                
                -- Sensor / Actuator
                elseif (insteonDeviceCategory7[devCat]) then
                    
                    -- IOLinc
                    if (insteonDeviceCategory7.iolinc[subCat]) then
                        debugLog("Updating IOLinc name for: node " .. node)
                        
                        -- Security Sensor
                        luup.attr_set("name", string.format("%s", name), insteonToChildMap[parent])
                              
                        -- Relay
                        luup.attr_set("name", string.format("%s", name), insteonToChildMap[insteonId] .. " 2")
                    end             
                   
                -- Security / Health / Safety
                elseif (insteonDeviceCategory16[devCat]) then
                    
                    -- Motion Sensor
                    if (insteonDeviceCategory16.motionSensor[subCat]) then
                        debugLog("Updating Motion Sensor name for: node " .. node)
                        
                        luup.attr_set("name", string.format("%s", name), insteonToChildMap[parent])
                    end
                   
                end
                
            -- Z-Wave items
            elseif (family ~= nil and family == "4") then
                if (zwaveDeviceCategory4[devCat]) then
                    
                    -- Relay
                    if (zwaveDeviceCategory4.relay[subCat]) then
                        debugLog("Updating Z-Wave Relay name for: node " .. node)
                        
                        -- Binary light
                        luup.attr_set("name", string.format("%s", name), insteonToChildMap[parent])
                              
                    -- Dimmer
                    elseif (zwaveDeviceCategory4.dimmer[subCat]) then
                        debugLog("Updating Z-Wave dimmer name for: node " .. node)
                        
                        luup.attr_set("name", string.format("%s", name), insteonToChildMap[parent])

                    -- Lock
                    elseif (zwaveDeviceCategory4.lock[subCat]) then
                        debugLog("Updating Z-Wave lock name for: node " .. node)
                        
                        luup.attr_set("name", string.format("%s", name), insteonToChildMap[parent])
                    end
                end
            end
        end
    end
end

--
-- Get node / device status from ISY
--
function getDeviceStatusData(node)
    local request
    local code
    local headers
    local t = {}
    
    if (node ~= nil) then
        debugLog("Getting device status for node: " .. node)
    	
        request, code, headers = http.request {
            url = "http://" .. isyIP .. ":" .. isyPort,
            method = "GET /rest/status/" .. url.escape(node),
            sink = ltn12.sink.table(t),
            headers = {
                ["Authorization"] = "Basic " .. (mime.b64(isyUser .. ":" .. isyPass))
            }
        }
	
    else 
        debugLog("Getting device status for all nodes.")
		
        request, code, headers = http.request {
            url = "http://" .. isyIP .. ":" .. isyPort,
            method = "GET /rest/status/",
            sink = ltn12.sink.table(t),
            headers = {
                ["Authorization"] = "Basic " .. (mime.b64(isyUser .. ":" .. isyPass))
            }
        }
		
    end

    if (code == 200) then
        httpResponse = table.concat(t)

        if (httpResponse) then
            local eventParser
			
            if (node ~= nil) then
                eventParser = statusXMLParser(node)
				
            else 
                eventParser = allStatusXMLParser()
				
            end
			
            local result, reason = eventParser:parse(httpResponse)
            eventParser:close()
			
            if (result) then
                local devices = eventParser.result()
				
                -- Add device to device map
                for i = 1, #devices do
                    local insteonId = devices[i].address
                    
                    if (deviceMap[insteonId] ~= nil) then
                        
                        for k, v in pairs(devices[i].property) do
                            debugLog("Device: " .. insteonId .. " status: " .. k .. " value: " .. v)
                            --deviceMap[insteonId][k] = v
                        end
                    end
                end
                
                return true
            end
        end
    end
end

--
-- Get nodes / devices from ISY
--
function getDeviceData()
    
	local t = {}
	request, code, headers = http.request {
		url = "http://" .. isyIP .. ":" .. isyPort,
		method = "GET /rest/nodes/devices",
		sink = ltn12.sink.table(t),
		headers = {
			["Authorization"] = "Basic " .. (mime.b64(isyUser .. ":" .. isyPass))
		}
	}

	if (code == 200) then
		httpResponse = table.concat(t)

		if (httpResponse) then
			local eventParser = deviceXMLParser()
			local result, reason = eventParser:parse(httpResponse)
			eventParser:close()
			
			if (result) then
                local devices = eventParser.result()
			
				-- Add device to device map
                for i = 1, #devices do
                    local insteonId = devices[i].address
                    
                    deviceMap[insteonId] = {}
                    deviceMap[insteonId]['name'] = devices[i].name
                    deviceMap[insteonId]['family'] = devices[i].family or "1"
                    deviceMap[insteonId]['type'] = devices[i].type
                    deviceMap[insteonId]['parent'] = devices[i].pnode
                        
                    for k, v in pairs(devices[i].property) do
                        deviceMap[insteonId][k] = v
                    end
                end
                
                return true
			end
		end
	end
end

--
-- Create child devices
--
local function initializeChildren(device)
    local children = luup.chdev.start(device)
    
    for k, v in pairs(deviceMap) do
        local node = k
        local name = v.name
        local family = v.family
        local type = v.type
        local parent = v.parent
        local status = v.ST
        
        if (node == parent) then
            local insteonId, subDev = string.match(parent, "(%w+ %w+ %w+) (%w+)")
            local devCat, subCat = string.match(type, "^(%d+)%.(%d+)")
            
            debugLog("Parsing node " .. node .. "; family = " .. family .. "; devCat = " .. devCat .. "; subCat = " .. subCat)
                
            if (family ~= nil and family == "1") then
            
            	-- Controller
                if (insteonDeviceCategory0[devCat]) then
            
            		-- RemoteLinc
                    if (insteonDeviceCategory0.remoteLinc[subCat]) then
                        
                        -- Scene Controller
                        luup.chdev.append(device, children,
                            string.format("%s", insteonId), string.format("%s SC", name),
                            "urn:schemas-micasaverde-com:device:SceneController:1", "D_SceneController1.xml",
                            "", "urn:garrettwp-com:serviceId:ISYController1,Family=1", false)
					end  
            
                -- Dimmer
                elseif (insteonDeviceCategory1[devCat]) then
                    
                    -- KeypadLinc Dimmer
                    if (insteonDeviceCategory1.dimmerKPL[subCat]) then
                        local loadLevel
                        local newStatus
                                            
                        debugLog("Creating KeypadLinc Dimmer for: node " .. node)
                        
                        -- On
                        if (status ~= nil and status ~= " " and tonumber(status) > 0) then  
                            loadLevel = minMaxConversion(100, status)
                            newStatus = 1
                        
                        -- Off
                        else
                            loadLevel = 0
                            newStatus = 0
                        end
                        
                        -- Dimmable light
                        luup.chdev.append(device, children,
                            string.format("%s", parent), string.format("%s", name),
                            "urn:schemas-upnp-org:device:DimmableLight:1", "D_DimmableLight1.xml",
                            "", "urn:upnp-org:serviceId:SwitchPower1,Status=" .. newStatus .. 
                            "\n" .. "urn:upnp-org:serviceId:Dimming1,LoadLevelStatus=" .. loadLevel ..
                            "\nurn:garrettwp-com:serviceId:ISYController1,Family=1", false)
                        
                        -- Scene Controller
                        luup.chdev.append(device, children,
                            string.format("%s", insteonId), string.format("%s SC", name),
                            "urn:schemas-micasaverde-com:device:SceneController:1", "D_SceneController1.xml",
                            "", "urn:garrettwp-com:serviceId:ISYController1,Family=1", false)
                        
                    -- FanLinc
                    elseif (insteonDeviceCategory1.fanLinc[subCat]) then
                        debugLog("Creating FanLinc for: node " .. node)
                        
                        -- Dimmable light
                        local loadLevel
                        local newStatus
                        
                        -- On
                        if (status ~= nil and status ~= " " and tonumber(status) > 0) then
                            loadLevel = minMaxConversion(100, status)
                            newStatus = 1
                        
                        -- Off
                        else
                            loadLevel = 0  
                            newStatus = 0
                        end
                        
                        luup.chdev.append(device, children,
                            string.format("%s", parent), string.format("%s", name),
                            "urn:schemas-upnp-org:device:DimmableLight:1", "D_DimmableLight1.xml",
                            "", "urn:upnp-org:serviceId:SwitchPower1,Status=" .. newStatus .. 
                            "\n" .. "urn:upnp-org:serviceId:Dimming1,LoadLevelStatus=" .. loadLevel ..
                            "\nurn:garrettwp-com:serviceId:ISYController1,Family=1", false)
                        
                        -- Fan 
                        local fanStatus = deviceMap[insteonId .. " 2"].ST
                        local fanNewStatus
                        
                        -- On
                        if (fanStatus ~= nil and fanStatus ~= " " and tonumber(fanStatus) > 0) then
                            fanNewStatus = 1
                        
                        -- Off
                        else
                            fanStatus = 0
                            fanNewStatus = 0
                        end
                        
                        luup.chdev.append(device, children,
                            string.format("%s", insteonId .. " 2"), string.format("%s", deviceMap[insteonId .. " 2"].name),
                            "urn:schemas-garrettwp-com:device:ISYFanLinc:1", "D_ISYFanLinc1.xml",
                            "", "urn:upnp-org:serviceId:SwitchPower1,Status=" .. fanNewStatus .. 
                            "\n" .. "urn:upnp-org:serviceId:Dimming1,LoadLevelStatus=" .. fanStatus ..
                            "\nurn:garrettwp-com:serviceId:ISYController1,Family=1", false)
                        
                    -- Dimmer
                    elseif (insteonDeviceCategory1.dimmer[subCat]) then
                        local loadLevel
                        local newStatus
                        
                        debugLog("Creating Dimmer for: node " .. node)
                        
                        -- On
                        if (status ~= nil and status ~= " " and tonumber(status) > 0) then
                            loadLevel = minMaxConversion(100, status)
                            newStatus = 1
                          
                        -- Off
                        else
                            loadLevel = 0
                            newStatus = 0
                        end
                        
                        luup.chdev.append(device, children,
                            string.format("%s", parent), string.format("%s", name),
                            "urn:schemas-upnp-org:device:DimmableLight:1", "D_DimmableLight1.xml",
                            "", "urn:upnp-org:serviceId:SwitchPower1,Status=" .. newStatus .. 
                            "\n" .. "urn:upnp-org:serviceId:Dimming1,LoadLevelStatus=" .. loadLevel ..
                            "\nurn:garrettwp-com:serviceId:ISYController1,Family=1", false)
                        
                    end
                    
                -- Relay / Switch
                elseif (insteonDeviceCategory2[devCat]) then
                    
                    -- KeypadLinc Relay
                    if (insteonDeviceCategory2.relayKPL[subCat]) then
                        local newStatus
                        
                        debugLog("Creating KeypadLinc Relay for: node " .. node)
                        
                        -- On
                        if (status ~= nil and status ~= " " and tonumber(status) > 0) then
                            newStatus = 1
                          
                        -- Off 
                        else
                            newStatus = 0
                        end
                        
                        -- Binary light
                        luup.chdev.append(device, children,
                            string.format("%s", parent), string.format("%s", name),
                            "urn:schemas-upnp-org:device:BinaryLight:1", "D_BinaryLight1.xml",
                            "", "urn:upnp-org:serviceId:SwitchPower1,Status=" .. newStatus ..
                            "\nurn:garrettwp-com:serviceId:ISYController1,Family=1", false)
                                
                        -- Scene Controller
                        luup.chdev.append(device, children,
                            string.format("%s", insteonId), string.format("%s SC", name),
                            "urn:schemas-micasaverde-com:device:SceneController:1", "D_SceneController1.xml",
                            "", "urn:garrettwp-com:serviceId:ISYController1,Family=1", false)
                                        
                    -- Relay / Switch
                    elseif (insteonDeviceCategory2.relay[subCat]) then
                        local newStatus
                        
                        debugLog("Creating Relay for: node " .. node)
                           
                        
                        -- On
                        if (status ~= nil and status ~= " " and tonumber(status) > 0) then
                            newStatus = 1
                          
                        -- Off 
                        else
                            newStatus = 0
                        end
                        
                        luup.chdev.append(PARENT, children,
                            string.format("%s", parent), string.format("Insteon Relay %s", node),
                            "urn:schemas-upnp-org:device:BinaryLight:1", "D_BinaryLight1.xml",
                            "", "urn:upnp-org:serviceId:SwitchPower1,Status=" .. newStatus ..
                            "\nurn:garrettwp-com:serviceId:ISYController1,Family=1", false)
                    end
                
                -- IOLinc
                elseif (insteonDeviceCategory7[devCat]) then
                    
                    -- IOLinc
                    if (insteonDeviceCategory7.iolinc[subCat]) then
                        debugLog("Creating IOLinc for: node " .. node)
                        
                        -- Security Sensor
                        local newStatus
                        
                        -- On
                        if (status ~= nil and status ~= " " and tonumber(status) > 0) then
                            newStatus = 1
                        
                        -- Off
                        else
                            newStatus = 0
                        end
                        
                        luup.chdev.append(device, children,
                            string.format("%s", parent), string.format("%s", name),
                            "urn:schemas-micasaverde-com:device:DoorSensor:1", "D_DoorSensor1.xml",
                            "", "urn:micasaverde-com:serviceId:SecuritySensor1,Tripped=" .. newStatus ..
                            "\nurn:garrettwp-com:serviceId:ISYController1,Family=1", false)
                            --..  "\n" .. "urn:micasaverde-com:serviceId:SecuritySensor1,Armed=0" ..
                            --"\n" .. "urn:micasaverde-com:serviceId:SecuritySensor1,Reverse=0", false)

                        -- Relay
                        local relayStatus = deviceMap[insteonId .. " 2"].ST
                        local relayNewStatus
                        
                        -- On
                        if (relayStatus ~= nil and relayStatus ~= " " and tonumber(relayStatus) > 0) then
                            relayNewStatus = 1
                        
                        -- Off
                        else
                            relayStatus = 0
                        end
                        
                        luup.chdev.append(device, children,
                            string.format("%s", insteonId .. " 2"), string.format("%s", deviceMap[insteonId .. " 2"].name),
                            "urn:schemas-upnp-org:device:BinaryLight:1", "D_BinaryLight1.xml",
                            "", "urn:upnp-org:serviceId:SwitchPower1,Status=" .. relayStatus ..
                            "\nurn:garrettwp-com:serviceId:ISYController1,Family=1", false)
                    end
                    
                -- Security / Health / Safety
                elseif (insteonDeviceCategory16[devCat]) then
                    
                    -- Motion Sensor
                    if (insteonDeviceCategory16.motionSensor[subCat]) then
                        debugLog("Creating Motion Sensor for: node " .. node)
                        
                        local newStatus
                        
                        -- tripped
                        if (status ~= nil and status ~= " " and tonumber(status) == 1) then
                            newStatus = 1
                        
                        -- secure (not tripped)
                        else
                            newStatus = 0
                        end
                        
                        luup.chdev.append(device, children,
                            string.format("%s", parent), string.format("%s", name),
                            "urn:schemas-micasaverde-com:device:MotionSensor:1", "D_MotionSensor1.xml",
                            "", "urn:micasaverde-com:serviceId:SecuritySensor1,Tripped=" .. newStatus ..  
                            "\n" .. "urn:micasaverde-com:serviceId:SecuritySensor1,Armed=0" ..
                            "\nurn:garrettwp-com:serviceId:ISYController1,Family=1", false)
                    end
                end
                
            -- Z-Wave items
            elseif (family ~= nil and family == "4") then
                    
                if (zwaveDeviceCategory4[devCat]) then
                    
                    -- Relay / Switch
                    if (zwaveDeviceCategory4.relay[subCat]) then
                        local newStatus
                        
                        debugLog("Creating Z-Wave Relay for: node " .. node)
                        
                        -- On
                        if (status ~= nil and status ~= " " and status ~= " " and tonumber(status) > 0) then
                            newStatus = 1
                          
                        -- Off 
                        else
                            newStatus = 0
                        end
                        
                        luup.chdev.append(PARENT, children,
                            string.format("%s", parent), string.format("%s", name),
                            "urn:schemas-upnp-org:device:BinaryLight:1", "D_BinaryLight1.xml",
                            "", "urn:upnp-org:serviceId:SwitchPower1,Status=" .. newStatus ..
                            "\nurn:garrettwp-com:serviceId:ISYController1,Family=4", false)

                    -- Dimmer
                    elseif (zwaveDeviceCategory4.dimmer[subCat]) then
                    	local loadLevel
                        local newStatus
                        
                        debugLog("Creating Z-Wave dimmer for: node " .. node)
                        
                        -- On
                        if (status ~= nil and status ~= " " and status ~= " " and tonumber(status) > 0) then
                            newStatus = 1
                          
                        -- Off 
                        else
                            newStatus = 0
                        end
                        
                        luup.chdev.append(device, children,
                            string.format("%s", parent), string.format("%s", name),
                            "urn:schemas-upnp-org:device:DimmableLight:1", "D_DimmableLight1.xml",
                            "", "urn:upnp-org:serviceId:SwitchPower1,Status=" .. newStatus ..
                            "\nurn:garrettwp-com:serviceId:ISYController1,Family=4", false)
                            --.. "\n" .. "urn:upnp-org:serviceId:Dimming1,LoadLevelStatus=" .. loadLevel, false)

                    -- Lock
                    elseif (zwaveDeviceCategory4.lock[subCat]) then
                        local newStatus
                        
                        debugLog("Creating Z-Wave lock for: node " .. node)
                        
                        -- On
                        if (status ~= nil and status ~= " " and tonumber(status) > 0) then
                            newStatus = 1
                          
                        -- Off 
                        else
                            newStatus = 0
                        end
                        
                        luup.chdev.append(PARENT, children,
                            string.format("%s", parent), string.format("%s", name),
                            "urn:schemas-micasaverde-com:device:DoorLock:1", "D_DoorLock1.xml",
                            "", "urn:micasaverde-com:serviceId:DoorLock1,Status=" .. newStatus ..
                            "\nurn:garrettwp-com:serviceId:ISYController1,Family=4", false)

                    -- Thermostat
                    elseif (zwaveDeviceCategory4.thermostat[subCat]) then
                    	  local loadLevel
                        local newStatus
                        
                        debugLog("Creating Z-Wave thermostat for: node " .. node)
                        
                        -- temp
                        if (status ~= nil and status ~= " " and tonumber(status) > 0) then
                            newStatus = tonumber(status)
                          
                        -- Off 
                        else
                            newStatus = 0
                        end

                        debugLog("  Z-Wave thermostat current temp = " .. newStatus)
                        
                        luup.chdev.append(device, children,
                            string.format("%s", parent), string.format("%s", name),
                            "urn:schemas-upnp-org:device:HVAC_ZoneThermostat:1", "D_HVAC_ZoneThermostat1.xml",
                            "", "urn:upnp-org:serviceId:TemperatureSensor1,CurrentTemperature="..newStatus, false)
                    end
                end
            end
        end
    end
    
    luup.chdev.sync(device, children)
    
    -- Loop through children devices and associate with the appropiate insteon id
    -- Add both device id and insteon id to childToInsteonMap for future lookups
    for k, v in pairs(luup.devices) do
        if (v.device_num_parent == PARENT) then
            debugLog("deviceId: " .. k .. " insteonId: " .. v.id)
            
            childToInsteonMap[k] = v.id
            insteonToChildMap[v.id] = k
        end
    end
end

--
-- Initialize ISY Plugin
--
function init(lul_device)
	log("Initializing plugin...")
    PARENT = lul_device
    
    isyIP = luup.variable_get(ISYCONTROLLER_SERVICEID, "ISYIP", PARENT)
    if (isyIP == nil) then
        luup.variable_set(ISYCONTROLLER_SERVICEID, "ISYIP", "", PARENT)
    end
    
    isyPort = luup.variable_get(ISYCONTROLLER_SERVICEID, "ISYPort", PARENT)
    if (isyPort == nil) then
        luup.variable_set(ISYCONTROLLER_SERVICEID, "ISYPort", "80", PARENT)
    end

    isyUser = luup.variable_get(ISYCONTROLLER_SERVICEID, "ISYUsername", PARENT)
    if (isyUser == nil) then
        luup.variable_set(ISYCONTROLLER_SERVICEID, "ISYUsername", "", PARENT)
    end

    isyPass = luup.variable_get(ISYCONTROLLER_SERVICEID, "ISYPassword", PARENT)
    if (isyPass == nil) then
        luup.variable_set(ISYCONTROLLER_SERVICEID, "ISYPassword", "", PARENT)
    end
    
    DEBUG = luup.variable_get(ISYCONTROLLER_SERVICEID, "Debug", PARENT)
    if (DEBUG == nil) then
        luup.variable_set(ISYCONTROLLER_SERVICEID, "Debug", "false", PARENT)
        DEBUG = false
    end
    
    if (isyIP ~= nil and isyUser ~= nil and isyPass ~= nil) then
        local status = getDeviceData()
        
        if (status) then
            initializeChildren(lul_device) 
            
        end
        
        -- Check if daemon is running
        running()
        
        return true
        
    else
        return false
        
    end
end
