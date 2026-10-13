-- Markdown preview plugin configuration (iamcco/markdown-preview.nvim)
-- Provides real-time markdown preview in browser with PlantUML, Mermaid, KaTeX support.
--
-- Commands:
--   :MarkdownPreview       - Start preview server and open browser
--   :MarkdownPreviewStop   - Stop the preview server
--   :MarkdownPreviewToggle - Toggle preview on/off
--
-- Keymaps:
--   <Leader>v - Open markdown preview (normal mode)
--
-- Preview URL format:
--   http://<host>:<port>/page/<bufnr>
--   - <host>: machine IP when mkdp_open_to_the_world=1, otherwise localhost
--   - <port>: fixed at 9275 (configured below)
--   - <bufnr>: Neovim buffer number, NOT fixed (depends on buffer open order)
--   - The URL is printed in command line each time :MarkdownPreview is called
--
-- CAVEAT: Do NOT manually refresh /page/<bufnr> in browser.
--   Next.js client-side routing will redirect /page/1 to /1, which returns 404.
--   Always use the plugin to open/refresh the preview.
--
-- PlantUML local server:
--   Start with: java -jar plantuml.jar -picoweb:9274
--   The plugin auto-detects localhost:9274 on load. If detected, PlantUML
--   diagrams are rendered via the local server; otherwise falls back to
--   https://www.plantuml.com/plantuml (public server).
--
--   CAVEAT: When accessing preview remotely (browser on a different machine),
--   the PlantUML <img> src points to http://localhost:9274 which resolves to
--   the BROWSER's machine, not the server. Two solutions:
--
--   Solution A: SSH port-forwarding (forward remote PlantUML to local)
--     ssh -L 9274:localhost:9274 -L 9275:localhost:9275 <remote>
--     This forwards both the PlantUML server (9274) and preview server (9275)
--     to your local machine. Access preview at http://localhost:9275/page/<bufnr>
--
--   Solution B: Run PlantUML locally on the browser's machine
--     java -jar plantuml.jar -picoweb:9274
--     Since <img> src already points to localhost:9274, a local PlantUML server
--     will handle the rendering directly without any port-forwarding needed.
--     Only the preview port (9275) needs forwarding in this case:
--     ssh -L 9275:localhost:9275 <remote>

return {
    "iamcco/markdown-preview.nvim",
    -- Lazy-load: only activate on these commands or when opening markdown files
    cmd = { "MarkdownPreviewToggle", "MarkdownPreview", "MarkdownPreviewStop" },
    ft = { "markdown" },
    -- Download pre-built binary from GitHub releases on install/update.
    -- During a fresh bootstrap lazy runs build BEFORE the plugin is added to
    -- runtimepath, so the autoload function is unknown (E117) unless its dir
    -- is prepended first (same idea as the README's minpac packloadall).
    -- plugin.dir is lazy's resolved install path, passed to build functions.
    build = function(plugin)
        vim.opt.runtimepath:prepend(plugin.dir)
        vim.fn["mkdp#util#install"]()
    end,
    config = function()
        -- Custom CSS to override default page layout (full-width, no border)
        ---@type string
        vim.g.mkdp_markdown_css = vim.fn.stdpath("config") .. "/assets/markdown-preview.css"
        -- Listen on 0.0.0.0 instead of 127.0.0.1 for remote access
        ---@type integer
        vim.g.mkdp_open_to_the_world = 1
        -- Print preview URL in command line on start
        ---@type integer
        vim.g.mkdp_echo_preview_url = 1
        -- Fixed port for stable URL and port-forwarding
        ---@type integer
        vim.g.mkdp_port = 9275

        --- Detect if a local PlantUML server is running on port 9274.
        --- Uses libuv TCP connect with 200ms timeout to probe localhost:9274.
        --- Returns the local server URL if available, nil otherwise (falls back to
        --- the plugin's default public server: https://www.plantuml.com/plantuml).
        ---@return string|nil server PlantUML server URL or nil for default
        local function detect_plantuml_server()
            ---@type string|nil
            local server = nil
            pcall(function()
                -- Compatible with Neovim >= 0.8 (vim.loop) and >= 0.10 (vim.uv)
                local uv = vim.uv or vim.loop
                -- Create a TCP handle for connection probing
                local tcp = uv.new_tcp()
                ---@type boolean
                local done = false
                ---@type boolean
                local connected = false
                -- Attempt async TCP connect to localhost:9274
                tcp:connect("127.0.0.1", 9274, function(e)
                    -- e is nil on success, error object on failure
                    connected = (e == nil)
                    -- Close the TCP handle inside callback
                    if not tcp:is_closing() then tcp:close() end
                    -- Signal that the async operation completed
                    done = true
                end)
                -- Block up to 200ms waiting for the callback (sufficient for localhost)
                vim.wait(200, function() return done end)
                if not done then
                    -- Timeout: close TCP handle to prevent resource leak
                    if not tcp:is_closing() then tcp:close() end
                else
                    -- Callback fired: use local server if connection succeeded
                    if connected then
                        server = "http://localhost:9274"
                    end
                end
            end)
            return server
        end

        -- Open markdown preview with <Leader>v
        vim.keymap.set("n", "<Leader>v", "<cmd>MarkdownPreview<CR>", { silent = true })

        -- Configure PlantUML rendering options
        -- If local PlantUML server (java -jar plantuml.jar -picoweb:9274) is detected,
        -- use it; otherwise the plugin falls back to https://www.plantuml.com/plantuml
        vim.g.mkdp_preview_options = {
            uml = {
                server = detect_plantuml_server(),
                imageFormat = "svg",
            },
        }
    end,
}
