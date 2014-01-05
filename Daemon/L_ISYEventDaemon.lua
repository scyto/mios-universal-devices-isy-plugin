--[[
	ISY Event Daemon
	Copyright 2013 Garrett Power

    Credit is due to Deborah Pickett where a lot of her code from the UPnP event proxy
    plugin has made this code / plugin possible.
    
    http://code.mios.com/trac/mios_upnp-event-proxy
    
    Parts of this program have been modified from the Luasocket library
    (http://w3.impa.br/~diego/software/luasocket/), released under the MIT licence.
]]

local socket = require('socket')
local url = require('socket.url')
local http = require('socket.http')
local mime = require('mime')
local ltn12 = require('ltn12')
local lxp = require('lxp')

local DEBUG = false
local ISY_IPADDRESS = ""
local ISY_PORT = ""
local ISY_USERNAME = ""
local ISY_PASSWORD = ""
local VERA_PLUGIN_ID = ""
local LISTEN_PORT = 9810


local API_VERSION = "1"
local LISTEN_BACKLOG = 5
local LISTEN_TIMEOUT = 10
local eventQueue = {}

function log(s)
    print(s)
end

--
-- Parse the HTTP request line.
-- Returns the method and the path (split at / characters)
--
function readStatusLine(c)
    local statusLine = c:receive('*l')
    
    --log(statusLine)
    
    local method, path = statusLine:match("^(%u+) ([^ ]+) HTTP/1.[01]")
    
    if (statusLine:match("^POST ")) then
        return "POST", url.parse_path(path)
       
    elseif (statusLine:match("^PUT ")) then
	    return "PUT", url.parse_path(path)  
 
    elseif (statusLine:match("^SUBSCRIBE ")) then
        return "SUBSCRIBE", url.parse_path(path)  
 
    else
        return nil, "405 Method not allowed"
    end
end

--
-- Parse the HTTP headers.
-- Returns them as a table.
--
function readHeaders(c)
    local headers = {}
    local headerLine = c:receive('*l')
    
    while (headerLine) do
        local nextLine = c:receive('*l')
        if (not nextLine) then
            -- Error, should always be a blank line at least.   
            return nil
            
        end
        
        if (nextLine:match("^%s")) then
            headerLine = headerLine .. nextLine:gsub("%s+", " ", 1)
            
        else
            -- Header line does not start with space; previous header is complete.
            local name, value = headerLine:match("^([^:]+): ?(.*)$")
            -- log("header: " .. name)
            -- log("value: " .. value)
            headers[name:lower()] = value
            if (nextLine == "") then
                return headers
                
            end
            
            headerLine = nextLine
        end
    end
end

--
-- Fetch the HTTP body.
-- Returns the html body
--
function readBody(c, len)
    local result = ""
    
    if (len) then
        -- log("Reading " .. len .. " bytes")
        local bytesToRead = len
        
        while (bytesToRead > 0) do
            local data, reason = c:receive(len)
            
            if (data) then
                bytesToRead = bytesToRead - data:len()
                result = result .. data
                
            else
                return nil, reason
            end
        end
    else
        -- Untested!
        if (DEBUG == true) then
            log("Reading till EOF")
        end
        
        while (true) do
            local data, reason = c:receive("*a")
            
            if (DEBUG == true) then
                log(data)
                log(reason)
            end
            
            if (data) then
                result = result .. data
                
            else
                return nil, reason
                
            end
        end
    end
    return result
end

--
-- Learn Vera's ip address
-- Returns the ip address as a string
--
function getIPAddress(ip)
    local s = socket.tcp()
    s:setpeername(ip, 80) -- Any port will do, not actually connecting.
    local myAddress = s:getsockname()
    
    if (DEBUG == true) then
        log("Local host is " .. myAddress)
    end
    
    s:close()
    
    return myAddress
end

--
-- Send outstanding events to ISY plugin.
--
function processEventQueue()
    local saveForLater = {}
    local nextTimeout = LISTEN_TIMEOUT
    
    while (#eventQueue > 0) do
        local event = table.remove(eventQueue, 1)
        
        if (event.delayUntil > os.time()) then
            -- Don't send yet, device may not be ready.
            if (DEBUG == true) then
                log("Event not ready, try again later")
            end
            
            table.insert(saveForLater, event)
            
        else
            if (DEBUG == true) then
                log("Sending event: " .. event.url)
            end
            
            local request, reason = http.request(event.url)
            if (request) then
                -- Successful notification.
                if (DEBUG == true) then
                    log("Response: " .. request)
                end
                
            else
                if (DEBUG == true) then
                    log("Error: " .. reason)
                end
                
                if (event.retries > 0) then
                    local randomDelay = math.random(1, 5)
                    event.delayUntil = os.time() + randomDelay
                    event.retries = event.retries - 1
                    nextTimeout = math.min(nextTimeout, randomDelay)
                    table.insert(saveForLater, event)
                end
            end
            
            -- sleep for 250 milliseconds
            socket.sleep(0.250)
            
            -- Wait at most ten seconds, at least 1.
            nextTimeout = math.min(nextTimeout, LISTEN_TIMEOUT)
            nextTimeout = math.max(nextTimeout, 1)
        end
    end
    
    -- Unsuccessful events will be requeued for next time.
    for _, event in pairs(saveForLater) do
        table.insert(eventQueue, event)
    end
    
    return nextTimeout
end

--
-- Add an event to the event queue.
-- This queue will be sent when the event daemon process
-- is back in its main loop.
--
function queueEvent(node, command, action)
    if (DEBUG == true) then
        log("Queueing event for " .. node .. " command: " .. command .. " action: " .. action)
    end
    
    table.insert(eventQueue, {
        delayUntil = os.time(),
        retries = 3,
        url = "http://127.0.0.1" .. 
                ":3480/data_request?id=lu_action" ..
                "&DeviceNum=" .. VERA_PLUGIN_ID ..
                "&serviceId=urn:garrettwp-com:serviceId:ISYController1" ..
                "&action=newEvent" .. 
                "&node=".. url.escape(node) .. 
                "&command=".. url.escape(command) .. 
                "&newAction=" .. url.escape(action)
    })
end

--
-- Returns a parser object that handles events from ISY
--
function xmlParser()
    local result = {}                            
    local variableName = nil
                         
    local xmlParser = lxp.new({                  
        CharacterData = function (parser, string) 
            if (variableName) then                  
                result[variableName] = string       
            end                                     
        end,                                        
        StartElement = function (parser, name, attr)
            variableName = name                     
            result[name] = ""               
        end,                                
        EndElement = function (parser, name)                    
            variableName = nil                                  
        end                                                     
    })
    
    return {                                        
        parse = function(this, s) return xmlParser:parse(s) end,
        close = function(this) xmlParser:close() end,           
        result = function(this) return result end,              
    }                                                           
end

--
-- Handle all POST requests:
-- isy device is sending an event
--
function handleEventRequest(c, path, headers, body)
    local eventParser = xmlParser()
    local result, reason = eventParser:parse(body)
    eventParser:close()
        
    if (result) then
        local event = eventParser.result()
        
        --if (event.control and (event.control == 'ST' or event.control == 'RR' or event.control == 'OL')) then
        if (event.control and event.control == 'ST') then
            queueEvent(event.node, event.control, event.action)
            
            if (DEBUG == true) then
                log("Parser succeeded")
                
                for k, v in pairs(event) do
                    log(k .. " = " .. v)
                    
                end
            end
            
        elseif (event.control and (event.control == 'DOF' or event.control == 'DON')) then
            queueEvent(event.node, event.control, event.action)
            
            if (DEBUG == true) then
                log("Parser succeeded")
                
                for k, v in pairs(event) do
                    log(k .. " = " .. v)
                    
                end
            end

        elseif (event.control and (event.control == 'CLIFS' or event.control == 'CLIMD' or event.control == 'CLISPC' or event.control == 'CLISPH')) then
            queueEvent(event.node, event.control, event.action)
            
            if (DEBUG == true) then
                log("Parser succeeded")
                
                for k, v in pairs(event) do
                    log(k .. " = " .. v)
                    
                end
            end

        end
        
        c:send("HTTP/1.1 200 OK\r\n\r\n")
            
    else
        if (DEBUG == true) then
            log("Parser failed: " .. reason)
        end
        
        c:send("HTTP/1.1 412 Precondition Failed\r\n\r\n")
    end
       
    return true
end

--
-- Handle all PUT requests:
--
function handlePutRequest(c, path, headers, body)
    local dataParser = xmlParser()
    local result, reason = dataParser:parse(body)
    dataParser:close()
         
    if (result) then
        local data = dataParser.result()
        
        if (data.pluginID) then
            VERA_PLUGIN_ID = data.pluginID
        end
        
        if (data.isyIP) then
            ISY_IPADDRESS = data.isyIP
        end
        
        if (data.isyPort) then
            ISY_PORT = data.isyPort
        end
        
        if (data.isyUser) then
            ISY_USERNAME = data.isyUser
        end
        
        if (data.isyPass) then
            ISY_PASSWORD = data.isyPass
        end
        
        if (DEBUG == true) then
            log("PUT request")
            
            log("Plugin ID: " .. VERA_PLUGIN_ID .. " ISY IP: " .. ISY_IPADDRESS .. " ISY Port: " .. ISY_PORT .. " ISY User: " .. ISY_USERNAME .. " ISY Pass: " .. ISY_PASSWORD)
        end
        
        c:send("HTTP/1.1 200 OK\r\n\r\n")
            
    else
        if (DEBUG == true) then
            log("")
        end
        
        c:send("HTTP/1.1 412 Precondition Failed\r\n\r\n")
    end
       
    return true
end

--
-- Subscribe to ISY function
--
local function subscribe(c)
    
    if (ISY_IPADDRESS ~= nil and ISY_PORT ~= nil and ISY_USERNAME ~= nil and ISY_PASSWORD ~= nil) then
        -- get vera ip address
        local veraIP = getIPAddress(ISY_IPADDRESS)
        
        if (veraIP) then
            body = "<s:Envelope><s:Body><u:Subscribe" ..
            " xmlns:u=\'urn:udi-com:service:X_Insteon_Lighting_Service:1\'>" ..
            "<reportURL>http://" .. veraIP .. ":" .. LISTEN_PORT .. "/</reportURL>" ..
            "<duration>infinite</duration>" ..
            "</u:Subscribe></s:Body></s:Envelope>\r\n"

            local t = {}
            request, code, headers = http.request {
                url = "http://" .. ISY_IPADDRESS .. ":" .. ISY_PORT,
                method = "POST /services HTTP/1.1",
                sink = ltn12.sink.table(t),
                source = ltn12.source.string(body),
                headers = {
                    ["Content-Length"] = tostring(body:len()),
                    ["Content-Type"] = "text/xml; charset=utf-8",
                    ["Authorization"] = "Basic " .. (mime.b64(ISY_USERNAME .. ":" .. ISY_PASSWORD)),
                    ["SOAPACTION"] = "urn:udi-com:service:X_Insteon_Lighting_Service:1#Subscribe",
                    ["Connection"] = "Keep-Alive"
                }
            }
            
            httpResponse = table.concat(t)
            
            if (DEBUG == true) then
                --print(httpResponse)
                --print(code)
            end
            
            -- Check the http response code
            if (code == 200) then
                if (DEBUG == true) then
                    log("Successfully subscribed to ISY.")
                end
                
                c:send("HTTP/1.1 200 Successfully subscribed to ISY.\r\n\r\n")
                
            else
                if (DEBUG == true) then
                    log("Could not subscribe to ISY.")
                end
                
                c:send("HTTP/1.1 500 Could not subscribe to ISY.\r\n\r\n")
            end
            
        else
            if (DEBUG == true) then
                log("Could not get Vera's ip address.")
            end
            
            c:send("HTTP/1.1 500 Could not get Vera's ip address.\r\n\r\n")
        end
    
    else
        if (DEBUG == true) then
            log("Could not subscribe to ISY.")
        end
        
        c:send("HTTP/1.1 500 Could not subscribe to ISY.\r\n\r\n")
    
    end
    
    return true
end 

--
-- Handle an incoming HTTP request.
--
function handleRequest(c, method, path, headers, body)
    if (method == "POST") then
        return handleEventRequest(c, path, headers, body)
        
    elseif (method == "PUT") then
        return handlePutRequest(c, path, headers, body)
        
    elseif (method == "SUBSCRIBE") then
        return subscribe(c), "subscribe"
        
    else
        c:send("HTTP/1.1 405 Method Not Allowed\r\n\r\n")
        return true
    end
end

--
-- Incoming connection
--
function incoming(c)
    local runServer = true
    local request = nil
    
    local remoteHost = c:getpeername()
    local method, path = readStatusLine(c)
                        
    if (method) then
        local logstring = os.date() .. " " .. remoteHost .. " > " .. method .. " "
        for i = 1, #path do
            logstring = logstring .. "/" .. path[i]
        end
        
        if (DEBUG == true) then
            log(logstring)
        end
        
        -- So far so good.
        local headers = readHeaders(c)
        
        if (headers) then
            -- Now read body.
            local body
            
            if (method == "GET" or method == "SUBSCRIBE") then
                body = nil
                
            elseif (headers["content-length"]) then
                body = readBody(c, tonumber(headers["content-length"]))
                
            else
                body = readBody(c, nil)
                
            end
            
            -- Dispatch the request.
            runServer, request = handleRequest(c, method, path, headers, body)
            if (DEBUG == true) then
                --log(body)
            end
            
        else
            if (DEBUG == true) then
                log("Error while processing headers")
            end
            
            c:send("HTTP/1.1 400 Bad Request\r\n\r\n")
            
        end
        
    else
        -- path contains the error code.
        if (DEBUG == true) then
            log("Error while processing request line: " .. path)
        end
        
        c:send("HTTP/1.1 500 " .. path .. "\r\n\r\n")
    end
      
    return runServer, request         
end

--
-- Run until instructed to exit (not yet implemented)
--
local runServer = true
local request = ""

local s = socket.tcp()
s:setoption("reuseaddr", true)
-- Every LISTEN_TIMEOUT seconds deal with retried notifications.
s:settimeout(LISTEN_TIMEOUT)

local result, reason = s:bind('*', LISTEN_PORT)
if (not result) then
    log("Cannot bind to port: " .. reason)
    os.exit(1)
end

result, reason = s:listen(LISTEN_BACKLOG)
if (not result) then
    log("Cannot listen: " .. reason)
    os.exit(1)
end

repeat       
    local c = s:accept()
     
    if (c) then
        local remoteHost = c:getpeername()
        if (DEBUG == true) then
            log("Connection established from " .. remoteHost)
        end
        
        if (request == "subscribe") then
            repeat
                runServer, request = incoming(c)
                    
                -- Send outstanding events
                s:settimeout(processEventQueue())
                
            until not c     
            c:close()
                   
        else 
            runServer, request = incoming(c)
            c:close()
             
        end
    end
    
until not runServer  
s:close()
