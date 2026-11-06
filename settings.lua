data:extend{
    {
        type          = "int-setting",
        name          = "lua-combinator-default-interval",
        setting_type  = "runtime-global",
        default_value = 20,
        minimum_value = 1,
        maximum_value = 216000,
        order         = "a",
    },
    {
        type          = "bool-setting",
        name          = "lua-combinator-error-marker",
        setting_type  = "runtime-global",
        default_value = true,
        order         = "b",
    },
    {
        type          = "bool-setting",
        name          = "lua-combinator-error-chat",
        setting_type  = "runtime-global",
        default_value = false,
        order         = "c",
    },
}
