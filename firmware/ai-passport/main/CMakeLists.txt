idf_component_register(
    SRCS "companion_app.c" "companion_model.c" "companion_presenter.c" "companion_ble.c" "companion_ui.c" "companion_voice.c" "companion_cue.c" "companion_pet_store.c" "companion_pet.c"
         "../assets/fonts/cp_font16.c" "../assets/fonts/cp_font20.c" "../assets/fonts/cp_digits58.c"
    INCLUDE_DIRS "."
    REQUIRES bsp bt esp_event esp_hw_support esp_timer nvs_flash json esp_partition mbedtls
)
foreach(phrase result question approval blocked test usage_low usage_reset)
    target_add_binary_data(${COMPONENT_LIB}
        "${CMAKE_CURRENT_LIST_DIR}/../assets/music/codex/${phrase}.pcm" BINARY
        RENAME_TO "pcm_${phrase}")
endforeach()

target_add_binary_data(${COMPONENT_LIB}
    "${CMAKE_CURRENT_LIST_DIR}/../assets/pets/nomi/frames-rgb565.bin" BINARY RENAME_TO "pet_frames")
