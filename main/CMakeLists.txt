idf_component_register(SRCS "hello.c"
                       INCLUDE_DIRS "."
                       REQUIRES esp_lcd esp_driver_spi esp_driver_gpio esp_driver_rmt esp_timer)
