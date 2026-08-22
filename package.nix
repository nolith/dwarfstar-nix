{
  lib,
  stdenv,
  fetchFromGitHub,
  rocmPackages,
  glibc,
  curl,
  makeWrapper,
  # GPU target. Default is Strix Halo (Radeon 8050S/8060S, Ryzen AI MAX).
  # Override for other AMD GPUs, e.g. "gfx1100" (RDNA3 dGPU).
  rocmArch ? "gfx1151",
}:

let
  rocm = rocmPackages;

  # Unwrapped gcc, used to give the ROCm clang a C++/libstdc++ toolchain.
  gcc = stdenv.cc.cc;
  triple = stdenv.hostPlatform.config;
  gccInstallDir = "${gcc}/lib/gcc/${triple}/${gcc.version}";

  deviceLibs = "${rocm.rocm-device-libs}/amdgcn/bitcode";

  # Headers needed to compile ds4_rocm.cu.
  includePkgs = [
    rocm.clr
    rocm.hipblas
    rocm.hipblas-common
    rocm.hipblaslt
    rocm.hipcub
    rocm.rocwmma
    rocm.rocprim
  ];
  includeFlags = lib.concatMapStringsSep " " (p: "-I${p}/include") includePkgs;

  # Shared libs the final binaries link against / load at runtime.
  runtimeLibPkgs = [
    rocm.clr        # libamdhip64
    rocm.hipblas
    rocm.hipblaslt
    rocm.rocblas
  ];
  linkFlags = lib.concatStringsSep " " (
    (map (p: "-L${p}/lib") runtimeLibPkgs)
    ++ (map (p: "-Wl,-rpath,${p}/lib") runtimeLibPkgs)
  );
in
stdenv.mkDerivation (finalAttrs: {
  pname = "ds4";
  version = "0-unstable-2026-08-09";

  src = fetchFromGitHub {
    owner = "antirez";
    repo = "ds4";
    rev = "84cc882352757baf628a1776badf7cc54d584e28";
    hash = "sha256-mdvKxI+/vDQcrpHepvXPmYcTjPTRnqJWWU0UFFnLJJk=";
  };

  # Tools that must be on PATH during the build:
  #  - hipcc:        compiles the .cu device code
  #  - llvm.clang:   the actual clang++ hipcc drives (HIP_CLANG_PATH)
  #  - llvm.lld:     provides ld.lld for the amdgcn device link
  #  - llvm.llvm:    provides llvm-objcopy used by clang-offload-bundler
  #  - makeWrapper:  to wrap the model downloader with curl
  nativeBuildInputs = [
    rocm.hipcc
    rocm.llvm.clang
    rocm.llvm.lld
    rocm.llvm.llvm
    makeWrapper
  ];

  buildInputs = includePkgs ++ [ rocm.rocblas ];

  # hipcc / the ROCm clang look these up from the environment.
  ROCM_PATH = "${rocm.clr}";
  HIP_PATH = "${rocm.clr}";
  HIP_CLANG_PATH = "${rocm.llvm.clang}/bin";

  dontConfigure = true;
  enableParallelBuilding = true;

  # ds4's Makefile `strix-halo` target recursively re-pins DS4_LINK to hipcc,
  # whose bundled clang cannot host-link on NixOS (no bare ld/crt/dynamic-linker).
  # So we invoke the underlying targets directly and split the build:
  #   * device .cu -> .o  with hipcc (gcc-toolchain + glibc + device-libs spelled out)
  #   * host link         with the nix-wrapped g++ (handles crt + dynamic-linker + rpath)
  buildPhase = ''
    runHook preBuild

    make -B ds4 ds4-server ds4-bench ds4-eval ds4-agent \
      CORE_OBJS='ds4.o ds4_distributed.o ds4_tp.o ds4_ssd.o ds4_rocm.o ds4_rocm_compat.o ds4_rocm_unavailable.o ds4_layer_pack.o' \
      CC=cc \
      CFLAGS="-O3 -ffast-math -g -Wall -Wextra -std=c99 -D_GNU_SOURCE -fno-finite-math-only -DDS4_ROCM_BUILD" \
      HIPCC=hipcc \
      ROCM_CFLAGS="-O3 -ffast-math -g -fno-finite-math-only -pthread -D__HIP_PLATFORM_AMD__ -Wno-unused-command-line-argument --offload-arch=${rocmArch} --rocm-device-lib-path=${deviceLibs} --gcc-install-dir=${gccInstallDir} -idirafter ${glibc.dev}/include ${includeFlags}" \
      DS4_LINK="g++" \
      DS4_LINK_LIBS="-lm -pthread -lhipblas -lhipblaslt -lamdhip64 ${linkFlags}" \
      -j$NIX_BUILD_CORES

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    install -Dm755 ds4 ds4-server ds4-bench ds4-eval ds4-agent -t $out/bin

    # Model downloader, wrapped so curl is available.
    install -Dm755 download_model.sh $out/bin/ds4-download-model
    wrapProgram $out/bin/ds4-download-model \
      --prefix PATH : ${lib.makeBinPath [ curl ]}

    runHook postInstall
  '';

  meta = {
    description = "DwarfStar (antirez ds4): DeepSeek V4 inference runtime, ROCm/Strix Halo build";
    homepage = "https://github.com/antirez/ds4";
    license = lib.licenses.bsd2;
    platforms = [ "x86_64-linux" ];
    mainProgram = "ds4";
  };
})
