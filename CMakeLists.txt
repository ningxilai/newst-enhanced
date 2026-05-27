cmake_minimum_required(VERSION 3.12)

project(emacs-stdio-jsonrpc-newsticker)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

include_directories(deps/emacs-stdio-jsonrpc/include)

# SQLite3 for pager
find_package(PkgConfig)
if(PkgConfig_FOUND)
  pkg_check_modules(SQLITE3 sqlite3)
endif()

# Executable: SQLite pager for paged plainview
add_executable(pager src/pager.cpp src/db.cpp src/utf8.cpp)
if(SQLITE3_FOUND)
  target_include_directories(pager PRIVATE ${SQLITE3_INCLUDE_DIRS})
  target_link_libraries(pager PRIVATE ${SQLITE3_LIBRARIES})
else()
  target_link_libraries(pager PRIVATE sqlite3)
endif()
