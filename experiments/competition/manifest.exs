# Procedencia de la competición. `decode_results.exs` copia estos datos en cada fila.
#
# Reciprocity: commit 76de9a9. Su player/ es idéntico al validado antes del commit
# (`git diff 0d56a25 76de9a9 -- player | shasum -a 256` = 82098727…5fad).
%{
  competition: "Reciprocity vs Exploradores (entrega oficial)",
  implementations: %{
    reciprocity: %{
      repo: "https://github.com/eguar11011/wiki_race",
      branch: "feature/reciprocity",
      path: "wiki_race_reciprocity/player",
      base_commit: "0d56a252f41d98e58ae0ef93dfca5e3566c5f884",
      commit: "76de9a9025d0ccc0bae6f814b9fd30d0818b4bd4",
      player_diff_sha256: "82098727c02aa9dcf1f0112b4f35e985cd301db918902f456b8d39779a285fad",
      description: "BFS asíncrona con reciprocidad verificada (strategy: :reverse, 16 workers)"
    },
    exploradores: %{
      repo: "https://github.com/eguar11011/wiki_race",
      ref: "main y tag final (entrega oficial)",
      path: "wiki_race_exploradores (worktree detached, proyecto en la raíz)",
      commit: "87853b159f55bb364df9767637452befbbb658ab",
      tree: "a70efad012b38c67f1680d36607fc9e218e259a7",
      description:
        "Player.ExplorerCoordinator: BFS concurrente por niveles (8 descargas) más 24 " <>
          "exploradores aleatorios sin semilla fija; 32 descargas en total."
    }
  },
  platform: %{
    repo: "https://github.com/FLAGlab/wiki_race",
    commit: "c414bb0ba78a6701493e7ddc39bd159f69cc96c1",
    local_changes: [
      "platform/config/dev.exs: generator :swiss, total_rounds 23, round_pairs del calendario",
      "docker-compose.override.yml: competition/docker-compose.override.block-{A,B}.yml"
    ],
    time_limit_ms: 120_000,
    poll_interval_ms: 250,
    results: "wiki_race/platform/priv/data/competition-2026-11/results.terms"
  },
  snapshot: %{
    book: "wikipedia_en_top_nopic",
    file: "wiki_race/.data/zim/wikipedia_en_top_nopic.zim",
    sha256: "b2806831e14690cbcafeb1b6e7bd4439fd59b3e5fbeaeb300a5792dece510ee0"
  }
}
