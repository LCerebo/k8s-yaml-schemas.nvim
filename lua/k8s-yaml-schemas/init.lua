local curl = require("plenary.curl")

local M = {
	github_clone_url = "https://github.com",
	github_raw_url = "https://raw.githubusercontent.com",
	github_base_api_url = "https://api.github.com/repos",
	github_headers = {
		Accept = "application/vnd.github+json",
		["X-GitHub-Api-Version"] = "2022-11-28",
	},
	schema_cache = {},
	schemas_map = {},
	config = {
		schema_mode = "local", --default "local", other option is "remote"
		local_schema_cache_path = "~/.local/share/k8s-yaml-schemas", -- Used if schema_mode is "local"
		cache_ttl_hours = 12, -- Time to live for cached schemas in hours
		disable_update = false, -- If true disable the cloning and pull of the git repository containin CRD schemas, in this case the user should manually manage the repositories
		log_level = "info", -- one of "trace", "debug", "info", "warn", "error"
		schemas_table = {
			crds = {
				repo = "/datreeio/CRDs-catalog",
				branch = "main",
			},
			k8s_core = {
				repo = "/yannh/kubernetes-json-schema",
				subfolder = "master-standalone-strict",
				branch = "master",
			},
		},
	},
}
local log_levels = { trace = 0, debug = 1, info = 2, warn = 3, error = 4 }

---@param message string the message to send
---@param level string the log level could be: "trace", "debug", "info", "warn", "error"
M.log = function(message, level)
	if log_levels[level] >= log_levels[M.config.log_level] then
		vim.notify(message, log_levels[level])
	end
end

-- Setup function to configure the plugin
M.setup = function(opts)
	opts = opts or {}
	M.config = vim.tbl_deep_extend("force", M.config, opts)
	if log_levels[M.config.log_level] == nil then
		vim.notify(
			"Invalid log level: " .. tostring(M.config.log_level) .. ". Defaulting to 'info'.",
			vim.log.levels.WARN
		)
		M.config.log_level = "info"
	end

	if M.config.schema_mode ~= "remote" and M.config.schema_mode ~= "local" then
		M.log(
			"Invalid schema_mode: '"
				.. M.config.schema_mode
				.. "'. Valid values are: 'api', 'git_clone'. Using default 'api'.",
			"warn"
		)
		M.config.schema_mode = "remote"
	end
	M.local_schema_cache_absolute_path = vim.fn.expand(M.config.local_schema_cache_path)
	M.ttl_file_path = M.local_schema_cache_absolute_path .. "/.k8s_yaml_schemas_ttl"

	if M.config.disable_update then
		M.log("CRD schema auto-update is disabled. Please manage the local cache manually.", "debug")
	end
	if M.config.schema_mode ~= "local" then
		M.log("Using remote schemas.", "debug")
	end
	if not M.is_cache_expired(M.ttl_file_path, M.config.cache_ttl_hours) then
		M.log("Cache TTL is still valid, skipping cache update.", "debug")
	end

	if
		not M.config.disable_update
		and M.config.schema_mode == "local"
		and M.is_cache_expired(M.ttl_file_path, M.config.cache_ttl_hours)
	then
		M.update_local_cache()
	end
	if M.config.schema_mode == "local" then
		M.load_schema_map()
		local len = 0
		if M.schema_map == nil then
			M.log("Schema map is nil", "debug")
		else
			for _ in pairs(M.schema_map) do
				len = len + 1
			end
			M.log("Schema map length is " .. len, "debug")
		end
	end
	M.setup_autocmd()
end

M.is_cache_expired = function(ttl_file_path, cache_ttl_hours)
	if cache_ttl_hours <= 0 then
		return true
	end
	local file = io.open(ttl_file_path, "r")
	if not file then
		return true
	end
	local timestamp = file:read("*a")
	file:close()
	local last_update = tonumber(timestamp)
	if not last_update then
		return true
	end
	local current_time = os.time()
	local ttl_seconds = cache_ttl_hours * 3600
	return (current_time - last_update) > ttl_seconds
end

M.update_ttl_file = function(ttl_file_path)
	local file = io.open(ttl_file_path, "w")
	if file then
		file:write(tostring(os.time()))
		file:close()
	end
end

