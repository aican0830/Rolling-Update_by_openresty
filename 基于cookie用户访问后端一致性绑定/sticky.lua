#user  nobody;
worker_processes  1;

#error_log  logs/error.log;
#error_log  logs/error.log  notice;
#error_log  logs/error.log  info;

#pid        logs/nginx.pid;


events {
    worker_connections  1024;
}


http {
    lua_shared_dict cache 1m;
    upstream foo.com {
        server 127.0.0.1 fail_timeout=53 weight=4 max_fails=100 backup;
        server agentzh.org:81;
    }

upstream bar {
    server 192.168.2.249:8000;
    server 127.0.0.1:8002;
    server 127.0.0.1:8003;
    server 127.0.0.1:8004;
    server 127.0.0.2:8001;
    server 127.0.0.2:8002;
    server 127.0.0.2:8003;
    balancer_by_lua_block {
    local balancer = require "ngx.balancer"
    local upstream = require "ngx.upstream"
    local upstream_name = 'bar'
    local srvs = upstream.get_servers(upstream_name)
    function get_server()
        local cache = ngx.shared.cache
        local key = "req_index"
        local index = cache:get(key)
        if index == nil or index > #srvs then
            index = 1 cache:set(key, index)
        end
        cache:incr(key, 1)
        return index
        end
    function is_down(server)
        local down = false
        local perrs = upstream.get_primary_peers(upstream_name)
        for i = 1, #perrs do
            local peer = perrs[i]
            if server == peer.name and peer.down == true then
                down = true
            end
        end
        return down
    end
    ----------------------------
    local route = ngx.var.cookie_router
    local server
    if route then
        local flag
        for k, v in pairs(srvs) do
            if ngx.md5(v.name) == route then
                server = v.addr
                local flag = 1
                --ngx.log(ngx.INFO,'server0:',server)
            end
        end
        --检测当server下线状态和cooike不匹配的情况
        if is_down(server) or flag == nil  then
            --ngx.log(ngx.INFO,'server01:',server)
            route = nil
        end
    end
    if not route then
        for i = 1, #srvs do
            if not server or is_down(server) then
                server = srvs[get_server()].addr
            end
        end
        --ngx.log(ngx.INFO,'server1:',server)
        local expires = 3600 * 24  -- 1 day
        ngx.header["Set-Cookie"] = 'router=' .. ngx.md5(server) .. '; path=/;Expires=' .. ngx.cookie_time(ngx.time() + expires )
    end
        --ngx.log(ngx.INFO,'server2:',server)
    local index = string.find(server, ':')
    local host = string.sub(server, 1, index - 1)
    local port = string.sub(server, index + 1)
    balancer.set_current_peer(host, tonumber(port))
    }
}
	init_worker_by_lua_block {
        local hc = require "resty.upstream.healthcheck"

        local ok, err = hc.spawn_checker{
            shm = "healthcheck",  -- defined by "lua_shared_dict"
            upstream = "bar", -- defined by "upstream"
            type = "http",

            http_req = "GET / HTTP/1.0\r\nHost: bar\r\n\r\n",
                    -- raw HTTP request for checking

            interval = 2000,  -- run the check cycle every 2 sec
            timeout = 1000,   -- 1 sec is the timeout for network operations
            fall = 3,  -- # of successive failures before turning a peer down
            rise = 2,  -- # of successive successes before turning a peer up
            valid_statuses = {200, 302},  -- a list valid HTTP status code
            concurrency = 10,  -- concurrency level for test requests
        }
        if not ok then
            ngx.log(ngx.ERR, "failed to spawn health checker: ", err)
            return
        end

        -- Just call hc.spawn_checker() for more times here if you have
        -- more upstream groups to monitor. One call for one upstream group.
        -- They can all share the same shm zone without conflicts but they
        -- need a bigger shm zone for obvious reasons.
    }

    server {
        # this server is just for mocking up a backend peer here...
        listen 127.0.0.1:8001;

        location = / {
            echo "this is the fake backend peer...8080";
        }
    }
    server {
        # this server is just for mocking up a backend peer here...
        listen 127.0.0.1:8002;

        location = / {
            echo "this is the fake backend peer...8081";
        }
    }


}

