{
  pkgs,
  lib,
  config,
  inputs,
  ...
}:

{

  # https://devenv.sh/packages/
  packages = with pkgs; [
    shellcheck
    lld
    llvm
    clang
    boehmgc
  ];

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
