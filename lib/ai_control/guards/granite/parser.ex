defmodule AiControl.Guards.Granite.Parser do
  @moduledoc "A complete, single binary score only. Reasoning is discarded, never returned."
  def parse(text) when is_binary(text) do
    # Accept one optional, complete leading thinking section, never arbitrary suffixes.
    stripped = Regex.replace(~r/\A\s*<think>.*?<\/think>\s*/s, text, "")

    case Regex.run(~r/\A\s*<score>\s*(yes|no)\s*<\/score>\s*\z/, stripped,
           capture: :all_but_first
         ) do
      [score] -> {:ok, score}
      _ -> {:error, :provider_invalid_response}
    end
  end

  def parse(_), do: {:error, :provider_invalid_response}
end
