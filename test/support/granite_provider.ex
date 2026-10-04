defmodule AiControl.TestGraniteProvider do
  @moduledoc false
  def analyze(prompt, config, deadline), do: config[:test_granite].(prompt, deadline)
end
