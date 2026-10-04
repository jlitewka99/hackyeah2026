defmodule AiControl.Guards.Granite.Model do
  @moduledoc "Immutable operator model and tokenizer identity; never selected by a client."
  @external_resource Path.expand("../../../../sidecar/tokenizer/granite.v1.json", __DIR__)
  @manifest @external_resource |> File.read!() |> Jason.decode!()
  def name, do: @manifest["model"]
  def digest, do: @manifest["digest"]
  def revision, do: @manifest["revision"]
end
