#!/usr/bin/perl
#
# 20211204,20211209 larry
#
# build script for ROCm architecture
#
# based on build-shell scripts for
# https://github.com/xuhuisheng/rocm-build

# possible debugging:
# * consider give cmake defines for llvm
#   -DLLVM_DEFINITIONS=
#   -DLLVM_INCLUDE_DIR=
#   -DLLVM_CONFIG_INCLUDE_DIR=
#   -DLLVM_MAIN_INCLUDE_DIR=

# Is my card supported by my kernel?
# The linux kernel contains the amdgpu module, which
# will possibly load some firmware, and contains
# support for the ROCM software platform.
# Se file https://github.com/torvalds/linux/blob/master/drivers/gpu/drm/amd/amdgpu/amdgpu_drv.c
# and run "lspci -n" to see your device id for your amd-vga card.

# The firmware packaged by debian contains a firmware for each card
# and is named by the chip-codename, (eg polaris etc).
# Find out your chip codename (eg navi22 is named navy-flounder), and
# ensure it is listed in the firmware-amd-graphics package.
# se https://debian.pkgs.org/sid/debian-nonfree-amd64/firmware-amd-graphics_20210818-1_all.deb.html
# run "dpkg -l firmware-amd-graphics" to see if the debian amd firmware package is installed
# run "dpkg -L firmware-amd-graphics" to see its content
# and run "apt show firmware-amd-graphics" to see the package metadata which is helpful to find your card

# after ensuring kernel and firmware are up-to-date, check if amdgpu is loading the firmware for your card:
# /sbin/modinfo -k `uname -r` amdgpu | less

# amdgpu architecture mismatch between device and compiled object code:
# if you have utilized the hipcc compiler, it will generate GPU-arch specific
#  code, like gfx1030, and if your card is of an other architecture, you
# will se the error:
# hip_code_object.cpp:486: "hipErrorNoBinaryForGpu: Unable to find code object for all current devices!"
# to find out the architecture in your object file, inspect the ELF-e_flags in the elf-header.
# to see how HIP resolves this, see the function getProcName in HIP/rocclr/hip_code_object.cpp

# gfx1030 and gfx1031 has the same ISA, and can share code:
# To use gfx1030 code on the gfx1031 hardware (RX 6700 XT):
# export HSA_OVERRIDE_GFX_VERSION=10.3.0

use strict;
use warnings;
use Cwd;

##############################################################################
### *** YOU MUST configure these: ***
my $ROCM_GIT_DIR = "/d/rocm-src-5"; # Where you have all ROCm git repositories
my $ROCM_INSTALL_DIR = "/d/rocm5"; # Where you want ROCm to be installed

# amd technology list, of pairs: graphicsArchitecture-gpuCodename-computeArchitecture
# (gfx803-polaris21-gcn4 gfx900-vega10-gcn5 gfx906-vega20-gcn5 gfx1010-navi10-rdna1 gfx1030-navi21-rdna2 gfx1031-navi22-rdna2 gfx1032-navi23-rdna2)
# se https://wiki.gentoo.org/wiki/AMDGPU
my $AMDGPU_TARGETS = "gfx1031";
##############################################################################

### Optional configure
my $dry_run = 0; # dont run any commands, just compile an output bash script
my $verbose = 1; # be more verbose
my $makethreads = 8; # make -j
my $apply_patches = 1; # apply patches in patches/ directory to the ROCm git repos before compiling

