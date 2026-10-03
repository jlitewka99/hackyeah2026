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
        "/api/tags" ->
          Req.Test.json(conn, %{
            models: [%{name: "qwen3.5:4b", digest: String.duplicate("a", 64)}]
          })

        "/v1/chat/completions" ->
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
