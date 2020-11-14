option(DBUS_USE_WINE "set to 1 or ON to support running test cases with Wine" OFF)

if(DBUS_BUILD_TESTS AND CMAKE_CROSSCOMPILING AND CMAKE_SYSTEM_NAME STREQUAL "Windows")
    if(CMAKE_HOST_SYSTEM_NAME STREQUAL "Linux")
        find_file(WINE_EXECUTABLE
            NAMES wine
            PATHS /usr/bin /usr/local/bin
            NO_CMAKE_FIND_ROOT_PATH
        )
        find_file(BINFMT_WINE_SUPPORT_FILE
            NAMES DOSWin wine Wine windows Windows
            PATHS /proc/sys/fs/binfmt_misc
            NO_SYSTEM_PATH NO_CMAKE_FIND_ROOT_PATH
        )
        if(EXISTS BINFMT_WINE_SUPPORT_FILE)
            file(READ ${BINFMT_WINE_SUPPORT_FILE} CONTENT)
            if(${CONTENT} MATCHES "enabled")
                set(HAVE_BINFMT_WINE_SUPPORT 1)
            endif()
        endif()
        if(WINE_EXECUTABLE)
            list(APPEND FOOTNOTES "NOTE: The requirements to run cross compiled applications on your host system are achieved. You may run 'make check'.")
        endif()
        if(NOT WINE_EXECUTABLE)
            list(APPEND FOOTNOTES "NOTE: You may install the Windows emulator 'wine' to be able to run cross compiled test applications.")
        endif()
        if(NOT HAVE_BINFMT_WINE_SUPPORT)
            list(APPEND FOOTNOTES "NOTE: You may activate binfmt_misc support for wine to be able to run cross compiled test applications directly.")
        endif()
    else()
        list(APPEND FOOTNOTES "NOTE: You will not be able to run cross compiled applications on your host system.")
    endif()

    # setup z drive required by wine
    set(Z_DRIVE_IF_WINE "z:")
    if(DBUS_USE_WINE AND WINE_EXECUTABLE)
        set(TEST_WRAPPER "${WINE_EXECUTABLE}")
    endif()
endif()

#
# add dbus specific test
#
# @param _name test name
# @param _target cmake target to use with this test
# @param ARGS <args> additional arguments added to the test command in front of the target file
# @param ENV <env> additional environment variables to provide to the running test
#
macro(add_unit_test _name _target)
    set(options)
    set(oneValueArgs)
    set(multiValueArgs ARGS ENV)
    cmake_parse_arguments(_ "${options}" "${oneValueArgs}" "${multiValueArgs}" ${ARGN})
    add_test(
        NAME ${_name}
        COMMAND ${TEST_WRAPPER} ${__ARGS} ${Z_DRIVE_IF_WINE}$<TARGET_FILE:${_target}> --tap
        WORKING_DIRECTORY ${DBUS_TEST_WORKING_DIR}
    )
    set(_env)
    list(APPEND _env "DBUS_SESSION_BUS_ADDRESS=")
    list(APPEND _env "DBUS_FATAL_WARNINGS=1")
    list(APPEND _env "DBUS_TEST_DAEMON=${DBUS_TEST_DAEMON}")
    list(APPEND _env "DBUS_TEST_DATA=${DBUS_TEST_DATA}")
    list(APPEND _env "DBUS_TEST_DBUS_LAUNCH=${DBUS_TEST_DBUS_LAUNCH}")
    list(APPEND _env "DBUS_TEST_EXEC=${DBUS_TEST_EXEC}")
    list(APPEND _env "DBUS_TEST_HOMEDIR=${DBUS_TEST_HOMEDIR}")
    list(APPEND _env "DBUS_TEST_UNINSTALLED=1")
    list(APPEND _env ${__ENV})
    set_tests_properties(${_name} PROPERTIES ENVIRONMENT "${_env}")
endmacro()

#
# create executable and add an associated unit test
#
# see @ref add_helper_executable for supported parameters
#
macro(add_test_executable _target _source)
    add_helper_executable(${_target} "${_source}" ${ARGN})
    add_unit_test(${_target} ${_target})
endmacro()

#
# create an executable
#
# The executable file is named _target and is created
# from the list of files provided with _source.
# Other optional parameters assume that it is a
# library to which this executable is linked.
#
# On Windows, a manifest is added to the executable
# file to avoid triggering user access control (uac).
#
# @param _target target name
# @param _source sources to add to this target
#
macro(add_helper_executable _target _source)
    set(_sources "${_source}")
    if(WIN32 AND NOT MSVC)
        # avoid triggering UAC
        add_uac_manifest(_sources)
    endif()
    add_executable(${_target} ${_sources})
    target_link_libraries(${_target} ${ARGN})
