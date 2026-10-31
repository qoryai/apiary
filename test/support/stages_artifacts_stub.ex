defmodule Apiary.StagesArtifactsStub do
  @moduledoc """
  A stand-in for `Apiary.Artifacts` while it is built on another branch: the functions
  the stage runner calls through `Apiary.Stages.Artifacts`, kept in an ETS table by work
  item, with versions shaped as `Apiary.Artifacts.list/1` gives them. Configured for the
  tests in `config/test.exs`; it goes once `Apiary.Artifacts` is merged.
  """

  @table __MODULE__

  @doc """
  move_during_push/2 sets the stage a push of the work item reads under its lock to
  `stage_id`, as an approve or a move that commits between a caller's read and its push.
  """
  def move_during_push(%{id: id}, stage_id) do
    table()
    true = :ets.insert(@table, {{:stage, id}, stage_id})
    :ok
  end

  @doc """
  push/5 keeps a new version, numbered after the artifact's newest. With
  `opts[:expect_stage]`, a work item in another stage is `{:error, :stage_changed}` and
  nothing is kept, as `Apiary.Artifacts.push/5` does; nil is a value, not an absent option.
  """
  def push(actor, work_item, type, files, opts) do
    table()

    case Keyword.fetch(opts, :expect_stage) do
      :error -> keep(actor, work_item, type, files, opts)
      {:ok, stage_id} -> keep_in(stage_id, actor, work_item, type, files, opts)
    end
  end

  defp keep_in(stage_id, actor, work_item, type, files, opts) do
    if stage_id == held_stage(work_item),
      do: keep(actor, work_item, type, files, opts),
      else: {:error, :stage_changed}
  end

  defp held_stage(%{id: id, stage_id: stage_id}) do
    case :ets.lookup(@table, {:stage, id}) do
      [{_key, moved_to}] -> moved_to
      [] -> stage_id
    end
  end

  defp keep(actor, work_item, type, files, opts) do
    name = Keyword.get(opts, :name, "main")
    {writer, run_id, user_id} = writer(actor)

    number =
      work_item
      |> versions()
      |> Enum.filter(&(&1.artifact.type == type and &1.artifact.name == name))
      |> Enum.map(& &1.number)
      |> Enum.max(fn -> 0 end)
      |> Kernel.+(1)

    version = %{
      public_id: Apiary.PublicId.generate("av"),
      number: number,
      writer: writer,
      run_id: run_id,
      user_id: user_id,
      stage_id: Keyword.get(opts, :stage_id),
      expect_stage: Keyword.get(opts, :expect_stage),
      note: Keyword.get(opts, :note),
      inserted_at: DateTime.utc_now(),
      artifact: %{type: type, name: name},
      files:
        Enum.map(files, fn file ->
          %{filename: file.filename, content: Map.get(file, :binary) || File.read!(file.path)}
        end)
    }

    true = :ets.insert(@table, {work_item.id, version})
    {:ok, version}
  end

  @doc "list/1 is the work item's artifacts by type and name, versions newest first."
  def list(work_item) do
    work_item
    |> versions()
    |> Enum.group_by(&{&1.artifact.type, &1.artifact.name})
    |> Enum.sort()
    |> Enum.map(fn {{type, name}, versions} ->
      %{type: type, name: name, versions: Enum.sort_by(versions, & &1.number, :desc)}
    end)
  end

  @doc "exists?/3 is whether a version of `type` was made in `stage_id`."
  def exists?(work_item, stage_id, type) do
    work_item
    |> versions()
    |> Enum.any?(&(&1.artifact.type == type and &1.stage_id == stage_id))
  end

  @doc "open_file/1 is a file's content as a stream."
  def open_file(%{content: content}), do: {:ok, [content]}

  defp versions(%{id: id}) do
    table()
    for {_id, version} <- :ets.lookup(@table, id), do: version
  end

  defp writer({:run, %{id: run_id}}), do: {:run, run_id, nil}
  defp writer({:person, %{user: %{id: user_id}}}), do: {:person, nil, user_id}

  # The table, made once by a process that lives as long as the test run, so a test that
  # ends does not take it with it.
  defp table do
    if :ets.whereis(@table) == :undefined do
      parent = self()

      spawn(fn ->
        try do
          :ets.new(@table, [:named_table, :public, :duplicate_bag])
        rescue
          ArgumentError -> :ok
        end

        send(parent, :table_ready)
        Process.sleep(:infinity)
      end)

      receive do
        :table_ready -> :ok
      after
        5_000 -> :ok
      end
    end

    :ok
  end
end
