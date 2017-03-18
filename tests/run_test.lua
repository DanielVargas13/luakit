--- Main test runner.
--
-- @script run_test
-- @copyright 2017 Aidan Holm

-- Add ./tests to package.path
package.path = package.path .. ';./tests/?.lua'
package.path = package.path .. ';./lib/?.lua;./lib/?/init.lua'

local util = require "tests.util"
local posix = require "posix"
local lfs = require "lfs"

local xvfb_display

local current_test_name
local prev_test_name
local function update_test_status(status, test_name, test_file)
    assert(type(status) == "string")

    local esc = string.char(27)
    local c_red   = esc .. "[0;31m"
    local c_green = esc .. "[0;32m"
    local c_grey  = esc .. "[0;37m"
    local c_reset = esc .. "[0;0m"

    local status_color = ({
        pass = c_green,
        fail = c_red,
        wait = c_grey,
        cont = c_grey,
        run  = c_grey,
    })[status] or ""

    if status == "run" then
        status = "run "
        current_test_name = test_file:match("tests/(.*)%.lua") .. " / " .. test_name
    else
        test_name = current_test_name
    end

    -- Overwrite the previous status line if it's for the same test
    if prev_test_name == test_name then
        io.write(esc .. "[1A" .. esc .. "[K")
    end
    prev_test_name = current_test_name

    print(status_color .. status:upper() .. c_reset .. " " .. test_name)
end

local function log_test_output(msg)
    prev_test_name = nil
    local indent = "  "
    print("  " .. msg:gsub("\n", "\n" .. indent))
end

local function do_style_tests(test_files)
    for _, test_file in ipairs(test_files) do
        -- Load test table
        local chunk, err = loadfile(test_file)
        assert(chunk, err)
        local T = chunk()
        assert(type(T) == "table")

        for test_name, func in pairs(T) do
            assert(type(test_name) == "string")
            assert(type(func) == "function")

            update_test_status("run", test_name, test_file)
            local ok, ret = pcall(func)
            update_test_status(ok and "pass" or "fail")
            if not ok and ret then
                log_test_output(ret)
            end
        end
    end
end

local luakit_tmp_dirs = {}

local function spawn_luakit_instance(config, ...)
    -- Create a temporary directory, hopefully on a ramdisk
    local dir = posix.mkdtemp("/tmp/luakit_test_XXXXXX")
    table.insert(luakit_tmp_dirs, dir)

    -- Cheap version of a chroot that doesn't require special permissions
    local env = {
        HOME            = dir,
        XDG_CACHE_HOME  = dir .. "/cache",
        XDG_DATA_HOME   = dir .. "/data",
        XDG_CONFIG_HOME = dir .. "/config",
        XDG_RUNTIME_DIR = dir .. "/runtime",
        XDG_CONFIG_DIRS = "",
        DISPLAY = xvfb_display
    }

    -- HACK: make GStreamer shut up about not finding random .so files
    -- when it rebuilds its registry, which it does with every single
    -- luakit instance spawned this way
    local gst_dir = posix.getenv("XDG_CACHE_HOME") .. "/gstreamer-1.0"
    if lfs.attributes(gst_dir, "mode") == "directory" then
        os.execute("mkdir -p " .. env.XDG_CACHE_HOME .. "/gstreamer-1.0/")
        os.execute("cp "..gst_dir.."/registry.x86_64.bin " .. env.XDG_CACHE_HOME .. "/gstreamer-1.0")
    end

    -- Build env prefix
    local cmd = "env --ignore-environment - "
    for k, v in pairs(env) do
        cmd = cmd .. k .."=" .. v .. " "
    end

    cmd = cmd .. "./luakit -U --log=fatal -c " .. config .. " " .. table.concat({...}, " ")  .. " 2>&1"
    return assert(io.popen(cmd))
end

-- Automatically clean up test directories
local luakit_tmp_dirs_prx = newproxy(true)
getmetatable(luakit_tmp_dirs_prx).__gc = function ()
    print("Removing temporary directories")
    for _, dir in ipairs(luakit_tmp_dirs) do
        assert(dir:match("^/tmp/luakit_test_"))
        os.execute("rm -r " .. dir)
    end
end

local function do_async_tests(test_files)
    for _, test_file in ipairs(test_files) do
        local f = spawn_luakit_instance("tests/async/run_test.lua", test_file)

        local status, test_name
        for line in f:lines() do
            status, test_name = line:match("^__(%a+)__ (.*)$")
            if status and test_name then
                update_test_status(status, test_name, test_file)
            else
                log_test_output(line)
            end
        end
        f:close()
    end
end

local function do_lunit_tests(test_files)
    print("Running legacy tests...")
    local f = spawn_luakit_instance("tests/lunit-run.lua", unpack(test_files))
    for line in f:lines() do
        print(line)
    end
    f:close()
end

local test_file_pat = "/test_%S+%.lua$"
local test_files = {
    style = util.find_files("tests/style/", test_file_pat),
    async = util.find_files("tests/async/", test_file_pat),
    lunit = util.find_files("tests/lunit/", test_file_pat),
}

-- Find a free server number
-- Does have a race condition...
for i=0,math.huge do
    local f = io.open(("/tmp/.X%d-lock"):format(i))
    if not f then
        xvfb_display = ":" .. tostring(i)
        break
    end
    f:close()
end

-- Launch Xvfb for lifetime of test runner
print("Starting Xvfb")
local pid_xvfb = util.spawn({"Xvfb", xvfb_display, "-screen", "0", "800x600x8"})
local xvfb_prx = newproxy(true)
getmetatable(xvfb_prx).__gc = function ()
    print("Stopping Xvfb")
    posix.kill(pid_xvfb)
end

-- Launch a test HTTP server
print("Starting HTTP server")
local pid_httpd = util.spawn({"luajit", "tests/httpd.lua"})
local httpd_prx = newproxy(true)
getmetatable(httpd_prx).__gc = function ()
    print("Stopping HTTP server")
    posix.kill(pid_httpd)
end

do_style_tests(test_files.style)
do_async_tests(test_files.async)
do_lunit_tests(test_files.lunit)

-- vim: et:sw=4:ts=8:sts=4:tw=80
