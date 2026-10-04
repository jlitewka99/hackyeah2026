defmodule AiControl.Gateway.LiveNerTest do
  use AiControl.DataCase, async: false

  import AiControl.AgentsFixtures
  import AiControl.GatewayFixtures
  import AiControl.OrganizationsFixtures

  alias AiControl.Audit.Event
  alias AiControl.{Gateway, Policies, Repo}
  alias AiControl.Gateway.Config
  alias AiControl.Guards.{Ner, Pii, Secret, Signatures}
  alias AiControl.Policies.Configuration

  @moduletag :live_ner

  test "real sidecar redacts generated Polish person and address in text and decoded arguments" do
    original = Application.fetch_env!(:ai_control, Config)

    Application.put_env(
      :ai_control,
      Config,
      original
      |> Keyword.put(:guards, %{
        "pii" => Pii,
        "secret" => Secret,
        "signatures" => Signatures,
        "ner" => Ner
      })
      |> Keyword.put(:http_plug, {Req.Test, :step8_live_output})
    )

    on_exit(fn -> Application.put_env(:ai_control, Config, original) end)
    assert Ner.ready?(Config.get())
    scope = organization_fixture()
    principal = principal_fixture(scope, agent_fixture(scope))

    source =
      Configuration.default(2)
      |> Map.put("guards", %{
        "semantic" => %{"enabled" => false, "required" => false},
        "ner" => %{"stages" => ["output"], "entities" => ["person", "address"]}
      })

    {:ok, version} = Policies.create_version(scope, source)
    {:ok, current} = Policies.current(scope)
    {:ok, _} = Policies.activate(scope, version.id, current.set.revision)

    text =
      "😀 Rozmawiałem z Janem Kowalskim. Adres: ul. Długa 12/3, 00-001 Warszawa. PESEL: 44051401458"

    Req.Test.stub(:step8_live_output, fn conn ->
      case conn.request_path do
        "/models" ->
          Req.Test.json(conn, %{
            data: [%{id: "deepseek-flash"}]
          })

        _ ->
          data =
            response(text)
            |> put_in(["choices", Access.at(0), "finish_reason"], "tool_calls")
            |> put_in(["choices", Access.at(0), "message", "tool_calls"], [
              %{
                "id" => "call-1",
                "type" => "function",
                "function" => %{
                  "name" => "lookup",
                  "arguments" => Jason.encode!(%{"message" => text}, escape: :unicode_safe)
                }
              }
            ])

          Req.Test.json(conn, data)
      end
    end)

    params =
      Map.put(request(), "tools", [
        %{
          "type" => "function",
          "function" => %{"name" => "lookup", "parameters" => %{"type" => "object"}}
        }
      ])

    assert {:ok, safe} = Gateway.chat(principal, params)
    message = hd(safe["choices"])["message"]
    arguments = hd(message["tool_calls"])["function"]["arguments"] |> Jason.decode!()

    for checked <- [message["content"], arguments["message"]] do
      refute checked =~ "Kowalskim"
      refute checked =~ "Długa"
      refute checked =~ "44051401458"
      assert String.valid?(checked)
    end

    audit = Repo.all(Event) |> Enum.map(&Map.take(&1, Event.fields())) |> Jason.encode!()
    refute audit =~ "Kowalskim"
    refute audit =~ "Długa"
    refute audit =~ "44051401458"
    assert Enum.any?(Repo.all(Event), &(&1.kind == :gateway && &1.stage == :output))
  end

  test "real sidecar removes Polish person and address before generation and audits no text" do
    original = Application.fetch_env!(:ai_control, Config)
    owner = self()

    Application.put_env(
      :ai_control,
      Config,
      original
      |> Keyword.put(:guards, %{
        "pii" => Pii,
        "secret" => Secret,
        "signatures" => Signatures,
        "ner" => Ner
      })
      |> Keyword.put(:http_plug, {Req.Test, __MODULE__})
    )

    on_exit(fn -> Application.put_env(:ai_control, Config, original) end)
    assert Ner.ready?(Config.get())
    scope = organization_fixture()
    principal = principal_fixture(scope, agent_fixture(scope))

    source =
      Configuration.default(2)
      |> Map.put("guards", %{"semantic" => %{"enabled" => false, "required" => false}})

    {:ok, version} = Policies.create_version(scope, source)
    {:ok, current} = Policies.current(scope)
    {:ok, _} = Policies.activate(scope, version.id, current.set.revision)

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/models" ->
          Req.Test.json(conn, %{
            data: [%{id: "deepseek-flash"}]
          })

        "/chat/completions" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(owner, {:generated_with, Jason.decode!(body)})
          Req.Test.json(conn, response("Oblicz wynik: dwa plus dwa."))
      end
    end)

    text =
      "😀 Rozmawiałem z Janem Kowalskim. Adres: ul. Długa 12/3, 00-001 Warszawa. PESEL: 44051401458"

    assert {:ok, _} =
             Gateway.chat(principal, %{
               request()
               | "messages" => [%{"role" => "user", "content" => text}]
             })

    assert_received {:generated_with, data}
    safe = hd(data["messages"])["content"]
    refute safe =~ "Kowalskim"
    refute safe =~ "Długa"
    refute safe =~ "44051401458"
    assert String.valid?(safe)
    audit = Repo.all(Event) |> Enum.map(&Map.take(&1, Event.fields())) |> Jason.encode!()
    refute audit =~ "Kowalskim"
    refute audit =~ "Długa"
    refute audit =~ "44051401458"
  end
end
