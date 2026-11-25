defmodule Apiary.Artifacts.ChangeEntry do
  @moduledoc false

  # The `change_request` entry of an adapter's change feed (the integration contract's
  # `changes.schema.json`, `$defs.change_request`) for a stored version of a delivered
  # type, built from what the run stored and from the type's JSON Schema in the record of
  # the run's process version:
  #
  #   * `change_request_id` is the version's public id, `change_kind` its type's name;
  #   * `target` is the caller's `target`, the run's (`Apiary.Artifacts.Delivery`); where
  #     the caller has none, the stored `target`, as qory writes it into every delivered
  #     version, with its `collection` and its `address` (`system` and `path`) alone, the
  #     members the feed's entry has (`Apiary.Adapters.Feed`); the stored `target` stays
  #     in `data` as it is;
  #   * `title` is the stored member whose schema refers, through the `$defs` of the same
  #     schema, to the `title` of qory's primitives (`Apiary.Artifacts.HarnessPrimitives`),
  #     else the work item's title; `text` the member that refers to the primitives'
  #     `text`, else the empty text;
  #   * `ref` and `previous` come from the caller, and are left out when nil; `previous`
  #     keeps its `title` and its `address` (`url` and `ref`) alone;
  #   * `data` is what the run stored, with the commits that qory fills from the run's
  #     pushes (the member marked `x-qory-fill: pushed-commits`) cut to the newest 100.
  #     The member marked `pushed-commits-left-out` then counts the commits left out: the
  #     stored count, where the run stored one, plus those cut. The stored version keeps
  #     every commit.
  #
  # shortcut: where two members refer to the same primitive, the first by name is taken,
  # and only the members in the schema's top-level `properties` are read; replace when a
  # delivered type has its title or its text inside a nested object.

  @primitives "https://qory.dev/contracts/harness/v1/primitives.schema.json#/$defs/"
  @max_commits 100

  @doc """
  build/3 is `{:ok, entry}`, the entry as a map with string keys, for the stored
  `content` of a version, the delivered type's JSON Schema `schema` and `facts`:
  `change_request_id`, `change_kind`, `work_item_title`, and `target`, `ref` and
  `previous`, each nil or left out for none. `:no_target` when `content` has no `target`
  object: such a version gets no entry. The entry is not checked here
  (`Apiary.Adapters.ChangeRequest.validate/1`).
  """
  @spec build(map, map, map) :: {:ok, map} | :no_target
  def build(%{"target" => %{} = target} = content, schema, facts) when is_map(schema) do
    members = Map.get(schema, "properties", %{})

    entry =
      %{
        "kind" => "change_request",
        "change_request_id" => facts.change_request_id,
        "change_kind" => facts.change_kind,
        "target" =>
          Map.get(facts, :target) || closed(target, ["collection", "address"], ["system", "path"]),
        "title" => primitive(content, members, schema, "title") || facts.work_item_title,
        "text" => primitive(content, members, schema, "text") || "",
        "data" => cut_commits(content, members)
      }
      |> put_given("ref", Map.get(facts, :ref))
      |> put_given("previous", previous(Map.get(facts, :previous)))

    {:ok, entry}
  end

  def build(_content, _schema, _facts), do: :no_target

  @doc """
  title/2 is the title that `content`, stored as a version of the type with the JSON
  Schema `schema`, has in its member that refers to the primitives' `title`; nil where it
  has none.
  """
  @spec title(map, map) :: String.t() | nil
  def title(content, schema) when is_map(content) and is_map(schema),
    do: primitive(content, Map.get(schema, "properties", %{}), schema, "title")

  def title(_content, _schema), do: nil

  # The value in `content` of the first member, by name, whose schema refers to the
  # primitive `name`, where it is a string.
  defp primitive(content, members, schema, name) do
    members
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.find_value(fn {member, member_schema} ->
      with ^name <- refers_to(member_schema, schema, []),
           value when is_binary(value) <- content[member],
           do: value,
           else: (_other -> nil)
    end)
  end

  # The primitive that `member_schema` refers to, following the `$ref`s to the schema's
  # `$defs`, each once; nil for none.
  defp refers_to(%{"$ref" => @primitives <> name}, _schema, _seen), do: name

  defp refers_to(%{"$ref" => "#/$defs/" <> local}, schema, seen) do
    if local in seen,
      do: nil,
      else: refers_to(get_in(schema, ["$defs", local]), schema, [local | seen])
  end

  defp refers_to(_member_schema, _schema, _seen), do: nil

  # `content` with the commits the run pushed cut to the newest `@max_commits`, the last in
  # the list, and the count of those left out raised by the cut.
  defp cut_commits(content, members) do
    commits = filled(members, "pushed-commits")
    left_out = filled(members, "pushed-commits-left-out")

    case commits && content[commits] do
      list when is_list(list) and length(list) > @max_commits ->
        cut = length(list) - @max_commits
        content = Map.put(content, commits, Enum.drop(list, cut))

        if left_out,
          do: Map.put(content, left_out, count(content[left_out]) + cut),
          else: content

      _other ->
        content
    end
  end

  defp count(stored) when is_integer(stored) and stored > 0, do: stored
  defp count(_stored), do: 0

  # The name of the member whose schema has `x-qory-fill` set to `fill`; nil for none.
  defp filled(members, fill) do
    members
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.find_value(fn
      {member, %{"x-qory-fill" => ^fill}} -> member
      _other -> nil
    end)
  end

  defp previous(%{} = previous), do: closed(previous, ["title", "address"], ["url", "ref"])
  defp previous(previous), do: previous

  # `object` with the `members` alone, and its `address`, where it is an object, with the
  # `address_members` alone.
  defp closed(object, members, address_members) do
    case Map.take(object, members) do
      %{"address" => %{} = address} = taken ->
        %{taken | "address" => Map.take(address, address_members)}

      taken ->
        taken
    end
  end

  defp put_given(entry, _member, nil), do: entry
  defp put_given(entry, member, value), do: Map.put(entry, member, value)
end
