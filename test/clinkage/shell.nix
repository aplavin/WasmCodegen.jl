# The toolchains of the C linkage tests (test/clinkage.jl), pinned: emscripten 6.0.9 (the C
# library for wasm64, `emcc -m64`) and clang (the same library, natively). Run the tests in
# it: `nix-shell test/clinkage/shell.nix --run 'julia --project=test test/runtests.jl clinkage'`.
{ pkgs ? import (fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/c7def046b9a883d46974757852106483d741586f.tar.gz";
    sha256 = "0vplppav4izj2462i00a3vd0nbvaj6dbp4m582ndfhhnf8688579";
  }) {} }:
pkgs.mkShell {
  packages = [ pkgs.emscripten pkgs.clang ];
}
