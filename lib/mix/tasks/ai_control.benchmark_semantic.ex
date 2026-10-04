defmodule Mix.Tasks.AiControl.BenchmarkSemantic do
  @shortdoc "Benchmark frozen Polish fixtures against a pinned injection provider"
  @moduledoc "Release-compatible benchmark adapter; reports contain IDs and measurements, never text."
  use Mix.Task

  alias AiControl.Benchmarks.Semantic

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    Semantic.run(args)
  rescue
    error in ArgumentError -> Mix.raise(Exception.message(error))
  end
end
