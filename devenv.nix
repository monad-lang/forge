{
  pkgs,
  lib,
  config,
  inputs,
  ...
}:

let
  # `monad` links Boehm GC STATICALLY on Linux
  # (`-Wl,-Bstatic -lgc -Wl,-Bdynamic`, see the toolchain's llvm/src/link.mo),
  # so the link needs `libgc.a`. The plain `pkgs.boehmgc` ships only the
  # shared library (`libgc.so`), which is why `monad test`/`monad run` died
  # with "cannot find -lgc ... have you installed the static version of the
  # gc library ?". The packaged `monad` and the project's own dev shell both
  # use this override.
  boehmgc-static = pkgs.boehmgc.override { enableStatic = true; };
in
{

  # https://devenv.sh/packages/
  packages = with pkgs; [
    shellcheck
    lld
    llvm
    clang
    boehmgc-static
  ];

  # The web profile (`--target wasm32-unknown-unknown`) compiles the C
  # runtime and links with clang. The nix-WRAPPED `clang` above injects
  # hardening flags (`-fzero-call-used-regs=used-gpr`) and a glibc
  # `-dynamic-linker`, both of which the wasm target rejects; `monad`
  # honours `MONAD_WEB_CC` for exactly this (llvm/src/target.mo,
  # `TargetPlan.web_cc`). wasm-ld comes from `lld` on PATH.
  env.MONAD_WEB_CC = "${pkgs.llvmPackages.clang-unwrapped}/bin/clang";

  # https://devenv.sh/basics/
  enterShell = "";

  # https://devenv.sh/tests/
  # NB: Do not use for CI tests. this is run every time devenv is loaded
  enterTest = "";

  # https://devenv.sh/git-hooks/
  git-hooks.hooks = {
  };

  # See full reference at https://devenv.sh/reference/options/
}
