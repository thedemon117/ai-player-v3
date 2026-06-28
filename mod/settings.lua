data:extend({

  -- Bridge connection
  {
    type = "string-setting",
    name = "ai-player-lm-studio-url",
    setting_type = "runtime-global",
    default_value = "http://localhost:1234/v1/chat/completions",
    order = "a"
  },
  {
    type = "string-setting",
    name = "ai-player-model-name",
    setting_type = "runtime-global",
    default_value = "local-model",
    order = "b"
  },
  {
    type = "string-setting",
    name = "ai-player-provider",
    setting_type = "runtime-global",
    default_value = "lmstudio",
    allowed_values = {"lmstudio", "openai", "anthropic", "custom"},
    order = "c"
  },
  {
    type = "string-setting",
    name = "ai-player-openai-api-key",
    setting_type = "runtime-global",
    default_value = "",
    allow_blank = true,
    order = "d"
  },
  {
    type = "string-setting",
    name = "ai-player-openai-api-base",
    setting_type = "runtime-global",
    default_value = "https://api.openai.com/v1",
    allow_blank = true,
    order = "e"
  },
  {
    type = "string-setting",
    name = "ai-player-custom-url",
    setting_type = "runtime-global",
    default_value = "",
    allow_blank = true,
    order = "f"
  },

  -- RCON (bridge → Factorio)
  {
    type = "string-setting",
    name = "ai-player-rcon-host",
    setting_type = "runtime-global",
    default_value = "localhost",
    allow_blank = false,
    order = "g"
  },
  {
    type = "int-setting",
    name = "ai-player-rcon-port",
    setting_type = "runtime-global",
    default_value = 27015,
    minimum_value = 1,
    maximum_value = 65535,
    order = "h"
  },
  {
    type = "string-setting",
    name = "ai-player-rcon-password",
    setting_type = "runtime-global",
    default_value = "",
    allow_blank = true,
    order = "i"
  },

  -- AI behaviour
  {
    type = "int-setting",
    name = "ai-player-tick-interval",
    setting_type = "runtime-global",
    default_value = 300,
    minimum_value = 60,
    maximum_value = 1800,
    order = "j"
  },
  {
    type = "int-setting",
    name = "ai-player-vision-radius",
    setting_type = "runtime-global",
    default_value = 20,
    minimum_value = 5,
    maximum_value = 50,
    order = "k"
  },
  {
    type = "bool-setting",
    name = "ai-player-enable-chat",
    setting_type = "runtime-global",
    default_value = true,
    order = "l"
  },
  {
    type = "bool-setting",
    name = "ai-player-auto-respawn",
    setting_type = "runtime-global",
    default_value = true,
    order = "m"
  },
  {
    type = "bool-setting",
    name = "ai-player-debug-chat",
    setting_type = "runtime-global",
    default_value = false,
    order = "n"
  },

})
