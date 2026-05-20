cmake_minimum_required(VERSION 3.12)

project(emacs-stdio-jsonrpc-newsticker)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

include_directories(include deps/emacs-stdio-jsonrpc/include)

# libxml2 for feed parsing
find_package(PkgConfig REQUIRED)
pkg_check_modules(LIBXML2 REQUIRED libxml-2.0)

# SQLite3 for feed_reader
pkg_check_modules(SQLITE3 sqlite3)

# Static library: RSS/Atom feed parser
add_library(feed_parser STATIC src/feed_parser.cpp)
target_include_directories(feed_parser PUBLIC include ${LIBXML2_INCLUDE_DIRS})
target_link_libraries(feed_parser PUBLIC ${LIBXML2_LIBRARIES})

# Executable: JSON-RPC feed processing server
add_executable(feed_processor src/feed_processor.cpp)
target_link_libraries(feed_processor PRIVATE feed_parser)

# Executable: SQLite feed reader for paged plainview
add_executable(feed_reader src/feed_reader.cpp)
if(SQLITE3_FOUND)
  target_include_directories(feed_reader PRIVATE ${SQLITE3_INCLUDE_DIRS})
  target_link_libraries(feed_reader PRIVATE ${SQLITE3_LIBRARIES})
else()
  target_link_libraries(feed_reader PRIVATE sqlite3)
endif()

# --- Tests ---
add_executable(feed_parser_test test/feed_parser_test.cpp)
target_link_libraries(feed_parser_test PRIVATE feed_parser)

add_executable(feed_processor_test test/feed_processor_test.cpp)
target_link_libraries(feed_processor_test PRIVATE feed_parser)
target_compile_definitions(feed_processor_test PRIVATE
    FEED_PROCESSOR_PATH="${CMAKE_BINARY_DIR}/feed_processor")
