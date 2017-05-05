#!/usr/bin/env python
# Copyright 2016 The Dart project authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

import argparse
import multiprocessing
import os
import subprocess
import sys
import time
import utils

HOST_OS = utils.GuessOS()
HOST_ARCH = utils.GuessArchitecture()
SCRIPT_DIR = os.path.dirname(sys.argv[0])
DART_ROOT = os.path.realpath(os.path.join(SCRIPT_DIR, '..'))

# Environment variables for default settings.
DART_USE_ASAN = "DART_USE_ASAN"  # Use instead of --asan
DART_USE_MSAN = "DART_USE_MSAN"  # Use instead of --msan
DART_USE_TSAN = "DART_USE_TSAN"  # Use instead of --tsan
DART_USE_WHEEZY = "DART_USE_WHEEZY"  # Use instread of --wheezy
DART_USE_TOOLCHAIN = "DART_USE_TOOLCHAIN"  # Use instread of --toolchain-prefix
DART_USE_SYSROOT = "DART_USE_SYSROOT"  # Use instead of --target-sysroot

def use_asan():
  return DART_USE_ASAN in os.environ


def use_msan():
  return DART_USE_MSAN in os.environ


def use_tsan():
  return DART_USE_TSAN in os.environ


def use_wheezy():
  return DART_USE_WHEEZY in os.environ


def toolchain_prefix(args):
  if args.toolchain_prefix:
    return args.toolchain_prefix
  return os.environ.get(DART_USE_TOOLCHAIN)


def target_sysroot(args):
  if args.target_sysroot:
    return args.target_sysroot
  return os.environ.get(DART_USE_SYSROOT)


def get_out_dir(mode, arch, target_os):
  return utils.GetBuildRoot(HOST_OS, mode, arch, target_os)


def to_command_line(gn_args):
  def merge(key, value):
    if type(value) is bool:
      return '%s=%s' % (key, 'true' if value else 'false')
    return '%s="%s"' % (key, value)
  return [merge(x, y) for x, y in gn_args.iteritems()]


def host_cpu_for_arch(arch):
  if arch in ['ia32', 'arm', 'armv6', 'armv5te', 'mips',
              'simarm', 'simarmv6', 'simarmv5te', 'simmips', 'simdbc',
              'armsimdbc']:
    return 'x86'
  if arch in ['x64', 'arm64', 'simarm64', 'simdbc64', 'armsimdbc64']:
    return 'x64'


def target_cpu_for_arch(arch, target_os):
  if arch in ['ia32', 'simarm', 'simarmv6', 'simarmv5te', 'simmips']:
    return 'x86'
  if arch in ['simarm64']:
    return 'x64'
  if arch == 'mips':
    return 'mipsel'
  if arch == 'simdbc':
    return 'arm' if target_os == 'android' else 'x86'
  if arch == 'simdbc64':
    return 'arm64' if target_os == 'android' else 'x64'
  if arch == 'armsimdbc':
    return 'arm'
  if arch == 'armsimdbc64':
    return 'arm64'
  return arch


def host_os_for_gn(host_os):
  if host_os.startswith('macos'):
    return 'mac'
  if host_os.startswith('win'):
    return 'win'
  return host_os


# Where string_map is formatted as X1=Y1,X2=Y2 etc.
# If key is X1, returns Y1.
def parse_string_map(key, string_map):
  for m in string_map.split(','):
    l = m.split('=')
    if l[0] == key:
      return l[1]
  return None


