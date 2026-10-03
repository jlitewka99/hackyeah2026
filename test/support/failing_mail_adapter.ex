defmodule AiControl.FailingMailAdapter do
  @moduledoc false
  use Swoosh.Adapter

  def deliver(_, _), do: {:error, :unavailable}
end
