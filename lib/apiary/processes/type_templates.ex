defmodule Apiary.Processes.TypeTemplates do
  @moduledoc """
  The default process of each workspace type, the instance's, kept as versions
  (`Apiary.Processes.TypeTemplate`): a new workspace copies the newest version of its
  type (`Apiary.Processes.copy_default/2`), and keeps `{type, number}` as its `template`.

  ## Versions

  A type is known by the key of its definition (`Apiary.Lingo.Domain.Definition`), such
  as `qory.software`; the types are the domains of `Apiary.Lingo.Domain.choices/0`. The
  first read of a type inserts its version 1, a copy of the process of the template of the
  Qory harness (`Apiary.Processes.template_process/1`), at the commit of `main` as last
  read (Apiary.Harnesses.Qory.current/0), or at the commit a new workspace read
  (`newest/2`), with no author. A later read where that process differs from the newest
  version's adds it as a new version, but only while every version of the type is a copy
  of the Qory harness's: once an instance admin has saved one, the Qory harness changes
  nothing. Before the Qory harness is first read, a type with no version has none.

  A save (`save/4`) is a new version, the newest at once; there is no trial.

  ## Texts

  Each version also keeps the type's name, summary and description, the "How it works"
  text (`Apiary.Processes.TypeTemplate`). A copy of the Qory harness's keeps none, and a
  page shows the Qory harness's texts instead (`Apiary.Processes.type_texts/1`).
  A save keeps the texts it is given, or the newest version's; a change of a text alone is
  a new version too.

  ## Who

  Reading asks nothing: every person who creates a workspace sees its type's newest
  version. A save asks `workspace_type.edit`, an instance action: an instance admin, asked
  in the instance's organisation (`Apiary.Access.in_instance/1`), on an instance with the
  feature `workflow_model`. It leaves one entry in the trail of the instance's
  organisation, about that organisation, as `instance.rename` does.

  ## Locks

  A save and the insert of a copy of the Qory harness's take a transaction-level advisory lock on
  the type, `apiary:type-template:<type>`, and nothing else, so the versions of one type
  are made one at a time. The unique index on `{type, number}` refuses a second row of
  one number all the same; a save it refuses is `:stale`.
  """

  import Ecto.Query, warn: false

  alias Apiary.{Access, Audit, Processes, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Artifacts.Type
  alias Apiary.Harnesses.Qory
  alias Apiary.Lingo.Domain
  alias Apiary.Organisations.Organisation
  alias Apiary.Processes.TypeTemplate

  # The standard artifact types of the workflow model (§ 11), with their base views: a
  # copy of `Apiary.Artifacts.Type.standard/0`, and the two lists have the same entries.
  @standard_types [
    {"acceptance-criteria", :document},
    {"explainer", :document},
    {"decision-record", :document},
    {"mockup", :image},
    {"screenshot", :image},
    {"demo-video", :video},
    {"change", :structured},
    {"proposal", :document},
    {"questions", :structured},
    {"review-comments", :structured},
    {"verdict", :structured}
  ]

  @texts [:name, :summary, :description]

  @typedoc "A type and its newest version, as `list/0` gives them."
  @type entry :: %{type: String.t(), name: String.t(), newest: TypeTemplate.t()}

  @typedoc """
  Why a save is refused: `:not_found`, where the feature `workflow_model` is off, and for
  anyone outside the instance's organisation; `:forbidden`, for anyone else there but an
  instance admin; `:stale`, when a version newer than `based_on` exists;
  `:unknown_type`, for a key no type has; `{:too_long, text, limit}`, for a text over its
  limit of characters (`Apiary.Processes.TypeTemplate.limits/0`);
  `{:too_many_words, :description, limit}`, for a description over its limit of words
  (`Apiary.Processes.TypeTemplate.word_limit/0`); or the document's errors, in the shape of
  `Apiary.Processes.validate/1`'s, with `:named_approvers` for a gate that lists people
  and `:unchanged` for the document and the texts of the newest version.
  """
  @type reason ::
          :not_found
          | :forbidden
          | :stale
          | :unknown_type
          | {:too_long, TypeTemplate.text(), pos_integer}
          | {:too_many_words, :description, pos_integer}
          | [Processes.error()]

  ## Reading

  @doc """
  list/0 is every workspace type, in the order a person picks one
  (`Apiary.Lingo.Domain.choices/0`), that has a version: its key, its name as its newest
  version shows it (`Apiary.Processes.type_texts/1`) and its newest version.
  """
  @spec list() :: [entry]
  def list do
    for domain <- Domain.choices(),
        key = Domain.definition(domain).key,
        %TypeTemplate{} = newest <- [newest(key)] do
      %{type: key, name: Processes.type_texts(newest).name, newest: newest}
    end
  end

  @doc """
  newest/1 is the newest version of the type with the key `type`, its author preloaded
  (nil for a copy of the Qory harness's): the one a new workspace copies. Nil for a key
  no type has, and for a type with no version before the Qory harness is first read. A
  read inserts a copy of the Qory harness's process at the commit of `main` where it
  differs (§ Versions).
  """
  @spec newest(String.t()) :: TypeTemplate.t() | nil
  def newest(type) when is_binary(type), do: newest(type, nil)

  @doc """
  newest/2 is `newest/1`, with the Qory harness at `commit`, whose files are kept, in place
  of the commit of `main`: a new workspace's, at the commit it read.
  """
  @spec newest(String.t(), String.t() | nil) :: TypeTemplate.t() | nil
  def newest(type, commit) when is_binary(type) do
    case domain(type) do
      nil ->
        nil

      _domain ->
        case ensure(type, commit || Qory.current()) do
          nil -> nil
          row -> Repo.preload(row, :author)
        end
    end
  end

  @doc """
  versions/1 is every version of the type with the key `type`, the newest first, their
  authors preloaded. Empty for a key no type has.
  """
  @spec versions(String.t()) :: [TypeTemplate.t()]
  def versions(type) when is_binary(type) do
    case newest(type) do
      nil ->
        []

      %TypeTemplate{} ->
        Repo.all(
          from t in TypeTemplate,
            where: t.type == ^type,
            order_by: [desc: t.number],
            preload: :author
        )
    end
  end

  @doc """
  version/2 is the version `number` of the type with the key `type`, its author
  preloaded; nil for none.
  """
  @spec version(String.t(), integer) :: TypeTemplate.t() | nil
  def version(type, number) when is_binary(type) and is_integer(number) do
    case newest(type) do
      nil ->
        nil

      %TypeTemplate{} ->
        TypeTemplate
        |> Repo.get_by(type: type, number: number)
        |> Repo.preload(:author)
    end
  end

  @doc """
  workflows/0 is the workflows a type's process may place: the names the Qory harness
  declares at the commit of `main` (`Apiary.Processes.qory_workflows/1`). Every new
  workspace composes the Qory harness (§ 8 of the workflow model); no workspace's harness
  is read.
  """
  @spec workflows() :: [String.t()]
  def workflows, do: Processes.qory_workflows(Qory.current())

  @doc """
  artifact_types/0 is the standard artifact types, each with its base view. A template's
  custom types are in `artifact_types/1`.
  """
  @spec artifact_types() :: [%{name: String.t(), base_view: atom}]
  def artifact_types, do: for({name, view} <- @standard_types, do: %{name: name, base_view: view})

  @doc """
  artifact_types/1 is the standard artifact types and the custom types of `listed`, each
  with its base view. `listed` is the `artifact_types` of a template that
  `Apiary.Harnesses.Reader.template/1` read and that passed the check of its types, nil
  for none.
  """
  @spec artifact_types([map] | nil) :: [%{name: String.t(), base_view: atom}]
  def artifact_types(nil), do: artifact_types()

  def artifact_types(listed) when is_list(listed) do
    custom =
      for %{"name" => name, "base_view" => view} <- listed,
          do: %{name: name, base_view: base_view(view)}

    artifact_types() ++ custom
  end

  defp base_view(view), do: Enum.find(Type.base_views(), &(Atom.to_string(&1) == view))

  @doc """
  offered_types/1 is the artifact types the page of the type with the key `type` offers
  for a stage's inputs and outputs, and the list `Apiary.Processes.placement_check/3`
  checks them against on that page: the standard types, and, where `type` is the `type` of
  the template of the Qory harness at the commit of `main`
  (Apiary.Harnesses.Qory.template/1), that template's custom types.
  """
  @spec offered_types(String.t()) :: [%{name: String.t(), base_view: atom}]
  def offered_types(type) when is_binary(type) do
    case Qory.template(Qory.current()) do
      %{type: ^type} = template -> artifact_types(template.artifact_types)
      _other -> artifact_types()
    end
  end

  ## Saving

  @doc """
  save/4 saves `document` as the newest version of the type with the key `type`, under
  `workspace_type.edit`, with the scope's person as its author. `based_on:`, a version of
  the type or its number, is the version the person started from; a save is `:stale` when
  a newer version exists. Without it, the save starts from the newest version. A stage
  with no `id` is given a new one (`Apiary.Processes.new_stage_id/0`).

  `texts:` is a map of the version's name, summary and description (`:name`, `:summary`,
  `:description`). Each is kept trimmed, with `\r\n` as `\n`; a blank text, a text the
  map does not have, or one equal to the default (`Apiary.Processes.type_text_defaults/1`),
  is kept as nil, so a page shows the default. Without `texts:`, the save keeps the newest
  version's texts.

  The document passes `Apiary.Processes.validate/1`, and one rule of a type's process: a
  gate's `approvers` is `"members"`, since a type has no people to list; a list of people
  is the error `:named_approvers`, at `#/stages/<index>/gate/approvers`. A machine type
  key the instance has no type for is kept, as a workspace's save keeps it.

  `{:ok, version}`, its author preloaded, or `{:error, reason}` (`t:reason/0`).
  """
  @spec save(Scope.t() | nil, String.t(), term, keyword) ::
          {:ok, TypeTemplate.t()} | {:error, reason}
  def save(scope, type, document, opts \\ []) when is_binary(type) do
    based_on = based_on(Keyword.get(opts, :based_on))
    document = Processes.with_stage_ids(document)
    texts = Keyword.get(opts, :texts)

    Repo.transact(fn ->
      # The table of machine types before the type, in the order of a key change
      # (`rekey_machine/3`), so that the two never wait on each other.
      with :ok <-
             Access.authorize(
               Access.in_instance(scope),
               :"workspace_type.edit",
               Access.instance_organisation()
             ),
           {:ok, _domain} <- known(type),
           :ok <- Apiary.MachineTypes.hold(),
           :ok <- lock(type),
           %TypeTemplate{} = newest <- ensure(type, Qory.current()) || {:error, :unknown_type},
           :ok <- fresh(newest, based_on),
           {:ok, texts} <- texts(texts, type, newest),
           :ok <- validate(document),
           :ok <- changed(newest, document, texts),
           {:ok, instance_scope, organisation} <- instance_scope(scope),
           {:ok, version} <- insert(scope, type, newest, document, texts),
           {:ok, _entry} <- record(instance_scope, organisation, version) do
        {:ok, Repo.preload(version, :author)}
      end
    end)
  end

  @doc """
  machine_key_types/1 is the newest version of each workspace type whose document uses
  the machine type key `key` (`Apiary.MachineTypes.uses_key?/2`), by type.
  """
  @spec machine_key_types(String.t()) :: [TypeTemplate.t()]
  def machine_key_types(key) when is_binary(key) do
    Repo.all(
      from t in TypeTemplate,
        distinct: t.type,
        order_by: [asc: t.type, desc: t.number]
    )
    |> Enum.filter(&Apiary.MachineTypes.uses_key?(&1.document, key))
  end

  @doc """
  rekey_machine/3 saves, for each version of `machine_key_types/1` for `from` that an
  instance admin saved, a newer version of its type whose document has the key `to` in
  each place that had `from`, with the same texts, authored by the scope's person, the
  instance admin who changed the key, with an entry `workspace_type.edit` each that has
  `machine_key`, the key before and after. A copy of the Qory harness's process
  (`release` set) stays as it is: its runs start on the default type until the harness
  changes the key. Called by `Apiary.MachineTypes.update/3`, in its transaction, which
  checks `machine_type.rekey` and holds the table of machine types. Each type is locked
  as a save locks it, and its newest version read again under the lock. `{:ok, count}`,
  the number of versions saved; `{:error, :forbidden}` on an instance with no instance
  organisation; or `{:error, :stale}` where a version of the type with the next number
  exists.
  """
  @spec rekey_machine(Scope.t(), String.t(), String.t()) ::
          {:ok, non_neg_integer} | {:error, :forbidden | :stale}
  def rekey_machine(%Scope{} = scope, from, to) when is_binary(from) and is_binary(to) do
    Enum.reduce_while(machine_key_types(from), {:ok, 0}, fn %TypeTemplate{type: type},
                                                            {:ok, saved} ->
      :ok = lock(type)
      newest = newest_row(type)
      document = Apiary.MachineTypes.rekey(newest.document, from, to)
      texts = Map.take(newest, @texts)

      with true <- is_nil(newest.release) || :unchanged,
           true <- Apiary.MachineTypes.uses_key?(newest.document, from) || :unchanged,
           {:ok, instance_scope, organisation} <- instance_scope(scope),
           {:ok, version} <- insert(scope, type, newest, document, texts),
           {:ok, _entry} <-
             record(instance_scope, organisation, version, %{machine_key: %{from: from, to: to}}) do
        {:cont, {:ok, saved + 1}}
      else
        :unchanged -> {:cont, {:ok, saved}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc """
  validate/1 checks a type's process: `Apiary.Processes.validate/1`, then that no gate
  lists people. `:ok`, or `{:error, errors}`.
  """
  @spec validate(term) :: :ok | {:error, [Processes.error()]}
  def validate(document) do
    with :ok <- Processes.validate(document) do
      case named_approvers(document["stages"]) do
        [] -> :ok
        errors -> {:error, errors}
      end
    end
  end

  defp named_approvers(stages) do
    for {stage, index} <- Enum.with_index(stages),
        is_map(get_in(stage, ["gate", "approvers"])),
        do: %{path: "#/stages/#{index}/gate/approvers", error: :named_approvers, detail: nil}
  end

  defp based_on(%TypeTemplate{number: number}), do: number
  defp based_on(number) when is_integer(number) or is_nil(number), do: number

  defp known(type) do
    case domain(type) do
      nil -> {:error, :unknown_type}
      domain -> {:ok, domain}
    end
  end

  defp fresh(_newest, nil), do: :ok
  defp fresh(%TypeTemplate{number: number}, number), do: :ok
  defp fresh(_newest, _based_on), do: {:error, :stale}

  # The texts the save keeps (§ Texts).
  defp texts(nil, _type, newest), do: {:ok, Map.take(newest, @texts)}

  defp texts(%{} = texts, type, _newest) do
    defaults = Processes.type_text_defaults(type)
    limits = TypeTemplate.limits()
    words = TypeTemplate.word_limit()

    Enum.reduce_while(@texts, {:ok, %{}}, fn text, {:ok, kept} ->
      value = kept_text(Map.get(texts, text), defaults[text])

      # Characters counted in code points, as the table's check counts them; words as the
      # runs between white space.
      cond do
        value && length(String.codepoints(value)) > limits[text] ->
          {:halt, {:error, {:too_long, text, limits[text]}}}

        value && text == :description && length(String.split(value)) > words ->
          {:halt, {:error, {:too_many_words, :description, words}}}

        true ->
          {:cont, {:ok, Map.put(kept, text, value)}}
      end
    end)
  end

  defp kept_text(value, default) when is_binary(value) do
    case value |> String.replace("\r\n", "\n") |> String.trim() do
      "" -> nil
      ^default -> nil
      value -> value
    end
  end

  defp kept_text(_none, _default), do: nil

  defp changed(%TypeTemplate{document: document} = newest, document, texts) do
    if Map.take(newest, @texts) == texts,
      do: {:error, [%{path: "#", error: :unchanged, detail: nil}]},
      else: :ok
  end

  defp changed(_newest, _document, _texts), do: :ok

  # The scope the entry is recorded with: the admin's, in the instance's organisation,
  # whose trail holds it.
  defp instance_scope(%Scope{} = scope) do
    with id when is_binary(id) <- Apiary.Edition.instance_organisation_id(),
         %Organisation{} = organisation <- Repo.get(Organisation, id) do
      {:ok, Scope.in_organisation(scope, organisation), organisation}
    else
      _none -> {:error, :forbidden}
    end
  end

  defp insert(%Scope{user: user}, type, newest, document, texts) do
    %TypeTemplate{
      type: type,
      number: newest.number + 1,
      document: document,
      author_id: user.id,
      based_on: newest.number,
      name: texts.name,
      summary: texts.summary,
      description: texts.description
    }
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.unique_constraint([:type, :number],
      name: :type_template_versions_type_number_index
    )
    |> Repo.insert()
    |> case do
      {:ok, version} -> {:ok, version}
      {:error, %Ecto.Changeset{}} -> {:error, :stale}
    end
  end

  defp record(scope, organisation, version, details \\ %{}) do
    Audit.record(Repo, scope, :"workspace_type.edit", organisation, %{
      after: %{type: version.type, version: version.number},
      details:
        Map.merge(
          %{
            change: "save",
            type: version.type,
            number: version.number,
            based_on: version.based_on
          },
          details
        )
    })
  end

  ## The Qory harness's default

  defp domain(type) do
    Enum.find(Domain.choices(), &(Domain.definition(&1).key == type))
  end

  # The type's newest row, after the insert of the process of the Qory harness at
  # `commit` where the type has none, or where its newest row copies another process of
  # the Qory harness's. Nil for a type with no row and no files of `commit` kept.
  defp ensure(type, commit) do
    document = Processes.template_process(commit)
    row = newest_row(type)

    if current?(row, document), do: row, else: seed(type, document)
  end

  # Whether `row` stays the newest: an instance admin's save, the copy of `document`, or
  # any row where no process of the Qory harness is kept.
  defp current?(%TypeTemplate{release: nil}, _document), do: true
  defp current?(%TypeTemplate{document: document}, document), do: true
  defp current?(_row, nil), do: true
  defp current?(_row, _document), do: false

  defp seed(type, document) do
    {:ok, row} =
      Repo.transact(fn ->
        :ok = lock(type)
        row = newest_row(type)

        if current?(row, document) do
          {:ok, row}
        else
          {:ok, _inserted} =
            Repo.insert(
              %TypeTemplate{
                type: type,
                number: if(row, do: row.number + 1, else: 1),
                document: document,
                release: if(row, do: row.release + 1, else: 1)
              },
              on_conflict: :nothing,
              conflict_target: [:type, :number]
            )

          {:ok, newest_row(type)}
        end
      end)

    row
  end

  defp newest_row(type) do
    Repo.one(from t in TypeTemplate, where: t.type == ^type, order_by: [desc: t.number], limit: 1)
  end

  defp lock(type) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      "apiary:type-template:" <> type
    ])

    :ok
  end
end