def to_gn_args(args, mode, arch, target_os):
  gn_args = {}

  host_os = host_os_for_gn(HOST_OS)
  if target_os == 'host':
    gn_args['target_os'] = host_os
  else:
    gn_args['target_os'] = target_os

  gn_args['dart_target_arch'] = arch
  gn_args['target_cpu'] = target_cpu_for_arch(arch, target_os)
  gn_args['host_cpu'] = host_cpu_for_arch(arch)

  # See: runtime/observatory/BUILD.gn.
  # This allows the standalone build of the observatory to fall back on
  # dart_bootstrap if the prebuilt SDK doesn't work.
  gn_args['dart_host_pub_exe'] = ""

  # We only want the fallback root certs in the standalone VM on
  # Linux and Windows.
  if gn_args['target_os'] in ['linux', 'win']:
    gn_args['dart_use_fallback_root_certificates'] = True

  gn_args['dart_zlib_path'] = "//runtime/bin/zlib"

  # Use tcmalloc only when targeting Linux and when not using ASAN.
  gn_args['dart_use_tcmalloc'] = ((gn_args['target_os'] == 'linux')
                                  and not args.asan
                                  and not args.msan
                                  and not args.tsan)

  if gn_args['target_os'] == 'linux':
    if gn_args['target_cpu'] == 'arm':
      # Force -mfloat-abi=hard and -mfpu=neon for arm on Linux as we're
      # specifying a gnueabihf compiler in //build/toolchain/linux BUILD.gn.
      gn_args['arm_arch'] = 'armv7'
      gn_args['arm_float_abi'] = 'hard'
      gn_args['arm_use_neon'] = True
    elif gn_args['target_cpu'] == 'armv6':
      raise Exception("GN support for armv6 unimplemented")
    elif gn_args['target_cpu'] == 'armv5te':
      raise Exception("GN support for armv5te unimplemented")

  gn_args['is_debug'] = mode == 'debug'
  gn_args['is_release'] = mode == 'release'
  gn_args['is_product'] = mode == 'product'
  gn_args['dart_debug'] = mode == 'debug'

  # This setting is only meaningful for Flutter. Standalone builds of the VM
  # should leave this set to 'develop', which causes the build to defer to
  # 'is_debug', 'is_release' and 'is_product'.
  gn_args['dart_runtime_mode'] = 'develop'

  # TODO(zra): Investigate using clang with these configurations.
  # Clang compiles tcmalloc's inline assembly for ia32 on Linux wrong, so we
  # don't use clang in that configuration. Thus, we use gcc for ia32 *unless*
  # asan or tsan is specified.
  has_clang = (host_os != 'win'
               and args.os not in ['android']
               and not gn_args['target_cpu'].startswith('arm')
               and not gn_args['target_cpu'].startswith('mips')
               and not ((gn_args['target_os'] == 'linux')
                        and (gn_args['host_cpu'] == 'x86')
                        and not args.asan
                        and not args.msan
                        and not args.tsan))  # Use clang for sanitizer builds.
  gn_args['is_clang'] = args.clang and has_clang

  gn_args['is_asan'] = args.asan and gn_args['is_clang']
  gn_args['is_msan'] = args.msan and gn_args['is_clang']
  gn_args['is_tsan'] = args.tsan and gn_args['is_clang']

  # Setup the user-defined sysroot.
  if gn_args['target_os'] == 'linux' and args.wheezy:
    gn_args['dart_use_wheezy_sysroot'] = True
  else:
    sysroot = target_sysroot(args)
    if sysroot:
      gn_args['target_sysroot'] = parse_string_map(arch, sysroot)

    toolchain = toolchain_prefix(args)
    if toolchain:
      gn_args['toolchain_prefix'] = parse_string_map(arch, toolchain)

  goma_dir = os.environ.get('GOMA_DIR')
  goma_home_dir = os.path.join(os.getenv('HOME', ''), 'goma')
  if args.goma and goma_dir:
    gn_args['use_goma'] = True
    gn_args['goma_dir'] = goma_dir
  elif args.goma and os.path.exists(goma_home_dir):
    gn_args['use_goma'] = True
    gn_args['goma_dir'] = goma_home_dir
  else:
    gn_args['use_goma'] = False
    gn_args['goma_dir'] = None

  if args.debug_opt_level:
    gn_args['dart_debug_optimization_level'] = args.debug_opt_level
    gn_args['debug_optimization_level'] = args.debug_opt_level

  return gn_args


def process_os_option(os_name):
  if os_name == 'host':
    return HOST_OS
  return os_name


def process_options(args):
  if args.arch == 'all':
    args.arch = 'ia32,x64,simarm,simarm64,simmips,simdbc64'
  if args.mode == 'all':
    args.mode = 'debug,release,product'
  if args.os == 'all':
    args.os = 'host,android'
  args.mode = args.mode.split(',')
  args.arch = args.arch.split(',')
  args.os = args.os.split(',')
  for mode in args.mode:
    if not mode in ['debug', 'release', 'product']:
      print "Unknown mode %s" % mode
      return False
  for arch in args.arch:
    archs = ['ia32', 'x64', 'simarm', 'arm', 'simarmv6', 'armv6',
             'simarmv5te', 'armv5te', 'simmips', 'mips', 'simarm64', 'arm64',
             'simdbc', 'simdbc64', 'armsimdbc', 'armsimdbc64']
    if not arch in archs:
      print "Unknown arch %s" % arch
      return False
  oses = [process_os_option(os_name) for os_name in args.os]
  for os_name in oses:
    if not os_name in ['android', 'freebsd', 'linux', 'macos', 'win32']:
      print "Unknown os %s" % os_name
      return False
    if os_name != HOST_OS:
      if os_name != 'android':
        print "Unsupported target os %s" % os_name
        return False
      if not HOST_OS in ['linux']:
        print ("Cross-compilation to %s is not supported on host os %s."
               % (os_name, HOST_OS))
        return False
      if not arch in ['ia32', 'x64', 'arm', 'armv6', 'armv5te', 'arm64', 'mips',
                      'simdbc', 'simdbc64']:
        print ("Cross-compilation to %s is not supported for architecture %s."
               % (os_name, arch))
        return False
  return True


def os_has_ide(host_os):
  return host_os.startswith('win') or host_os.startswith('mac')


def ide_switch(host_os):
  if host_os.startswith('win'):
    return '--ide=vs'
  elif host_os.startswith('mac'):
    return '--ide=xcode'
  else:
    return '--ide=json'


