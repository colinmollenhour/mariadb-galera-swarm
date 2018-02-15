#!/bin/bash
# my_print_defaults does not quote spaces in config values which breaks wsrep_sst_common
# See https://github.com/MariaDB/server/pull/617
pigz --fast --processes 2