my $rocm_src_dir = "..";
my $rocclr_pkg = "$ROCM_GIT_DIR/ROCclr/build";
my $OPENCL_DIR = "$ROCM_GIT_DIR/ROCm-OpenCL-Runtime";
my $HIP_DIR = "$ROCM_GIT_DIR/HIP";
my $ROCCLR_DIR = "$ROCM_GIT_DIR/ROCclr";
my $gittag = "rocm-5.3.3";
# cmake defines
#my $hip_compiler  = " -DHIP_COMPILER=clang";
my $hip_compiler  = " -DHIP_COMPILER=hipcc";
my $hip_platform  = " -DHIP_PLATFORM=amd";
my $rocm_path     = " -DROCM_PATH=$ROCM_INSTALL_DIR";
my $hsa_path      = " -DHSA_PATH=$ROCM_INSTALL_DIR";
my $d_opencl_dir    = " -DOPENCL_DIR=$OPENCL_DIR";
my $hip_clang_inc = " -DHIP_CLANG_INCLUDE_PATH=$ROCM_INSTALL_DIR/llvm/include";
my $install_dir   = " -DCMAKE_INSTALL_PREFIX=$ROCM_INSTALL_DIR";

# environemnt

# needed by rocBLAS (hipvars.pm uses HIP_PATH)
$ENV{ROCM_PATH} = $ROCM_INSTALL_DIR;
$ENV{LD_LIBRARY_PATH} = "$ROCM_INSTALL_DIR/lib";
#$ENV{TENSILE_ROCM_ASSEMBLER_PATH} = "$ROCM_INSTALL_DIR/bin/llvm-as";
$ENV{AMDGPU_TARGETS} = $AMDGPU_TARGETS;
$ENV{PATH} = "$ROCM_INSTALL_DIR/bin:$ROCM_INSTALL_DIR/llvm/bin:$ENV{PATH}";

# read command line

my $build_continue = 0;
foreach my $arg (@ARGV) {
  $apply_patches = 0  if($arg eq "-p");
  $build_continue = 1 if($arg eq "-m");
}

