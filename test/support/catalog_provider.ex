defmodule AiControl.TestCatalogProvider do
  @moduledoc false
  @behaviour AiControl.Gateway.Provider

  defdelegate models(config), to: AiControl.Gateway.DeepSeek
  defdelegate prepare(params, config), to: AiControl.Gateway.DeepSeek
  defdelegate chat(params, config), to: AiControl.Gateway.DeepSeek
  defdelegate chat_stream(params, config), to: AiControl.Gateway.DeepSeek
end