endmacro()

#
# create executable and add an associated unit test with dbus session setup
#
# see @ref add_helper_executable for supported parameters
#
macro(add_session_test_executable _target _source)
    add_helper_executable(${_target} "${_source}" ${ARGN})
    add_unit_test(${_target} ${_target}
        ARGS
            ${DBUS_TEST_RUN_SESSION}
            --config-file=${DBUS_TEST_DATA}/valid-config-files/tmp-session.conf
            --dbus-daemon=${DBUS_TEST_DAEMON}
        ENV
            "DBUS_SESSION_BUS_PID="
    )
endmacro()

#
# generate compiler flags from MSVC warning identifiers (e.g. '4114') or gcc warning keys (e.g. 'pointer-sign')
#
# @param target the variable name which will contain the warnings flags
# @param warnings a string with space delimited warnings
# @param disabled_warnings a string with space delimited disabled warnings
# @param error_warnings a string with space delimited warnings which should result into compile errors
#
macro(generate_warning_cflags target warnings disabled_warnings error_warnings)
    if(DEBUG_MACROS)
        message("generate_warning_cflags got: ${warnings} - ${disabled_warnings} - ${error_warnings}")
    endif()
    if(MSVC)
        # level 1 is default
        set(enabled_prefix "/w1")
        set(error_prefix "/we")
        set(disabled_prefix "/wd")
    else()
        set(enabled_prefix "-W")
        set(error_prefix "-Werror=")
        set(disabled_prefix "-Wno-")
    endif()

    set(temp)
    string(REPLACE " " ";" warnings_list "${warnings}")
    foreach(warning ${warnings_list})
        string(STRIP ${warning} _warning)
        if(_warning)
            set(temp "${temp} ${enabled_prefix}${_warning}")
        endif()
    endforeach()

    string(REPLACE " " ";" disabled_warnings_list "${disabled_warnings}")
    foreach(warning ${disabled_warnings_list})
        string(STRIP ${warning} _warning)
        if(_warning)
            set(temp "${temp} ${disabled_prefix}${_warning}")
        endif()
    endforeach()

    string(REPLACE " " ";" error_warnings_list "${error_warnings}")
    foreach(warning ${error_warnings_list})
        string(STRIP ${warning} _warning)
        if(_warning)
            set(temp "${temp} ${error_prefix}${_warning}")
        endif()
    endforeach()
    set(${target} "${temp}")
    if(DEBUG_MACROS)
        message("generate_warning_cflags return: ${${target}}")
    endif()
endmacro()

#
# Avoid triggering UAC
#
# This macro adds an rc file to _sources that is
# linked to a target and prevents UAC from making
# requests for administrator access.
#
macro(add_uac_manifest _sources)
    # 1 is the resource ID, ID_MANIFEST
    # 24 is the resource type, RT_MANIFEST
    # constants are used because of a bug in windres
    # see https://stackoverflow.com/questions/33000158/embed-manifest-file-to-require-administrator-execution-level-with-mingw32
    get_filename_component(UAC_FILE ${CMAKE_SOURCE_DIR}/tools/Win32.Manifest REALPATH)
    set(outfile ${CMAKE_BINARY_DIR}/disable-uac.rc)
    if(NOT EXISTS outfile)
        file(WRITE ${outfile} "1 24 \"${UAC_FILE}\"\n")
    endif()
    list(APPEND ${_sources} ${outfile})
endmacro()

macro(add_executable_version_info _sources _name)
    set(DBUS_VER_INTERNAL_NAME "${_name}")
    set(DBUS_VER_ORIGINAL_NAME "${DBUS_VER_INTERNAL_NAME}${CMAKE_EXECUTABLE_SUFFIX}")
    set(DBUS_VER_FILE_TYPE "VFT_APP")
    configure_file(${CMAKE_SOURCE_DIR}/dbus/versioninfo.rc.in ${CMAKE_CURRENT_BINARY_DIR}/versioninfo-${DBUS_VER_INTERNAL_NAME}.rc)
    # version info and uac manifest can be combined in a binary because they use different resource types
    list(APPEND ${_sources} ${CMAKE_CURRENT_BINARY_DIR}/versioninfo-${DBUS_VER_INTERNAL_NAME}.rc)