########################################
# configuration for each ROCM repository
# Contains build information, provision
########################################
my %conf = (
  ###################################
  #  "cmake \
  #    -G Ninja \
  #    $ROCM_GIT_DIR/llvm-project/llvm
  "llvm-project" =>
  { order => 1,
    gitrepo => "https://github.com/RadeonOpenCompute/llvm-project.git",
    installdir => "/llvm", # relative to (on-top-of) ${ROCM_INSTALL_DIR}
    misc => "-DCMAKE_BUILD_TYPE=Release -DLLVM_ENABLE_ASSERTIONS=1 -DLLVM_TARGETS_TO_BUILD=\"AMDGPU;X86\" -DLLVM_ENABLE_PROJECTS=\"compiler-rt;lld;clang\"",
    srcdir => "llvm",
    compiler => "use-system"
  },
  ###################################
  # ROCT-Thunk-Interface
  # The thunk interface talks to the
  # ROCk driver.
  # And the rock-driver is the kernel parts
  #   amdgpu, amdkfd, amdkcl (git upstream https://github.com/RadeonOpenCompute/ROCK-Kernel-Driver)
  "ROCT-Thunk-Interface" =>
  { order => 2,
    gitrepo => "https://github.com/RadeonOpenCompute/ROCT-Thunk-Interface.git"
  },
  ###################################
  "rocm-cmake" =>
  { order => 3,
    gitrepo => "https://github.com/RadeonOpenCompute/rocm-cmake.git"
  },
  ###################################
  "ROCm-Device-Libs" =>
  { order => 4,
    cmake_defines => ["ROCM_PATH=$ROCM_INSTALL_DIR",
                      #"LLVM_INCLUDE_DIRS=$ROCM_INSTALL_DIR/llvm/include",
                      # ${CLANG_INCLUDE_DIRS}
                      # ${LLD_INCLUDE_DIRS}
                     ],
    misc => $hip_clang_inc,
    pkgprefix => "$ROCM_INSTALL_DIR/llvm",
    gitrepo => "https://github.com/RadeonOpenCompute/ROCm-Device-Libs.git"
  },
  ###################################
  # ROCR-Runtime needs hsakmt.h which is provided by the thunk.
  "ROCR-Runtime" =>
  { order => 5,
    gitrepo => "https://github.com/RadeonOpenCompute/ROCR-Runtime.git",
    compiler => "use-system", # if using clang: error: unknown warning option '-Werror=unused-but-set-variable'
    depends => "ROCT-Thunk-Interface",
    needs => ["deb:libelf-dev"],
    provides => ["libhsa-runtime64.so"],
    srcdir => "src"
  },
  ###################################
  "rocminfo" =>
  { order => 6,
    gitrepo => "https://github.com/RadeonOpenCompute/rocminfo.git"
  },
  ###################################
  "ROCm-CompilerSupport" =>
  { order => 7,
    gitrepo => "https://github.com/RadeonOpenCompute/ROCm-CompilerSupport.git",
    cmake_defines => ["LLVM_INCLUDE_DIRS=$ROCM_INSTALL_DIR/llvm/include",
                      "LLVM_INSTALL_PREFIX=$ROCM_INSTALL_DIR/llvm",
                      # ${CLANG_INCLUDE_DIRS}
                      # ${LLD_INCLUDE_DIRS}
                     ],
    funcs => "$d_opencl_dir $hip_clang_inc",
    srcdir => "lib/comgr",
    pkgprefix => "$ROCM_INSTALL_DIR/llvm",
    misc => $hip_clang_inc,
  },
#  ###################################
#  # Needs amd_comgr.h provided by ROCm-CompilerSupport/build/include/amd_comgr.h
#  "ROCclr" =>
#  { order => 8,
#    gitrepo => "https://github.com/ROCm-Developer-Tools/ROCclr.git",
#    funcs => $d_opencl_dir,
#  },
  ###################################
  # HIP needs platform/runtime.hpp provided by ROCclr/platform/runtime.hpp
  #"HIP" =>
  "hipamd" =>
  { order => 9,
    gitrepo => "https://github.com/ROCm-Developer-Tools/hipamd.git",
    deprepos => ["https://github.com/ROCm-Developer-Tools/HIP.git",
                 "https://github.com/ROCm-Developer-Tools/ROCclr.git",
                 "https://github.com/RadeonOpenCompute/ROCm-OpenCL-Runtime.git"],
    flags => $hip_compiler . $hip_platform . $hsa_path . $rocm_path,
    funcs => $d_opencl_dir . $hip_clang_inc,
    pkgprefix => $rocclr_pkg,
    misc => "-DHIP_COMMON_DIR=\"$HIP_DIR\" -DAMD_OPENCL_PATH=\"$OPENCL_DIR\" -DROCCLR_PATH=\"$ROCCLR_DIR\""
  },
  ###################################
  # CXX=$ROCM_INSTALL_DIR/hip/bin/hipcc cmake \
  #  -DAMDGPU_TARGETS=$AMDGPU_TARGETS \
  #  -DCMAKE_BUILD_TYPE=Release \
  #  -DCPACK_SET_DESTDIR=OFF \
  #  -DCPACK_PACKAGING_INSTALL_PREFIX=$ROCM_INSTALL_DIR \
  #  -DCMAKE_INSTALL_PREFIX=hipsparse-install \
  #  -G Ninja \
  #  $ROCM_GIT_DIR/rocFFT
  "rocFFT" =>
  { order => 10,
    gitrepo => "https://github.com/ROCmSoftwarePlatform/rocFFT.git",
    #gitbranch => "remotes/origin/release/rocm-rel-5.3",
    cmake_defines => ["AMDGPU_TARGETS=\"$AMDGPU_TARGETS\"", "USE_HIP_CLANG=ON", "HIP_COMPILER=clang"]
  },
  ###################################
  # Prerequisite, check if gfortran is installed (f95 is on path)?
  "rocBLAS" =>
  { order => 11,
    gitrepo => "https://github.com/ROCmSoftwarePlatform/rocBLAS.git",
    #flags => "-lpthread",
    cmake_defines => ["AMDGPU_TARGETS=\"$AMDGPU_TARGETS\"",
                      "ROCM_PATH=$ROCM_INSTALL_DIR",
                      "LLVM_INCLUDE_DIRS=$ROCM_INSTALL_DIR/llvm/include",
                      "LLVM_INSTALL_PREFIX=$ROCM_INSTALL_DIR/llvm",
                      "USE_HIP_CLANG=ON", "HIP_COMPILER=clang",
                      "Tensile_LOGIC=asm_full",
                      "Tensile_ARCHITECTURE=$AMDGPU_TARGETS",
                      "Tensile_CODE_OBJECT_VERSION=V3",
                      "Tensile_LIBRARY_FORMAT=yaml",
                      "RUN_HEADER_TESTING=OFF",
                      "Tensile_COMPILER=hipcc"],
    pkgprefix => "$ROCM_INSTALL_DIR/llvm",
    # if gfx803 is requested, remove asm, and build from source
    patch => ["run" => "rm -rf library/src/blas3/Tensile/Logic/asm_full/r9nano*"]
  },
  ###################################
  "rocRAND" =>
  { order => 12,
    flags => $hip_compiler . $hip_platform . $hsa_path . $rocm_path
  },
  "clang-ocl" =>
  { order => 13,
    flags => $hip_compiler . $hip_platform . $hsa_path . $rocm_path
  },
  # needs clang-ocl
  "MIOpen" =>
  { order => 14,
    flags => $hip_compiler . $hip_platform . $hsa_path . $rocm_path
  },

#  ###################################
#  # libhsa-runtime64.so is provided by ROCm-OpenCL-Runtime
#  # Needs top.hpp which is provided by ./ROCclr/include/top.hpp
#  "ROCm-OpenCL-Runtime" =>
#  { order => 18,
#    gitrepo => "https://github.com/RadeonOpenCompute/ROCm-OpenCL-Runtime.git",
#    misc => "-DUSE_COMGR_LIBRARY=ON -Dhsa-runtime64_DIR=$ROCM_INSTALL_DIR/lib/cmake/hsa-runtime64 -DROCclr_DIR=$ROCM_INSTALL_DIR",
#    pkgprefix => "$ROCM_GIT_DIR/ROCm-OpenCL-Runtime/rocclr"
#  },
  ###################################
  "roctracer" =>
  { order => 20,
    cmake_defines => ["HIP_VDI=1",
                      "HIP_API_STRING=1",
                      "HIP_PATH=$ROCM_INSTALL_DIR",
                      "HSA_RUNTIME_INC=$ROCM_INSTALL_DIR/include"
                     ]
  },
  ###################################
  "rocm_smi_lib" =>
  { order => 22,
  },
  ###################################
  "rocprofiler" =>
  { order => 25,
  },
  _ => {order => 0} # dummy
);