local clone_or_update_repository = function(repo, branch, subfolder)
	local repo_path = M.local_schema_cache_absolute_path .. repo
	vim.system({ "mkdir", "-p", repo_path })
	local git_clone_command
	if subfolder then
		git_clone_command = {
			"bash",
			"-c",
			"git clone --filter=blob:none --sparse --depth 1 -b "
				.. branch
				.. " "
				.. M.github_clone_url
				.. repo
				.. ".git "
				.. repo_path
				.. " && git -C "
				.. repo_path
				.. " sparse-checkout set "
				.. subfolder,
		}
	else
		git_clone_command = {
			"git",
			"clone",
			"--depth",
			"1",
			"-b",
			branch,
			M.github_clone_url .. repo .. ".git",
			repo_path,
		}
	end
	M.log("Executing: " .. table.concat(git_clone_command, " "), "trace")
	local git_pull_command = { "git", "-C", repo_path, "pull" }
	vim.system(git_clone_command, { text = true }, function(clone_obj)
		if clone_obj.code == 0 then
			M.log("Cloned CRD schemas to " .. repo_path, "info")
		elseif clone_obj.code == 128 then
			-- Repository already exists, perform git pull
			M.log("Executing " .. table.concat(git_pull_command, " "), "trace")
			vim.system(git_pull_command, { text = true }, function(pull_obj)
				if pull_obj.code == 0 then
					M.log("Updated schemas in " .. repo_path, "info")
				else
					M.log("Failed to update schemas: " .. pull_obj.stderr, "error")
				end
			end)
		else
			M.log("Failed to clone schemas: " .. clone_obj.stderr, "error")
		end
		M.log("Loading schema map...", "debug")
		M.load_schema_map()
	end)
end

M.update_local_cache = function()
	for _, repo_info in pairs(M.config.schemas_table) do
		clone_or_update_repository(repo_info.repo, repo_info.branch, repo_info.subfolder)
	end
	M.update_ttl_file(M.ttl_file_path)
end

-- List CRD schemas from GitHub (include both json and yaml)
M.list_github_tree = function()
	if M.schema_cache.trees then
		return M.schema_cache.trees
	end
	local url = M.github_base_api_url
		.. M.config.schemas_table.crds.repo
		.. "/git/trees/"
		.. M.config.schemas_table.crds.branch
	local response = curl.get(url, { headers = M.github_headers, query = { recursive = 1 } })
	local body = vim.fn.json_decode(response.body)
	local trees = {}
	for _, tree in ipairs(body.tree) do
		if tree.type == "blob" and (tree.path:match("%.json$") or tree.path:match("%.yaml$")) then
			table.insert(trees, tree.path)
		end
	end
	M.schema_cache.trees = trees
	return trees
end

M.extract_api_version_and_kind = function(buffer_content)
	local api_version = buffer_content:match("apiVersion:%s*([%w%p]+)")
	local kind = buffer_content:match("kind:%s*([%w%-]+)")
	M.log("Extracted apiVersion: " .. tostring(api_version), "debug")
	M.log("Extracted kind: " .. tostring(kind), "debug")
	return api_version, kind
end

M.split_api_version = function(api_version)
	if not api_version then
		return nil, nil
	end
	if api_version:match("^v%d") then
		return "", api_version
	end
	local group, version = api_version:match("([^/]+)/([^/]+)")
	return group, version
end

M.get_resource_key = function(api_version, kind)
	local group, version = M.split_api_version(api_version)
	if not version or not kind then
		return nil
	end
	if group == "" then
		return kind:lower() .. "-" .. version
	elseif not string.find(group, "%.") then
		return kind:lower() .. "-" .. group .. "-" .. version
	else
		return group .. "/" .. kind:lower() .. "-" .. version
	end
end

-- Normalize CRD filename: pluralize kind, ignore version in filename
M.normalize_crd_name = function(api_version, kind)
	if not api_version or not kind then
		return nil
	end
	local group, version = api_version:match("([^/]+)/([^/]+)")
	if not group or not version then
		return nil
	end
	-- underscore before version, and lowercase kind
	return group .. "/" .. kind:lower() .. "_" .. version .. ".json"
end

-- Match CRD file from GitHub tree
M.match_crd = function(api_version, kind)
	local crd_name = M.normalize_crd_name(api_version, kind)
	if not crd_name then
		return nil
	end
	local all_crds = M.list_github_tree()
	for _, crd in ipairs(all_crds) do
		if crd:match(crd_name) then
			return crd
		end
	end
	return nil
end

-- Attach schema to current buffer, scoped by filename
M.attach_schema = function(schema_url, description, bufnr)
	local clients = vim.lsp.get_clients({ name = "yamlls" })
	if #clients == 0 then
		M.log("yaml-language-server is not active.", "warn")
		return
	end
	local yaml_client = clients[1]
	yaml_client.config.settings = yaml_client.config.settings or {}
	yaml_client.config.settings.yaml = yaml_client.config.settings.yaml or {}
	yaml_client.config.settings.yaml.schemas = yaml_client.config.settings.yaml.schemas or {}
	local bufname = vim.api.nvim_buf_get_name(bufnr)
	yaml_client.config.settings.yaml.schemas[schema_url] = { bufname }
	yaml_client.notify("workspace/didChangeConfiguration", {
		settings = yaml_client.config.settings,
	})
	M.log("Attached schema: " .. description, "info")
end

