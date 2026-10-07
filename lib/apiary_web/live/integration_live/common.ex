defmodule ApiaryWeb.IntegrationLive.Common do
  @moduledoc """
  What the pages of Workspace settings › Integrations share (`ApiaryWeb.IntegrationLive.Index`,
  `ApiaryWeb.IntegrationLive.Show`, `ApiaryWeb.IntegrationLive.Release`,
  `ApiaryWeb.IntegrationLive.Definition`): their paths, the words for a kind and for where
  a connection applies, the people who changed one, the plain settings a description
  declares and the form values cast to them, and the sentence for each refusal of
  `Apiary.Connections` and `Apiary.Integrations`.

  The pages call a connection of `Apiary.Connections` what the console calls it: a
  runtime, an integration or a service. No run receives any of them yet: each page says
  so once, near its top (`not_yet/1`), and nothing on them says otherwise.
  """
  use ApiaryWeb, :html

  alias Apiary.Connections.Connection
  alias Apiary.Integrations.{Description, Source}
  alias Apiary.Organisations
  alias ApiaryWeb.People

  ## Paths

  @doc "index_path/1 is the section's list."
  def index_path(scope),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/settings/integrations"

  @doc "add_path/1 is Add integration, the form that asks for a release."
  def add_path(scope),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/settings/integrations/add"

  @doc "new_runtime_path/1 and new_service_path/1 are the forms that set one up."
  def new_runtime_path(scope),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/settings/integrations/new-runtime"

  def new_service_path(scope),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/settings/integrations/new-service"

  @doc "release_path/3 is a release asked for, before it is added; `for`, a connection moved to it."
  def release_path(scope, release_id, for \\ nil)

  def release_path(scope, release_id, nil),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/settings/integrations/releases/#{release_id}"

  def release_path(scope, release_id, for),
    do:
      ~p"/#{scope.organisation}/#{scope.workspace}/settings/integrations/releases/#{release_id}?#{[for: for]}"

  @doc "connection_path/3 is a connection's page, its tab or act `rest` after it."
  def connection_path(scope, connection, rest \\ nil)

  def connection_path(scope, %Connection{public_id: id}, rest),
    do: connection_path(scope, id, rest)

  def connection_path(scope, id, nil),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/settings/integrations/#{id}"

  def connection_path(scope, id, :targets),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/settings/integrations/#{id}/targets"

  def connection_path(scope, id, :add_target),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/settings/integrations/#{id}/targets/add"

  def connection_path(scope, id, :settings),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/settings/integrations/#{id}/settings"

  def connection_path(scope, id, :version),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/settings/integrations/#{id}/version"

  def connection_path(scope, id, :delete),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/settings/integrations/#{id}/delete"

  @doc "remove_target_path/3 is the confirmation, on its row, of taking a target from a connection."
  def remove_target_path(scope, connection, target_id),
    do:
      ~p"/#{scope.organisation}/#{scope.workspace}/settings/integrations/#{connection.public_id}/targets/#{target_id}/remove"

  @doc "definition_path/3 is the workspace's own service definitions: new, one, its edit or its deletion."
  def definition_path(scope, definition, rest \\ nil)

  def definition_path(scope, :new, nil),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/settings/integrations/definitions/new"

  def definition_path(scope, definition, nil),
    do:
      ~p"/#{scope.organisation}/#{scope.workspace}/settings/integrations/definitions/#{definition.public_id}"

  def definition_path(scope, definition, :edit),
    do:
      ~p"/#{scope.organisation}/#{scope.workspace}/settings/integrations/definitions/#{definition.public_id}/edit"

  def definition_path(scope, definition, :delete),
    do:
      ~p"/#{scope.organisation}/#{scope.workspace}/settings/integrations/definitions/#{definition.public_id}/delete"

  @doc "settings_path/1 is the workspace's settings, the breadcrumb's step before the section."
  def settings_path(scope), do: ~p"/#{scope.organisation}/#{scope.workspace}/settings"

  @doc "secrets_path/1 is Secrets and variables, where the workspace's secrets are stored."
  def secrets_path(scope), do: ~p"/#{scope.organisation}/#{scope.workspace}/settings/secrets"

  ## The line every page says once

  @doc """
  not_yet/1 is the one line each page of the section says near its top: no run
  receives a runtime, an integration or a service yet (`not_on_runs/1`).
  """
  attr :id, :string, default: "not-on-runs"

  def not_yet(assigns) do
    ~H"""
    <.not_on_runs id={@id}>
      {gettext("Runs don't receive integrations yet. Today a run receives only its security policy.")}
    </.not_on_runs>
    """
  end

  ## Words

  @doc "kind_word/1 is a kind's name, capitalised: Runtime, Integration, Service."
  def kind_word("runtime"), do: gettext("Runtime")
  def kind_word("integration"), do: gettext("Integration")
  def kind_word("service"), do: gettext("Service")

  @doc "applies_word/2 is where a connection applies, in a few words: every target, or how many chosen."
  def applies_word(%Connection{applies_to: "all"}), do: gettext("Every target")

  def applies_word(%Connection{applies_to: "selected", targets: targets}) when is_list(targets) do
    case length(targets) do
      0 -> gettext("No target yet")
      n -> ngettext("%{count} chosen target", "%{count} chosen targets", n)
    end
  end

  @doc "people/1 is the members of the scope's organisation by user id, for who added or changed a thing."
  def people(scope) do
    for %{user: user} <- Organisations.list_members(scope),
        email = People.email(user),
        into: %{},
        do: {user.id, email}
  end

  @doc "who/2 is the person `id` among `people`, or nil for none."
  def who(people, id), do: People.member(people, id)

  @doc "may_write?/1 says whether the scope may change the workspace's integrations."
  def may_write?(scope),
    do: Apiary.Access.can?(scope, :"connection.write", scope.workspace)

  @doc "only_admins/0 is the line a reader who may not change the section reads."
  def only_admins, do: gettext("Only owners and admins change the integrations of a workspace.")

  ## A description's plain settings

  @doc """
  plain_settings/1 is the plain settings `description` lets a workspace set, in name
  order, each `%{name:, title:, description:, type:}`: those its roles list, never a
  secret or a secret's file (`Apiary.Integrations.Description.check_settings/2`).
  """
  def plain_settings(%Description{} = description) do
    properties = get_in(description.document, ["settings", "properties"]) || %{}
    secrets = Enum.map(description.secrets, & &1.name)
    files = Enum.map(secrets, &(&1 <> "_file"))

    listed =
      for {role, body} <- description.document["roles"],
          role in Description.ways(),
          name <- body["settings"] || [],
          uniq: true,
          do: name

    for name <- Enum.sort(listed),
        name not in secrets and name not in files,
        property = properties[name] || %{} do
      %{
        name: name,
        title: property["title"] || name,
        description: property["description"],
        type: type(property)
      }
    end
  end

  defp type(%{"type" => type}) do
    types = List.wrap(type)

    cond do
      "string" in types -> :string
      "boolean" in types -> :boolean
      "integer" in types -> :integer
      "number" in types -> :number
      true -> :string
    end
  end

  defp type(_property), do: :string

  @doc """
  argument_patterns/1 is the patterns of the roles of `description` that have one: an
  argument must match each of them whole.
  """
  def argument_patterns(%Description{document: document}) do
    for {role, %{"argument" => pattern}} <- document["roles"],
        role in Description.ways(),
        do: pattern
  end

  @doc """
  cast_settings/2 is the plain settings a form sent, as `plain_settings/1` declares them:
  a field left blank is left out, a boolean is a boolean, a number a number where it
  reads as one (else the text, which the description's check refuses).
  """
  def cast_settings(declared, params) when is_map(params) do
    for %{name: name, type: type} <- declared,
        value = Map.get(params, name),
        is_binary(value),
        cast = cast(type, String.trim(value)),
        cast != :blank,
        into: %{},
        do: {name, cast}
  end

  def cast_settings(_declared, _params), do: %{}

  defp cast(:boolean, value), do: value == "true"
  defp cast(_type, ""), do: :blank

  defp cast(:integer, value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> value
    end
  end

  defp cast(:number, value) do
    case Float.parse(value) do
      {n, ""} -> if(String.contains?(value, "."), do: n, else: trunc(n))
      _ -> value
    end
  end

  defp cast(:string, value), do: value

  @doc "setting_value/1 is a stored setting's value as a form field shows it."
  def setting_value(value) when is_binary(value), do: value
  def setting_value(nil), do: nil
  def setting_value(value) when is_boolean(value), do: to_string(value)
  def setting_value(value) when is_number(value), do: to_string(value)
  def setting_value(value), do: Jason.encode!(value)

  ## A source

  @doc "source_owner/1 is what a person can check of a source: its host and owner (`Apiary.Integrations.Source.owner/1`)."
  def source_owner(source) do
    case Source.parse(source, url_sources: true) do
      {:ok, parsed} -> Source.owner(parsed)
      {:error, _reason} -> nil
    end
  end

  @doc "released_on/1 is where a release is published, by its forge's kind: the forge, or an address."
  def released_on("github"), do: "GitHub"
  def released_on("gitlab"), do: "GitLab"
  def released_on("forgejo"), do: "Codeberg"
  def released_on(_none), do: gettext("An https address")

  @doc "url_source?/1 says whether `source` is an https address, not a forge path."
  def url_source?(source) when is_binary(source), do: String.starts_with?(source, "https://")
  def url_source?(_source), do: false

  ## Refusals

  @doc """
  refusal/2 is the sentence for a refusal of `Apiary.Connections` or
  `Apiary.Integrations`, the workspace's `connections` naming those an overlap is with.
  """
  def refusal(reason, connections \\ [])

  def refusal({:overlap, ids}, connections) do
    names =
      for %Connection{public_id: id, name: name} <- connections, id in ids, do: name

    pgettext(
      "plain",
      "It would overlap with %{names} where both apply: the same runtime, the same integration, or a host in common.",
      names: Enum.join(if(names == [], do: ids, else: names), ", ")
    )
  end

  def refusal({:in_use, ids}, connections) do
    names =
      for %Connection{public_id: id, name: name} <- connections, id in ids, do: name

    gettext("Services still use it: %{names}. Delete them first.",
      names: Enum.join(if(names == [], do: ids, else: names), ", ")
    )
  end

  def refusal(:runtime_unknown, _), do: gettext("That runtime is not in Qory's catalogue.")
  def refusal(:service_unknown, _), do: gettext("That service definition is not one Qory has.")
  def refusal(:release_not_ready, _), do: gettext("The release is not ready to add.")

  def refusal(:integration_source_refused, _),
    do: gettext("This instance no longer accepts integrations from this source.")

  def refusal({:integration_source_mismatch, :name}, _),
    do: gettext("That release is of another integration.")

  def refusal({:integration_source_mismatch, _}, _),
    do: gettext("That release is from another source.")

  def refusal(:target_not_found, _), do: gettext("That target is not one of this workspace's.")
  def refusal(:ways_not_allowed, _), do: gettext("It can't be used that way.")

  def refusal({:integration_settings_not_allowed, names}, _),
    do: gettext("It takes no such settings: %{names}.", names: Enum.join(List.wrap(names), ", "))

  def refusal({:integration_settings_invalid, _}, _),
    do: gettext("Its settings don't match what its description asks for.")

  def refusal({:integration_settings_too_large, _}, _),
    do: gettext("Its settings are too large.")

  def refusal({:integration_argument_not_allowed, _}, _),
    do: gettext("The argument doesn't match what its description allows.")

  def refusal({:definition_invalid, _}, _),
    do: gettext("The definition is not valid.")

  def refusal(:forbidden, _), do: only_admins()
  def refusal(:not_found, _), do: gettext("It is no longer there.")
  def refusal(%Ecto.Changeset{}, _), do: gettext("Check the fields below.")
  def refusal(_other, _), do: gettext("That could not be saved.")

  @doc """
  definition_problems/1 is a sentence for each problem `Apiary.Kinds.ServiceDefinition`
  found in a definition.
  """
  def definition_problems(problems) do
    for problem <- problems, do: definition_problem(problem)
  end

  defp definition_problem({:definition_invalid, _}),
    do: gettext("It is not a service definition: check its JSON and its fields.")

  defp definition_problem({:declaration_unknown, where}),
    do:
      gettext("%{where} names a secret it doesn't declare, or declares one twice.", where: where)

  defp definition_problem({:connection_host_invalid, host}),
    do: gettext("%{host} is a host a definition may not name.", host: host)

  defp definition_problem({:connection_header_reserved, header}),
    do: gettext("%{header} is a header a definition may not set.", header: header)

  defp definition_problem({:placeholder_conflict, name}),
    do: gettext("%{name} is a variable a placeholder may not take.", name: name)

  defp definition_problem(_other), do: gettext("It is not a valid service definition.")
end
