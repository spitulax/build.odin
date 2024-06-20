#!/usr/bin/env bash

# `odin test` is doing weird things so I made this script instead

if [ $# -eq 0 ]; then
    TESTS=$(find tests -type f -name '*.odin' -execdir bash -c 'printf "%s\n" "${@%.*}"' bash {} +)
else
    TESTS=($1)
fi

cd `dirname $0`

[ ! -d ./bin ] && mkdir ./bin

for test in ${TESTS[@]}; do
    if [ ! -x ./bin/$test ] || [ $(stat --format='%Y' ./${test}.odin) -gt $(stat --format='%Y' ./bin/$test) ]; then
        odin build ${test}.odin -file -out:./bin/$test -vet -disallow-do -warnings-as-errors -debug
        [ $? -ne 0 ] && echo -e "\033[1;31mBuild failed.\033[0m" && exit 1
    fi
done

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
