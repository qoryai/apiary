defmodule ApiaryWeb.Contract.RunApi.FindingsBody do
  @moduledoc false

  # The body of `POST /v1/runs/<run_id>/findings`, as the run contract's
  # `findings-post.schema.json` has it, read from the raw bytes the request was signed
  # over, at most `max_bytes/0` bytes, else `{:error, :too_large}`.
  #
  # `{:ok, %{bases: [%{index, target, base}], events: [event]}}`, each event with `index`,
  # its place in `events`, and its members as atoms; a member the event does not have is
  # nil, and `place` has only the members the contract defines. `target` is the decoded
  # `{collection, address?}` object.
  #
  # A member the schema does not define is ignored, at any depth, unless `must_understand`
  # lists it: every pointer that `must_understand` may list is one this reader defines,
  # and any other is refused. Beside the schema, the contract's `FindingsPost.Check`
  # refuses two bases of one target and two raises with one `ref`. A refusal is
  # `{:error, :invalid_request, member}`, the path of the first member that failed, such
  # as `events[0].by`.

  @max_bytes 8 * 1024 * 1024
  @max_bases 20
  @max_events 100
  @max_pointers 32

  @kinds ~w(raise repeat reply_fixed reply_disputed close_fixed close_dismissed)
  @with_reason ~w(reply_fixed reply_disputed close_fixed close_dismissed)
  @finding_members ~w(ref target stage source severity place point problem fix proof)
  @source_kinds ~w(reviewer check criterion scenario hook)
  @severities ~w(blocking non-blocking)

  @ref ~r/\A[A-Za-z0-9._-]{1,64}\z/
  @id ~r/\Af[1-9][0-9]{0,8}\z/
  @stage ~r/\A[a-z0-9]+(-[a-z0-9]+)*\z/
  @version ~r/\A[A-Za-z0-9._\/-]{1,255}\z/
  @system ~r/\A[a-z0-9.-]{1,253}\z/
  # The integration contract's prose line and the run contract's `point`: no control or
  # format character but U+200C and U+200D, and no line or paragraph separator.
  @line ~r/\A(?:[^\p{Cc}\p{Cf}\x{2028}\x{2029}]|[\x{200C}\x{200D}])+\z/u
  @address_path ~r/\A[^\x00-\x1f\x7f{}]+\z/u

  # The pointers that `must_understand` may list, as the schema's pattern has them.
  @index "(?:0|[1-9][0-9]*)"
  @target_pointers ["", "/address", "/address/path", "/address/system", "/collection"]
  @event_members ~w(by fix id kind point problem proof reason ref severity stage version)
  @pointer Regex.compile!(
             "\\A(?:" <>
               Enum.join(
                 ["/bases", "/bases/#{@index}", "/bases/#{@index}/base"] ++
                   Enum.map(@target_pointers, &"/bases/#{@index}/target#{&1}") ++
                   ["/events", "/events/#{@index}"] ++
                   Enum.map(@event_members, &"/events/#{@index}/#{&1}") ++
                   Enum.map(
                     ~w(place place/file place/line place/quote place/version source
                        source/kind source/name),
                     &"/events/#{@index}/#{&1}"
                   ) ++
                   Enum.map(@target_pointers, &"/events/#{@index}/target#{&1}"),
                 "|"
               ) <> ")\\z"
           )

  @spec max_bytes() :: pos_integer
  def max_bytes, do: @max_bytes

  @spec post(binary) ::
          {:ok, %{bases: [map], events: [map]}}
          | {:error, :too_large}
          | {:error, :invalid_request, String.t()}
  def post(raw_body) when byte_size(raw_body) > @max_bytes, do: {:error, :too_large}

  def post(raw_body) do
    with {:ok, body} <- object(raw_body),
         :ok <- must_understand(Map.get(body, "must_understand", :absent)),
         {:ok, bases} <- bases(Map.get(body, "bases", [])),
         {:ok, events} <- events(Map.get(body, "events")) do
      {:ok, %{bases: bases, events: events}}
    end
  end

  defp object(raw_body) do
    case Jason.decode(raw_body) do
      {:ok, %{} = body} -> {:ok, body}
      _other -> invalid("body")
    end
  end

  defp must_understand(:absent), do: :ok

  defp must_understand(pointers)
       when is_list(pointers) and length(pointers) <= @max_pointers do
    if Enum.all?(pointers, &pointer?/1) and Enum.uniq(pointers) == pointers,
      do: :ok,
      else: invalid("must_understand")
  end

  defp must_understand(_pointers), do: invalid("must_understand")

  defp pointer?(pointer),
    do: is_binary(pointer) and byte_size(pointer) <= 256 and Regex.match?(@pointer, pointer)

  ## Bases

  defp bases(bases) when is_list(bases) and length(bases) <= @max_bases do
    bases
    |> Enum.with_index()
    |> each(fn {base, index} -> base(base, index) end)
    |> then(fn
      # One base per collection: the controller matches a target by its collection alone.
      {:ok, read} -> unique(read, & &1.target["collection"], &"bases[#{&1.index}].target")
      error -> error
    end)
  end

  defp bases(_bases), do: invalid("bases")

  defp base(%{} = base, index) do
    member = &"bases[#{index}].#{&1}"

    with {:ok, target} <- required(base, "target", &target?/1, member),
         {:ok, version} <- required(base, "base", &version?/1, member) do
      {:ok, %{index: index, target: target(target), base: version}}
    end
  end

  defp base(_base, index), do: invalid("bases[#{index}]")

  ## Events

  defp events(events) when is_list(events) and events != [] and length(events) <= @max_events do
    events
    |> Enum.with_index()
    |> each(fn {event, index} -> event(event, index) end)
    |> then(fn
      {:ok, read} ->
        with {:ok, _raises} <-
               unique(
                 Enum.filter(read, &(&1.kind == "raise")),
                 & &1.ref,
                 &"events[#{&1.index}].ref"
               ),
             do: {:ok, read}

      error ->
        error
    end)
  end

  defp events(_events), do: invalid("events")

  defp event(%{} = event, index) do
    member = &"events[#{index}].#{&1}"

    with {:ok, kind} <- required(event, "kind", &(&1 in @kinds), member),
         {:ok, by} <- required(event, "by", &line?(&1, 200), member),
         {:ok, version} <- optional(event, "version", &version?/1, member),
         {:ok, reason} <- reason(event, kind, member),
         {:ok, read} <- kind_members(event, kind, member) do
      {:ok,
       Map.merge(read, %{index: index, kind: kind, by: by, version: version, reason: reason})}
    end
  end

  defp event(_event, index), do: invalid("events[#{index}]")

  defp reason(event, kind, member) when kind in @with_reason,
    do: required(event, "reason", &text?(&1, 2000), member)

  defp reason(event, _kind, member), do: optional(event, "reason", &text?(&1, 2000), member)

  # A raise has the members of a new finding and no id; every other kind has an id and
  # none of those members.
  defp kind_members(event, "raise", member) do
    with :ok <- absent(event, ["id"], member),
         {:ok, ref} <- required(event, "ref", &form?(&1, @ref), member),
         {:ok, target} <- required(event, "target", &target?/1, member),
         {:ok, stage} <- required(event, "stage", &form?(&1, @stage, 64), member),
         {:ok, source} <- required(event, "source", &source?/1, member),
         {:ok, severity} <- required(event, "severity", &(&1 in @severities), member),
         {:ok, place} <- place(event, member),
         {:ok, point} <- required(event, "point", &line?(&1, 500), member),
         {:ok, problem} <- required(event, "problem", &text?(&1, 4000), member),
         {:ok, fix} <- required(event, "fix", &text?(&1, 4000), member),
         {:ok, proof} <- required(event, "proof", &text?(&1, 4000), member) do
      {:ok,
       %{
         ref: ref,
         id: nil,
         target: target(target),
         stage: stage,
         source_kind: source["kind"],
         source_name: source["name"],
         severity: severity,
         place: place,
         point: point,
         problem: problem,
         fix: fix,
         proof: proof
       }}
    end
  end

  defp kind_members(event, _kind, member) do
    with :ok <- absent(event, @finding_members, member),
         {:ok, id} <- required(event, "id", &form?(&1, @id), member) do
      {:ok, %{id: id, ref: nil}}
    end
  end

  defp absent(event, members, member) do
    case Enum.find(members, &Map.has_key?(event, &1)) do
      nil -> :ok
      present -> invalid(member.(present))
    end
  end

  defp source?(%{"kind" => kind, "name" => name}),
    do: kind in @source_kinds and line?(name, 200)

  defp source?(_source), do: false

  # The place, with only the members the contract defines: `quote`, and `file`, `line`
  # and `version` where the event has them. A `line` needs a `file`.
  defp place(event, member) do
    with {:ok, %{} = place} <- required(event, "place", &is_map/1, member),
         {:ok, quote} <- required(place, "quote", &text?(&1, 2000), &member.("place." <> &1)),
         {:ok, file} <- optional(place, "file", &line?(&1, 300), &member.("place." <> &1)),
         {:ok, line} <-
           optional(place, "line", &(is_integer(&1) and &1 >= 1), &member.("place." <> &1)),
         {:ok, version} <- optional(place, "version", &version?/1, &member.("place." <> &1)),
         :ok <- if(line && is_nil(file), do: invalid(member.("place.file")), else: :ok) do
      {:ok,
       for(
         {key, value} <- [{"quote", quote}, {"file", file}, {"line", line}, {"version", version}],
         value != nil,
         into: %{},
         do: {key, value}
       )}
    end
  end

  ## Members

  # The target `{collection, address?}` with only those members.
  defp target(%{"collection" => collection} = target) do
    case target["address"] do
      %{"system" => system, "path" => path} ->
        %{"collection" => collection, "address" => %{"system" => system, "path" => path}}

      nil ->
        %{"collection" => collection}
    end
  end

  defp target?(%{"collection" => collection} = target) do
    text?(collection, 200) and
      case Map.fetch(target, "address") do
        :error ->
          true

        {:ok, %{"system" => system, "path" => path}} ->
          form?(system, @system) and is_binary(path) and length_in(path, 1, 200) and
            Regex.match?(@address_path, path)

        {:ok, _other} ->
          false
      end
  end

  defp target?(_target), do: false

  defp version?(value), do: form?(value, @version)

  defp form?(value, pattern, max \\ nil),
    do:
      is_binary(value) and String.valid?(value) and Regex.match?(pattern, value) and
        (is_nil(max) or length_in(value, 1, max))

  # A line: 1 to `max` code points, with no control or format character.
  defp line?(value, max),
    do: is_binary(value) and length_in(value, 1, max) and Regex.match?(@line, value)

  # A text: 1 to `max` code points, without U+0000.
  defp text?(value, max),
    do: is_binary(value) and length_in(value, 1, max) and not String.contains?(value, <<0>>)

  # The length counted in code points, never graphemes.
  defp length_in(value, min, max) do
    String.valid?(value) and length(String.codepoints(value)) in min..max//1
  end

  defp required(map, key, valid?, member) do
    case Map.fetch(map, key) do
      {:ok, value} -> if valid?.(value), do: {:ok, value}, else: invalid(member.(key))
      :error -> invalid(member.(key))
    end
  end

  defp optional(map, key, valid?, member) do
    case Map.fetch(map, key) do
      {:ok, value} -> if valid?.(value), do: {:ok, value}, else: invalid(member.(key))
      :error -> {:ok, nil}
    end
  end

  defp each(entries, read) do
    entries
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, done} ->
      case read.(entry) do
        {:ok, value} -> {:cont, {:ok, [value | done]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, done} -> {:ok, Enum.reverse(done)}
      error -> error
    end
  end

  # The entries, where no two have the same `key`; the second of two is refused.
  defp unique(entries, key, member) do
    entries
    |> Enum.reduce_while(MapSet.new(), fn entry, seen ->
      if MapSet.member?(seen, key.(entry)),
        do: {:halt, invalid(member.(entry))},
        else: {:cont, MapSet.put(seen, key.(entry))}
    end)
    |> case do
      %MapSet{} -> {:ok, entries}
      error -> error
    end
  end

  defp invalid(member), do: {:error, :invalid_request, member}
end
