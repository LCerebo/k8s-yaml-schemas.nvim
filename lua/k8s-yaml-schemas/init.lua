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
	config = {
		schema_mode = "api", --default "api", other option is "git_clone"
		local_schema_cache_path = "~/.local/share/k8s-yaml-schemas", -- Used if schema_mode is "git_clone"
		cache_ttl_hours = 12, -- Time to live for cached schemas in hours
		disable_update = false, -- If true disable the cloning and pull of the git repository containin CRD schemas, in this case the user should manage the repository manually
		schemas_table = {
			crds = {
				repo = "/datreeio/CRDs-catalog",
				branch = "main",
			},
			k8s_core = {
				repo = "/yannh/kubernetes-json-schema",
				subfolder = "/master-standalone-strict",
				branch = "master",
			},
		},
	},
}

-- Setup function to configure the plugin
M.setup = function(opts)
	opts = opts or {}
	M.config = vim.tbl_deep_extend("force", M.config, opts)
	if M.config.schema_mode ~= "api" and M.config.schema_mode ~= "git_clone" then
		vim.notify(
			"Invalid schema_mode: '"
				.. M.config.schema_mode
				.. "'. Valid values are: 'api', 'git_clone'. Using default 'api'.",
			vim.log.levels.WARN
		)
		M.config.schema_mode = "api"
	end
	M.local_schema_cache_absolute_path = vim.fn.expand(M.config.local_schema_cache_path)
	M.ttl_file_path = M.local_schema_cache_absolute_path .. "/.k8s_yaml_schemas_ttl"

	if M.config.disable_update then
		vim.notify("CRD schema auto-update is disabled. Please manage the local cache manually.", vim.log.levels.DEBUG)
	end
	if M.config.schema_mode ~= "git_clone" then
		vim.notify("Using remote schemas.", vim.log.levels.DEBUG)
	end
	if not M.is_cache_expired(M.ttl_file_path, M.config.cache_ttl_hours) then
		vim.notify("Cache TTL is still valid, skipping cache update.", vim.log.levels.DEBUG)
	end

	if
		not M.config.disable_update
		and M.config.schema_mode == "git_clone"
		and M.is_cache_expired(M.ttl_file_path, M.config.cache_ttl_hours)
	then
		M.update_local_cache()
	end
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

M.update_local_cache = function()
	local crd_cache_path = M.local_schema_cache_absolute_path .. "/datreeio_crds"
	vim.system({ "mkdir", "-p", crd_cache_path })

	local git_clone_command = {
		"git",
		"clone",
		"-b",
		M.config.schemas_table.crds.branch,
		M.git_clone_url .. M.config.schemas_table.crds.repo .. ".git",
		crd_cache_path,
	}

	vim.system(git_clone_command, { text = true }, function(clone_obj)
		if clone_obj.code == 0 then
			vim.notify("Cloned CRD schemas to " .. crd_cache_path, vim.log.levels.INFO)
		elseif clone_obj.code == 128 then
			-- Repository already exists, perform git pull
			local git_pull_command = { "git", "-C", crd_cache_path, "pull" }
			vim.system(git_pull_command, { text = true }, function(pull_obj)
				if pull_obj.code == 0 then
					vim.notify("Updated CRD schemas in " .. crd_cache_path, vim.log.levels.INFO)
				else
					vim.notify("Failed to update CRD schemas: " .. pull_obj.stderr, vim.log.levels.ERROR)
				end
			end)
		else
			vim.notify("Failed to clone CRD schemas: " .. clone_obj.stderr, vim.log.levels.ERROR)
		end
	end)
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

-- Extract apiVersion and kind from buffer content
M.extract_api_version_and_kind = function(buffer_content)
	buffer_content = buffer_content:gsub("%-%-%-%s*\n", "")
	local api_version = buffer_content:match("apiVersion:%s*([%w%p]+)")
	local kind = buffer_content:match("kind:%s*([%w%-]+)")
	return api_version, kind
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
		vim.notify("yaml-language-server is not active.", vim.log.levels.WARN)
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
	vim.notify("Attached schema: " .. description, vim.log.levels.INFO)
end

-- Kubernetes core schema URL fallback
M.get_kubernetes_schema_url = function(api_version, kind)
	local version = api_version:match("/([%w%-]+)$") or api_version
	local schema_name = kind:lower() .. "-" .. version .. ".json"
	local base_url =
		"https://raw.githubusercontent.com/yannh/kubernetes-json-schema/refs/heads/master/master-standalone-strict/"

	local url_with_version = base_url .. schema_name
	local url_without_version = base_url .. kind:lower() .. ".json"
	vim.notify("Checking schema URL: " .. url_with_version, vim.log.levels.DEBUG)
	vim.notify("Checking schema URL without version: " .. url_without_version, vim.log.levels.DEBUG)
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

-- Main entrypoint to attach schemas for a buffer
M.init = function(bufnr)
	if vim.b[bufnr].schema_attached then
		return
	end
	vim.b[bufnr].schema_attached = true

	local buffer_content = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")

	local number_of_k8s_resources = select(2, string.gsub(buffer_content, "apiVersion:", ""))
	vim.notify("Number of apiVersion occurrences: " .. number_of_k8s_resources, vim.log.levels.DEBUG)
	if number_of_k8s_resources < 1 then
		vim.notify("No kubernets resources found in buffer " .. vim.api.nvim_buf_get_name(bufnr), vim.log.levels.DEBUG)
		return
	elseif number_of_k8s_resources > 1 then
		vim.notify(
			"Multiple resources in a single file not supported. Please split them or ignore the message.",
			vim.log.levels.INFO
		)
		return
	else
		local api_version, kind = M.extract_api_version_and_kind(buffer_content)

		local crd = M.match_crd(api_version, kind)

		if crd then
			local schema_url
			if M.config.schema_mode == "git_clone" then
				schema_url = vim.fn.expand(M.config.local_schema_cache_path) .. "/datreeio_crds/" .. crd
			else
				schema_url = M.github_raw_url
					.. M.config.schemas_table.crds.repo
					.. "/"
					.. M.config.schemas_table.crds.branch
					.. "/"
					.. crd
			end
			M.attach_schema(schema_url, "CRD schema for " .. crd, bufnr)
		else
			if api_version and kind then
				local url = M.get_kubernetes_schema_url(api_version, kind)
				if url then
					M.attach_schema(url, "Kubernetes schema for " .. kind, bufnr)
				else
					vim.notify(
						"No Kubernetes schema found for " .. kind .. " (" .. api_version .. ")",
						vim.log.levels.WARN
					)
				end
			else
				vim.notify(
					"No CRD or Kubernetes schema found. Falling back to default LSP configuration.",
					vim.log.levels.WARN
				)
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
