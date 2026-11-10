defmodule Player.SearchHelper do
  @moduledoc false

  # Las configuraciones pequeñas y deterministas se usan solo en las pruebas.
  def start(start_url, target_url, opts \\ []) do
    concurrency = Keyword.get(opts, :max_concurrency, 3)
    explorers = Keyword.get(opts, :explorer_count, 1)

    config = %{
      max_concurrency: concurrency,
      bfs_concurrency: Keyword.get(opts, :bfs_concurrency, concurrency - explorers),
      explorer_count: explorers,
      jump_hops: Keyword.get(opts, :jump_hops, 5),
      explorer_budget: Keyword.get(opts, :explorer_budget, 32),
      random_seed: Keyword.get(opts, :random_seed, 17)
    }

    DynamicSupervisor.start_child(
      Player.CrawlerSupervisor,
      {Player.ExplorerCoordinator, {start_url, target_url, config}}
    )
  end
end
