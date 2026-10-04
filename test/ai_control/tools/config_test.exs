defmodule AiControl.Tools.ConfigTest do
  use ExUnit.Case, async: true

  alias AiControl.Tools.Config

  test "only operator UUID assignments and pinned endpoint grants configure sandboxes" do
    org = Ecto.UUID.generate()
    agent = Ecto.UUID.generate()
    context = Ecto.UUID.generate()

    source = %{
      "contexts" => %{agent => context},
      "grants" => %{
        agent => %{
          "paths" => ["demo.txt"],
          "endpoints" => %{
            "http://demo.invalid/report" => %{"ip" => "127.0.0.1", "allow_private" => true}
          }
        }
      }
    }

    assert {:ok, options} = Config.options(org, source)
    assert options[:contexts] == %{agent => context}

    assert options[:grants][agent].endpoints["http://demo.invalid/report"] == %{
             ip: {127, 0, 0, 1},
             allow_private?: true
           }

    assert options[:name] == Config.via(org)

    for invalid <- [
          Map.put(source, "contexts", %{agent => "client-context"}),
          put_in(source, ["grants", agent, "paths"], "*"),
          put_in(
            source,
            ["grants", agent, "endpoints", "http://demo.invalid/report", "ip"],
            "localhost"
          ),
          Map.put(source, "files", [])
        ] do
      assert {:error, :invalid_tool_configuration} = Config.options(org, invalid)
    end
  end
end
