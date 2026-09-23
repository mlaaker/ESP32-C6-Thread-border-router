/*
 * SPDX-FileCopyrightText: 2021-2026 Espressif Systems (Shanghai) CO LTD
 *
 * SPDX-License-Identifier: CC0-1.0
 *
 * OpenThread Border Router Example
 *
 * This example code is in the Public Domain (or CC0 licensed, at your option.)
 *
 * Unless required by applicable law or agreed to in writing, this
 * software is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
 * CONDITIONS OF ANY KIND, either express or implied.
 */

#include <stdio.h>
#include <string.h>

#include "sdkconfig.h"
#include "esp_check.h"
#include "esp_coexist.h"
#include "esp_err.h"
#include "esp_event.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_openthread.h"
#include "esp_openthread_border_router.h"
#include "esp_openthread_lock.h"
#include "esp_openthread_netif_glue.h"
#include "openthread/dataset.h"
#include "protocol_examples_common.h"
#include "esp_openthread_spinel.h"
#include "esp_openthread_types.h"
#if CONFIG_OPENTHREAD_CLI_ESP_EXTENSION
#include "esp_ot_cli_extension.h"
#endif // CONFIG_OPENTHREAD_CLI_ESP_EXTENSION
#include "esp_ot_config.h"
#include "esp_vfs_dev.h"
#include "esp_vfs_eventfd.h"
#include "mdns.h"
#include "nvs_flash.h"
#include "ot_examples_br.h"
#include "ot_examples_common.h"

#if CONFIG_OPENTHREAD_STATE_INDICATOR_ENABLE
#include "ot_led_strip.h"
#endif

#if CONFIG_ESP_COEX_EXTERNAL_COEXIST_ENABLE
#include "ext_coex_cmd.h"
#endif

#define TAG "esp_ot_br"

#if CONFIG_OPENTHREAD_SUPPORT_HW_RESET_RCP
#define PIN_TO_RCP_RESET CONFIG_OPENTHREAD_HW_RESET_RCP_PIN
static void rcp_failure_hardware_reset_handler(void)
{
    gpio_config_t reset_pin_config;
    memset(&reset_pin_config, 0, sizeof(reset_pin_config));
    reset_pin_config.intr_type = GPIO_INTR_DISABLE;
    reset_pin_config.pin_bit_mask = BIT(PIN_TO_RCP_RESET);
    reset_pin_config.mode = GPIO_MODE_OUTPUT;
    reset_pin_config.pull_down_en = GPIO_PULLDOWN_DISABLE;
    reset_pin_config.pull_up_en = GPIO_PULLUP_DISABLE;
    gpio_config(&reset_pin_config);
    gpio_set_level(PIN_TO_RCP_RESET, 0);
    vTaskDelay(pdMS_TO_TICKS(10));
    gpio_set_level(PIN_TO_RCP_RESET, 1);
    vTaskDelay(pdMS_TO_TICKS(30));
    gpio_reset_pin(PIN_TO_RCP_RESET);
}
#endif

#if CONFIG_OPENTHREAD_BORDER_ROUTER && CONFIG_OPENTHREAD_NETWORK_AUTO_START
// Same as esp_openthread_border_router_start() in ot_examples_br, plus: once the border router is up,
// rejoin the Thread network saved in NVS. Never forms a new network when no dataset is saved.
static void ot_br_init_and_resume(void *ctx)
{
    ESP_ERROR_CHECK(example_connect());
    esp_openthread_lock_acquire(portMAX_DELAY);
    esp_openthread_set_backbone_netif(get_example_netif());
    ESP_ERROR_CHECK(esp_openthread_set_meshcop_instance_name(CONFIG_OTBR_INSTANCE_NAME));
    ESP_ERROR_CHECK(esp_openthread_border_router_init());

    otOperationalDatasetTlvs dataset;
    if (otDatasetGetActiveTlvs(esp_openthread_get_instance(), &dataset) == OT_ERROR_NONE) {
        ESP_LOGI(TAG, "Resuming saved Thread network");
        ESP_ERROR_CHECK(esp_openthread_auto_start(&dataset));
    } else {
        ESP_LOGW(TAG, "No saved Thread dataset; provision via CLI: ot dataset set active <tlvs>");
    }
    esp_openthread_lock_release();
    vTaskDelete(NULL);
}
#endif

void app_main(void)
{
    // Used eventfds:
    // * netif
    // * task queue
    // * border router
    size_t max_eventfd = 3;

#if CONFIG_OPENTHREAD_RADIO_NATIVE || CONFIG_OPENTHREAD_RADIO_SPINEL_SPI
    // * radio driver (A native radio device needs a eventfd for radio driver.)
    // * SpiSpinelInterface (The Spi Spinel Interface needs a eventfd.)
    // The above will not exist at the same time.
    max_eventfd++;
#endif
#if CONFIG_OPENTHREAD_RADIO_TREL
    // * TREL reception (The Thread Radio Encapsulation Link needs a eventfd for reception.)
    max_eventfd++;
#endif
    esp_vfs_eventfd_config_t eventfd_config = {
        .max_fds = max_eventfd,
    };
    ESP_ERROR_CHECK(esp_vfs_eventfd_register(&eventfd_config));
    ESP_ERROR_CHECK(nvs_flash_init());
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    ESP_ERROR_CHECK(mdns_init());
    ESP_ERROR_CHECK(mdns_hostname_set(CONFIG_OTBR_HOSTNAME));
#if CONFIG_OPENTHREAD_SUPPORT_HW_RESET_RCP
    esp_openthread_register_rcp_failure_handler(rcp_failure_hardware_reset_handler);
    esp_openthread_set_coprocessor_reset_failure_callback(rcp_failure_hardware_reset_handler);
#endif

#if CONFIG_OPENTHREAD_CLI
    ot_console_start();
    ot_register_external_commands();
#if CONFIG_ESP_COEX_EXTERNAL_COEXIST_ENABLE
    register_cmd_extcoex();
#endif
#endif

#if CONFIG_ESP_COEX_EXTERNAL_COEXIST_ENABLE
    ot_external_coexist_init();
#endif

    static esp_openthread_config_t config = {
        .netif_config = ESP_NETIF_DEFAULT_OPENTHREAD(),
        .platform_config = {
            .radio_config = ESP_OPENTHREAD_DEFAULT_RADIO_CONFIG(),
            .host_config = ESP_OPENTHREAD_DEFAULT_HOST_CONFIG(),
            .port_config = ESP_OPENTHREAD_DEFAULT_PORT_CONFIG(),
        },
    };

    ESP_ERROR_CHECK(esp_openthread_start(&config));
#if CONFIG_OPENTHREAD_CLI_ESP_EXTENSION
    esp_cli_custom_command_init();
#endif
#if CONFIG_OPENTHREAD_STATE_INDICATOR_ENABLE
    ESP_ERROR_CHECK(esp_openthread_state_indicator_init(esp_openthread_get_instance()));
#endif
#if CONFIG_OPENTHREAD_BORDER_ROUTER && CONFIG_OPENTHREAD_NETWORK_AUTO_START
    ESP_ERROR_CHECK((xTaskCreate(ot_br_init_and_resume, "ot_br_init", 6144, NULL, 4, NULL) == pdPASS) ? ESP_OK
                                                                                                     : ESP_FAIL);
#if CONFIG_ESP_COEX_SW_COEXIST_ENABLE && CONFIG_SOC_IEEE802154_SUPPORTED
    ESP_ERROR_CHECK(esp_coex_wifi_i154_enable());
#endif
#endif
}
