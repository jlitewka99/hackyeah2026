defmodule AiControlWeb.PolicyHTML do
  @moduledoc "Shared policy editor markup, rendered from a HEEx template."
  use AiControlWeb, :html

  alias AiControl.Policies.Configuration
  alias AiControl.Tools.Catalog

  embed_templates "policy_html/*"

  def defaults(form) do
    profile = form[:profile].value
    profile = if profile in Configuration.profiles(), do: profile, else: "balanced"

    {:ok, %{settings: settings}} =
      Configuration.validate(
        Map.put(Configuration.default(schema_version(form)), "profile", profile)
      )

    settings
  end

  def schema_version(form), do: Ecto.Changeset.get_field(form.source, :schema_version)
  def guard_catalog(form), do: Configuration.guards(schema_version(form))
  def entity_types, do: Configuration.ner_entities()
  def category_catalog(form), do: Configuration.categories(schema_version(form))
  def severities, do: Configuration.severities()
  def safety_categories, do: Configuration.safety_categories()

  def tool_catalog, do: Catalog.all()

  def tool_label(tool),
    do:
      if(Enum.any?(tool_catalog(), &(&1["name"] == tool)),
        do: tool,
        else: tool <> " (unsupported)"
      )

  def tool_selected?(form, tool),
    do: Map.get(form[:tool_selection].value || %{}, tool) in [true, "true"]

  def unknown_tools(form) do
    known = Enum.map(tool_catalog(), & &1["name"])
    Map.keys(form[:tool_selection].value || %{}) -- known
  end

  def tool_id(tool), do: "policy-tool-" <> Base.url_encode64(tool, padding: false)
  def tool_description("file.read"), do: "Read a virtual file."
  def tool_description("file.write"), do: "Create or replace a virtual file."
  def tool_description("file.delete"), do: "Delete a virtual file."
  def tool_description("http.get"), do: "Read an exact endpoint pinned by the operator."
  def tool_description("database.select"), do: "Read bounded rows from a demo table."
  def tool_description("email.send"), do: "Queue a message in the local demo mailbox."
  def tool_description("command.run"), do: "Run a permitted status or echo function."

  def label_rule?(form, category),
    do:
      schema_version(form) in [3, 4, 5] &&
        (category == "content_safety" ||
           (category == "prompt_injection" && injection_provider(form) == "qwen"))

  def injection_provider(form), do: nested(form, :guards, "semantic", "provider", "qwen")
  def provider_label("prompt_guard"), do: "Llama Prompt Guard 2 86M"
  def provider_label(_), do: "Qwen3Guard Gen 0.6B"

  def diff_label("guards.semantic.provider"), do: "Injection provider"
  def diff_label("rules.prompt_injection.threshold"), do: "Injection sensitivity"
  def diff_label(path), do: path

  def diff_value(%{path: "guards.semantic.provider"}, settings, _side),
    do: provider_label(get_in(settings, ["guards", "semantic", "provider"]))

  def diff_value(%{path: "rules.prompt_injection.threshold"}, settings, _side) do
    if label_rule_settings?(settings, "prompt_injection"),
      do:
        "Severity labels: #{Enum.join(settings["guards"]["semantic"]["severities"], ", ")} · Jailbreak",
      else: "Score threshold: #{settings["rules"]["prompt_injection"]["threshold"]}"
  end

  def diff_value(change, _settings, side), do: Map.fetch!(change, side)

  def provider_change_notice(settings) do
    if get_in(settings, ["guards", "semantic", "provider"]) == "prompt_guard",
      do:
        "Injection now uses the maximum malicious score across all windows and the new score threshold. Response moderation continues to use Qwen.",
      else:
        "Injection now uses the new version's selected severity labels with the Jailbreak category. Label mapping replaces the malicious-score threshold; zero is not a score cutoff. Response moderation continues to use Qwen."
  end

  def label_rule_settings?(settings, category),
    do:
      settings["schema_version"] in [3, 4, 5] &&
        (category == "content_safety" ||
           (category == "prompt_injection" &&
              get_in(settings, ["guards", "semantic", "provider"]) != "prompt_guard"))

  def rule_actions(form, category) do
    if category in ~w(prompt_injection content_safety) && schema_version(form) in [3, 4, 5],
      do: [{"Allow", "allow"}, {"Block", "block"}],
      else: [{"Allow", "allow"}, {"Redact", "redact"}, {"Block", "block"}]
  end

  def default_guard_mode(settings) do
    cond do
      !settings["enabled"] -> "disabled"
      settings["required"] -> "required"
      true -> "optional"
    end
  end

  def label("ner"), do: "Named entities"
  def label("geographical_location"), do: "Geographical places"
  def label("place"), do: "Localities"
  def label("person"), do: "People"

  def label("pii"), do: "Personal data"
  def label("secret"), do: "Secrets"
  def label("exploit"), do: "Exploit signatures"
  def label("prompt_injection"), do: "Prompt injection"
  def label("signatures"), do: "Signatures"
  def label("semantic"), do: "Semantic analysis"
  def label("moderation"), do: "Response moderation"
  def label("content_safety"), do: "Response safety"
  def label(value), do: value |> String.replace("_", " ") |> String.capitalize()

  def nested(form, field, key, subkey, default \\ "") do
    with map when is_map(map) <- form[field].value,
         nested when is_map(nested) <- Map.get(map, key, %{}) do
      Map.get(nested, subkey, default)
    else
      _ -> default
    end
  end

  def field_errors(errors, path), do: for({^path, message} <- errors, do: message)
  def export_path(:global, _scope, id), do: "/platform/policies/versions/#{id}/export"

  def export_path(_, scope, id),
    do: "/organizations/#{scope.organization.id}/policies/versions/#{id}/export"

  def short(id), do: String.slice(id, 0, 8)
end