-- Kubernetes core schema URL fallback
M.get_kubernetes_schema_url = function(api_version, kind)
	local version = api_version:match("/([%w%-]+)$") or api_version
	local schema_name = kind:lower() .. "-" .. version .. ".json"
	local base_url =
		"https://raw.githubusercontent.com/yannh/kubernetes-json-schema/refs/heads/master/master-standalone-strict/"

	local url_with_version = base_url .. schema_name
	local url_without_version = base_url .. kind:lower() .. ".json"
	M.log("Checking schema URL: " .. url_with_version, "debug")
	M.log("Checking schema URL without version: " .. url_without_version, "debug")
	local r1 = curl.get(url_with_version, { headers = M.github_headers })
	if r1.status == 200 then
		return url_with_version
	end

	local r2 = curl.get(url_without_version, { headers = M.github_headers })
	if r2.status == 200 then
		return url_without_version
	end
	return nil
end
M.load_schema_map = function()
	M.log("Loading schema map from local cache...", "debug")
	for _, repo_info in pairs(M.config.schemas_table) do
		local repo_path = M.local_schema_cache_absolute_path .. repo_info.repo
		if repo_info.subfolder then
			repo_path = repo_path .. "/" .. repo_info.subfolder
		end
		M.log("Loading schemas from path: " .. repo_path, "debug")
		local find_command = "find " .. repo_path .. " -name '*.json'"
		M.log("Executing find command: " .. find_command, "trace")
		local handle = io.popen(find_command)
		if not handle then
			M.log("Failed to open schema directory for repo: " .. repo_info.repo .. ".", "error")
		else
			local stdout = handle:read("*a")
			handle:close()
			for json_file_path in stdout:gmatch("[^\n]+") do
				local key = json_file_path
					:gsub(vim.pesc(repo_path .. "/"), "")
					:gsub(vim.pesc(".json"), "")
					:gsub(vim.pesc("_"), vim.pesc("-"))
				M.schemas_map[key] = json_file_path
			end
		end
	end
	M.log("Loaded " .. tostring(vim.tbl_count(M.schemas_map)) .. " schemas into map.", "debug")
end
-- Main entrypoint to attach schemas for a buffer
M.init = function(bufnr)
	if vim.b[bufnr].schema_attached then
		return
	end
	vim.b[bufnr].schema_attached = true
	local buffer_content = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")

	local number_of_k8s_resources = select(2, string.gsub(buffer_content, "apiVersion:", ""))
	M.log("Number of apiVersion occurrences: " .. number_of_k8s_resources, "debug")
	if number_of_k8s_resources < 1 then
		M.log("No kubernets resources found in buffer " .. vim.api.nvim_buf_get_name(bufnr), "debug")
		return
	elseif number_of_k8s_resources > 1 then
		M.log("Multiple resources in a single file not supported. Please split them or ignore the message.", "info")
		return
	else
		local api_version, kind = M.extract_api_version_and_kind(buffer_content)

		if M.config.schema_mode == "local" then
			local resource_key = M.get_resource_key(api_version, kind)
			M.log("Resource key: " .. resource_key, "debug")
			local schema_path = M.schemas_map[resource_key]
			M.attach_schema(schema_path, "from local path for " .. resource_key, bufnr)
		else
			-- TODO merge in an optmized searh pattern with a map of remote schemas
			local crd = M.match_crd(api_version, kind)
			if crd then
				local schema_url

				schema_url = M.github_raw_url
					.. M.config.schemas_table.crds.repo
					.. "/"
					.. M.config.schemas_table.crds.branch
					.. "/"
					.. crd

				M.attach_schema(schema_url, "CRD schema for " .. crd, bufnr)
			else
				if api_version and kind then
					local url = M.get_kubernetes_schema_url(api_version, kind)
					if url then
						M.attach_schema(url, "Kubernetes schema for " .. kind, bufnr)
					else
						M.log("No Kubernetes schema found for " .. kind .. " (" .. api_version .. ")", "warn")
					end
				else
					M.log("No CRD or Kubernetes schema found. Falling back to default LSP configuration.", "warn")
				end
			end
		end
	end
end

M.setup_autocmd = function()
	vim.api.nvim_create_autocmd("FileType", {
		pattern = "yaml",
		callback = function(args)
			local bufnr = args.buf
			local clients = vim.lsp.get_clients({ name = "yamlls", bufnr = bufnr })

			if #clients > 0 then
				require("k8s-yaml-schemas").init(bufnr)
			else
				vim.api.nvim_create_autocmd("LspAttach", {
					once = true,
					buffer = bufnr,
					callback = function(lsp_args)
						local client = vim.lsp.get_client_by_id(lsp_args.data.client_id)
						if client and client.name == "yamlls" then
							require("k8s-yaml-schemas").init(bufnr)
						end
					end,
				})
			end
		end,
	})
end

return M