endmacro()

macro(add_library_version_info _sources _name)
    set(DBUS_VER_INTERNAL_NAME "${_name}")
    set(DBUS_VER_ORIGINAL_NAME "${DBUS_VER_INTERNAL_NAME}${CMAKE_SHARED_LIBRARY_SUFFIX}")
    set(DBUS_VER_FILE_TYPE "VFT_DLL")
    configure_file(${CMAKE_SOURCE_DIR}/dbus/versioninfo.rc.in ${CMAKE_CURRENT_BINARY_DIR}/versioninfo-${DBUS_VER_INTERNAL_NAME}.rc)
    # version info and uac manifest can be combined in a binary because they use different resource types
    list(APPEND ${_sources} ${CMAKE_CURRENT_BINARY_DIR}/versioninfo-${DBUS_VER_INTERNAL_NAME}.rc)
endmacro()

#
# provide option with three states AUTO, ON, OFF
#
macro(add_auto_option _name _text _default)
    if(NOT DEFINED ${_name})
        set(${_name} ${_default} CACHE STRING "${_text}" FORCE)
    else()
        set(${_name} ${_default} CACHE STRING "${_text}")
    endif()
    set_property(CACHE ${_name} PROPERTY STRINGS AUTO ON OFF)
endmacro()


#
# Ensure that if a tristate ON/OFF/AUTO feature is set to ON,
# its requirements have been met. Fail with a fatal error if not.
#
# _name: name of a variable ENABLE_FOO representing a tristate ON/OFF/AUTO feature
# _text: human-readable description of the feature enabled by _name, for the
#        error message
# _var: name of a variable representing a system property we checked for,
#       such as an executable that must exist for the feature enabled by _name to work
# _vartext: what we checked for, for the error message
#
macro(check_auto_option _name _text _var _vartext)
    set(_nameval ${${_name}})
    set(_varval ${${_var}})
    #message("debug: _name ${_name} ${_nameval}  _var ${_var} ${_varval}")
    if(${_nameval} AND NOT ${_nameval} STREQUAL "AUTO" AND NOT ${_varval})
        message(FATAL_ERROR "${_text} requested but ${_vartext} not found")
    endif()
endmacro()

#
# Provide option that takes a path
#
macro(add_path_option _name _text _default)
    if(NOT DEFINED ${_name})
        set(${_name} ${_default} CACHE STRING "${_text}" FORCE)
    else()
        set(${_name} ${_default} CACHE STRING "${_text}")
    endif()
endmacro()

#
# create directory on install
#
macro(install_dir filepath)
    install(CODE "
    set(_path \"\$ENV{DESTDIR}\${CMAKE_INSTALL_PREFIX}/${filepath}\")
    if(NOT EXISTS \"\${_path}\")
        execute_process(COMMAND ${CMAKE_COMMAND} -E make_directory \"\${_path}\")
        message(\"-- Creating directory: \${_path}\")
    else()
        message(\"-- Up-to-date: \${_path}\")
    endif()
    ")
endmacro()

#
# create symlink on install
#
macro(install_symlink filepath sympath)
    install(CODE "
    set(_sympath \"\$ENV{DESTDIR}\${CMAKE_INSTALL_PREFIX}/${sympath}\")
    file(REMOVE \"\${_sympath}\")
    execute_process(COMMAND ${CMAKE_COMMAND} -E create_symlink \"${filepath}\" \"\${_sympath}\" RESULT_VARIABLE result)
    if(NOT result)
        message(\"-- Creating symlink: \${_sympath} -> ${filepath}\")
    else()
        message(FATAL ERROR \"-- Failed to create symlink: \${_sympath} -> ${filepath}\")
    endif()
    ")
endmacro()

#
# add system service <file> PATH <install path> LINKS [multi-user.target.wants [...]]
#
macro(add_systemd_service file)
    set(options)
    set(oneValueArgs PATH)
    set(multiValueArgs LINKS)
    cmake_parse_arguments(_ "${options}" "${oneValueArgs}" "${multiValueArgs}" ${ARGN})
    set(_targetdir ${__PATH})
    install(FILES ${file} DESTINATION ${_targetdir})
    get_filename_component(_name ${file} NAME)
    foreach(l ${__LINKS})
        set(_linkdir ${_targetdir}/${l})
        install_dir(${_linkdir})
        install_symlink(../${_name} ${_linkdir}/${_name})
    endforeach()
endmacro()