########################################
print "Applying patches..\n";

if($apply_patches){
  foreach my $patchfile (`ls patches/*.diff`) {
    chomp $patchfile;
    my ($targetdir) = ($patchfile =~ /^patches\/(.*)\.diff/);
    print "applying patch $patchfile to targetdir $targetdir\n";
    dir_push("../$targetdir");
    system("patch -p1 --dry-run < ../tools/$patchfile");
    if ($? != 0){
      mydie("Failed to apply patch $patchfile");
    }
    system("patch -p1 < ../tools/$patchfile");
    dir_pop();
  }
}

########################################

{
  my $flags = "";
  my @reponames = sort { $conf{$a}->{order} <=> $conf{$b}->{order} } keys %conf;

  for my $reponame (@reponames) {
    my $order = $conf{$reponame}->{order};
    print "$order) $reponame\n";
  }
  my $what; # = shift;
  if(!defined($what)){
    $what = <STDIN>;
  }
  chomp $what;
  for my $reponame (@reponames) {
    my $order = $conf{$reponame}->{order};
    if($what eq $order){
      $what = $reponame;
      last;
    }
  }
  maybe_git_clone("dir", $what, %{$conf{$what}});
  print "Building $what.\n" if($verbose);
  build_system("dir", $what, %{$conf{$what}});
}
    
###########################################################

