defmodule Apiary.Runs.About do
  @moduledoc """
  What a run says it is about, `about` of the contract: the kind of run, a title, the
  subjects it works on and details, every member optional. The rules are the contract's for
  `about` of `run.started` (`Apiary.Runs.Fold` states them).

  Two readings of the same rules. `read/1` is the fold's: lenient, member by member, so a
  stored event that breaks a rule keeps what it can and never makes the projection fail.
  `validate/1` is strict, for a body the server refuses whole when it breaks any rule
  (`Apiary.Runs.Registration`): a member the contract does not name, a string out of its
  bounds or holding a control character, a subject the fold would drop, cut or not keep
  first of its type and ref, and `details` the fold would drop. What `validate/1` accepts,
  `read/1` keeps whole.

  Pure: nothing here touches the database or logs.
  """

  @about_kind 64
  @about_title 256
  @max_subjects 16
  @subject_type ~r/\A[a-z0-9]+([ _.-][a-z0-9]+)*\z/
  @subject_type_bytes 64
  @subject_text 256
  @subject_url 2048
  @details_bytes 8192
  @details_depth 4
  @details_key 64
  # What no string of `about` holds, key or value, as `Apiary.Runs.Target` reads a label: C0
  # and DEL, C1, and the line and paragraph separators.
  @control ~r/[\x{00}-\x{1F}\x{7F}-\x{9F}\x{2028}\x{2029}]/u

  @members ~w(kind title subjects details)

  @typedoc "The four fields of a run that say what it is about."
  @type fields :: %{
          about_kind: String.t() | nil,
          about_title: String.t() | nil,
          about_subjects: [map],
          about_details: map | nil
        }

  @doc """
  The four fields of what the run is about, from `about` as sent: any term, read member by
  member, and nothing when it is not an object. Every one is set, so a later `run.started`
  replaces all of them.
  """
  @spec read(term) :: fields
  def read(about) do
    about = if is_map(about), do: about, else: %{}

    %{
      about_kind: bounded(about, "kind", @about_kind),
      about_title: bounded(about, "title", @about_title),
      about_subjects: subjects(about),
      about_details: details(about)
    }
  end

  @doc """
  `:ok` when `about`, as decoded, keeps every rule of the contract, else
  `{:error, detail}`: `detail` names the member and never repeats a value.
  """
  @spec validate(term) :: :ok | {:error, String.t()}
  def validate(%{} = about) do
    with :ok <- only(about, @members, "about"),
         :ok <- optional(about, "kind", &(bounded(about, "kind", @about_kind) == &1)),
         :ok <- optional(about, "title", &(bounded(about, "title", @about_title) == &1)),
         :ok <- valid_subjects(about) do
      optional(about, "details", fn details ->
        is_map(details) and details(about) == details
      end)
    end
  end

  def validate(_about), do: {:error, "about"}

  defp only(map, members, name) do
    if Enum.all?(Map.keys(map), &(&1 in members)), do: :ok, else: {:error, name}
  end

  defp optional(map, key, valid?) do
    case map do
      %{^key => value} -> if valid?.(value), do: :ok, else: {:error, "about." <> key}
      _ -> :ok
    end
  end

  # From 1 to 16 subjects, each kept whole by the fold, no two of one type and ref.
  defp valid_subjects(%{"subjects" => subjects})
       when is_list(subjects) and length(subjects) in 1..@max_subjects//1 do
    whole? = Enum.all?(subjects, &(is_map(&1) and subject(&1) == &1))

    if whole? and Enum.uniq_by(subjects, &{&1["type"], &1["ref"]}) == subjects,
      do: :ok,
      else: {:error, "about.subjects"}
  end

  defp valid_subjects(%{"subjects" => _subjects}), do: {:error, "about.subjects"}
  defp valid_subjects(_about), do: :ok

  # A string of 1 to `max` bytes with no control character, whole, or nil: never cut.
  defp bounded(data, key, max) do
    case data do
      %{^key => value} when is_binary(value) and byte_size(value) in 1..max//1 ->
        if clean?(value), do: value

      _ ->
        nil
    end
  end

  defp clean?(string), do: String.valid?(string) and not Regex.match?(@control, string)

  # Dropped one by one, then the first of each type and ref, then cut.
  defp subjects(%{"subjects" => subjects}) when is_list(subjects) do
    subjects
    |> Stream.map(&subject/1)
    |> Stream.reject(&is_nil/1)
    |> Stream.uniq_by(&{&1["type"], &1["ref"]})
    |> Enum.take(@max_subjects)
  end

  defp subjects(_about), do: []

  # A type and a ref, or no subject; a title or a url only when it keeps its bound. A
  # member the contract does not name is not kept.
  defp subject(%{} = subject) do
    with type when is_binary(type) <- bounded(subject, "type", @subject_type_bytes),
         true <- Regex.match?(@subject_type, type),
         ref when is_binary(ref) <- bounded(subject, "ref", @subject_text) do
      [{"url", url(subject)}, {"title", bounded(subject, "title", @subject_text)}]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
      |> Map.merge(%{"type" => type, "ref" => ref})
    else
      _ -> nil
    end
  end

  defp subject(_subject), do: nil

  # An absolute http or https url with a host and no user name or password, as given, or
  # nil.
  defp url(subject) do
    with url when is_binary(url) <- bounded(subject, "url", @subject_url),
         {:ok, %URI{scheme: scheme, host: host, userinfo: nil}}
         when scheme in ["http", "https"] and is_binary(host) and host != "" <- URI.new(url) do
      url
    else
      _ -> nil
    end
  end

  # An object within its bounds, whole, or nil.
  defp details(%{"details" => %{} = details}) do
    with true <- nested_within?(details, @details_depth),
         true <- clean_details?(details),
         {:ok, json} <- Jason.encode(details),
         true <- carried_size(json) <= @details_bytes do
      details
    else
      _ -> nil
    end
  end

  defp details(_about), do: nil

  # Whether `value` nests no deeper than `levels`. An object or an array is a level, the
  # outermost the first, as `Apiary.Runs.Batch` counts the depth of `data`.
  defp nested_within?(%{} = map, levels),
    do: levels > 0 and Enum.all?(Map.values(map), &nested_within?(&1, levels - 1))

  defp nested_within?(list, levels) when is_list(list),
    do: levels > 0 and Enum.all?(list, &nested_within?(&1, levels - 1))

  defp nested_within?(_value, _levels), do: true

  # Whether every key at every level is 1 to 64 bytes, and every key and string has no
  # control character.
  defp clean_details?(%{} = map) do
    Enum.all?(map, fn {key, value} ->
      byte_size(key) in 1..@details_key//1 and clean?(key) and clean_details?(value)
    end)
  end

  defp clean_details?(list) when is_list(list), do: Enum.all?(list, &clean_details?/1)
  defp clean_details?(string) when is_binary(string), do: clean?(string)
  defp clean_details?(_value), do: true

  # The bytes of compact JSON as the event carries it, `<`, `>` and `&` written as
  # `<`, `>` and `&`, six bytes each. They are counted here: Jason's
  # `html_safe` escape writes `<` alone of the three, and `/` as `\/` besides.
  defp carried_size(json),
    do: byte_size(json) + 5 * length(:binary.matches(json, ["<", ">", "&"]))
end
