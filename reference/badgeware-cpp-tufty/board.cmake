# Tufty 2350 board target: board glue + the parallel ST7789 driver (PIO+DMA).
# Consumed by lib/CMakeLists.txt, which provides badge_support and picovector.
add_library(board STATIC
  ${CMAKE_CURRENT_LIST_DIR}/board.cpp
  ${CMAKE_CURRENT_LIST_DIR}/st7789.cpp
)
pico_generate_pio_header(board ${CMAKE_CURRENT_LIST_DIR}/st7789_parallel.pio)
target_include_directories(board PUBLIC ${CMAKE_CURRENT_LIST_DIR})
target_link_libraries(board PUBLIC
  badge_support picovector
  pico_stdlib hardware_pio hardware_dma hardware_pwm hardware_gpio hardware_clocks
)