sub maybe_git_clone {
  my %h = @_;
  my $dir = $h{dir};
  my $gitrepo = $h{gitrepo} || 0;
  return if (-d "../$dir");
  mydie("No git repo for $dir\n") if (! $gitrepo);
  dir_push("..");
  my $deprepos = $h{deprepos} || ();
  if ($#$deprepos >= 0) {
    gitcheckout_repos(@$deprepos);
  }
  git_clone_repo($gitrepo);
  dir_pop();
  printgreen("Successfully cloned $dir\n");
}

sub gitcheckout_repos {
  my @deprepos = @_;
  foreach my $repo (@deprepos) {
    git_clone_repo($repo);
  }
}

sub git_clone_repo {
  my($url) = @_;
  system("git clone $url --branch $gittag --single-branch");
  mydie("Failed to clone repo $url") if($? != 0);
}

sub build_system {
  my %h = @_;
  my $dir = $h{dir};
  my $misc = $h{misc} || "";
  my $flags = $h{flags} || "";
  my $cmake_defines = $h{cmake_defines} || ();
  my $funcs = $h{funcs} || "";
  my $installdir = $h{installdir} || "";
  my $srcdir = "../" . ($h{srcdir} || "");
  my $pkgprefix = $h{pkgprefix} || "";
  my $compiler = $h{compiler} || 0;

  my $cmake_defines_str = "";
  foreach my $def (@$cmake_defines) {
    $cmake_defines_str .= " -D$def";
  }

  $flags .= " -DCMAKE_VERBOSE_MAKEFILE:BOOL=ON";
  $flags .= " -DROCM_PATH=$ROCM_INSTALL_DIR";
  # when building LLVM we DO want to use the system-compiler
  # But from then on, and especially when building rocblas use LLVM
  # (since that has been built with GPU architecture support).
  if($compiler ne "use-system"){
    #$flags .= " -DCMAKE_C_COMPILER=$ROCM_INSTALL_DIR/llvm/bin/clang";
    #$flags .= " -DCMAKE_CXX_COMPILER=$ROCM_INSTALL_DIR/llvm/bin/clang++";
    $flags .= " -DCMAKE_CXX_COMPILER=$ROCM_INSTALL_DIR/bin/hipcc"; # Needed for rocRANDR and rocBLAS
  }
  dir_push("$rocm_src_dir/$dir");

  if(! $build_continue) {
    system("rm -rf build");
    system("mkdir build");
  }
  chdir("build") or mydie("cant CD into build");

  my $str = "cmake $flags $cmake_defines_str -DCMAKE_PREFIX_PATH=\"$ROCM_INSTALL_DIR;$ROCM_INSTALL_DIR/cmake;$ROCM_INSTALL_DIR/hip;$pkgprefix\" -DCMAKE_INSTALL_PREFIX=${ROCM_INSTALL_DIR}$installdir $funcs $misc $srcdir";
  if(! $build_continue) {
    print "RUN CMAKE: $str\n" if($verbose);
    cmd($str);
  }
  cmd("cmake --build . --parallel $makethreads 2>&1 | tee l");
  cmd("cmake --install .");
  dir_pop();
  printgreen("Successfully built $dir\n");
}

my $save_dir;

sub dir_push {
  $save_dir = getcwd;
  my($new_dir) = @_;
  chdir($new_dir) or mydie("cant CD into $new_dir");
}

sub dir_pop {
  chdir($save_dir) or mydie("cant CD back into $save_dir");
}
  
sub cmd {
  my($str) = @_;
  system($str);
  if($? != 0){
    mydie("FAIL: $str");
  }
}

sub mydie {
  printcolor(1, 31, $_[0]);
  die "\n";
}

sub printcolor {
  my($dest, $color, $str) = @_;
  if($dest){ # print to STDERR
    printf(STDERR "\033[${color}m$str\033[0m");
  }else{
    printf("\033[${color}m$str\033[0m");
  }
}

sub printgreen {
  my($str) = @_;
  printcolor(0, 32, $_[0]);
}

sub printyellow {
  printcolor(0, 33, $_[0]);
}

sub printred {
  printcolor(0, 31, $_[0]);
}

