defmodule Apiary.Dispatches.Inputs do
  @moduledoc false

  # The input of a step, `inputs` of the provisioner contract's `handover-answer.schema.json`,
  # which Qory writes at the handover (`Apiary.Dispatches.Handover`) and the job reads.
  #
  # - `prebuild/1`: exactly `{"version": 1, "environment_ref": ref}`, as the contract closes
  #   it, the ref the run of the queue was queued for (`dispatch_runs.environment_ref`),
  #   which the job reports back, unchanged, in its `prebuilt`.
  # - `explore/3`: the explore contract's `inputs.schema.json`, version 1, every member in
  #   the schema's order, from the rows Qory keeps and nothing the starter sent:
  #   - `work_item`: its public id, its number and its address (`Apiary.WorkItems.stable_url/1`);
  #   - `run`: the run's `attempt` and `of`;
  #   - `ticket`: the ticket as the work item kept it when it was taken in, its ref, its
  #     address, its title and its collection's title, and as the ticket's row holds it now,
  #     its text, who filed it and when (`Apiary.Sources.Item`);
  #   - `instruction`: the work item's first instruction, empty for none, who took it in and
  #     when. Who took it in is named by their account: the local part of its email
  #     address (`Apiary.Accounts.User.short_name/1`), or the fixed words `former member`
  #     for an account deleted. The words are data on the wire, never translated;
  #   - `comments`: the ticket's comments not deleted at their source, oldest first, each
  #     with its author as the source named them, when it was written there and its text.
  #     The names the source gave, who filed the ticket and who wrote each comment, are the
  #     integration contract's `person` names: 1 to 100 characters, which may hold a tab
  #     or a line break but never U+0000. Their columns already hold them to that
  #     (`Apiary.Sources.Item`, `Apiary.Sources.Comment`);
  #   - `comments_omitted`: how many of the oldest were left out to keep the input within
  #     `max_bytes/0`, 768 KiB encoded, 0 for none;
  #   - `answers`: the answers given within the run's take in, oldest first
  #     (`Apiary.WorkItems.take_in_answers/2`), each with who gave it, named as who took
  #     the work item in is named and held to the same rule;
  #   - `target`: the run's target, the handover answer's `target`, left out where the
  #     work item has none;
  #   - `domain`: the name of the workspace's domain, the handover answer's `domain`.
  #
  #   The handover gives the target and the domain (`Apiary.Dispatches.Handover`), the
  #   same values it writes into its answer.
  #
  #   Every time is in UTC to the whole second, and every length is counted in code
  #   points, as the contract counts it. The answer is `{:ok, inputs}`, a
  #   `Jason.OrderedObject`, or `{:error, :ticket_gone}` when the work item's ticket is no
  #   longer kept, or `{:error, :inputs_invalid}` when a value breaks the contract's rule for
  #   it and no input can be formed: an address that is not the contract's URL, a first
  #   instruction or a name that holds a character the contract refuses, or is too long.
  #   Nothing is cut or cleaned: a run is never given an input other than the one Qory
  #   keeps.
  #
  # Reads, never writes, and logs nothing.

  import Ecto.Query, only: [from: 2]

  alias Apiary.{Repo, WorkItems}
  alias Apiary.Accounts.User
  alias Apiary.Adapters.Wire, as: AdapterWire
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Sources.{Comment, Item}
  alias Apiary.WorkItems.WorkItem

  @version 1
  # The most bytes the input takes, encoded: 768 KiB.
  @max_bytes 786_432
  # The words for a person whose account is deleted, as the input names them.
  @former_member "former member"
  # explore/v1 inputs.schema.json: `$defs/member` name, 1 to 160 characters on one line.
  @max_name 160
  # result.schema.json `$defs/text`: the characters a text refuses; a name refuses tab,
  # line feed and carriage return besides.
  @refused_in_text ~r/[\x{0}-\x{8}\x{B}\x{C}\x{E}-\x{1F}\x{7F}-\x{9F}\x{AD}\x{61C}\x{180E}\x{200B}\x{200E}\x{200F}\x{2028}\x{2029}\x{202A}-\x{202E}\x{2060}-\x{2064}\x{2066}-\x{2069}\x{FEFF}\x{FFF9}-\x{FFFB}]/u
  @refused_in_name ~r/[\x{9}\x{A}\x{D}]/u
  @max_instruction 4000

  # max_bytes/0 is the most bytes an input takes, encoded.
  @doc false
  @spec max_bytes() :: pos_integer
  def max_bytes, do: @max_bytes

  # former_member/0 is the words the input names a person by whose account is deleted.
  @doc false
  @spec former_member() :: String.t()
  def former_member, do: @former_member

  # prebuild/1 is the input of a prebuild queued for `environment_ref`, exactly
  # `{"version": 1, "environment_ref": environment_ref}`.
  @doc false
  @spec prebuild(String.t()) :: Jason.OrderedObject.t()
  def prebuild(environment_ref) when is_binary(environment_ref),
    do: Jason.OrderedObject.new([{"version", @version}, {"environment_ref", environment_ref}])

  # explore/4 is the input of the explore run `dispatch_run` of `work_item`, for the run's
  # `target`, nil for none, and the name of its workspace's `domain` (the moduledoc), within
  # `budget` bytes encoded, `max_bytes/0` at most: the handover gives the budget the
  # handover answer's limit leaves (`Apiary.Dispatches.Handover`). An input that cannot be
  # within a budget below `max_bytes/0`, with every comment left out, is
  # `{:error, :answer_too_large}`, and within `max_bytes/0`, `{:error, :inputs_invalid}`.
  @doc false
  @spec explore(
          WorkItem.t(),
          DispatchRun.t(),
          %{
            domain: String.t(),
            target: %{system: String.t(), path: String.t()} | nil
          },
          pos_integer
        ) ::
          {:ok, Jason.OrderedObject.t()}
          | {:error, :ticket_gone | :inputs_invalid | :answer_too_large}
  def explore(
        %WorkItem{} = work_item,
        %DispatchRun{} = dispatch_run,
        %{domain: domain, target: target} = run,
        budget \\ @max_bytes
      )
      when is_binary(domain) and (is_nil(target) or is_map(target)) and is_integer(budget) and
             budget > 0 do
    budget = min(budget, @max_bytes)

    with {:ok, item} <- ticket(work_item),
         {:ok, by} <- taken_in_by(work_item),
         :ok <- valid(work_item),
         {:ok, answers} <- answers(work_item, dispatch_run) do
      comments = Enum.map(comments(item), &comment/1)
      document = &document(work_item, dispatch_run, item, by, answers, run, &1, &2)
      inputs = bounded(document, comments, budget)

      # Every comment left out, the rest is within `max_bytes/0` by the columns' bounds; held
      # all the same, and within a smaller budget only when the rest fits it.
      size = encoded_size(inputs)

      cond do
        size <= budget -> {:ok, inputs}
        size <= @max_bytes -> {:error, :answer_too_large}
        true -> {:error, :inputs_invalid}
      end
    end
  end

  defp ticket(%WorkItem{item_id: nil}), do: {:error, :ticket_gone}

  defp ticket(%WorkItem{item_id: item_id}) do
    case Repo.get(Item, item_id) do
      nil -> {:error, :ticket_gone}
      item -> {:ok, item}
    end
  end

  # Who took the work item in, by their account.
  defp taken_in_by(%WorkItem{taken_in_by_id: id}) do
    name = person_name(id)
    if name?(name), do: {:ok, name}, else: {:error, :inputs_invalid}
  end

  # person_name/1 is the name the input gives the person whose account is `id`: the local
  # part of its email address, or the fixed words `former member` for an account deleted,
  # or for none.
  @doc false
  @spec person_name(Ecto.UUID.t() | nil) :: String.t()
  def person_name(id) do
    case id && Repo.get(User, id) do
      %User{deleted_at: nil, email: email} when is_binary(email) -> User.short_name(email)
      _deleted -> @former_member
    end
  end

  # The answers of the run's take in, read once, each with a name the contract takes.
  defp answers(work_item, %DispatchRun{take_in: take_in}) do
    answers = WorkItems.take_in_answers(work_item, take_in)

    if Enum.all?(answers, &name?(&1["by"]["name"])),
      do: {:ok, answers},
      else: {:error, :inputs_invalid}
  end

  defp name?(name),
    do:
      code_points(name) in 1..@max_name and not Regex.match?(@refused_in_text, name) and
        not Regex.match?(@refused_in_name, name)

  # What the database does not hold to the contract's rules already.
  defp valid(%WorkItem{url: url, first_instruction: instruction}) do
    instruction = instruction || ""

    if AdapterWire.url?(url) and code_points(instruction) <= @max_instruction and
         not Regex.match?(@refused_in_text, instruction),
       do: :ok,
       else: {:error, :inputs_invalid}
  end

  # The length the contract counts: code points, never graphemes.
  defp code_points(text), do: text |> String.codepoints() |> length()

  defp comments(%Item{id: item_id}) do
    Repo.all(
      from c in Comment,
        where: c.item_id == ^item_id and is_nil(c.deleted_at),
        order_by: [asc: c.source_created_at, asc: c.inserted_at, asc: c.id]
    )
  end

  defp comment(%Comment{} = comment) do
    Jason.OrderedObject.new([
      {"by", person(comment.author_name, comment.author_kind)},
      {"at", time(comment.source_created_at)},
      {"body", comment.body}
    ])
  end

  defp person(name, kind),
    do: Jason.OrderedObject.new([{"name", name}, {"kind", Atom.to_string(kind)}])

  defp document(work_item, dispatch_run, item, by, answers, run, comments, omitted) do
    Jason.OrderedObject.new(
      [
        {"version", @version},
        {"work_item",
         Jason.OrderedObject.new([
           {"id", work_item.public_id},
           {"number", work_item.number},
           {"url", WorkItems.stable_url(work_item)}
         ])},
        {"run",
         Jason.OrderedObject.new([{"attempt", dispatch_run.attempt}, {"of", dispatch_run.of}])},
        {"ticket",
         Jason.OrderedObject.new([
           {"external_ref", work_item.external_ref},
           {"url", work_item.url},
           {"title", work_item.title},
           {"body", item.body},
           {"filed_by", person(item.filed_by_name, item.filed_by_kind)},
           {"filed_at", time(item.source_created_at)},
           {"collection", work_item.collection_title}
         ])},
        {"instruction",
         Jason.OrderedObject.new([
           {"text", work_item.first_instruction || ""},
           {"by", Jason.OrderedObject.new([{"name", by}])},
           {"at", time(work_item.taken_in_at)}
         ])},
        {"comments", comments},
        {"comments_omitted", omitted},
        {"answers", answers}
      ] ++ target(run.target) ++ [{"domain", run.domain}]
    )
  end

  defp target(nil), do: []

  defp target(%{system: system, path: path}),
    do: [{"target", Jason.OrderedObject.new([{"system", system}, {"path", path}])}]

  # The document with every comment that fits, the newest kept: the fewest oldest left out
  # for the whole to be at most `max` bytes encoded. Each comment's size is counted once;
  # the document is then encoded again to hold the count, which only adds a comment more
  # left out should a digit of `comments_omitted` tip it over.
  defp bounded(document, comments, max) do
    sizes = Enum.map(comments, &encoded_size/1)
    empty = encoded_size(document.([], 0))
    count = length(comments)
    # The comments from the `k`th on, with the commas between them.
    total = Enum.sum(sizes) + max(count - 1, 0)

    omitted =
      sizes
      |> Enum.reduce_while({0, total}, fn size, {k, kept} ->
        if empty + digits(k) - 1 + kept <= max,
          do: {:halt, {k, kept}},
          else: {:cont, {k + 1, kept - size - if(k + 1 < count, do: 1, else: 0)}}
      end)
      |> elem(0)

    fit(document, comments, omitted, max)
  end

  defp fit(document, comments, omitted, max) do
    built = document.(Enum.drop(comments, omitted), omitted)

    if encoded_size(built) <= max or omitted >= length(comments),
      do: built,
      else: fit(document, comments, omitted + 1, max)
  end

  defp encoded_size(term), do: term |> Jason.encode_to_iodata!() |> IO.iodata_length()

  defp digits(n), do: n |> Integer.to_string() |> byte_size()

  defp time(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
