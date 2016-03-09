--
-- ISY Event plugin
-- By Garrett Power
-- Credit to Deborah Pickett
--
module ("L_ISYEvent", package.seeall)
--local http = require("socket.http")
--local ltn12 = require("ltn12")

local initScript = [=[#!/bin/sh /etc/rc.common
# Copyright (C) 2007 OpenWrt.org
START=80
PID_FILE=/var/run/isy_event_daemon.pid
PROXY_DAEMON=/tmp/isy_event_daemon.lua

start() {
    if [ -f "$PID_FILE" ]; then
        # May already be running.
        PID=$(cat "$PID_FILE")
    
        if [ -d "/proc/$PID" ]; then
            COMMAND=$(readlink "/proc/$PID/exe")
    
            if [ "$COMMAND" = "/usr/bin/lua" ]; then
                echo "Daemon is already running"
                return 1
            fi
        fi
    fi

    # Find and decompress the proxy daemon Lua source.
    if [ -f /etc/cmh-ludl/L_ISYEventDaemon.lua.lzo ]; then
        PROXY_DAEMON_LZO=/etc/cmh-ludl/L_ISYEventDaemon.lua.lzo
        
    elif [ -f /etc/cmh-lu/L_ISYEventDaemon.lua.lzo ]; then
        PROXY_DAEMON_LZO=/etc/cmh-lu/L_ISYEventDaemon.lua.lzo
    fi

    if [ -n "$PROXY_DAEMON_LZO" ]; then
        /usr/bin/pluto-lzo d "$PROXY_DAEMON_LZO" "$PROXY_DAEMON"
    fi
    
    # Close file descriptors.
    for fd in /proc/self/fd/*; do
        fd=${fd##*/}
        case $fd in
            0|1|2) ;;
            *) eval "exec $fd<&-"
        esac
    done

    # Find if the file is already decompressed in /etc/cmh-ldl - if it is assume we are running on openLuup
    if [ -f /etc/cmh-ludl/L_ISYEventDaemon.lua ]; then
        PROXY_DAEMON=/etc/cmh-ludl/L_ISYEventDaemon.lua
    fi

    # Run daemon.
    /usr/bin/lua "$PROXY_DAEMON" </dev/null >/dev/null 2>&1 &
    echo "$!" > "$PID_FILE"
}

stop() {
    if [ -f "$PID_FILE" ]; then
        PID=$(cat "$PID_FILE")
    
        if [ -d "/proc/$PID" ]; then
            COMMAND=$(readlink "/proc/$PID/exe")
    
            if [ "$COMMAND" = "/usr/bin/lua" ]; then
                /bin/kill -KILL "$PID" && /bin/rm "$PID_FILE"
                return 0
            fi
        fi
    fi
    echo "Daemon is not running"
    return 1
}
]=]

local initScriptPath = "/etc/init.d/isy_event_daemon"
local DeviceId
local taskHandle = -1

function task(message, mode)
    taskHandle = luup.task(message, mode, string.format("%s[%d]", luup.devices[DeviceId].description, DeviceId), taskHandle)
end

function createInitScript()
    task("Creating init script", 1)
    local f = io.open(initScriptPath, "w")
    f:write(initScript)
    f:close()
    task("Created init script", 4)
    task("Making init script executable", 1)
    os.execute("chmod +x " .. initScriptPath)
    task("Made init script executable", 4)
    --task("Enabling init script", 1)
    --os.execute(initScriptPath .. " enable")
    --task("Enabled init script", 4)
    task("Starting init script", 1)
    os.execute(initScriptPath .. " start")
    task("Started init script", 4)
end

function initialize(deviceId)
    DeviceId = deviceId
    
    -- Create the init script in /etc/init.d/isy_event_daemon.
    local f = io.open(initScriptPath, "r")
    if (f) then
        -- File already exists.
        if (f:read("*a") == initScript) then
            luup.log("Init script unchanged.")
            f:close()
            
        else
            luup.log("Init script different; will be recreated.")
            f:close()
            task("Stopping init script", 1)
            os.execute(initScriptPath .. " stop")
            task("Stopped init script", 4)
            createInitScript()
            --luup.call_delay("restartNeeded", 1, "Restart Luup engine to complete installation")
            
            return true
        end
        
    else
        luup.log("Init script absent; will be created.")
        createInitScript()
        --luup.call_delay("restartNeeded", 1, "Restart Luup engine to complete installation")
        
        return true
    end
    
    return true
end

function uninstall(deviceId)
    local f = io.open(initScriptPath, "r")
    if (f) then
        -- File exists.
        f:close()
        task("Stopping init script", 1)
        os.execute(initScriptPath .. " stop")
        task("Stopped init script", 4)
        task("Disabling init script", 1)
        os.execute(initScriptPath .. " disable")
        task("Disabling init script", 4)
        task("Removing init script", 1)
        os.execute("rm " .. initScriptPath)
        task("Removed init script", 4)
        --task("Delete the ISY Event Proxy device, then reload Luup engine.", 1)
    end
end

function restartNeeded(message)
    task(message, 2)
end
