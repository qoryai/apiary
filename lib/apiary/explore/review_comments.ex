defmodule Apiary.Explore.ReviewComments do
  # ReviewComments reads and writes a work item's review comments: the one file of a
  # version of the standard artifact type `review-comments`, name `main`, in the review
  # comments format qory publishes (`priv/schemas/artifacts/review-comments.schema.json`).
  # One document holds every review comment of the work item, in the order members wrote
  # them, each on one version of an artifact (`on`, such as `{"artifact": "proposal",
  # "version": 2}`), with its `state` (`open` or `closed`) and its `replies`, oldest
  # first, by a member or by a run.
  #
  # Qory Apiary writes what members write (`comment/5`, `reply/5`, from
  # `Apiary.WorkItems.Moves`): a review comment is a new entry, `open`; a member's reply
  # is added to the review comment's replies and opens it again. A run reads the open
  # review comments, and in the version it pushes through the run API it may only add its
  # reply to an open review comment and close it (`check_run/3`), else the version is
  # refused with one of these reasons:
  #
  #   * `:id_dropped`: an `id` of the newest version is missing;
  #   * `:comment_added`: a review comment the newest version does not have;
  #   * `:comment_changed`: a review comment's `on`, `text`, `by` or `at` changed;
  #   * `:reply_changed`: a reply of the newest version changed or is missing;
  #   * `:reply_not_run`: a reply the run added is not by the run, by its number;
  #   * `:replies_added`: the run added more than one reply to one review comment;
  #   * `:not_open`: the run added a reply to a review comment that is closed;
  #   * `:not_closed`: the run added a reply and left the review comment open;
  #   * `:state_changed`: the run closed a review comment without a reply, or opened one;
  #   * `:question_unknown`: the run's reply has the outcome `asked` with a `question`
  #     that is not an id of the newest version of the work item's questions stored when
  #     the run pushes the review comments, so a run pushes its questions first.
  #
  # A run is named by its number in the run API (`Apiary.Runs.Run`, `number`), which a
  # member sees as "Run N": a reply's `by.run`.
  #
  # Numbers compare by value, as the schema's integers do: `4.0` is `4`. Qory Apiary stores
  # each number of a version that is an integer in value as an integer
  # (`Apiary.Artifacts.push/5`), so a reader finds `4`, never `4.0`.
  #
  # The schema's checks, and each `id` once, come first, at the format check of the push
  # (`Apiary.Artifacts.Format`).
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  alias Apiary.Artifacts
  alias Apiary.WorkItems.WorkItem

  @type_name "review-comments"
  @name "main"
  @kept ~w(id on text by at)
  @reasons [
    :id_dropped,
    :comment_added,
    :comment_changed,
    :reply_changed,
    :reply_not_run,
    :replies_added,
    :not_open,
    :not_closed,
    :state_changed,
    :question_unknown
  ]

  @typedoc "A review comments document, decoded: a map with string keys."
  @type document :: %{optional(String.t()) => term}

  @typedoc "Why a run's version of the review comments is refused."
  @type reason ::
          :id_dropped
          | :comment_added
          | :comment_changed
          | :reply_changed
          | :reply_not_run
          | :replies_added
          | :not_open
          | :not_closed
          | :state_changed
          | :question_unknown

  # type_name/0 and name/0 are the type and the name of the artifact of a work item's
  # review comments.
  @doc false
  @spec type_name() :: String.t()
  def type_name, do: @type_name

  @doc false
  @spec name() :: String.t()
  def name, do: @name

  # reasons/0 is every reason `check_run/3` refuses a run's version for.
  @doc false
  @spec reasons() :: [reason]
  def reasons, do: @reasons

  ## Reading

  # newest/1 is the newest version of the work item's review comments with its document,
  # `{version, document}`; nil for none, and for a version whose file cannot be read.
  @doc false
  @spec newest(WorkItem.t()) :: {Artifacts.Version.t(), document} | nil
  def newest(%WorkItem{} = work_item) do
    with %{} = version <- Artifacts.newest(work_item, @type_name, @name),
         %{} = document <- read(version) do
      {version, document}
    else
      _none -> nil
    end
  end

  # current/1 is the newest version of the work item's review comments with its document, for a
  # write that builds on it: `{:ok, {version, document}}`; `{:ok, nil}` for no version;
  # and `{:error, :store_unavailable}` for a newest version whose file cannot be read as
  # a document of the format, so a write never takes it for no version and drops what
  # members wrote.
  @doc false
  @spec current(WorkItem.t()) ::
          {:ok, {Artifacts.Version.t(), document} | nil} | {:error, :store_unavailable}
  def current(%WorkItem{} = work_item) do
    case Artifacts.newest(work_item, @type_name, @name) do
      nil -> {:ok, nil}
      version -> with {:ok, document} <- loaded(version), do: {:ok, {version, document}}
    end
  end

  # loaded/1 is the document of `version`, a version of the review comments, for a write:
  # `{:ok, document}`, or `{:error, :store_unavailable}` when `read/1` cannot read it.
  @doc false
  @spec loaded(map) :: {:ok, document} | {:error, :store_unavailable}
  def loaded(version) do
    case read(version) do
      %{} = document -> {:ok, document}
      nil -> {:error, :store_unavailable}
    end
  end

  # read/1 is the document of a version of the review comments, nil when its file cannot
  # be read or is not one JSON object with a list of review comments.
  @doc false
  @spec read(map) :: document | nil
  def read(%{files: [file | _rest]}) do
    with {:ok, source} <- Artifacts.open_file(file),
         {:ok, text} <- bytes(source) do
      decode(text)
    else
      _other -> nil
    end
  end

  def read(_version), do: nil

  # decode/1 is the document of `text`, a file's bytes, nil for one that is not a JSON
  # object with a list of review comments.
  @doc false
  @spec decode(binary) :: document | nil
  def decode(text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, %{"review_comments" => comments} = document} when is_list(comments) -> document
      _other -> nil
    end
  end

  defp bytes(path) when is_binary(path), do: File.read(path)
  defp bytes(stream), do: {:ok, stream |> Enum.to_list() |> IO.iodata_to_binary()}

  # entries/1 is the review comments of `document`, in order; none for nil.
  @doc false
  @spec entries(document | nil) :: [map]
  def entries(%{"review_comments" => comments}) when is_list(comments), do: comments
  def entries(_document), do: []

  ## A run's version

  # check_run/4 checks `document`, the version a run whose number is `run_number` pushes,
  # against `newest`, the newest version's document, nil for none, and `questions`, the
  # ids of the newest version of the work item's questions (the moduledoc): `:ok`, or
  # `{:error, reason}` for the first rule it breaks, the review comments read in order.
  @doc false
  @spec check_run(document | nil, document, pos_integer, [String.t()]) :: :ok | {:error, reason}
  def check_run(newest, %{"review_comments" => comments}, run_number, questions)
      when is_list(comments) and is_list(questions) do
    earlier = entries(newest)
    given = Map.new(comments, &{&1["id"], &1})
    known = MapSet.new(earlier, & &1["id"])

    cond do
      Enum.any?(comments, &(not MapSet.member?(known, &1["id"]))) ->
        {:error, :comment_added}

      true ->
        Enum.reduce_while(earlier, :ok, fn entry, :ok ->
          case kept(entry, Map.get(given, entry["id"]), run_number, questions) do
            :ok -> {:cont, :ok}
            refused -> {:halt, refused}
          end
        end)
    end
  end

  defp kept(_earlier, nil, _run_number, _questions), do: {:error, :id_dropped}

  defp kept(earlier, given, run_number, questions) do
    before = replies(earlier)
    now = replies(given)
    added = Enum.drop(now, length(before))

    cond do
      Map.take(given, @kept) != Map.take(earlier, @kept) ->
        {:error, :comment_changed}

      length(now) < length(before) or Enum.take(now, length(before)) != before ->
        {:error, :reply_changed}

      added == [] and given["state"] != earlier["state"] ->
        {:error, :state_changed}

      added == [] ->
        :ok

      length(added) > 1 ->
        {:error, :replies_added}

      get_in(hd(added), ["by", "run"]) != run_number ->
        {:error, :reply_not_run}

      earlier["state"] != "open" ->
        {:error, :not_open}

      given["state"] != "closed" ->
        {:error, :not_closed}

      asked?(hd(added)) and hd(added)["question"] not in questions ->
        {:error, :question_unknown}

      true ->
        :ok
    end
  end

  defp replies(entry), do: Map.get(entry, "replies") || []

  defp asked?(reply), do: reply["outcome"] == "asked"

  ## What members write

  # comment/5 is `document`, nil for none yet, with a member's review comment `text` on
  # `on`, `%{"artifact" => type, "version" => number}`, by the member named `by` (the
  # explore input's form of a member, `Apiary.Dispatches.Inputs.person_name/1`), at `at`:
  # `{id, document}`, `id` the next free `c<n>`.
  @doc false
  @spec comment(document | nil, map, String.t(), String.t(), DateTime.t()) ::
          {String.t(), document}
  def comment(document, %{} = on, text, by, %DateTime{} = at)
      when is_binary(text) and is_binary(by) do
    comments = entries(document)
    id = next_id(comments)

    entry = %{
      "id" => id,
      "on" => on,
      "text" => text,
      "by" => %{"name" => by},
      "at" => time(at),
      "state" => "open"
    }

    {id, %{"review_comments" => comments ++ [entry]}}
  end

  # reply/5 is `document` with a member's reply `text` added to the review comment `id`,
  # by the member named `by`, at `at`, and that review comment opened again:
  # `{:ok, document}`, or `:error` for an `id` the document does not have.
  @doc false
  @spec reply(document | nil, String.t(), String.t(), String.t(), DateTime.t()) ::
          {:ok, document} | :error
  def reply(document, id, text, by, %DateTime{} = at)
      when is_binary(id) and is_binary(text) and is_binary(by) do
    comments = entries(document)

    if Enum.any?(comments, &(&1["id"] == id)) do
      reply = %{"text" => text, "by" => %{"name" => by}, "at" => time(at)}

      comments =
        Enum.map(comments, fn
          %{"id" => ^id} = entry ->
            entry |> Map.put("replies", replies(entry) ++ [reply]) |> Map.put("state", "open")

          entry ->
            entry
        end)

      {:ok, %{"review_comments" => comments}}
    else
      :error
    end
  end

  # The next free id of the form `c<n>`, one past the highest such id.
  defp next_id(comments) do
    highest =
      comments
      |> Enum.flat_map(fn entry ->
        case Regex.run(~r/\Ac([0-9]{1,9})\z/, entry["id"] || "") do
          [_all, n] -> [String.to_integer(n)]
          nil -> []
        end
      end)
      |> Enum.max(fn -> 0 end)

    "c#{highest + 1}"
  end

  defp time(at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  # file/1 is `document` as the one file of a version of the review comments.
  @doc false
  @spec file(document) :: Artifacts.file()
  def file(document),
    do: %{
      filename: @type_name <> ".json",
      content_type: "application/json",
      binary: Jason.encode!(document)
    }
end
