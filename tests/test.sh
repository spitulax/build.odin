#!/usr/bin/env bash

# `odin test` is doing weird things so I made this script instead

max () {
    [ $1 -gt $2 ] && echo $1 || echo $2
}

[[ $2 = "-c" ]] && DONT_RUN=1
[[ $2 = "-f" ]] && FORCE=1
[[ $2 = "-cf" ]] && DONT_RUN=1 && FORCE=1

if [ $# -lt 1 ] || [ $1 = "all" ]; then
    TESTS=$(find tests -type f -name '*.odin' -execdir bash -c 'printf "%s\n" "${@%.*}"' bash {} +)
else
    TESTS=($1)
fi

cd `dirname $0`

[ ! -d ./bin ] && mkdir ./bin

LIB_FILES=$(find ../build.odin -type f -name '*.odin')
LIB_MODIFIED=0
for lib in ${LIB_FILES[@]}; do
    LIB_MODIFIED=$(max $LIB_MODIFIED $(stat --format='%Y' $lib))
done

for test in ${TESTS[@]}; do
    [ ! -r ${test}.odin ] && exit 1
    SRC_MODIFIED=$(stat --format='%Y' ./${test}.odin)
    [ -x ./bin/$test ] && BIN_MODIFIED=$(stat --format='%Y' ./bin/$test)
    if [[ ! -x ./bin/$test || $SRC_MODIFIED -gt $BIN_MODIFIED || $LIB_MODIFIED -gt $BIN_MODIFIED || $FORCE -eq 1 ]]; then
        printf "\033[1;38m"
        echo "Building ${test}..."
        printf "\033[0m"
        odin build ${test}.odin -file -out:./bin/$test -vet -disallow-do -warnings-as-errors -debug -target:linux_amd64
        [ $? -ne 0 ] && echo -e "\033[1;31mBuild failed.\033[0m" && exit 1
    fi
done

if [[ $DONT_RUN -ne 1 ]]; then
    for test in ${TESTS[@]}; do
        printf "\033[1;34m"
        echo "~~~~~~~~~~~~~~~~~~~~"
        echo "Running ${test}..."
        printf "\033[0m"
        ./bin/$test --track-alloc
        if [ $? -eq 0 ]; then
            printf "\033[1;32m"
            echo "$test passed"
            echo "~~~~~~~~~~~~~~~~~~~~"
            printf "\033[0m"
        else
            printf "\033[1;31m"
            echo "$test failed"
            echo "~~~~~~~~~~~~~~~~~~~~"
            printf "\033[0m"
        fi
    done
fi
