cmake_minimum_required(VERSION 3.12)

project(emacs-stdio-jsonrpc-newsticker)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

include_directories(include deps/emacs-stdio-jsonrpc/include)

# SQLite3 for feed_reader
find_package(PkgConfig)
if(PkgConfig_FOUND)
  pkg_check_modules(SQLITE3 sqlite3)
endif()

# Executable: SQLite feed reader for paged plainview
add_executable(feed_reader src/feed_reader.cpp)
if(SQLITE3_FOUND)
  target_include_directories(feed_reader PRIVATE ${SQLITE3_INCLUDE_DIRS})
  target_link_libraries(feed_reader PRIVATE ${SQLITE3_LIBRARIES})
else()
  target_link_libraries(feed_reader PRIVATE sqlite3)
endif()
