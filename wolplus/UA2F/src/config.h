#pragma once

#ifdef UA2F_ENABLE_UCI
#ifndef UA2F_CONFIG_H
#define UA2F_CONFIG_H

#include <stdbool.h>

struct ua2f_config {
    bool use_custom_ua;
    char *custom_ua;
    bool disable_connmark;
};

void load_config();

extern struct ua2f_config config;

#endif // UA2F_CONFIG_H
#endif
