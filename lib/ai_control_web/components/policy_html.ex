defmodule AiControlWeb.PolicyHTML do
  @moduledoc "Shared policy editor markup, rendered from a HEEx template."
  use AiControlWeb, :html

  alias AiControl.Policies.Configuration

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
