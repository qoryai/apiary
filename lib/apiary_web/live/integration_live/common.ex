defmodule ApiaryWeb.IntegrationLive.Common do
  @moduledoc """
  What the pages of Workspace settings › Integrations share (`ApiaryWeb.IntegrationLive.Index`,
  `ApiaryWeb.IntegrationLive.Show`, `ApiaryWeb.IntegrationLive.Release`,
  `ApiaryWeb.IntegrationLive.Definition`): their paths, the words for a kind and for where
  a connection applies, the people who changed one, the plain settings a description
  declares and the form values cast to them, and the sentence for each refusal of
  `Apiary.Connections` and `Apiary.Integrations`.

  The pages say only what Qory Apiary stores and does. They call a connection of
  `Apiary.Connections` by its kind's word: an Agent (a runtime), an API (a service) or a
  Program (an integration added from a release); a service definition of the workspace's
  own is a Custom API. "Integrations" is the section's name alone, and "service
  definition" is not a word of the pages. Each page says once, near its top, that a run
  receives only its security policy (`not_on_runs/1`), and nothing on them says
  otherwise.
  """
  use ApiaryWeb, :html

  alias Apiary.Connections
  alias Apiary.Connections.Connection
  alias Apiary.Integrations.Description
  alias Apiary.Kinds.Runtimes
  alias Apiary.Organisations
  alias ApiaryWeb.People

  ## Paths

  @doc "index_path/1 is the section's list."
  def index_path(scope),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/settings/integrations"

  @doc """
  add_path/2 is Add from a release, the form that asks for a release; `query`, the
  `source` and `version` it is opened with, such as a release asked for again or a named
  release's card (`ApiaryWeb.IntegrationLive.Named`).
  """
  def add_path(scope, query \\ [])

  def add_path(scope, []),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/settings/integrations/add"

  def add_path(scope, query),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/settings/integrations/add?#{query}"

  @doc """
  new_runtime_path/2 and new_service_path/2 are the forms that set one up, Set up a
  runtime and Set up an API; `chosen`, the item a card opens them with: a runtime's name,
  or an API as `builtin:<key>` or `own:<public id>`.
  """
  def new_runtime_path(scope, chosen \\ nil)

  def new_runtime_path(scope, nil),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/settings/integrations/new-runtime"

  def new_runtime_path(scope, runtime),
    do:
      ~p"/#{scope.organisation}/#{scope.workspace}/settings/integrations/new-runtime?#{[runtime: runtime]}"

  def new_service_path(scope, chosen \\ nil)

  def new_service_path(scope, nil),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/settings/integrations/new-service"

  def new_service_path(scope, definition),
    do:
      ~p"/#{scope.organisation}/#{scope.workspace}/settings/integrations/new-service?#{[definition: definition]}"

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

  @doc "definition_path/3 is the workspace's own custom APIs (service definitions): new, one, its edit or its deletion."
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
  not_on_runs/1 is the one line each page of the section says near its top: a run receives
  only its security policy (`ApiaryWeb.PageComponents.not_on_runs/1`).
  """
  attr :id, :string, default: "not-on-runs"

  def not_on_runs(assigns) do
    ~H"""
    <ApiaryWeb.PageComponents.not_on_runs id={@id}>
      {gettext("A run receives only its security policy.")}
    </ApiaryWeb.PageComponents.not_on_runs>
    """
  end

  ## Words

  @doc """
  kind_word/1 is a kind's name, capitalised: Agent (a runtime), API (a service), Program
  (an integration added from a release).
  """
  def kind_word("runtime"), do: gettext("Agent")
  def kind_word("integration"), do: gettext("Program")
  def kind_word("service"), do: gettext("API")

  @doc """
  kind_order/1 is a kind's place among the section's groups, the order its list and its
  cards follow: the agent (a runtime), then outside APIs (services), then programs
  (integrations).
  """
  def kind_order("runtime"), do: 0
  def kind_order("service"), do: 1
  def kind_order("integration"), do: 2

  @doc "applies_label/0 is the label of where a connection applies, in a list, a form or its facts."
  def applies_label, do: pgettext("plain", "Applies to")

  @doc """
  names/1 is how a person reads a connection's name, `{title, machine_name}`: a runtime's
  title in the catalogue or an integration's in its description, with the name it has
  there beside it (`claude`, `github`); a service's own name alone, `{name, nil}`. The
  machine name is nil where it is the title.
  """
  def names(%Connection{kind: kind, name: name} = connection)
      when kind in ["runtime", "integration"] do
    title = title(connection)
    {title, if(title != name, do: name)}
  end

  def names(%Connection{name: name}), do: {name, nil}

  defp title(%Connection{kind: "runtime", name: name}) do
    case Runtimes.fetch(name) do
      {:ok, runtime} -> runtime.title
      :error -> name
    end
  end

  defp title(%Connection{kind: "integration", name: name} = connection) do
    case Connections.description(connection) do
      {:ok, description} -> description.title
      {:error, _reason} -> name
    end
  end

  @doc """
  label/1 is a connection's title with its machine name beside it, "GitHub (github)", for
  a sentence, a heading or a message that names it in plain text (`names/1`).
  """
  def label(%Connection{} = connection), do: connection |> names() |> label()
  def label({title, nil}), do: title
  def label({title, name}), do: gettext("%{title} (%{name})", title: title, name: name)

  @doc """
  name/1 is a connection's title and, in mono beside it, its machine name (`names/1`),
  given the connection or its names.
  """
  attr :names, :any, required: true, doc: "a connection, or its `names/1`"
  attr :class, :any, default: nil

  def name(%{names: %Connection{} = connection} = assigns),
    do: name(assign(assigns, :names, names(connection)))

  def name(assigns) do
    ~H"""
    <span class={@class}>{elem(@names, 0)}</span><span
      :if={elem(@names, 1)}
      class="q-mono text-[12.5px] font-normal text-muted"
    > ({elem(@names, 1)})</span>
    """
  end

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

  @doc """
  only_admins/1 is the line a person who may not change the section reads: a reader
  through the edition's reach is told what they may do (`ApiaryWeb.Access.reads_only/1`),
  a member who and what.
  """
  def only_admins(scope) do
    if Apiary.Access.reader(scope),
      do: ApiaryWeb.Access.reads_only(scope),
      else: gettext("Only owners and admins change the integrations of a workspace.")
  end

  ## A description's plain settings

  @doc """
  plain_settings/1 is the plain settings `description` lets a workspace set, in name
  order, each `%{name:, title:, description:, type:}`: every top-level setting that is
  neither a secret nor a secret's file (`Apiary.Integrations.Description.check_settings/2`).
  """
  def plain_settings(%Description{} = description) do
    properties = get_in(description.document, ["settings", "properties"]) || %{}

    for name <- description.settings, property = properties[name] || %{} do
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
  argument_patterns/1 is the credential role's `argument` pattern of `description`, in a
  list, or none: an argument must match it whole.
  """
  def argument_patterns(%Description{} = description),
    do: List.wrap(Description.argument_pattern(description))

  @doc """
  cast_settings/2 is the plain settings a form sent, as `plain_settings/1` declares them:
  a field left blank is left out, a boolean is a boolean, a number a number where it
  reads as one (else the text, which the description's check refuses).
  """
  def cast_settings(declared, params) when is_map(params) do
    # The cast is a generator, not a filter: a filter would leave out a boolean set to
    # false.
    for %{name: name, type: type} <- declared,
        value = Map.get(params, name),
        is_binary(value),
        cast <- [cast(type, String.trim(value))],
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
  refusal/3 is the sentence for a refusal of `Apiary.Connections` or
  `Apiary.Integrations` to `scope`, the workspace's `connections` naming those an overlap
  is with.
  """
  def refusal(scope, reason, connections \\ [])

  def refusal(scope, :forbidden, _connections), do: only_admins(scope)
  def refusal(_scope, reason, connections), do: sentence(reason, connections)

  defp sentence({:overlap, ids}, connections) do
    names =
      for %Connection{public_id: id} = connection <- connections,
          id in ids,
          do: label(connection)

    pgettext(
      "plain",
      "It would overlap with %{names} where both apply: the same runtime, the same program, or a host in common.",
      names: Enum.join(if(names == [], do: ids, else: names), ", ")
    )
  end

  defp sentence({:in_use, ids}, connections) do
    names =
      for %Connection{public_id: id} = connection <- connections,
          id in ids,
          do: label(connection)

    gettext("APIs are set up from it: %{names}. Remove them first.",
      names: Enum.join(if(names == [], do: ids, else: names), ", ")
    )
  end

  defp sentence(:runtime_unknown, _),
    do: gettext("That runtime is not in the runner's catalogue.")

  defp sentence(:service_unknown, _),
    do: gettext("That API is neither built in nor a custom API of this workspace.")

  defp sentence(:release_not_ready, _), do: gettext("The release is not ready to add.")

  defp sentence(:integration_source_refused, _),
    do: gettext("This instance no longer accepts integrations from this source.")

  defp sentence({:integration_source_mismatch, :name}, _),
    do: gettext("That release is of another program.")

  defp sentence({:integration_source_mismatch, _}, _),
    do: gettext("That release is from another source.")

  defp sentence(:target_not_found, _), do: gettext("That target is not one of this workspace's.")

  defp sentence({:integration_settings_not_allowed, names}, _),
    do: gettext("It takes no such settings: %{names}.", names: Enum.join(List.wrap(names), ", "))

  defp sentence({:integration_settings_invalid, _}, _),
    do: gettext("Its settings don't match what its description asks for.")

  defp sentence({:integration_settings_too_large, _}, _),
    do: gettext("Its settings are too large.")

  defp sentence({:integration_argument_not_allowed, _}, _),
    do: gettext("The argument doesn't match what its description allows.")

  defp sentence({:definition_invalid, _}, _),
    do: gettext("The definition is not valid.")

  defp sentence(:not_found, _), do: gettext("It is no longer there.")
  defp sentence(%Ecto.Changeset{}, _), do: gettext("Check the fields below.")
  defp sentence(_other, _), do: gettext("That could not be saved.")

  @doc """
  definition_problems/1 is a sentence for each problem `Apiary.Kinds.ServiceDefinition`
  found in a custom API's definition.
  """
  def definition_problems(problems) do
    for problem <- problems, do: definition_problem(problem)
  end

  defp definition_problem({:definition_invalid, _}),
    do: gettext("It is not a custom API's definition: check its JSON and its fields.")

  defp definition_problem({:declaration_unknown, where}),
    do:
      gettext("%{where} names a secret it doesn't declare, or declares one twice.", where: where)

  defp definition_problem({:connection_host_invalid, host}),
    do: gettext("%{host} is a host a definition may not name.", host: host)

  defp definition_problem({:connection_header_reserved, header}),
    do: gettext("%{header} is a header a definition may not set.", header: header)

  defp definition_problem({:placeholder_conflict, name}),
    do: gettext("%{name} is a variable a placeholder may not take.", name: name)

  defp definition_problem(_other), do: gettext("It is not a valid definition of a custom API.")
end
