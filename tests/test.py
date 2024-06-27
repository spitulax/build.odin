#!/usr/bin/env python3

import subprocess
import sys
import os

force: bool = False
dont_run: bool = False
tests: list[str] = []

def usage():
    print("test.py [test...] [option...]")
    print("Options:")
    print("    -h       Show this help")
    print("    -f       Force rebuild")
    print("    -c       Build only")

if __name__ == '__main__':
    prog_name, *args = sys.argv

    parse_ok = True
    while True:
        if len(args) <= 0:
            break
        arg, *args = args

        if arg.startswith('-'):
            if arg == '-h':
                usage()
                exit(1)
            elif arg == '-f':
                force = True
            elif arg == '-c':
                dont_run = True
            else:
                parse_ok = False
                break
        else:
            tests.append(arg)

    if not parse_ok:
        usage()
        exit(1)

    os.chdir(os.path.dirname(sys.argv[0]))

    if len(tests) == 0:
        tests = subprocess.run(['sh', '-c', 'find -type f -name \'*.odin\' -execdir bash -c \'printf "%s\n" "${@%.*}"\' bash {} +'], capture_output=True).stdout.decode('utf-8').splitlines()

    try:
        os.mkdir('./bin')
    except FileExistsError:
        pass

    lib_files = subprocess.run(['sh', '-c', 'find ../build_odin -type f -name \'*.odin\''], capture_output=True).stdout.decode('utf-8').splitlines()
    lib_modified = 0
    for lib in lib_files:
        proc = subprocess.run(['sh', '-c', f'stat --format="%Y" {lib}'], capture_output=True)
        lib_modified = max(lib_modified, int(proc.stdout))

    for test in tests:
        test_src = test + '.odin'
        test_bin = 'bin/' + test
        if not os.path.isfile(test_src):
            print(f'{test_src} does not exist in {os.getcwd()}')
            exit(1)
        src_modified = int(subprocess.run(['sh', '-c', f'stat --format="%Y" {test_src}'], capture_output=True).stdout)
        script_path = os.getcwd() + '/' + os.path.basename(sys.argv[0])
        script_modified = int(subprocess.run(['sh', '-c', f'stat --format="%Y" {script_path}'], capture_output=True).stdout)
        bin_modified = 0
        if os.path.isfile(test_bin):
            bin_modified = int(subprocess.run(['sh', '-c', f'stat --format="%Y" {test_bin}'], capture_output=True).stdout)
        if force or src_modified > bin_modified or lib_modified > bin_modified or script_modified > bin_modified:
            print('\033[1;38m', end='', flush=True)
            print(f'Building {test}...')
            print('\033[0m', end='', flush=True)
            if subprocess.run(['sh', '-c', f'odin build {test_src} -file -out:{test_bin} -vet -disallow-do -warnings-as-errors -debug -target:linux_amd64']).returncode != 0:
                print('\033[1;31m', end='', flush=True)
                print('Build failed.')
                print('\033[0m', end='', flush=True)
                exit(1)

    if not dont_run:
        print()
        for test in tests:
            test_bin = 'bin/' + test
            print('\033[1;34m', end='', flush=True)
            print('~~~~~~~~~~~~~~~~~~~~')
            print(f'Running {test}...')
            print('\033[0m', end='', flush=True)
            if subprocess.run(['sh', '-c', f'./{test_bin} --track-alloc']).returncode == 0:
                print('\033[1;32m', end='', flush=True)
                print(f'{test} passed')
                print('~~~~~~~~~~~~~~~~~~~~')
                print('\033[0m', end='', flush=True)
            else:
                print('\033[1;31m', end='', flush=True)
                print(f'{test} failed')
                print('~~~~~~~~~~~~~~~~~~~~')
                print('\033[0m', end='', flush=True)
            print()
