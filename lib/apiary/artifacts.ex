defmodule Apiary.Artifacts do
  # Artifacts stores the results of a work item's runs and people's edits: artifacts by
  # type and name (`Apiary.Artifacts.Artifact`), each with numbered versions
  # (`Apiary.Artifacts.Version`) of one or more files (`Apiary.Artifacts.ArtifactFile`),
  # whose content is in a store (`Apiary.Artifacts.Store`). Every artifact is untrusted
  # data: a page shows it only in the views Qory Apiary ships.
  #
  # ## Types
  #
  # `types(workspace)` is the ten standard types and the workspace's custom types, and
  # `type(workspace, name)` one of them, nil for a name neither has
  # (`Apiary.Artifacts.Type`). `create_type/3`, `update_type/3` and `delete_type/2` edit
  # a workspace's custom types, the Artifact types section of its settings: each checks
  # `artifact_type.edit` with `Apiary.Access` and writes its entry in the audit trail, about
  # the workspace. A custom type's name and base view are fixed once it is made. A type
  # is deleted only while no artifact of the workspace has its name, else `:in_use`.
  #
  # ## A push
  #
  # `push(actor, work_item, type, files, opts)` stores a new version of the work item's
  # artifact of `type` and `opts[:name]`, `main` unless given, made in the stage
  # `opts[:stage_id]`, with the writer's `opts[:note]`. `actor` is `{:run, run}`, a run of
  # the queue (`Apiary.Dispatches.DispatchRun`) of that work item, or `{:person, scope}`,
  # a person who may `artifact.write` the work item (`Apiary.Access`), whose push writes
  # its entry in the audit trail. A run writes only the types in `opts[:writes]`, any type
  # when it is `:any`, the default, and always `verdict` and `questions`.
  #
  # `files` is a list of `%{filename: name, content_type: text, path: path}` or
  # `%{filename: name, content_type: text, binary: bytes}`; `content_type` is read by
  # nothing (`Apiary.Artifacts.Format` decides it from the bytes). The checks, in order,
  # each refusal `{:error, {code, detail}}`:
  #
  #   1. the actor: a person whom `Apiary.Access` refuses `artifact.write` on the work
  #      item, `{:error, :not_found}` or `{:error, :forbidden}`; a run of another work
  #      item, `{:error, :not_found}`;
  #   2. the type: a name of no type, `{:unknown_type, name}`; a name of the wrong form,
  #      `{:invalid, :type}`;
  #   3. a run's writes: `{:not_writable, type}`;
  #   4. the options: `{:invalid, :name | :stage_id | :note}`;
  #   5. the files: none, `{:invalid, :no_files}`; more than the type's most,
  #      `{:too_many_files, max_files}`; an entry of the wrong shape, a filename
  #      `Apiary.Artifacts.Filename` refuses, or a filename twice,
  #      `{:invalid, {:file | :filename | :duplicate_filename, index}}`, `index` the
  #      entry's position from 0;
  #   6. each file is staged within what is left of the type's size limit, which bounds
  #      all files of a version together: past it, `{:too_large, size_limit}`, the
  #      source read at most 64 KiB past the limit; a path that cannot be read,
  #      `{:invalid, {:unreadable, index}}`;
  #   7. each staged file passes its base view's format check, else
  #      `{:invalid, {:format | :extension | :schema | :unreadable, index}}`;
  #   8. a version of a video type has an MP4 or WebM file beside its WebVTT captions,
  #      else `{:invalid, :no_video}`.
  #
  # Then every file is kept in the store, and only then are the rows written, in one
  # transaction: the work item locked `FOR UPDATE`, read again in the workspace it was
  # in, else `{:error, :not_found}`; the artifact found or made; the next number, one
  # more than the highest; the version and its files. The lock makes the transactions of
  # pushes to one work item run one after the other, so the numbers of an artifact are
  # 1, 2, … with no gap. A refusal, or a failure of the transaction, writes no row; a
  # file kept in the store before it stays there (a content address that a later version
  # may share). A store with no root, or one that cannot write, is
  # `{:error, :store_unavailable}`.
  #
  # Once the push's transaction commits, `{:artifact_pushed, work_item_id, version_id}`,
  # the work item's public id (`wi_…`) and the version's (`av_…`), goes to the work item's
  # artifacts topic (`topic/1`), so its pages show the version. A push called inside an
  # outer transaction sends the message when its transaction ends, before the outer one
  # commits: a page that reads at once may not find the version yet, or find none should
  # the outer transaction roll back.
  #
  # ## Reading
  #
  # `list(work_item)` is the work item's artifacts by type and name, each with its
  # versions, newest first, and their files by filename; `versions(artifact)` an
  # artifact's versions, newest first, with their files; `newest(work_item, type, name)`
  # the version with the highest number, or nil; `get_version!(id)` a version by its
  # public id (`av_…`), with its artifact and files; `open_file(file)` a file's stored
  # copy, a path or a stream of its bytes. Each version comes with its `user`, the
  # person who made it, and its `run`, the run of the queue that made it, where the row
  # is there; that run comes with its `run`, the run its claim registered
  # (`Apiary.Runs.Run`, with its id, public id and `dispatch_run_id` only), or nil before
  # a claim. These read no scope: the caller has read the work item through
  # `Apiary.Access`.
  #
  # `exists?(work_item, stage_id, type)` is the Exists check of a stage's output: whether
  # the work item has a version of `type`, of any name, made in `stage_id`, whose files
  # are what the type's base view takes, by the content types the format check kept at
  # the push (`Apiary.Artifacts.Format.stored?/2`); no file is read again. False for a
  # type the workspace does not have.
  #
  # Left out of the documentation at `/docs` (`@moduledoc false`), as the work items are.
  @moduledoc false

  import Ecto.Query, warn: false

  alias Apiary.{Access, Audit, PublicId, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Artifacts.{Artifact, ArtifactFile, CustomSchema, Filename, Format, Store, Type}
  alias Apiary.Artifacts.Version
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Organisations.Workspace
  alias Apiary.WorkItems.WorkItem

  # The access actions of artifacts, of the feature `workflow_model` (`Apiary.Access`):
  # where the feature is off or hidden from the person, `authorize/3` refuses them as
  # `{:error, :not_found}`.
  @write :"artifact.write"
  @edit_types :"artifact_type.edit"

  # What a run writes whatever its workflow's writes list.
  @always_writable ~w(verdict questions)

  @stage_id ~r/\A[A-Za-z0-9_-]{1,64}\z/
  @max_note 4000
  @refused_in_note ~r/(?![\x{9}\x{A}\x{200C}\x{200D}])[\p{Cc}\p{Cf}\x{2028}\x{2029}]/u

  @typedoc "Who pushes a version: a run of the queue, or a person."
  @type actor :: {:run, DispatchRun.t()} | {:person, Scope.t()}

  @typedoc "A file of a push."
  @type file ::
          %{
            required(:filename) => String.t(),
            optional(:content_type) => String.t(),
            optional(:path) => Path.t(),
            optional(:binary) => binary
          }

  @typedoc "Why a push is refused."
  @type refusal ::
          {:unknown_type | :too_many_files | :too_large | :not_writable | :invalid, term}

  ## Types

  @doc false
  @spec types(Workspace.t()) :: [Type.t()]
  def types(%Workspace{id: workspace_id}) do
    custom =
      Repo.all(from t in Type, where: t.workspace_id == ^workspace_id, order_by: t.name)

    Type.standard() ++ custom
  end

  @doc false
  @spec type(Workspace.t(), term) :: Type.t() | nil
  def type(%Workspace{id: workspace_id}, name) when is_binary(name) do
    case Enum.find(Type.standard(), &(&1.name == name)) do
      %Type{} = standard ->
        standard

      nil ->
        if Type.name?(name),
          do: Repo.one(from t in Type, where: t.workspace_id == ^workspace_id and t.name == ^name)
    end
  end

  def type(%Workspace{}, _name), do: nil

  # create_type/3 makes a custom type in `workspace`: `{:ok, type}`,
  # `{:error, :not_found | :forbidden}`, or `{:error, changeset}`. `attrs` has `name`,
  # `base_view`, `size_limit`, `max_files` and, for a structured type, `json_schema`, a
  # map or its JSON text.
  @doc false
  @spec create_type(Scope.t(), Workspace.t(), map) ::
          {:ok, Type.t()} | {:error, :not_found | :forbidden | Ecto.Changeset.t()}
  def create_type(%Scope{} = scope, %Workspace{} = workspace, attrs) do
    Repo.transact(fn ->
      with :ok <- authorize(scope, @edit_types, workspace),
           {:ok, changeset} <-
             %Type{organisation_id: workspace.organisation_id, workspace_id: workspace.id}
             |> Type.create_changeset(json_attrs(attrs))
             |> checked_schema(),
           {:ok, type} <- PublicId.Insert.insert(changeset),
           {:ok, _entry} <- audit_type(scope, workspace, :create, type) do
        {:ok, type}
      end
    end)
  end

  # update_type/3 changes a custom type's size limit, most files and JSON Schema.
  @doc false
  @spec update_type(Scope.t(), Type.t(), map) ::
          {:ok, Type.t()} | {:error, :not_found | :forbidden | Ecto.Changeset.t()}
  def update_type(%Scope{} = scope, %Type{standard: false} = type, attrs) do
    Repo.transact(fn ->
      with :ok <- authorize(scope, @edit_types, type),
           %Type{} = held <- held_type(type),
           {:ok, changeset} <-
             held |> Type.update_changeset(json_attrs(attrs)) |> checked_schema(),
           {:ok, updated} <- Repo.update(changeset),
           {:ok, _entry} <- audit_type(scope, workspace_of(held), :update, updated) do
        {:ok, updated}
      else
        nil -> {:error, :not_found}
        {:error, _refusal} = refused -> refused
      end
    end)
  end

  def update_type(%Scope{}, %Type{}, _attrs), do: {:error, :not_found}

  # delete_type/2 deletes a custom type no artifact of its workspace has: `{:ok, type}`,
  # `{:error, :in_use}`, or `{:error, :not_found | :forbidden}`.
  @doc false
  @spec delete_type(Scope.t(), Type.t()) ::
          {:ok, Type.t()} | {:error, :not_found | :forbidden | :in_use}
  def delete_type(%Scope{} = scope, %Type{standard: false} = type) do
    Repo.transact(fn ->
      with :ok <- authorize(scope, @edit_types, type),
           %Type{} = held <- held_type(type),
           false <- in_use?(held),
           {:ok, deleted} <- Repo.delete(held),
           {:ok, _entry} <- audit_type(scope, workspace_of(held), :delete, held) do
        {:ok, deleted}
      else
        nil -> {:error, :not_found}
        true -> {:error, :in_use}
        {:error, _refusal} = refused -> refused
      end
    end)
  end

  def delete_type(%Scope{}, %Type{}), do: {:error, :not_found}

  # The type's row, locked `FOR UPDATE` until the change commits; nil once it is gone.
  defp held_type(%Type{id: id, workspace_id: workspace_id}) do
    Repo.one(
      from t in Type,
        where: t.id == ^id and t.workspace_id == ^workspace_id,
        lock: "FOR UPDATE"
    )
  end

  defp in_use?(%Type{workspace_id: workspace_id, name: name}) do
    Repo.exists?(from a in Artifact, where: a.workspace_id == ^workspace_id and a.type == ^name)
  end

  defp workspace_of(%Type{workspace_id: workspace_id}), do: Repo.get!(Workspace, workspace_id)

  # A form sends the schema as JSON text: decoded here, so the changeset casts a map. A
  # text of more than 262,144 bytes, four times the most a schema has as canonical JSON
  # (`Apiary.Artifacts.CustomSchema`), is not decoded, and the cast refuses it.
  defp json_attrs(attrs) do
    attrs = Map.new(attrs)

    Enum.reduce([:json_schema, "json_schema"], attrs, fn key, attrs ->
      case attrs do
        %{^key => text} when is_binary(text) and byte_size(text) <= 262_144 ->
          case Jason.decode(text) do
            {:ok, decoded} -> Map.put(attrs, key, decoded)
            {:error, _reason} -> Map.put(attrs, key, text)
          end

        _other ->
          attrs
      end
    end)
  end

  defp checked_schema(%Ecto.Changeset{valid?: false} = changeset), do: {:error, changeset}

  defp checked_schema(changeset) do
    case Ecto.Changeset.fetch_change(changeset, :json_schema) do
      {:ok, schema} when is_map(schema) ->
        case CustomSchema.check(schema) do
          :ok ->
            {:ok, changeset}

          {:error, refusal} ->
            {:error,
             Ecto.Changeset.add_error(
               changeset,
               :json_schema,
               "is not a schema Qory Apiary takes",
               validation: refusal
             )}
        end

      _none ->
        {:ok, changeset}
    end
  end

  defp audit_type(scope, workspace, change, %Type{} = type) do
    Audit.record(Repo, scope, @edit_types, workspace, %{
      details: %{"change" => Atom.to_string(change), "type" => type.name}
    })
  end

  ## A push

  @doc false
  @spec push(actor, WorkItem.t(), term, [file], keyword) ::
          {:ok, Version.t()}
          | {:error, refusal | :not_found | :forbidden | :store_unavailable}
  def push(actor, %WorkItem{} = work_item, type_name, files, opts \\ []) do
    with {:ok, work_item} <- current(work_item),
         {:ok, writer} <- writer(actor, work_item),
         {:ok, type} <- push_type(work_item, type_name),
         :ok <- writable(writer, type, Keyword.get(opts, :writes, :any)),
         {:ok, fields} <- fields(opts),
         {:ok, files} <- files(type, files),
         {:ok, staged} <- stage_all(type, files),
         :ok <- complete(type, staged) do
      case commit_all(staged) do
        {:ok, stored} -> writer |> write(work_item, type, fields, stored) |> broadcast()
        {:error, _reason} = error -> error
      end
    end
  end

  # topic/1 is the PubSub topic of the work item's artifacts (`"artifacts:<work item
  # id>"`, its internal id): after each push, `{:artifact_pushed, work_item_id,
  # version_id}`, with the work item's public id (`wi_…`) and the version's (`av_…`). One
  # topic per work item, so that only its pages get the message.
  @doc false
  @spec topic(WorkItem.t()) :: String.t()
  def topic(%WorkItem{id: id}) when is_binary(id), do: "artifacts:" <> id

  # subscribe/2 subscribes the caller to the work item's artifacts topic (`topic/1`), for
  # a person who may read the work item (`work_item.read`): `:ok`, or `Apiary.Access`'s
  # refusal.
  @doc false
  @spec subscribe(Scope.t(), WorkItem.t()) :: :ok | {:error, Access.reason()}
  def subscribe(%Scope{} = scope, %WorkItem{} = work_item) do
    with :ok <- Access.authorize(scope, :"work_item.read", work_item),
         do: Phoenix.PubSub.subscribe(Apiary.PubSub, topic(work_item))
  end

  # After the push's transaction ends, the work item's pages hear of the new version
  # (`topic/1`), with the work item's public id as the transaction read it.
  defp broadcast({:ok, {%Version{} = version, %WorkItem{} = held}}) do
    Phoenix.PubSub.broadcast(
      Apiary.PubSub,
      topic(held),
      {:artifact_pushed, held.public_id, version.public_id}
    )

    {:ok, version}
  end

  defp broadcast(refused), do: refused

  # The work item as it is now, unlocked: the transaction reads it again under its lock.
  defp current(%WorkItem{id: id}) do
    case Ecto.UUID.cast(id) do
      {:ok, id} ->
        case Repo.get(WorkItem, id) do
          %WorkItem{} = found -> {:ok, found}
          nil -> {:error, :not_found}
        end

      :error ->
        {:error, :not_found}
    end
  end

  defp writer({:person, %Scope{user: %{id: user_id}} = scope}, work_item)
       when is_binary(user_id) do
    with :ok <- authorize(scope, @write, work_item),
         do: {:ok, %{writer: :person, user_id: user_id, run_id: nil, scope: scope}}
  end

  defp writer({:run, %DispatchRun{id: run_id} = run}, %WorkItem{} = work_item)
       when is_binary(run_id) do
    if run.work_item_id == work_item.id and run.organisation_id == work_item.organisation_id,
      do: {:ok, %{writer: :run, user_id: nil, run_id: run_id, scope: nil}},
      else: {:error, :not_found}
  end

  defp writer(_actor, _work_item), do: {:error, :not_found}

  # The one call site of `Apiary.Access` for this module's actions.
  defp authorize(scope, action, subject), do: Access.authorize(scope, action, subject)

  defp push_type(work_item, name) do
    workspace = %Workspace{id: work_item.workspace_id, organisation_id: work_item.organisation_id}

    cond do
      not Type.name?(name) -> {:error, {:invalid, :type}}
      type = type(workspace, name) -> {:ok, type}
      true -> {:error, {:unknown_type, name}}
    end
  end

  defp writable(%{writer: :person}, _type, _writes), do: :ok
  defp writable(%{writer: :run}, _type, :any), do: :ok

  defp writable(%{writer: :run}, %Type{name: name}, writes) when is_list(writes) do
    if name in @always_writable or name in writes,
      do: :ok,
      else: {:error, {:not_writable, name}}
  end

  defp writable(%{writer: :run}, %Type{name: name}, _writes),
    do: {:error, {:not_writable, name}}

  defp fields(opts) do
    name = Keyword.get(opts, :name, "main")
    stage_id = Keyword.get(opts, :stage_id)
    note = normal_note(Keyword.get(opts, :note))

    cond do
      not Type.name?(name) -> {:error, {:invalid, :name}}
      not stage_id?(stage_id) -> {:error, {:invalid, :stage_id}}
      not note?(note) -> {:error, {:invalid, :note}}
      true -> {:ok, %{name: name, stage_id: stage_id, note: note}}
    end
  end

  defp stage_id?(nil), do: true
  defp stage_id?(id) when is_binary(id), do: Regex.match?(@stage_id, id)
  defp stage_id?(_id), do: false

  # A note's line breaks become line feeds and it is trimmed; empty, it is none.
  defp normal_note(note) when is_binary(note) do
    if String.valid?(note) do
      case note |> String.replace(["\r\n", "\r"], "\n") |> String.trim() do
        "" -> nil
        text -> text
      end
    else
      note
    end
  end

  defp normal_note(note), do: note

  defp note?(nil), do: true

  # The length is counted in code points, as the database's `char_length` counts it
  # (`artifact_versions_note_check`): "é" written as "e" and U+0301 is one grapheme and
  # two code points.
  defp note?(note) when is_binary(note) do
    byte_size(note) <= 4 * @max_note and String.valid?(note) and
      length(String.to_charlist(note)) <= @max_note and
      not Regex.match?(@refused_in_note, note)
  end

  defp note?(_note), do: false

  defp files(_type, []), do: {:error, {:invalid, :no_files}}

  defp files(%Type{max_files: max}, files) when is_list(files) do
    if length(files) > max do
      {:error, {:too_many_files, max}}
    else
      files
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, [], MapSet.new()}, fn {file, index}, {:ok, acc, seen} ->
        case source(file) do
          {:ok, filename, source} ->
            cond do
              not Filename.valid?(filename) ->
                {:halt, {:error, {:invalid, {:filename, index}}}}

              MapSet.member?(seen, filename) ->
                {:halt, {:error, {:invalid, {:duplicate_filename, index}}}}

              true ->
                {:cont, {:ok, [{index, filename, source} | acc], MapSet.put(seen, filename)}}
            end

          :error ->
            {:halt, {:error, {:invalid, {:file, index}}}}
        end
      end)
      |> case do
        {:ok, files, _seen} -> {:ok, Enum.reverse(files)}
        {:error, _refusal} = refused -> refused
      end
    end
  end

  defp files(_type, _files), do: {:error, {:invalid, :no_files}}

  defp source(%{filename: filename, path: path}) when is_binary(path),
    do: {:ok, filename, {:path, path}}

  defp source(%{filename: filename, binary: binary}) when is_binary(binary),
    do: {:ok, filename, {:binary, binary}}

  defp source(_file), do: :error

  # Each file staged within what is left of the size limit, then checked; on a refusal,
  # every staged copy is dropped.
  defp stage_all(%Type{size_limit: limit} = type, files) do
    store = Store.impl()

    files
    |> Enum.reduce_while({:ok, [], 0}, fn {index, filename, source}, {:ok, acc, used} ->
      case stage_one(store, type, index, filename, source, limit - used) do
        {:ok, staged} -> {:cont, {:ok, [staged | acc], used + staged.size}}
        {:error, refusal} -> {:halt, {:error, refusal, acc}}
      end
    end)
    |> case do
      {:ok, staged, _used} ->
        {:ok, Enum.reverse(staged)}

      {:error, refusal, staged} ->
        Enum.each(staged, &store.discard(&1.staged))
        {:error, refusal}
    end
  end

  # A version of a video type has a video, not captions alone; else every staged copy is
  # dropped.
  defp complete(%Type{base_view: :video}, staged) do
    if Format.video?(Enum.map(staged, & &1.content_type)) do
      :ok
    else
      store = Store.impl()
      Enum.each(staged, &store.discard(&1.staged))
      {:error, {:invalid, :no_video}}
    end
  end

  defp complete(_type, _staged), do: :ok

  defp stage_one(store, type, index, filename, source, left) do
    case store.stage(source, left) do
      {:ok, staged} ->
        case Format.check(type, filename, staged.path) do
          {:ok, content_type} ->
            {:ok,
             %{
               staged: staged,
               filename: filename,
               content_type: content_type,
               size: staged.size,
               sha256: staged.sha256
             }}

          {:error, reason} ->
            store.discard(staged)
            {:error, {:invalid, {reason, index}}}
        end

      {:error, :too_large} ->
        {:error, {:too_large, type.size_limit}}

      {:error, :unreadable} ->
        {:error, {:invalid, {:unreadable, index}}}

      {:error, _reason} ->
        {:error, :store_unavailable}
    end
  end

  defp commit_all(staged) do
    store = Store.impl()

    staged
    |> Enum.reduce_while({:ok, []}, fn file, {:ok, acc} ->
      case store.commit(file.staged) do
        {:ok, key} -> {:cont, {:ok, [Map.put(file, :store_key, key) | acc]}}
        {:error, _reason} -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, stored} ->
        {:ok, Enum.reverse(stored)}

      :error ->
        Enum.each(staged, &store.discard(&1.staged))
        {:error, :store_unavailable}
    end
  end

  defp write(writer, work_item, type, fields, stored) do
    Repo.transact(fn ->
      now = DateTime.utc_now()

      with %WorkItem{} = held <- held_work_item(work_item),
           :ok <- type_kept(type),
           {:ok, artifact} <- artifact(held, type, fields, now),
           {:ok, version} <- version(artifact, writer, fields, now),
           :ok <- insert_files(version, stored),
           :ok <- audit_push(writer, held, artifact, version) do
        {:ok, {Repo.preload(%{version | artifact: artifact}, files: files_query()), held}}
      else
        nil -> {:error, :not_found}
        {:error, _reason} = error -> error
      end
    end)
  end

  # The work item held `FOR UPDATE`, where it was when the push read it; nil once it
  # moved to another workspace or went.
  defp held_work_item(%WorkItem{id: id, workspace_id: workspace_id}) do
    Repo.one(
      from w in WorkItem,
        where: w.id == ^id and w.workspace_id == ^workspace_id,
        lock: "FOR UPDATE"
    )
  end

  # A custom type locked `FOR SHARE` until the push commits, so a deletion of the type,
  # which locks it `FOR UPDATE` before it counts the artifacts of its name, runs before or
  # after the push and not between its check and its rows.
  defp type_kept(%Type{standard: true}), do: :ok

  defp type_kept(%Type{id: id, name: name}) do
    case Repo.one(from t in Type, where: t.id == ^id, lock: "FOR SHARE", select: t.id) do
      nil -> {:error, {:unknown_type, name}}
      _id -> :ok
    end
  end

  defp artifact(held, type, fields, now) do
    case Repo.one(
           from a in Artifact,
             where: a.work_item_id == ^held.id and a.type == ^type.name and a.name == ^fields.name
         ) do
      %Artifact{} = artifact ->
        {:ok, artifact}

      nil ->
        PublicId.Insert.insert(%Artifact{
          public_id: PublicId.generate(Artifact.prefix()),
          organisation_id: held.organisation_id,
          workspace_id: held.workspace_id,
          work_item_id: held.id,
          type: type.name,
          name: fields.name,
          stage_id: fields.stage_id,
          inserted_at: now
        })
    end
  end

  defp version(artifact, writer, fields, now) do
    highest =
      Repo.one(from v in Version, where: v.artifact_id == ^artifact.id, select: max(v.number))

    PublicId.Insert.insert(%Version{
      public_id: PublicId.generate(Version.prefix()),
      organisation_id: artifact.organisation_id,
      workspace_id: artifact.workspace_id,
      artifact_id: artifact.id,
      number: (highest || 0) + 1,
      writer: writer.writer,
      run_id: writer.run_id,
      user_id: writer.user_id,
      stage_id: fields.stage_id,
      note: fields.note,
      inserted_at: now
    })
  end

  defp insert_files(version, stored) do
    rows =
      for file <- stored do
        %{
          id: Ecto.UUID.generate(),
          organisation_id: version.organisation_id,
          workspace_id: version.workspace_id,
          version_id: version.id,
          filename: file.filename,
          content_type: file.content_type,
          size: file.size,
          sha256: file.sha256,
          store_key: file.store_key
        }
      end

    {count, _rows} = Repo.insert_all(ArtifactFile, rows)
    if count == length(rows), do: :ok, else: {:error, :store_unavailable}
  end

  defp audit_push(%{writer: :run}, _work_item, _artifact, _version), do: :ok

  defp audit_push(%{writer: :person, scope: scope}, work_item, artifact, version) do
    with {:ok, _entry} <-
           Audit.record(Repo, scope, @write, work_item, %{
             details: %{
               "artifact_id" => artifact.public_id,
               "version_id" => version.public_id,
               "type" => artifact.type,
               "name" => artifact.name,
               "number" => version.number
             }
           }),
         do: :ok
  end

  ## Reading

  @doc false
  @spec list(WorkItem.t()) :: [Artifact.t()]
  def list(%WorkItem{id: id, workspace_id: workspace_id}) do
    Repo.all(
      from a in Artifact,
        where: a.work_item_id == ^id and a.workspace_id == ^workspace_id,
        order_by: [a.type, a.name],
        preload: [
          versions: ^{versions_query(), [:user, run: [run: runs_query()], files: files_query()]}
        ]
    )
  end

  @doc false
  @spec versions(Artifact.t()) :: [Version.t()]
  def versions(%Artifact{id: id}) do
    Repo.all(
      from v in versions_query(),
        where: v.artifact_id == ^id,
        preload: [:user, run: [run: ^runs_query()], files: ^files_query()]
    )
  end

  @doc false
  @spec newest(WorkItem.t(), String.t(), String.t()) :: Version.t() | nil
  def newest(%WorkItem{id: id, workspace_id: workspace_id}, type, name \\ "main") do
    Repo.one(
      from v in Version,
        join: a in assoc(v, :artifact),
        where:
          a.work_item_id == ^id and a.workspace_id == ^workspace_id and a.type == ^type and
            a.name == ^name,
        order_by: [desc: v.number],
        limit: 1,
        preload: [:user, run: [run: ^runs_query()], artifact: a, files: ^files_query()]
    )
  end

  @doc false
  @spec get_version!(String.t()) :: Version.t()
  def get_version!(id) do
    unless PublicId.valid?(Version.prefix(), id),
      do: raise(Ecto.NoResultsError, queryable: Version)

    Repo.one!(
      from v in Version,
        where: v.public_id == ^id,
        preload: [:artifact, :user, run: [run: ^runs_query()], files: ^files_query()]
    )
  end

  # The run a run of the queue registered when it was claimed (`Apiary.Runs.Run`), for its
  # public id (`rn_…`) and its page: its id and public id, and `dispatch_run_id`, which
  # the preload needs to match each run to its run of the queue.
  defp runs_query,
    do: from(r in Apiary.Runs.Run, select: struct(r, [:id, :public_id, :dispatch_run_id]))

  @doc false
  @spec open_file(ArtifactFile.t()) :: {:ok, Path.t() | Enumerable.t()} | {:error, term}
  def open_file(%ArtifactFile{store_key: key}), do: Store.impl().open(key)

  @doc false
  @spec exists?(WorkItem.t(), String.t(), String.t()) :: boolean
  def exists?(%WorkItem{} = work_item, stage_id, type_name)
      when is_binary(stage_id) and is_binary(type_name) do
    workspace = %Workspace{id: work_item.workspace_id, organisation_id: work_item.organisation_id}

    case type(workspace, type_name) do
      %Type{base_view: base_view} ->
        work_item
        |> made_in(stage_id, type_name)
        |> Enum.any?(&Format.stored?(base_view, &1))

      nil ->
        false
    end
  end

  def exists?(%WorkItem{}, _stage_id, _type_name), do: false

  # The content types of the files of each version of `type`, of any name, made in
  # `stage_id`: a list per version. A version has one file or more.
  defp made_in(%WorkItem{id: id, workspace_id: workspace_id}, stage_id, type) do
    Repo.all(
      from v in Version,
        join: a in assoc(v, :artifact),
        join: f in assoc(v, :files),
        where:
          a.work_item_id == ^id and a.workspace_id == ^workspace_id and a.type == ^type and
            v.stage_id == ^stage_id,
        group_by: v.id,
        select: fragment("array_agg(?)", f.content_type)
    )
  end

  defp versions_query, do: from(v in Version, order_by: [desc: v.number])
  defp files_query, do: from(f in ArtifactFile, order_by: f.filename)
end
