{
  lib,
  stdenv,
  fetchurl,
  makeBinaryWrapper,
  installShellFiles,
  git,
  ripgrep,
  procps,
  bubblewrap,
  binName ? "grok",
}:

let
  sources = lib.importJSON ./sources.json;
  inherit (sources) version;

  platformMap = {
    "aarch64-darwin" = "macos-aarch64";
    "x86_64-darwin" = "macos-x86_64";
    "x86_64-linux" = "linux-x86_64";
    "aarch64-linux" = "linux-aarch64";
  };

  platform =
    platformMap.${stdenv.hostPlatform.system}
      or (throw "grok is not available for ${stdenv.hostPlatform.system}. Supported: ${lib.concatStringsSep ", " (lib.attrNames platformMap)}");

  # x.ai is the Cloudflare-fronted host the official installer prefers; the GCS
  # bucket is the direct origin and stays as a fallback if x.ai is unreachable.
  # The hash pin guarantees both resolve to identical bytes.
  binary = fetchurl {
    name = "grok-${version}-${platform}";
    urls = [
      "https://x.ai/cli/grok-${version}-${platform}"
      "https://storage.googleapis.com/grok-build-public-artifacts/cli/grok-${version}-${platform}"
    ];
    hash = sources.platforms.${platform};
  };

  # grok shells out to these. PATH is suffixed, not prefixed, so a user's own
  # git/ripgrep still wins — these are the floor, not an override.
  runtimeDeps = [
    git
    ripgrep
    procps
  ]
  # Linux sandboxing re-execs the agent under bwrap (xai-grok-sandbox).
  ++ lib.optionals stdenv.hostPlatform.isLinux [ bubblewrap ];
in
stdenv.mkDerivation {
  pname = "grok";
  inherit version;

  dontUnpack = true;
  # The macOS builds carry xAI's code signature; stripping invalidates it.
  dontStrip = true;

  nativeBuildInputs = [
    makeBinaryWrapper
    installShellFiles
  ];

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin
    install -m755 ${binary} $out/bin/.${binName}-unwrapped

    makeBinaryWrapper $out/bin/.${binName}-unwrapped $out/bin/${binName} \
      --inherit-argv0 \
      --set GROK_DISABLE_AUTOUPDATER 1 \
      --suffix PATH : ${lib.makeBinPath runtimeDeps}

    runHook postInstall
  '';

  # Completions come from the binary itself, so they can only be generated when
  # the build machine can run the host binary.
  postInstall = lib.optionalString (stdenv.buildPlatform.canExecute stdenv.hostPlatform) ''
    installShellCompletion --cmd ${binName} \
      --bash <($out/bin/${binName} completions bash) \
      --zsh <($out/bin/${binName} completions zsh) \
      --fish <($out/bin/${binName} completions fish)
  '';

  doInstallCheck = stdenv.buildPlatform.canExecute stdenv.hostPlatform;
  installCheckPhase = ''
    runHook preInstallCheck
    $out/bin/${binName} --version | grep -qF "${version}"
    runHook postInstallCheck
  '';

  meta = {
    description = "xAI's terminal-based AI coding agent";
    longDescription = ''
      Grok Build (`grok`) is a full-screen terminal coding agent that reads and
      edits your codebase, runs shell commands, searches the web, and manages
      long-running tasks — interactively, headlessly for CI, or embedded in
      editors over the Agent Client Protocol.

      This package installs the binary xAI publishes for the `${sources.channel}`
      channel, with the built-in auto-updater disabled: the Nix store is
      read-only, so updates land by bumping this flake instead.
    '';
    homepage = "https://x.ai/cli";
    downloadPage = "https://github.com/xai-org/grok-build";
    changelog = "https://x.ai/build/changelog";
    license = lib.licenses.asl20;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = lib.attrNames platformMap;
    mainProgram = binName;
  };
}
