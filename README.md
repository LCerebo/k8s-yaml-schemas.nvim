# k8s-yaml-schemas.nvim

Auto-attach Kubernetes & CRD schemas to `yaml-language-server` in Neovim

---

## Features

- Detects and attaches:
  - Core Kubernetes resource schemas (from [kubernetes-json-schema](https://github.com/yannh/kubernetes-json-schema))
  - Custom Resource Definitions (from [datreeio/CRDs-catalog](https://github.com/datreeio/CRDs-catalog))

---

## Requirements

- Neovim `>=0.11`, it's not an hard requirment but previous version are untested.
- [yaml-language-server](https://github.com/redhat-developer/yaml-language-server) via `lspconfig`
- [`plenary.nvim`](https://github.com/nvim-lua/plenary.nvim) (Optional, required only when schema_mode = "remote")
- ```git``` (Optional, required only when schema_mode = "local")
- ```find``` (Optional, required only when schema_mode = "local")

---

## Installation

### Using [Lazy.nvim](https://github.com/folke/lazy.nvim)

#### minimal config

```lua
{
  "LCerebo/k8s-yaml-schemas.nvim",
}
```

#### custom config

Customize the options below as needed.

```lua
{
  "LCerebo/k8s-yaml-schemas.nvim",
  opts = {
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
  }
}
```

---

## How It Works

### Offilne mode

1. When starting Neovim, update or create the local cache of schemas from the specified GitHub repositories, unless `disable_update` is true.
2. Load all the schemas into table.
3. When opening a YAML file, it reads the buffer, extracts `apiVersion` and `kind`.
4. Converts `apiVersion` and `kind` into a searchable table key that return the local path of the corresponding schema if exist.
5. Attach the schema to the current buffer via `yamlls`.

### Online mode (more work needed)

1. On opening a YAML file, it waits for `yamlls` to attach.
2. It reads the buffer, extracts `apiVersion` and `kind`.
3. It tries to match a CRD schema from `datreeio/CRDs-catalog`.
4. If no CRD matches, it tries the core Kubernetes schema.
5. It attaches the found schema to the current buffer via `yamlls`.

---

## Manual Trigger

Want to run it manually?

```lua
require("k8s_yaml_schemas").init(0) -- 0 = current buffer
```

---

## Debugging and troubleshooting

- Check for messages via `:NoiceAll`
- If `yamlls` is not running, schema won't attach
- Increase log level by setting `log_level` to `debug` or `trace`. (See [config](#custom-config) for more details)

---

## Credits

This repo was originally forked from [kritag/k8s-yaml-schemas.nvim](https://github.com/kritag/k8s-yaml-schemas.nvim)

The work started from this discussion on reddit: [improving_kubernetes_yaml_support_in_neovim_crds](https://www.reddit.com/r/neovim/comments/1iykmqc/improving_kubernetes_yaml_support_in_neovim_crds/)

Thanks to the contributor and maintainers of these schemas repositories:

- [yannh/kubernetes-json-schema](https://github.com/yannh/kubernetes-json-schema)
- [datreeio/CRDs-catalog](https://github.com/datreeio/CRDs-catalog)

---

## TODO

- Implement support for multiple object definitions in one file. Currentl not supported by `yamlls`. [#946](https://github.com/redhat-developer/yaml-language-server/issues/946)
- Improve the remote config by creating a local table of resources.
- Enable the hybrid mode where one can specify for each repo if it is local or remote.
- Fully support custom local repo (for example for a private CRD catalog).
- Add commands to manually update the local cache.
- Add unit tests.

---

## 📝 License

This project is licensed under the terms of the **GNU General Public License v3.0**.
See [LICENSE](./LICENSE) for details.
