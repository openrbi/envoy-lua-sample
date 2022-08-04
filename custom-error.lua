-- Convert a lua table into a lua syntactically correct string
function table_to_string(tbl)
    local result = "{"
    for k, v in pairs(tbl) do
        -- Check the key type (ignore any numerical keys - assume its an array)
        if type(k) == "string" then
            result = result .. "[\"" .. k .. "\"]" .. "="
        end

        -- Check the value type
        if type(v) == "table" then
            result = result .. table_to_string(v)
        elseif type(v) == "boolean" then
            result = result .. tostring(v)
        else
            result = result .. "\"" .. v .. "\""
        end
        result = result .. ","
    end
    -- Remove leading commas from the result
    if result ~= "" then
        result = result:sub(1, result:len() - 1)
    end
    return result .. "}"
end

function envoy_on_request(request_handle)
    local table = {}
    table.userAgent = request_handle:headers():get("user-agent")
    request_handle:streamInfo():dynamicMetadata():set("envoy.filters.http.lua", "request.info", table)
end

function envoy_on_response(response_handle)

    local status = response_handle:headers():get(":status")

    if status == "404" then
        local meta = response_handle:streamInfo():dynamicMetadata():get("envoy.filters.http.lua")["request.info"]

        -- fix set new body
        -- https://github.com/envoyproxy/envoy/issues/13985#issuecomment-725724707
        response_handle:body()

        local errHeaders, errBody = response_handle:httpCall(
            "{{ .Err404.Cluster }}",
            {
                [":method"] = "GET",
                [":path"] = "{{ .Err404.Path }}",
                [":authority"] = "{{ .Err404.Authority }}",
                ["user-agent"] = meta.userAgent
            },
            nil,
            5000)

        -- Set new body
        response_handle:body(true):setBytes(errBody)

        -- debug old headers
        response_handle:logDebug("old headers: " .. table_to_string(response_handle:headers()))

        -- debug error headers
        response_handle:logDebug("error headers: " .. table_to_string(errHeaders))

        -- Set new headers
        for key, value in pairs(errHeaders) do
            response_handle:headers():replace(key, value)
        end

        -- Set default status
        response_handle:headers():replace(":status", 404)
    end

    if status == "500" or status == "503" then
        -- local meta = response_handle:streamInfo():dynamicMetadata():get("envoy.filters.http.lua")["request.info"]

        response_handle:body()

        local errHeaders, errBody = response_handle:httpCall(
            "{{ .Err5xx.Cluster }}",
            {
                [":method"] = "GET",
                [":path"] = "{{ .Err5xx.Path }}",
                [":authority"] = "{{ .Err5xx.Authority }}",
            },
            nil,
            5000)
        response_handle:body(true):setBytes(errBody)
        response_handle:logInfo("Got status 5xx, redirect to s3 bucket with embeded 500 page " ..
            os.getenv("ENVOY_AUTHORITY_5XX") .. os.getenv("PAENVOY_PATH_5XX"))
        response_handle:headers():add("location",
            os.getenv("ENVOY_AUTHORITY_5XX") .. os.getenv("PAENVOY_PATH_5XX"))
        for key, value in pairs(errHeaders) do
            response_handle:headers():replace(key, value)
        end
        -- response_handle:headers():replace(":status", 500)
    end

end
