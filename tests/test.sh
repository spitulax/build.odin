#!/usr/bin/env bash

# `odin test` is doing weird things so I made this script instead

[[ $2 = "-c" ]] && DONT_RUN=1

if [ $# -lt 1 ] || [ $1 = "*" ]; then
    TESTS=$(find tests -type f -name '*.odin' -execdir bash -c 'printf "%s\n" "${@%.*}"' bash {} +)
else
    TESTS=($1)
fi

cd `dirname $0`

[ ! -d ./bin ] && mkdir ./bin

LIB_MODIFIED=$(stat --format='%Y' ../build.lib.odin)

for test in ${TESTS[@]}; do
    SRC_MODIFIED=$(stat --format='%Y' ./${test}.odin)
    [ -x ./bin/$test ] && BIN_MODIFIED=$(stat --format='%Y' ./bin/$test)
    if [ ! -x ./bin/$test ] || [ $SRC_MODIFIED -gt $BIN_MODIFIED ] || [ $LIB_MODIFIED -gt $BIN_MODIFIED ]; then
        odin build ${test}.odin -file -out:./bin/$test -vet -disallow-do -warnings-as-errors -debug
        [ $? -ne 0 ] && echo -e "\033[1;31mBuild failed.\033[0m" && exit 1
    fi
done

if [[ $DONT_RUN -ne 1 ]]; then
    for test in ${TESTS[@]}; do
        # echo -e "\033[1;38m====> ${test}\033[0m"
        ./bin/$test --track-alloc
        if [ $? -eq 0 ]; then
            printf "\033[1;32m"
            echo "::::::::::::::::::::"
            echo "$test passed"
            echo "::::::::::::::::::::"
            printf "\033[0m"
        else
            printf "\033[1;31m"
            echo "::::::::::::::::::::"
            echo "$test failed"
            echo "::::::::::::::::::::"
            printf "\033[0m"
        fi
    done
fi