def parse_args(args):
  args = args[1:]
  parser = argparse.ArgumentParser(
      description='A script to run `gn gen`.',
      formatter_class=argparse.ArgumentDefaultsHelpFormatter)
  common_group = parser.add_argument_group('Common Arguments')
  other_group = parser.add_argument_group('Other Arguments')

  common_group.add_argument('--arch', '-a',
      type=str,
      help='Target architectures (comma-separated).',
      metavar='[all,ia32,x64,simarm,arm,simarmv6,armv6,simarmv5te,armv5te,'
              'simmips,mips,simarm64,arm64,simdbc,armsimdbc]',
      default='x64')
  common_group.add_argument('--mode', '-m',
      type=str,
      help='Build variants (comma-separated).',
      metavar='[all,debug,release,product]',
      default='debug')
  common_group.add_argument('--os',
      type=str,
      help='Target OSs (comma-separated).',
      metavar='[all,host,android]',
      default='host')
  common_group.add_argument("-v", "--verbose",
      help='Verbose output.',
      default=False, action="store_true")

  other_group.add_argument('--asan',
      help='Build with ASAN',
      default=use_asan(),
      action='store_true')
  other_group.add_argument('--no-asan',
      help='Disable ASAN',
      dest='asan',
      action='store_false')
  other_group.add_argument('--clang',
      help='Use Clang',
      default=True,
      action='store_true')
  other_group.add_argument('--no-clang',
      help='Disable Clang',
      dest='clang',
      action='store_false')
  other_group.add_argument('--debug-opt-level',
      '-d',
      help='The optimization level to use for debug builds',
      type=str)
  other_group.add_argument('--goma',
      help='Use goma',
      default=True,
      action='store_true')
  other_group.add_argument('--no-goma',
      help='Disable goma',
      dest='goma',
      action='store_false')
  other_group.add_argument('--ide',
      help='Generate an IDE file.',
      default=os_has_ide(HOST_OS),
      action='store_true')
  other_group.add_argument('--msan',
      help='Build with MSAN',
      default=use_msan(),
      action='store_true')
  other_group.add_argument('--no-msan',
      help='Disable MSAN',
      dest='msan',
      action='store_false')
  other_group.add_argument('--target-sysroot', '-s',
      type=str,
      help='Comma-separated list of arch=/path/to/sysroot mappings')
  other_group.add_argument('--toolchain-prefix', '-t',
      type=str,
      help='Comma-separated list of arch=/path/to/toolchain-prefix mappings')
  other_group.add_argument('--tsan',
      help='Build with TSAN',
      default=use_tsan(),
      action='store_true')
  other_group.add_argument('--no-tsan',
      help='Disable TSAN',
      dest='tsan',
      action='store_false')
  other_group.add_argument('--wheezy',
      help='Use the Debian wheezy sysroot on Linux',
      default=use_wheezy(),
      action='store_true')
  other_group.add_argument('--no-wheezy',
      help='Disable the Debian wheezy sysroot on Linux',
      dest='wheezy',
      action='store_false')
  other_group.add_argument('--workers', '-w',
      type=int,
      help='Number of simultaneous GN invocations',
      dest='workers',
      # Set to multiprocessing.cpu_count() when GN can be run in parallel.
      default=1)

  options = parser.parse_args(args)
  if not process_options(options):
    parser.print_help()
    return None
  return options


def run_command(command):
  try:
    subprocess.check_output(
        command, cwd=DART_ROOT, stderr=subprocess.STDOUT)
    return 0
  except subprocess.CalledProcessError as e:
    return ("Command failed: " + ' '.join(command) + "\n" +
            "output: " + e.output)


def main(argv):
  starttime = time.time()
  args = parse_args(argv)

  if sys.platform.startswith(('cygwin', 'win')):
    subdir = 'win'
  elif sys.platform == 'darwin':
    subdir = 'mac'
  elif sys.platform.startswith('linux'):
     subdir = 'linux64'
  else:
    print 'Unknown platform: ' + sys.platform
    return 1

  commands = []
  for target_os in args.os:
    for mode in args.mode:
      for arch in args.arch:
        command = [
          '%s/buildtools/%s/gn' % (DART_ROOT, subdir),
          'gen',
          '--check'
        ]
        gn_args = to_command_line(to_gn_args(args, mode, arch, target_os))
        out_dir = get_out_dir(mode, arch, target_os)
        if args.verbose:
          print "gn gen --check in %s" % out_dir
        if args.ide:
          command.append(ide_switch(HOST_OS))
        command.append(out_dir)
        command.append('--args=%s' % ' '.join(gn_args))
        commands.append(command)

  pool = multiprocessing.Pool(args.workers)
  results = pool.map(run_command, commands, chunksize=1)
  for r in results:
    if r != 0:
      print r.strip()
      return 1

  endtime = time.time()
  if args.verbose:
    print ("GN Time: %.3f seconds" % (endtime - starttime))
  return 0


if __name__ == '__main__':
  sys.exit(main(sys.argv))
